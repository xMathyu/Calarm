//
//  SharedRemindersService.swift
//  Calarm
//
//  Sharing of alarms and countdowns.
//
//  Since 1.1 new shares live in Firestore (`SharedRemindersService+Firestore`),
//  so an iPhone can share with an Android phone. This file keeps the CloudKit
//  side that existing shares still need: invitations already sent (`/i/`, `/c/`
//  links) keep working, received CloudKit shares keep syncing until their owner
//  migrates them, and an owner keeps writing to the CloudKit record while it has
//  a `CKShare` (see «Migración desde CloudKit» in calarmi-firebase/DESIGN.md).
//
//  SwiftData persists Reminders to a CloudKit private database via NSPersistentCloudKitContainer
//  under the hood; that sync of the person's own alarms is untouched.
//

import CloudKit
import FirebaseFirestore
import Foundation
import Observation
import os
import SwiftData
import SwiftUI
import UIKit

/// Errors thrown while preparing or accepting a share.
enum SharedRemindersError: LocalizedError {
    case noCloudKitAccount
    case shareUnavailable
    case shareURLUnavailable
    case shareCreationFailed(any Error)
    case acceptFailed(any Error)
    /// Compilación sin `GoogleService-Info.plist`: Firebase no arrancó.
    case firebaseUnavailable
    case signInFailed(any Error)
    /// Firestore exige el nombre de quien comparte o se une (lo ven los demás).
    case nameRequired
    /// La invitación no existe, se revocó o no es de un tipo que esta versión entienda.
    case inviteInvalid
    /// El share existe pero lo creó otra sesión (otro dispositivo de la cuenta).
    case notShareOwner

    var errorDescription: String? {
        switch self {
        case .noCloudKitAccount:
            return "Inicia sesión en iCloud para compartir alarmas."
        case .shareUnavailable:
            return "No se pudo preparar la alarma para compartirla."
        case .shareURLUnavailable:
            return "iCloud preparó el compartido, pero no devolvió un enlace de invitación. Intenta nuevamente."
        case .shareCreationFailed(let error):
            return "Error al compartir: \(error.localizedDescription)"
        case .acceptFailed(let error):
            return "Error al aceptar la invitación: \(error.localizedDescription)"
        case .firebaseUnavailable:
            return appLocalized("Compartir no está disponible en esta versión de la app.")
        case .signInFailed(let error):
            return appLocalized("No se pudo conectar para compartir: \(error.localizedDescription)")
        case .nameRequired:
            return appLocalized("Primero escribe tu nombre: así te verán las personas con quienes compartes.")
        case .inviteInvalid:
            return appLocalized("Esta invitación ya no es válida. Pide que te la envíen otra vez.")
        case .notShareOwner:
            return appLocalized("Esta alarma se compartió desde otro dispositivo. Invita desde ese dispositivo.")
        }
    }
}

/// Who shared a received alarm, with enough info to look up their Contacts photo.
struct SharedByPerson: Equatable {
    var name: String
    var email: String?
    var phone: String?
}

/// A share participant rendered for the UI: who they are and whether they joined.
struct ShareParticipantInfo: Identifiable {
    let id = UUID()
    var name: String
    let email: String?
    let phone: String?
    let status: CKShare.ParticipantAcceptanceStatus
    let isOwner: Bool
    /// Stable CloudKit user id — link-joined (public) participants often carry
    /// no email/phone in `lookupInfo`, so removal matches on this first.
    var userRecordName: String? = nil
    /// The participant's id in this share, the same on both sides: the key of
    /// the name they published themselves (`ShareNames`).
    var participantID: String? = nil
    /// False while `name` is only the «Alguien» placeholder.
    var hasName: Bool = true
    /// Firestore member (or trusted helper): their anonymous uid, the key to
    /// remove them. Nil for a CloudKit participant.
    var firebaseUID: String? = nil

    /// Localized acceptance label, e.g. "Aceptó" / "Pendiente".
    var statusLabel: String {
        switch status {
        case .accepted: return appLocalized("Aceptó")
        case .pending: return appLocalized("Pendiente")
        case .removed: return appLocalized("Eliminado")
        case .unknown: return appLocalized("Desconocido")
        @unknown default: return appLocalized("Desconocido")
        }
    }
}

/// Owns the CloudKit container and shares-related state. Created once at app launch.
@Observable
@MainActor
final class SharedRemindersService {
    let containerIdentifier: String
    // Internal (not private): `SharedRemindersService+Countdowns.swift` shares them.
    let cloudKitContainer: CKContainer
    let modelContainer: ModelContainer
    /// Cancels the alarms of received shares the owner deleted.
    private let scheduler: ReminderScheduler

    /// Latest error message surfaced to the UI when an operation fails.
    private(set) var lastErrorMessage: String?
    /// Set when accepting an incoming invitation fails, so the app can alert the
    /// user instead of leaving them staring at a list that never updates.
    private(set) var acceptErrorMessage: String?

    /// What the person sees while an invitation they opened becomes an alarm on
    /// their list, and right after (the toast in `ContentView`). Accepting takes
    /// a few CloudKit round trips — a few seconds with nothing on screen otherwise.
    enum IncomingShareStatus: Equatable {
        case accepting
        case accepted(reminderID: UUID, title: String, ownerName: String?)
        /// Same two steps for an invitation to a countdown.
        case acceptingCountdown
        case acceptedCountdown(id: UUID, title: String, ownerName: String?)

        var isAccepting: Bool { self == .accepting || self == .acceptingCountdown }
    }
    var incomingShare: IncomingShareStatus?

    /// The person has no name yet: `ContentView` shows the «¿Cómo te llamas?»
    /// sheet, which can't be dismissed without one. Without it, whoever shares
    /// with them sees «Alguien»: iCloud never gives the name of someone who
    /// joined through the invitation link (see `ShareNames`). New people set it
    /// in the onboarding; this catches everyone who was already using the app.
    var asksForName = false

    /// Re-checked on launch, on every return to the app and when iCloud brings
    /// a name set on another device (which closes the sheet).
    func refreshNameRequirement() {
        asksForName = ShareNames.myName == nil
    }
    /// Shares joined while the person had no name yet: it gets published there
    /// as soon as they type it.
    @ObservationIgnored private var sharesAwaitingName: [CKShare] = []
    /// Received shares whose name publishing already ran this session, so the
    /// scan doesn't fetch them again every time.
    @ObservationIgnored private var namedShareIDs: Set<CKRecord.ID> = []

    /// Right after joining a share (alarm, countdown or trusted-people list):
    /// publish this person's name there, or ask for it.
    func announceMyself(in share: CKShare) {
        guard ShareNames.myName != nil else {
            sharesAwaitingName.append(share)
            asksForName = true
            return
        }
        Task { await ShareNames.publishMine(in: [share], container: cloudKitContainer) }
    }

    /// The name typed in the alert or in Settings: saved, then published on
    /// every share this person is in (the scan finds the received ones).
    func saveMyName(_ name: String) async {
        await ShareNames.setMyName(name, container: cloudKitContainer)
        asksForName = ShareNames.myName == nil
        let waiting = sharesAwaitingName
        sharesAwaitingName = []
        namedShareIDs = []
        await ShareNames.publishMine(in: waiting, container: cloudKitContainer)
        // En Firestore el nombre va en cada share y lista de confianza (lo leen
        // los demás de ahí, también desde Android).
        await propagateMyNameToFirestore()
        // Las invitaciones que esperaban el nombre para poder unirse.
        let pending = invitesAwaitingName
        invitesAwaitingName = []
        for token in pending {
            await resumeInvite?(token)
        }
        await importAllSharedReminders()
    }

    /// Invitaciones de Firestore abiertas sin nombre puesto: unirse exige uno
    /// (las reglas lo piden), así que esperan a que la persona lo escriba.
    @ObservationIgnored var invitesAwaitingName: [String] = []
    /// Vuelve a abrir una invitación de Firestore (por su token). Lo pone
    /// `CalarmApp`, que sabe repartir entre alarmas, cuentas y personas de confianza.
    @ObservationIgnored var resumeInvite: ((String) async -> Void)?
    /// La escucha de `shares where memberUids array-contains uid` mientras la
    /// app está en pantalla (ver `startFirestoreListener`).
    @ObservationIgnored var firestoreListener: (any ListenerRegistration)?
    /// Pide el escaneo de CloudKit en la próxima pasada (`importAllSharedReminders`).
    @ObservationIgnored var wantsCloudKitScan = false
    /// La próxima pasada lee Firestore del servidor. Si solo la pidió la escucha
    /// (que ya trajo lo último a la caché), lee la caché y no cuesta lecturas.
    @ObservationIgnored var wantsFirestoreServerRead = false

    /// After a scan: this person's name goes on every received share they're
    /// in. The share records usually come with the zone's changes; any that
    /// didn't are fetched once per session. With no name yet, it's asked once.
    private func publishMyName(found shares: [CKShare], referenced shareIDs: Set<CKRecord.ID>) async {
        guard !shareIDs.isEmpty || !shares.isEmpty else { return }
        guard ShareNames.myName != nil else {
            asksForName = true
            return
        }
        var all = shares.filter { !namedShareIDs.contains($0.recordID) }
        let missing = shareIDs.subtracting(shares.map(\.recordID)).subtracting(namedShareIDs)
        if !missing.isEmpty,
           let fetched = try? await cloudKitContainer.sharedCloudDatabase.records(for: Array(missing)) {
            all += fetched.values.compactMap { try? $0.get() as? CKShare }
        }
        guard !all.isEmpty else { return }
        namedShareIDs.formUnion(all.map(\.recordID))
        await ShareNames.publishMine(in: all, container: cloudKitContainer)
    }

    /// Invitations just accepted. A scan that listed the shared zones before
    /// `accept()` finished — or right after, while CloudKit still catches up —
    /// doesn't see the new zone, so without this it would take the freshly
    /// ingested copy for one the owner deleted and remove it.
    @ObservationIgnored var acceptingIDs: Set<UUID> = []

    /// The scan in progress. A request that arrives meanwhile waits for it and
    /// gets one more pass (`rescanRequested`) instead of starting its own.
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var rescanRequested = false

    /// Who shared each received alarm, as iCloud reported it during this
    /// session. Memory only: Apple's iCloud Extended Share Access entitlement,
    /// which makes these names readable at all, allows showing them but not
    /// storing them. (Firestore names are the app's own data and are also
    /// kept in `FirestoreShareStore`.)
    @ObservationIgnored var ownerNames: [UUID: SharedByPerson] = [:]

    static let log = Logger(subsystem: "MathyuSolutions.Calarm", category: "sharing")

    /// Internal (not private): the Firestore extension cancels alarms too.
    var reminderScheduler: ReminderScheduler { scheduler }

    init(modelContainer: ModelContainer, scheduler: ReminderScheduler, containerIdentifier: String = "iCloud.MathyuSolutions.Calarm") {
        self.modelContainer = modelContainer
        self.scheduler = scheduler
        self.containerIdentifier = containerIdentifier
        self.cloudKitContainer = CKContainer(identifier: containerIdentifier)
        // Older builds saved the owners' names here; see `ownerNames`.
        UserDefaults.standard.removeObject(forKey: "calarm.shareOwners")
    }

    func clearAcceptError() {
        acceptErrorMessage = nil
    }

    /// Shows the «agregando…» toast from the moment the invitation link is
    /// opened, before its metadata is even fetched.
    func beginAcceptingShare(countdown: Bool = false) {
        incomingShare = countdown ? .acceptingCountdown : .accepting
    }

    func clearIncomingShare() {
        incomingShare = nil
    }

    /// An invitation that failed before reaching `acceptShare` (the link's
    /// metadata couldn't be fetched: expired, revoked, offline). Same alert.
    func reportAcceptFailure(_ error: any Error) {
        incomingShare = nil
        let wrapped = error as? SharedRemindersError ?? .acceptFailed(error)
        acceptErrorMessage = wrapped.errorDescription
    }

    // MARK: - Owner side

    // New invitations are Firestore shares (`prepareFirestoreInvite`). The
    // CloudKit share of an alarm shared before 1.1 is still read here: its
    // participants show in «Personas», and it gets every edit while it exists.

    /// Returns the existing `CKShare` for a reminder WITHOUT creating one, or
    /// `nil` if it hasn't been shared yet. Lets the detail view decide whether
    /// to offer "manage sharing".
    func existingShare(for reminder: Reminder) async -> CKShare? {
        let zoneID = CKRecordZone.ID(zoneName: Self.sharingZoneName, ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: reminder.id.uuidString, zoneID: zoneID)
        return try? await fetchExistingShare(for: recordID)
    }

    /// Returns participants currently associated with the share (for the RSVP UI).
    func participants(of share: CKShare) -> [CKShare.Participant] {
        share.participants
    }

    /// Display-friendly participants of a share (name, contact handle, acceptance
    /// status), for showing who has joined inline in the owner's detail view.
    func participantInfos(of share: CKShare) -> [ShareParticipantInfo] {
        share.participants.map { participant in
            let known = Self.knownDisplayName(participant.userIdentity)
            return ShareParticipantInfo(
                name: known ?? appLocalized("Alguien"),
                email: participant.userIdentity.lookupInfo?.emailAddress,
                phone: participant.userIdentity.lookupInfo?.phoneNumber,
                status: participant.acceptanceStatus,
                isOwner: participant.role == .owner,
                userRecordName: participant.userIdentity.userRecordID?.recordName,
                participantID: participant.participantID,
                hasName: known != nil
            )
        }
    }

    /// Same, filling in the name each person published for themselves wherever
    /// iCloud gave none (people who joined through the invitation link always
    /// arrive nameless). Also publishes this person's own name for the share,
    /// so the people on the other side see who shared it.
    func namedParticipantInfos(of share: CKShare) async -> [ShareParticipantInfo] {
        Task { await ShareNames.publishMine(in: [share], container: cloudKitContainer) }
        var infos = participantInfos(of: share)
        let nameless = infos.compactMap { info -> (participantID: String, userRecordName: String?)? in
            guard !info.hasName, let id = info.participantID else { return nil }
            return (id, info.userRecordName)
        }
        let published = await ShareNames.names(for: nameless, container: cloudKitContainer)
        for index in infos.indices {
            if let id = infos[index].participantID, let name = published[id] {
                infos[index].name = name
                infos[index].hasName = true
            }
        }
        return infos
    }

    /// Who shared what was just accepted, when iCloud didn't say: the name the
    /// owner published, kept in memory like the rest of `ownerNames`.
    func rememberOwner(of share: CKShare, for id: UUID) {
        guard ownerNames[id] == nil else { return }
        Task {
            if let owner = await ownerPerson(of: share) { ownerNames[id] = owner }
        }
    }

    /// A share's owner as a person to show, from iCloud or, failing that, from
    /// the name they published themselves (`ShareNames`).
    func ownerPerson(of share: CKShare) async -> SharedByPerson? {
        if let owner = Self.person(share.owner.userIdentity) { return owner }
        let published = await ShareNames.names(
            for: [(share.owner.participantID, share.owner.userIdentity.userRecordID?.recordName)],
            container: cloudKitContainer
        )
        return published[share.owner.participantID].map { SharedByPerson(name: $0, email: nil, phone: nil) }
    }

    /// A share's owner as a person to show (recipient side), or nil when iCloud
    /// gave no name, email or phone.
    static func person(_ identity: CKUserIdentity) -> SharedByPerson? {
        guard let name = knownDisplayName(identity) else { return nil }
        return SharedByPerson(
            name: name,
            email: identity.lookupInfo?.emailAddress,
            phone: identity.lookupInfo?.phoneNumber
        )
    }

    /// Who shared a received alarm. Read from iCloud the first time it's asked
    /// in a session, then from memory. Nil when it can't be read (offline, the
    /// owner deleted it) or iCloud gives no name.
    func owner(ofReceived id: UUID) async -> SharedByPerson? {
        if let known = ownerNames[id] { return known }
        // De Firestore: el nombre viene en el share y la app lo guarda.
        if let entry = FirestoreShareStore.received(id) {
            return entry.ownerName.map { SharedByPerson(name: $0, email: nil, phone: nil) }
        }
        guard let record = try? await receivedRecord(id: id) else { return nil }
        return await owner(of: record)
    }

    /// Reads the owner from the share `record` hangs from, and keeps it in memory.
    func owner(of record: CKRecord) async -> SharedByPerson? {
        guard let shareID = record.share?.recordID,
              let share = try? await cloudKitContainer.sharedCloudDatabase.record(for: shareID) as? CKShare,
              let owner = await ownerPerson(of: share)
        else { return nil }
        ownerNames[candidateLocalID(for: record)] = owner
        return owner
    }

    /// Best-effort human name for a CloudKit identity: full name if shared,
    /// otherwise the email/phone, otherwise a generic placeholder.
    static func displayName(_ identity: CKUserIdentity?) -> String {
        knownDisplayName(identity) ?? appLocalized("Alguien")
    }

    /// Same, but nil when iCloud shared nothing usable (no name, email or phone),
    /// for places where a placeholder reads worse than saying nothing.
    static func knownDisplayName(_ identity: CKUserIdentity?) -> String? {
        if let components = identity?.nameComponents {
            let formatted = PersonNameComponentsFormatter().string(from: components)
            if !formatted.isEmpty { return formatted }
        }
        if let email = identity?.lookupInfo?.emailAddress, !email.isEmpty { return email }
        if let phone = identity?.lookupInfo?.phoneNumber, !phone.isEmpty { return phone }
        return nil
    }

    /// Stops sharing — removes the share record from CloudKit. The owner's local Reminder stays.
    func stopSharing(_ share: CKShare) async throws {
        let database = cloudKitContainer.privateCloudDatabase
        do {
            _ = try await database.modifyRecords(saving: [], deleting: [share.recordID])
        } catch {
            throw SharedRemindersError.shareCreationFailed(error)
        }
    }

    /// If the owner edited a shared reminder, re-write its envelope onto the
    /// existing shared record so participants pick up the change (via push, or
    /// their next scan). No-op for received shares or reminders that aren't shared.
    func pushUpdateIfShared(_ reminder: Reminder) async {
        guard !reminder.isReceivedShare else { return }
        // Firestore: solo si esta sesión es la dueña (lo creó o lo migró aquí).
        await pushFirestoreUpdate(reminder)
        await writeCloudKitRecordIfShared(reminder)
    }

    /// CloudKit: mientras exista el registro del share de antes (con
    /// participantes en versiones viejas, o un enlace `/i/` aún sin abrir), sigue
    /// recibiendo cada cambio. El token de Firestore viaja dentro para que la app
    /// nueva del otro lado se pase sola.
    func writeCloudKitRecordIfShared(_ reminder: Reminder) async {
        let zoneID = CKRecordZone.ID(zoneName: Self.sharingZoneName, ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: reminder.id.uuidString, zoneID: zoneID)
        let database = cloudKitContainer.privateCloudDatabase
        guard let record = try? await database.record(for: recordID) else { return }
        let token = FirestoreShareStore.owned(reminder.id)?.inviteToken ?? decodePayload(from: record).firebaseToken
        writeFields(from: reminder, to: record, firebaseToken: token)
        _ = try? await database.modifyRecords(saving: [record], deleting: [])
        ShareDiagnostics.log("↻ push update '\(reminder.title)'")
    }

    /// If the owner deleted a shared reminder, remove its CloudKit record + share so
    /// participants lose access and their copy is reconciled away on next sync.
    /// Takes the id (not the `Reminder`) since the local object is deleted first.
    /// Same for its Firestore share (and invitation, and photo).
    func deleteSharedRecord(forReminderID id: UUID) async {
        await deleteFirestoreShare(id: id)
        let zoneID = CKRecordZone.ID(zoneName: Self.sharingZoneName, ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        let database = cloudKitContainer.privateCloudDatabase
        guard let record = try? await database.record(for: recordID) else { return }
        var toDelete = [recordID]
        if let shareReference = record.share {
            toDelete.append(shareReference.recordID)
        }
        _ = try? await database.modifyRecords(saving: [], deleting: toDelete)
        ShareDiagnostics.log("🗑️ borrado compartido \(id.uuidString)")
    }

    /// The invitee drops out of the share behind a received alarm they deleted,
    /// so the owner's «Personas» list stops showing them as joined. A participant
    /// removes themselves by deleting the share record from the SHARED database.
    /// Best effort: `scanSharedDatabase` retries for any deleted invitation whose
    /// record is still visible (offline at the time, or deleted before this existed).
    func leaveShare(forReminderID id: UUID) async {
        // De Firestore: se quita de `members` (el dueño deja de verla en «Personas»).
        if FirestoreShareStore.received(id) != nil {
            await leaveFirestoreShare(id: id)
            return
        }
        do {
            if let record = try await receivedRecord(id: id) {
                await leaveShare(of: record)
                return
            }
            ShareDiagnostics.log("👋 salir del share: el registro \(id.uuidString) ya no está")
        } catch {
            ShareDiagnostics.log("❌ salir del share \(id.uuidString): \(error.localizedDescription)")
        }
    }

    /// A received alarm's record in the shared database, or nil if it's gone.
    /// The zone's owner isn't stored locally: try every sharing zone (one per
    /// person who ever shared with us); the one that has it answers.
    private func receivedRecord(id: UUID) async throws -> CKRecord? {
        let database = cloudKitContainer.sharedCloudDatabase
        let zones = try await database.allRecordZones()
            .filter { $0.zoneID.zoneName == Self.sharingZoneName }
        for zone in zones {
            let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zone.zoneID)
            if let record = try? await database.record(for: recordID) {
                return record
            }
        }
        return nil
    }

    /// Deletes, from the shared database, the share `record` hangs from.
    func leaveShare(of record: CKRecord) async {
        guard let shareID = record.share?.recordID else {
            ShareDiagnostics.log("⚠️ salir del share: '\(record.recordID.recordName)' no referencia ningún share")
            return
        }
        do {
            try await cloudKitContainer.sharedCloudDatabase.deleteRecord(withID: shareID)
            ShareDiagnostics.log("👋 fuera del share de '\(record.recordID.recordName)'")
        } catch where Self.isCKError(error, .unknownItem) {
            // Already out — another device of this account got there first.
        } catch {
            ShareDiagnostics.log("❌ salir del share: \(error.localizedDescription)")
        }
    }

    /// Subscribes to changes in the shared database so participants get a silent
    /// push when an owner edits/deletes a shared reminder, triggering an immediate
    /// re-sync (the launch/foreground scan remains a fallback if a push is missed).
    func ensureSharedSubscription() async {
        let database = cloudKitContainer.sharedCloudDatabase
        let subscriptionID = "shared-reminders-changes"
        if (try? await database.subscription(for: subscriptionID)) != nil {
            return // already subscribed
        }
        let subscription = CKDatabaseSubscription(subscriptionID: subscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true // silent push, no alert/permission needed
        subscription.notificationInfo = info
        do {
            _ = try await database.save(subscription)
            ShareDiagnostics.log("🔔 suscripción a base compartida creada")
        } catch {
            Self.log.error("ensureSharedSubscription failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Invitee side

    /// Whether this device holds any alarm someone shared with it.
    var hasReceivedShares: Bool {
        let descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.isReceivedShare })
        return ((try? modelContainer.mainContext.fetchCount(descriptor)) ?? 0) > 0
    }

    /// Accepts an incoming share invitation, fetches the shared record, and creates a local
    /// `Reminder` row marked as shared.
    func acceptShare(metadata: CKShare.Metadata) async throws {
        Self.log.info("acceptShare: accepting invitation")
        ShareDiagnostics.log("▶️ acceptShare: aceptando…")
        incomingShare = .accepting
        let guardedID = Self.rootRecordID(of: metadata).flatMap { UUID(uuidString: $0.recordName) }
        if let guardedID { acceptingIDs.insert(guardedID) }
        do {
            let acceptedShare = try await cloudKitContainer.accept(metadata)
            ShareDiagnostics.log("✅ accept() OK")
            let (reminder, record) = try await ingestSharedRecord(from: metadata)
            acceptErrorMessage = nil
            incomingShare = .accepted(
                reminderID: reminder.id,
                title: reminder.title,
                ownerName: Self.knownDisplayName(metadata.ownerIdentity)
            )
            Self.log.info("acceptShare: ingested shared reminder OK")
            ShareDiagnostics.log("✅ ingesta completa")
            announceMyself(in: acceptedShare)
            rememberOwner(of: acceptedShare, for: reminder.id)
            // An old `/i/` link whose owner already moved the alarm to Firestore:
            // straight over there, so it also syncs with Android.
            if let token = decodePayload(from: record).firebaseToken {
                let migration = CloudKitMigration(id: reminder.id, token: token, record: record)
                Task { await migrateReceivedCloudKitShares([migration]) }
            }
            Task { await releaseAcceptGuard(guardedID) }
        } catch {
            let wrapped = SharedRemindersError.acceptFailed(error)
            incomingShare = nil
            acceptErrorMessage = wrapped.errorDescription
            Self.log.error("acceptShare failed: \(error.localizedDescription, privacy: .public)")
            ShareDiagnostics.log("❌ acceptShare error: \(error.localizedDescription)")
            Task { await releaseAcceptGuard(guardedID) }
            throw wrapped
        }
    }

    /// Keeps the guard past the scan that may have started before `accept()`,
    /// and a while longer for the shared database to list the new zone. An owner
    /// deleting the alarm inside that window is caught by the next scan.
    func releaseAcceptGuard(_ id: UUID?) async {
        guard let id else { return }
        if let running = scanTask { await running.value }
        try? await Task.sleep(for: .seconds(30))
        acceptingIDs.remove(id)
    }

    /// `hierarchicalRootRecordID` is the modern accessor; fall back to the
    /// deprecated `rootRecordID` so we always resolve the shared record's ID.
    /// A zone-wide share (delegation) has neither.
    static func rootRecordID(of metadata: CKShare.Metadata) -> CKRecord.ID? {
        metadata.hierarchicalRootRecordID ?? (metadata.rootRecordID as CKRecord.ID?)
    }

    /// Fetches the share metadata behind a CloudKit share URL.
    ///
    /// iOS only hands an app `CKShare.Metadata` on its own when *it* opens an
    /// `icloud.com/share/…` link. Calarm's own invitation links never go
    /// through that path, so the metadata has to be fetched explicitly before
    /// `acceptShare(metadata:)` can run — same destination, different door.
    func shareMetadata(for url: URL) async throws -> CKShare.Metadata {
        /// CloudKit's result blocks run off the main actor, so the metadata is
        /// parked here rather than captured directly.
        final class Box: @unchecked Sendable {
            var result: Result<CKShare.Metadata, any Error>?
        }
        let box = Box()

        return try await withCheckedThrowingContinuation { continuation in
            let operation = CKFetchShareMetadataOperation(shareURLs: [url])
            // Match what the system's own accept flow provides, so the ingest
            // path downstream sees exactly the metadata it already expects.
            operation.shouldFetchRootRecord = true
            operation.perShareMetadataResultBlock = { _, result in
                box.result = result
            }
            operation.fetchShareMetadataResultBlock = { operationResult in
                if case .success(let metadata) = box.result {
                    continuation.resume(returning: metadata)
                    return
                }
                // Prefer the per-share error: it says why *this* invitation
                // failed (expired, revoked), where the operation-level one is
                // usually just "the request failed".
                switch (box.result, operationResult) {
                case (.failure(let error), _), (_, .failure(let error)):
                    continuation.resume(throwing: SharedRemindersError.acceptFailed(error))
                default:
                    continuation.resume(throwing: SharedRemindersError.shareUnavailable)
                }
            }
            cloudKitContainer.add(operation)
        }
    }

    // MARK: - Private helpers

    static let sharingZoneName = "SharedRemindersZone"

    func fetchRootRecord(for recordID: CKRecord.ID) async throws -> CKRecord? {
        let database = cloudKitContainer.privateCloudDatabase
        do {
            return try await database.record(for: recordID)
        } catch {
            if Self.isCKError(error, .unknownItem) {
                return nil
            }
            throw error
        }
    }

    func fetchShare(attachedTo record: CKRecord, database: CKDatabase) async throws -> CKShare? {
        guard let shareReference = record.share else { return nil }
        do {
            return try await database.record(for: shareReference.recordID) as? CKShare
        } catch {
            if Self.isCKError(error, .unknownItem) {
                ShareDiagnostics.log("⚠️ root record apunta a un share inexistente")
                return nil
            }
            throw error
        }
    }

    func fetchExistingShare(for recordID: CKRecord.ID) async throws -> CKShare? {
        let database = cloudKitContainer.privateCloudDatabase
        guard let record = try await fetchRootRecord(for: recordID) else { return nil }
        return try await fetchShare(attachedTo: record, database: database)
    }

    static func isCKError(_ error: Error, _ code: CKError.Code) -> Bool {
        let nsError = error as NSError
        return nsError.domain == CKError.errorDomain && nsError.code == code.rawValue
    }

    static func diagnosticDescription(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == CKError.errorDomain,
           let code = CKError.Code(rawValue: nsError.code) {
            return "\(code): \(nsError.localizedDescription)"
        }
        return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
    }

    /// Writes a reminder's data onto a (new or existing) shared record. Reused when
    /// the owner edits a shared reminder so the same record is updated in place,
    /// preserving its `CKShare` association.
    func writeFields(from reminder: Reminder, to record: CKRecord, firebaseToken: String? = nil) {
        // Authoritative copy: a single versioned JSON envelope (the `payload` Bytes
        // field). Adding a new shared property means adding a field to `SharePayload`
        // and bumping its version — never another CloudKit schema change.
        if let data = try? JSONEncoder().encode(makePayload(from: reminder, firebaseToken: firebaseToken)) {
            record["payload"] = data as CKRecordValue
        }
        // Also mirror the core values into the original discrete columns. These
        // already exist in the schema; they're a FROZEN compatibility layer (never
        // extended) that lets an older app build — one that predates `payload` — still
        // import the share during a version rollout. New builds prefer `payload`, so
        // the evolving extras (custom category, multiple lead times) live only there.
        record["id"] = reminder.id.uuidString as CKRecordValue
        record["title"] = reminder.title as CKRecordValue
        record["notes"] = (reminder.notes ?? "") as CKRecordValue
        record["date"] = reminder.date as CKRecordValue
        record["categoryRaw"] = reminder.categoryRaw as CKRecordValue
        record["iconKindRaw"] = reminder.iconKindRaw as CKRecordValue
        record["symbolName"] = (reminder.symbolName ?? "") as CKRecordValue
        record["leadTimeSeconds"] = reminder.leadTimeSeconds as CKRecordValue
        record["isEnabled"] = (reminder.isEnabled ? 1 : 0) as CKRecordValue
        record["recurrenceData"] = reminder.recurrenceData as CKRecordValue
    }

    /// Writes a `SharePayload` (not a local `Reminder`) onto a record. Used by the
    /// delegation HELPER side, which has no local `Reminder` to mirror from.
    func writePayload(_ payload: SharePayload, to record: CKRecord) {
        if let data = try? JSONEncoder().encode(payload) {
            record["payload"] = data as CKRecordValue
        }
        record["id"] = payload.id as CKRecordValue
        record["title"] = payload.title as CKRecordValue
        record["notes"] = (payload.notes ?? "") as CKRecordValue
        record["date"] = payload.date as CKRecordValue
        record["categoryRaw"] = payload.categoryRaw as CKRecordValue
        record["iconKindRaw"] = payload.iconKindRaw as CKRecordValue
        record["symbolName"] = (payload.symbolName ?? "") as CKRecordValue
        record["leadTimeSeconds"] = (payload.leadTimeSeconds.first ?? AlarmLeadTime.atStart.rawValue) as CKRecordValue
        record["isEnabled"] = (payload.isEnabled ? 1 : 0) as CKRecordValue
        record["recurrenceData"] = payload.recurrenceData as CKRecordValue
    }

    /// Builds the current-version envelope from a reminder. Denormalizes the
    /// custom category (color/icon) so the recipient — who won't have it in their
    /// own catalog — can reconstruct it.
    func makePayload(from reminder: Reminder, firebaseToken: String? = nil) -> SharePayload {
        var custom: SharePayload.CustomCategoryInfo?
        if let cid = reminder.customCategoryID,
           let cat = CategoryStore.shared?.customCategory(id: cid) {
            custom = SharePayload.CustomCategoryInfo(
                id: cid.uuidString,
                name: cat.name,
                colorHex: cat.colorHex,
                iconKindRaw: cat.iconKindRaw,
                iconValue: cat.iconValue
            )
        }
        return SharePayload(
            version: SharePayload.currentVersion,
            id: reminder.id.uuidString,
            title: reminder.title,
            notes: reminder.notes,
            date: reminder.date,
            categoryRaw: reminder.categoryRaw,
            iconKindRaw: reminder.iconKindRaw,
            symbolName: reminder.symbolName,
            // Carry ALL lead times — the legacy per-field format dropped extras.
            leadTimeSeconds: reminder.leadTimes.map(\.rawValue),
            isEnabled: reminder.isEnabled,
            recurrenceData: reminder.recurrenceData,
            customCategory: custom,
            updatedAt: reminder.updatedAt,
            isDeleted: nil,
            photoThumbnail: photoThumbnailData(from: reminder),
            additionalSchedules: reminder.additionalSchedules.isEmpty
                ? nil
                : reminder.additionalSchedules.map {
                    SharePayload.ScheduleInfo(date: $0.date, recurrenceData: $0.recurrenceData)
                },
            challengeData: reminder.challenge == nil ? nil : reminder.challengeData,
            invitePreview: InvitePreview(
                reminder: reminder,
                style: CategoryStore.shared?.style(for: reminder) ?? CategoryStyle(builtin: reminder.category)
            ),
            firebaseToken: firebaseToken,
            tone: reminder.toneRaw.isEmpty ? nil : reminder.toneRaw
        )
    }

    /// A small JPEG of the reminder's photo icon for sharing — downscaled so it
    /// fits inside the payload envelope. Nil unless the reminder uses a photo icon.
    func photoThumbnailData(from reminder: Reminder) -> Data? {
        guard reminder.iconKind == .photo,
              let data = reminder.photoData,
              let image = UIImage(data: data) else { return nil }
        return resized(image, to: 512).jpegData(compressionQuality: 0.7)
    }

    /// Reads the versioned envelope, falling back to the legacy per-field layout
    /// for any shares created before the envelope existed.
    func decodePayload(from record: CKRecord) -> SharePayload {
        if let data = record["payload"] as? Data,
           let payload = try? JSONDecoder().decode(SharePayload.self, from: data) {
            return payload
        }
        return legacyPayload(from: record)
    }

    /// Reconstructs an envelope from the old per-field record layout.
    private func legacyPayload(from record: CKRecord) -> SharePayload {
        var custom: SharePayload.CustomCategoryInfo?
        if let cidString = record["customCategoryID"] as? String {
            custom = SharePayload.CustomCategoryInfo(
                id: cidString,
                name: (record["customCategoryName"] as? String) ?? "Categoría",
                colorHex: (record["customCategoryColorHex"] as? String) ?? "#AF52DE",
                iconKindRaw: (record["customCategoryIconKindRaw"] as? Int) ?? ReminderIconKind.symbol.rawValue,
                iconValue: (record["customCategoryIconValue"] as? String) ?? "star.fill"
            )
        }
        return SharePayload(
            version: 0,
            id: (record["id"] as? String) ?? record.recordID.recordName,
            title: (record["title"] as? String) ?? "",
            notes: record["notes"] as? String,
            date: (record["date"] as? Date) ?? Date(),
            categoryRaw: (record["categoryRaw"] as? Int) ?? ReminderCategory.event.rawValue,
            iconKindRaw: (record["iconKindRaw"] as? Int) ?? ReminderIconKind.symbol.rawValue,
            symbolName: record["symbolName"] as? String,
            leadTimeSeconds: [(record["leadTimeSeconds"] as? Int) ?? AlarmLeadTime.atStart.rawValue],
            isEnabled: ((record["isEnabled"] as? Int) ?? 1) == 1,
            recurrenceData: (record["recurrenceData"] as? Data) ?? Data(),
            customCategory: custom
        )
    }

    /// Ensures the recipient has a local `CustomCategory` matching a shared one
    /// (deduped by id), so the received reminder renders with its real color/icon.
    func ensureCustomCategory(_ info: SharePayload.CustomCategoryInfo?, in context: ModelContext) -> UUID? {
        guard let info, let cid = UUID(uuidString: info.id) else { return nil }
        let descriptor = FetchDescriptor<CustomCategory>(predicate: #Predicate { $0.id == cid })
        let name = info.name.isEmpty ? "Categoría" : info.name
        let colorHex = info.colorHex.isEmpty ? "#AF52DE" : info.colorHex
        let iconValue = info.iconValue.isEmpty ? "star.fill" : info.iconValue
        if let existing = try? context.fetch(descriptor).first {
            existing.name = name
            existing.colorHex = colorHex
            existing.iconKindRaw = info.iconKindRaw
            existing.iconValue = iconValue
        } else {
            context.insert(CustomCategory(
                id: cid, name: name, colorHex: colorHex,
                iconKind: ReminderIconKind(rawValue: info.iconKindRaw) ?? .symbol,
                iconValue: iconValue
            ))
        }
        return cid
    }

    /// Ingests the shared record behind an accepted invitation and returns the
    /// local reminder it became.
    @MainActor
    private func ingestSharedRecord(from metadata: CKShare.Metadata) async throws -> (Reminder, CKRecord) {
        // A zone-wide share (delegation) has no root record — bail out instead of
        // crashing on the implicitly-unwrapped `rootRecordID`. Such shares are
        // routed to DelegationService upstream; this is just a safety net.
        guard let rootRecordID = Self.rootRecordID(of: metadata) else {
            ShareDiagnostics.log("❌ ingest: share sin root record (¿zone-wide?)")
            throw SharedRemindersError.shareUnavailable
        }
        ShareDiagnostics.log("ingest: rootRecord=\(rootRecordID.recordName)")

        let record: CKRecord
        if let carried = metadata.rootRecord, carried.recordType == "CalarmSharedReminder" {
            // The metadata fetch already brought the record along (the link path
            // asks for it), so there's nothing to wait for. The fetch below, with
            // its retries while the shared database catches up, was most of the
            // seconds between tapping the invitation and seeing the alarm listed.
            record = carried
            ShareDiagnostics.log("ingest: record ya venía en la metadata")
        } else {
            record = try await fetchSharedRecordWithRetries(rootRecordID)
        }
        ShareDiagnostics.log("ingest: record OK (payload=\(record["payload"] != nil))")

        let context = modelContainer.mainContext
        // No change notification here: the person is accepting the invitation and
        // sees the alarm as it is now.
        guard let applied = applyRecord(record, in: context)?.reminder else {
            throw SharedRemindersError.shareUnavailable
        }
        if let owner = Self.person(metadata.ownerIdentity) {
            ownerNames[applied.id] = owner
        }
        // Re-accepting an invitation the user had deleted should bring it back, so
        // clear any tombstone for it.
        DeletedSharesStore.remove(applied.id)
        try context.save()
        CategoryStore.shared?.reload()
        ShareDiagnostics.log("✅ ingest: reminder guardado '\(applied.title)'")
        return (applied, record)
    }

    /// Right after accepting, the shared record can take a moment to appear in
    /// the shared database. Retry a few times before giving up so the reminder
    /// doesn't silently fail to import.
    func fetchSharedRecordWithRetries(_ rootRecordID: CKRecord.ID) async throws -> CKRecord {
        let database = cloudKitContainer.sharedCloudDatabase
        for attempt in 1...5 {
            do {
                return try await database.record(for: rootRecordID)
            } catch {
                Self.log.info("Fetch shared record attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)")
                ShareDiagnostics.log("ingest: fetch intento \(attempt) falló: \(error.localizedDescription)")
                if attempt < 5 {
                    try? await Task.sleep(nanoseconds: 600_000_000) // 0.6s
                }
            }
        }
        Self.log.error("Shared record unavailable after retries for \(rootRecordID.recordName, privacy: .public)")
        ShareDiagnostics.log("❌ ingest: record no disponible tras 5 intentos")
        throw SharedRemindersError.shareUnavailable
    }

    /// Scans for received shares and imports what's found: CloudKit's shared
    /// database (invitations from before 1.1, until their owner migrates them)
    /// and Firestore (`syncFirestoreShares`). This is the RELIABLE path: it
    /// runs on launch / activation and after a push, and doesn't depend on the
    /// `userDidAcceptCloudKitShareWith` callback, which iOS frequently fails to
    /// deliver to SwiftUI apps. Accepting a share (tapping "Open") makes the
    /// owner's zone appear in the recipient's shared database, so we just read
    /// whatever is there.
    ///
    /// One scan at a time: launch alone starts two (`.task` and the first
    /// `.active`), and a push can add a third. Overlapping scans can both find a
    /// record missing and both insert it — a duplicate alarm. A request that
    /// arrives mid-scan is folded into one more pass, so no change is missed.
    ///
    /// `cloudKit: false` skips the CloudKit half: a Firestore push or the
    /// Firestore listener only need the other one. `firestoreSource: .cache`
    /// reads what the listener just brought instead of asking the server again.
    func importAllSharedReminders(cloudKit: Bool = true, firestoreSource: FirestoreSource = .default) async {
        if cloudKit { wantsCloudKitScan = true }
        if firestoreSource != .cache { wantsFirestoreServerRead = true }
        if let running = scanTask {
            rescanRequested = true
            await running.value
            return
        }
        let task = Task {
            repeat {
                rescanRequested = false
                let includeCloudKit = wantsCloudKitScan
                let source: FirestoreSource = wantsFirestoreServerRead ? .default : .cache
                wantsCloudKitScan = false
                wantsFirestoreServerRead = false
                await scanAll(includeCloudKit: includeCloudKit, firestoreSource: source)
            } while rescanRequested
            // Same step as the last check, so no request slips in between.
            scanTask = nil
        }
        scanTask = task
        await task.value
    }

    /// What a CloudKit scan found. Nil from `scanSharedDatabase` when it failed:
    /// then nothing it would have reported can be taken as deleted.
    struct CloudKitScan {
        /// Alarm records present (unreadable ones count for both kinds).
        var alarmIDs: Set<UUID> = []
        var countdownIDs: Set<UUID> = []
        /// The shares behind what's imported, to publish this person's name there.
        var shareRecords: [CKShare] = []
        var shareIDs: Set<CKRecord.ID> = []
        /// Received records whose owner already created the Firestore share.
        var migrations: [CloudKitMigration] = []
    }

    struct CloudKitMigration {
        var id: UUID
        var token: String
        var record: CKRecord
    }

    /// One pass: CloudKit (optional), Firestore, then what each source says is
    /// gone — each only for its own copies (`ShareMigration.staleReceived`).
    private func scanAll(includeCloudKit: Bool, firestoreSource: FirestoreSource) async {
        let context = modelContainer.mainContext
        // Before the sync adds the new ones: a copy that came from Firestore is
        // only Firestore's to remove.
        let tracked = FirestoreShareStore.receivedIDs
        let cloudKit = includeCloudKit ? await scanSharedDatabase() : nil
        let firestore = await syncFirestoreShares(source: firestoreSource)
        await removeStaleCopies(
            cloudKitPresent: cloudKit?.alarmIDs,
            firestorePresent: firestore,
            tracked: tracked,
            in: context
        )
        removeStaleCountdowns(
            cloudKitPresent: cloudKit?.countdownIDs,
            firestorePresent: firestore,
            tracked: tracked,
            in: context
        )
        if let firestore {
            // Lo que se está aceptando sigue siendo de Firestore aunque esta
            // lectura no lo traiga: si el dueño lo borró justo entonces, la
            // próxima pasada (ya sin la guarda) lo quita.
            FirestoreShareStore.keepReceived(firestore.union(acceptingIDs))
        }
        guard let cloudKit else { return }
        // What came from Firestore counts as present: those entries aren't
        // CloudKit's to prune.
        let firestoreKnown = firestore ?? FirestoreShareStore.receivedIDs
        // Drop tombstones whose owner record is gone, so a fresh re-invite with
        // the same id can be accepted again. Countdown ids count too, or their
        // tombstones would be dropped on every scan.
        DeletedSharesStore.prune(presentIDs: cloudKit.alarmIDs.union(cloudKit.countdownIDs).union(firestoreKnown))
        // Same for the recipient's personal avisos — a re-share starts fresh.
        ShareLeadTimesStore.prune(presentIDs: cloudKit.alarmIDs.union(firestoreKnown))
        ShareChangeNotifier.prune(presentIDs: cloudKit.alarmIDs.union(firestoreKnown))
        await publishMyName(
            found: cloudKit.shareRecords.filter { cloudKit.shareIDs.contains($0.recordID) },
            referenced: cloudKit.shareIDs
        )
        // The owner already moved these to Firestore: join there, leave the CKShare.
        await migrateReceivedCloudKitShares(cloudKit.migrations)
    }

    private func scanSharedDatabase() async -> CloudKitScan? {
        let database = cloudKitContainer.sharedCloudDatabase
        do {
            let zones = try await database.allRecordZones()
            ShareDiagnostics.log("scan: \(zones.count) zona(s) compartida(s)")
            let context = modelContainer.mainContext
            var scan = CloudKitScan()
            var imported = 0
            var skipped = 0
            var rescheduled: [(reminder: Reminder, record: CKRecord)] = []
            // Shared countdowns live in the same zones, as their own record type.
            var countdownRecords: [CKRecord] = []
            for zone in zones {
                // SAFETY: never ingest the delegation zone here. Those records are
                // someone else's alarms that this device (acting as a helper) only
                // MANAGES — ingesting them into local SwiftData would make them ring
                // on the helper's phone. They're handled separately by DelegationService.
                guard zone.zoneID.zoneName != DelegationService.zoneName else { continue }
                // Read EVERY page: a record left on a later page would look deleted
                // to `removeStaleCopies` — copy removed, "deleted" notice sent.
                var token: CKServerChangeToken?
                var moreComing = true
                while moreComing {
                    let changes = try await database.recordZoneChanges(inZoneWith: zone.zoneID, since: token)
                    for (ckRecordID, modResult) in changes.modificationResultsByID {
                        guard case .success(let modification) = modResult else {
                            // Unreadable this time, but it exists: keep the local copy
                            // instead of treating it as deleted. Its type is unknown,
                            // so it counts for alarms and countdowns alike.
                            if let id = UUID(uuidString: ckRecordID.recordName) {
                                scan.alarmIDs.insert(id)
                                scan.countdownIDs.insert(id)
                            }
                            continue
                        }
                        let record = modification.record
                        if let share = record as? CKShare {
                            scan.shareRecords.append(share)
                            continue
                        }
                        if record.recordType == Self.countdownRecordType {
                            let id = candidateLocalID(for: record)
                            scan.countdownIDs.insert(id)
                            // Removed from the list on this account: out of the share,
                            // and never imported again (see the alarm case below).
                            if DeletedSharesStore.contains(id) {
                                skipped += 1
                                await leaveShare(of: record)
                                continue
                            }
                            if let token = countdownPayload(from: record)?.firebaseToken {
                                scan.migrations.append(CloudKitMigration(id: id, token: token, record: record))
                            }
                            // Already moved to Firestore (the CloudKit exit is pending):
                            // the Firestore copy is the one that counts.
                            guard FirestoreShareStore.received(id) == nil else { continue }
                            countdownRecords.append(record)
                            if let shareID = record.share?.recordID { scan.shareIDs.insert(shareID) }
                            continue
                        }
                        guard record.recordType == "CalarmSharedReminder" else { continue }
                        let recordID = candidateLocalID(for: record)
                        scan.alarmIDs.insert(recordID)
                        // Skip invitations the recipient deleted — re-importing them
                        // would make a deleted share reappear on every launch.
                        if DeletedSharesStore.contains(recordID) {
                            skipped += 1
                            // Still a participant of an invitation this person
                            // deleted: the leave didn't go through (offline), or
                            // the deletion predates it. Once out, the zone is gone
                            // next scan, which prunes the tombstone — so a fresh
                            // invitation from the owner works again.
                            await leaveShare(of: record)
                            continue
                        }
                        if let token = decodePayload(from: record).firebaseToken {
                            scan.migrations.append(CloudKitMigration(id: recordID, token: token, record: record))
                        }
                        guard FirestoreShareStore.received(recordID) == nil else { continue }
                        guard let applied = applyRecord(record, in: context) else { continue }
                        if applied.scheduleChanged { rescheduled.append((applied.reminder, record)) }
                        if let shareID = record.share?.recordID { scan.shareIDs.insert(shareID) }
                        imported += 1
                    }
                    token = changes.changeToken
                    moreComing = changes.moreComing
                }
            }
            if imported > 0 {
                try? context.save()
                CategoryStore.shared?.reload()
                ShareDiagnostics.log("✅ scan: \(imported) recordatorio(s) importado(s)")
                // The owner moved these to another day/time: tell the person, or
                // they keep counting on the old time.
                for (reminder, record) in rescheduled {
                    let owner = await owner(of: record)
                    await ShareChangeNotifier.notifyScheduleChanged(reminder, ownerName: owner?.name)
                }
            } else {
                ShareDiagnostics.log("scan: sin recordatorios compartidos\(skipped > 0 ? " (\(skipped) borrado(s) ignorado(s))" : "")")
            }
            applyReceivedCountdowns(countdownRecords, in: context)
            return scan
        } catch {
            Self.log.error("importAllSharedReminders failed: \(error.localizedDescription, privacy: .public)")
            ShareDiagnostics.log("❌ scan error: \(error.localizedDescription)")
            return nil
        }
    }

    /// The local `Reminder` id a shared record maps to, using the same resolution
    /// as `applyRecord` (record name first, then the payload id). Used to test a
    /// record against the deleted-invitation tombstones before importing it.
    private func candidateLocalID(for record: CKRecord) -> UUID {
        if let id = UUID(uuidString: record.recordID.recordName) { return id }
        return UUID(uuidString: decodePayload(from: record).id) ?? UUID()
    }

    /// Upserts a shared `CalarmSharedReminder` CKRecord into a local `Reminder`
    /// (marked as a received share). Caller is responsible for saving the context.
    private func applyRecord(_ record: CKRecord, in context: ModelContext) -> (reminder: Reminder, scheduleChanged: Bool)? {
        let payload = decodePayload(from: record)
        // Reuse the record name as the local UUID so importing twice updates the
        // reminder in place instead of duplicating it.
        let localID = UUID(uuidString: record.recordID.recordName)
            ?? UUID(uuidString: payload.id)
            ?? UUID()
        return applyReceivedPayload(payload, localID: localID, in: context)
    }

    /// Upserts a received alarm (from a CloudKit record or a Firestore share)
    /// into a local `Reminder` marked as a received share. Caller is responsible
    /// for saving the context. Returns the local reminder, and whether the owner
    /// changed its schedule since this device last saw it; nil if the id belongs
    /// to one of this person's own alarms, which a received copy never overwrites.
    func applyReceivedPayload(_ payload: SharePayload, localID: UUID, in context: ModelContext) -> (reminder: Reminder, scheduleChanged: Bool)? {
        let customCategoryID = ensureCustomCategory(payload.customCategory, in: context)
        // There can be several: each device inserts its own copy when its scan
        // runs before SwiftData has synced the other device's (or the app's own,
        // after a reinstall), and a CloudKit-synced store can't enforce a unique
        // id. Keep the oldest — `createdAt` syncs too, so every device keeps the
        // same one — and drop the rest.
        let descriptor = FetchDescriptor<Reminder>(
            predicate: #Predicate { $0.id == localID },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        let matches = (try? context.fetch(descriptor)) ?? []
        let reminder: Reminder
        if let oldest = matches.first {
            guard oldest.isReceivedShare else { return nil }
            reminder = oldest
            for duplicate in matches.dropFirst() where duplicate.isReceivedShare {
                context.delete(duplicate)
            }
            if matches.count > 1 {
                ShareDiagnostics.log("🧹 \(matches.count - 1) copia(s) duplicada(s) de '\(payload.title)'")
            }
        } else {
            reminder = Reminder(id: localID)
            context.insert(reminder)
        }
        apply(payload, to: reminder, customCategoryID: customCategoryID)
        let scheduleChanged = ShareChangeNotifier.recordSchedule(of: payload, for: localID)
        return (reminder, scheduleChanged)
    }

    /// Removes local received-share reminders whose source says they're gone
    /// (owner deleted it, stopped sharing, or took this person off) and tells the
    /// person; and removes, quietly, every copy of an invitation the person
    /// deleted — one that SwiftData synced back from another device, or a
    /// duplicate left behind. Cancels their alarms. A source whose read failed
    /// (`nil`) can't remove anything, so a transient fetch failure can't wipe
    /// valid copies.
    private func removeStaleCopies(
        cloudKitPresent: Set<UUID>?,
        firestorePresent: Set<UUID>?,
        tracked: Set<UUID>,
        in context: ModelContext
    ) async {
        let descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.isReceivedShare })
        guard let received = try? context.fetch(descriptor), !received.isEmpty else { return }
        let local = Set(received.map(\.id))
        let stale = ShareMigration.staleReceived(
            local: local,
            cloudKitPresent: cloudKitPresent,
            firestorePresent: firestorePresent,
            firestoreTracked: tracked,
            accepting: acceptingIDs,
            tombstoned: local.filter(DeletedSharesStore.contains)
        )
        let deletedByMe = received.filter { stale.byMe.contains($0.id) }
        let deletedByOwner = received.filter { stale.byOwner.contains($0.id) }
        if !deletedByMe.isEmpty {
            ShareDiagnostics.log("🧹 scan: \(deletedByMe.count) copia(s) de invitaciones borradas")
        }
        let gone = deletedByMe + deletedByOwner
        guard !gone.isEmpty else { return }
        // Captured before deleting: the notice needs the alarm's title.
        let notices = deletedByOwner.filter(ShareChangeNotifier.isUpcoming).map(ShareChangeNotifier.Alarm.init)
        for reminder in gone {
            // `syncAlarms` only schedules reminders that still exist, so without
            // this a deleted alarm kept ringing until the next cold launch.
            await scheduler.cancelAlarms(forReminderID: reminder.id)
            context.delete(reminder)
        }
        try? context.save()
        CategoryStore.shared?.reload()
        if !deletedByOwner.isEmpty {
            ShareDiagnostics.log("🗑️ scan: \(deletedByOwner.count) compartido(s) eliminado(s) por el dueño")
        }
        // A CloudKit share that's gone can't say who owned it anymore: the name
        // is known only if this session already read it. Firestore's is kept.
        for notice in notices {
            let owner = ownerNames[notice.id]?.name ?? FirestoreShareStore.received(notice.id)?.ownerName
            await ShareChangeNotifier.notifyDeleted(notice, ownerName: owner)
        }
    }

    /// Copies an envelope onto a local reminder.
    ///
    /// `markAsReceivedShare` is true for the per-record share path (the recipient's
    /// read-only copy) and FALSE for delegation down-sync (the principal owns those
    /// alarms — they must NOT be flagged as received). The payload's `updatedAt` is
    /// preserved when present so the delegation mirror's last-writer-wins and
    /// echo-suppression work; falling back to `Date()` keeps legacy v1 behavior.
    func apply(_ payload: SharePayload, to reminder: Reminder, customCategoryID: UUID?, markAsReceivedShare: Bool = true) {
        reminder.title = payload.title
        reminder.notes = payload.notes?.isEmpty == true ? nil : payload.notes
        reminder.date = payload.date
        reminder.categoryRaw = payload.categoryRaw
        reminder.customCategoryID = customCategoryID
        reminder.iconKindRaw = payload.iconKindRaw
        reminder.symbolName = payload.symbolName?.isEmpty == true ? nil : payload.symbolName
        // Photo icon: carry the shared thumbnail (nil clears it for non-photo).
        reminder.photoData = payload.photoThumbnail
        reminder.recurrenceData = payload.recurrenceData
        reminder.additionalSchedules = (payload.additionalSchedules ?? []).map {
            let rule = (try? JSONDecoder().decode(RecurrenceRule.self, from: $0.recurrenceData)) ?? .once
            return AlarmSchedule(date: $0.date, recurrence: rule)
        }
        reminder.challengeData = payload.challengeData ?? Data()
        let payloadLeadTimes = payload.leadTimeSeconds.compactMap { AlarmLeadTime(rawValue: $0) }
        let ownerLeadTimes = payloadLeadTimes.isEmpty ? [AlarmLeadTime.atStart] : payloadLeadTimes
        if markAsReceivedShare {
            // Avisos are personal to the recipient: they decide only when THIS
            // device rings and are never pushed back to the owner. Keep the
            // recipient's own list instead of overwriting it on every scan.
            ShareLeadTimesStore.recordShared(ownerLeadTimes, for: reminder.id)
            reminder.leadTimes = ShareLeadTimesStore.personal(for: reminder.id) ?? ownerLeadTimes
        } else {
            reminder.leadTimes = ownerLeadTimes
        }
        reminder.isEnabled = payload.isEnabled
        // El tono: en una recibida es de quien la recibe (como sus avisos); en las
        // alarmas propias que edita una persona de confianza, el que ella elija
        // (solo los que trae la app; sin tono, se queda el que había).
        if !markAsReceivedShare, let raw = payload.tone, let tone = AlarmTone(rawValue: raw),
           AlarmTone.builtins.contains(tone) {
            reminder.tone = tone
        }
        reminder.updatedAt = payload.updatedAt ?? Date()
        reminder.isReceivedShare = markAsReceivedShare
    }

    // MARK: - Photo thumbnail

    /// Center-crops + scales `image` to `size × size`. Keeps the thumbnail tight
    /// to where the subject lives without distortion.
    func resized(_ image: UIImage, to size: CGFloat) -> UIImage {
        let target = CGSize(width: size, height: size)
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in
            let scale = max(target.width / image.size.width, target.height / image.size.height)
            let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let origin = CGPoint(
                x: (target.width - drawSize.width) / 2,
                y: (target.height - drawSize.height) / 2
            )
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
    }
}

/// Versioned JSON envelope for everything a shared reminder carries, stored in a
/// single CloudKit `payload` (Bytes) field on `CalarmSharedReminder`.
///
/// This is the schema-stable contract for sharing: adding a new shared property
/// means adding a field here and bumping `currentVersion` — never another
/// CloudKit schema change / Production deploy. Add future fields as **optionals**
/// so payloads written by an older sender still decode on a newer recipient
/// (the synthesized decoder treats a missing key for a non-optional as an error).
struct SharePayload: Codable {
    static let currentVersion = 2

    var version: Int
    var id: String
    var title: String
    var notes: String?
    var date: Date
    var categoryRaw: Int
    var iconKindRaw: Int
    var symbolName: String?
    /// All lead times (raw seconds). The legacy per-field format carried only one.
    var leadTimeSeconds: [Int]
    var isEnabled: Bool
    /// Opaque encoded `RecurrenceRule`, decoded with the recipient's own decoder
    /// so a future rule-shape change can't break the rest of the payload.
    var recurrenceData: Data
    var customCategory: CustomCategoryInfo?
    /// v2: last-modified timestamp, the basis for last-writer-wins in the
    /// bidirectional delegation mirror. Optional so v1 payloads still decode.
    var updatedAt: Date? = nil
    /// v2: soft-delete marker for the delegation mirror, so a delete wins by
    /// `updatedAt` instead of racing against a concurrent edit. Optional/absent
    /// means "not deleted".
    var isDeleted: Bool? = nil
    /// v2: a downscaled JPEG of the reminder's photo icon (~512px), so photo-icon
    /// reminders show their picture on recipients/helpers. Small enough to live in
    /// the `payload` Bytes field (no CKAsset / schema change). Optional/absent for
    /// non-photo reminders.
    var photoThumbnail: Data? = nil
    /// v3: extra (date+recurrence) schedules beyond the primary one, so a multi-
    /// schedule alarm keeps all its days/times on recipients and helpers. Optional/
    /// absent = single-schedule (older senders).
    var additionalSchedules: [ScheduleInfo]? = nil
    /// v3: reto para apagar (JSON `WakeChallenge`), para que una alarma con reto
    /// lo conserve en invitados y personas de confianza. Opcional/ausente = sin
    /// reto (emisores anteriores).
    var challengeData: Data? = nil
    /// Lo que la página de invitación necesita y el resto del payload no dice
    /// (zona horaria, idioma, color e ícono resueltos). La web lo lee de
    /// CloudKit para dibujar un enlace que solo lleva el token del share.
    /// Opcional/ausente en payloads de versiones anteriores a la 1.0.18.
    var invitePreview: InvitePreview? = nil
    /// 1.1: el token de la invitación de Firestore que el dueño creó para este
    /// mismo share (DESIGN.md › «Migración desde CloudKit»). Un invitado con la
    /// app nueva se une con él en Firestore y sale del `CKShare`; uno con la
    /// vieja lo ignora y sigue por CloudKit. También va en los registros de la
    /// zona de delegación (el de la invitación a personas de confianza).
    var firebaseToken: String? = nil
    /// 1.1: el tono (`AlarmTone.rawValue`), para Firestore y la delegación.
    /// Solo los tonos que trae la app; uno importado no existe en otro teléfono.
    var tone: String? = nil

    struct CustomCategoryInfo: Codable {
        var id: String
        var name: String
        var colorHex: String
        var iconKindRaw: Int
        var iconValue: String
    }

    /// One extra schedule in the payload (mirrors `AlarmSchedule` minus its id).
    struct ScheduleInfo: Codable {
        var date: Date
        var recurrenceData: Data
    }
}
