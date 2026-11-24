//
//  DelegationService.swift
//  Calarm
//
//  "Personas de confianza" (delegation). The principal shares their ENTIRE alarm
//  list, read/write, with trusted helpers (an assistant, a partner). Helpers can
//  create/edit/delete alarms that RING on the principal's phone.
//
//  Since 1.1 this lives in Firestore (calarmi-firebase/DESIGN.md), so a helper can
//  be on Android:
//  - `delegations/{principalUid}`: the principal's name and the helpers
//    (`helpers` / `helperUids`). A helper joins with the invitation's token
//    (`invites/{token}`, kind "delegation"), like a share member.
//  - `delegations/{principalUid}/reminders/{id}`: the principal mirrors every own
//    alarm there (`alarm`, `deleted`, `revision`, `updatedAt`, `updatedBy`).
//  - The principal's SwiftData store stays the source of truth (so alarms ring).
//    Helper changes (`updatedBy != principal`) are pulled back in, last writer
//    wins by `updatedAt`; a helper deletes softly (`deleted: true`) and the
//    principal's phone removes the alarm and the document.
//  - The HELPER never inserts into their own SwiftData — they read/write the
//    principal's documents directly — so delegated alarms never ring on the
//    helper's phone.
//
//  CloudKit (before 1.1) is kept for what still depends on it: a dedicated zone
//  `DelegationZone` in the principal's private DB, shared through a ZONE-WIDE
//  CKShare. While that share exists the principal keeps mirroring into it and
//  pulling from it (helpers on an old version), and every record carries the
//  Firestore invitation token (`SharePayload.firebaseToken`) so a helper with the
//  new version joins in Firestore and leaves the CKShare («Migración desde
//  CloudKit»). A helper also still manages the lists of principals on old versions.
//

import CloudKit
import FirebaseFirestore
import Foundation
import Observation
import os
import SwiftData
import UIKit

/// A delegated reminder as seen by a helper (never a local `Reminder`).
struct DelegatedReminder: Identifiable {
    enum Source {
        case cloudKit(CKRecord.ID)
        case firestore(docID: String)
    }

    let id: UUID
    let source: Source
    let payload: SharePayload

    var title: String { payload.title }
    var date: Date { payload.date }
    var isEnabled: Bool { payload.isEnabled }
}

/// A principal whose alarm list a helper has been granted access to.
struct DelegationPrincipal: Identifiable {
    enum Source {
        case cloudKit(CKRecordZone.ID)
        case firestore
    }

    let id: String          // principal uid (Firestore) or zone owner name (CloudKit)
    let source: Source
    let name: String        // owner display name
}

@Observable
@MainActor
final class DelegationService {
    static let zoneName = "DelegationZone"
    static let shareType = "com.mathyusolutions.calarm.delegation"
    /// La invitación vigente a la lista (`invites/{token}`). En el dispositivo:
    /// el contrato no guarda el token en `delegations/{uid}`.
    static let inviteTokenKey = "calarm.delegation.inviteToken"
    /// El uid con el que esta lista existe en Firestore (la sesión que la creó).
    private static let firestoreUIDKey = "calarm.delegation.firestoreUID"
    /// El `updatedAt` más nuevo ya leído de `reminders`: las lecturas siguientes
    /// piden solo lo posterior.
    private static let lastPulledKey = "calarm.delegation.firestoreLastPulled"

    let containerIdentifier: String
    private let cloudKitContainer: CKContainer
    private let modelContainer: ModelContainer
    /// Reused for the payload codec (makePayload/writeFields/decodePayload/apply…).
    private let sharing: SharedRemindersService
    /// Used to (un)schedule local alarms when helper changes are pulled in.
    private let scheduler: ReminderScheduler

    private static let log = Logger(subsystem: "MathyuSolutions.Calarm", category: "delegation")
    private static let tokenKey = "calarm.delegation.changeToken"
    private static let lastSyncedKey = "calarm.delegation.lastSynced"
    /// Lo que cabe en un lote de Firestore (el límite es 500).
    private static let batchSize = 400
    /// `photo` en `reminders/{id}`: hasta 300 KB (reglas).
    private static let maxPhotoBytes = 300_000

    private(set) var lastErrorMessage: String?

    /// IDs just written locally from a remote (helper) change — skipped by the next
    /// up-sync pass so we don't echo them straight back (ping-pong).
    private var recentlyAppliedFromZone: Set<UUID> = []
    /// Per-reminder last-synced timestamp, the up-sync change detector (shared
    /// by the Firestore and CloudKit mirrors: both get every change).
    private var lastSyncedUpdatedAt: [UUID: Date] = [:]

    init(modelContainer: ModelContainer, sharing: SharedRemindersService,
         scheduler: ReminderScheduler,
         containerIdentifier: String = "iCloud.MathyuSolutions.Calarm") {
        self.modelContainer = modelContainer
        self.sharing = sharing
        self.scheduler = scheduler
        self.containerIdentifier = containerIdentifier
        self.cloudKitContainer = CKContainer(identifier: containerIdentifier)
        self.lastSyncedUpdatedAt = Self.loadLastSynced()
    }

    func clearError() { lastErrorMessage = nil }

    private var db: Firestore { FirebaseSession.shared.db }

    // MARK: - Principal: Firestore list + invitation

    /// The principal's uid when their list is on Firestore (from this session).
    private var firestorePrincipalUID: String? {
        guard let uid = FirebaseSession.shared.uid,
              UserDefaults.standard.string(forKey: Self.firestoreUIDKey) == uid
        else { return nil }
        return uid
    }

    private func remindersRef(_ principal: String) -> CollectionReference {
        db.collection("delegations").document(principal).collection("reminders")
    }

    /// Turns delegation on: the Firestore list (`delegations/{uid}`), its
    /// invitation, and every own alarm mirrored there. Returns the invitation
    /// link (`…/s/<token>/`), the same for everyone invited.
    @discardableResult
    func enable() async throws -> URL {
        do {
            let token = try await ensureFirestoreDelegation()
            await mirrorAllLocalReminders()
            return InviteLink.make(token: token)
        } catch {
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    /// The link to invite one more helper (creates the list if needed).
    func inviteURL() async throws -> URL {
        let token = try await ensureFirestoreDelegation()
        return InviteLink.make(token: token)
    }

    /// Creates or refreshes `delegations/{uid}` and a usable invitation; returns its token.
    private func ensureFirestoreDelegation() async throws -> String {
        let (uid, name) = try await sharing.sharingIdentity()
        let ref = db.collection("delegations").document(uid)
        // El principal puede leer su propio documento, exista o no.
        let snapshot = try await ref.getDocument(source: .server)
        if snapshot.exists {
            if snapshot.data()?["principalName"] as? String != name {
                try await ref.updateData(["principalName": name, "updatedAt": FieldValue.serverTimestamp()])
            }
        } else {
            // Las reglas: al crearla, sin personas de confianza (entran con la invitación).
            try await ref.setData([
                "principalName": name,
                "helpers": [String: Any](),
                "helperUids": [String](),
                "updatedAt": FieldValue.serverTimestamp(),
            ])
            ShareDiagnostics.log("👥 Firestore: lista de confianza creada")
        }
        UserDefaults.standard.set(uid, forKey: Self.firestoreUIDKey)

        if let token = UserDefaults.standard.string(forKey: Self.inviteTokenKey),
           InviteToken.isValid(token),
           let invite = try? await db.collection("invites").document(token).getDocument(source: .server),
           invite.exists,
           invite.data()?["revoked"] as? Bool == false,
           invite.data()?["ownerUid"] as? String == uid,
           invite.data()?["kind"] as? String == "delegation" {
            return token
        }
        let token = InviteToken.make()
        try await db.collection("invites").document(token).setData([
            "kind": "delegation",
            "targetId": uid,
            "ownerUid": uid,
            "ownerName": name,
            // En «delegation» el título es el nombre del principal.
            "preview": FirestoreMapping.previewMap(
                title: name,
                date: Date(),
                hasTime: false,
                preview: InvitePreview(tintHex: nil, emoji: nil, symbol: "person.2.fill")
            ),
            "revoked": false,
            "createdAt": FieldValue.serverTimestamp(),
        ])
        UserDefaults.standard.set(token, forKey: Self.inviteTokenKey)
        ShareDiagnostics.log("👥 Firestore: invitación de confianza creada")
        return token
    }

    /// Helpers of the list (for the management UI): Firestore's, plus the
    /// CloudKit participants of before 1.1 that haven't moved yet.
    func participantInfos() async -> [ShareParticipantInfo] {
        var infos: [ShareParticipantInfo] = []
        if let uid = firestorePrincipalUID,
           let snapshot = try? await db.collection("delegations").document(uid).getDocument(),
           snapshot.exists {
            let data = FirestoreValues.document(snapshot.data())
            infos = FirestoreMapping.people(in: data["helpers"], excluding: uid, dateKey: "addedAt")
                .map(SharedRemindersService.participant)
        }
        if let share = await existingZoneShare() {
            infos += await sharing.namedParticipantInfos(of: share).filter { !$0.isOwner }
        }
        return infos
    }

    /// Removes a helper: from the Firestore list, or (before 1.1) from the
    /// CloudKit share — matched by CloudKit user id first, since link-joined
    /// (public) participants often have no email/phone, then by email/phone.
    func removeHelper(_ person: ShareParticipantInfo) async {
        if let helperUID = person.firebaseUID {
            guard let uid = firestorePrincipalUID,
                  let name = try? await sharing.sharingIdentity().name
            else { return }
            do {
                try await db.collection("delegations").document(uid).updateData([
                    "principalName": name,
                    FieldPath(["helpers", helperUID]): FieldValue.delete(),
                    "helperUids": FieldValue.arrayRemove([helperUID]),
                    "updatedAt": FieldValue.serverTimestamp(),
                ])
                ShareDiagnostics.log("🚫 Firestore: persona de confianza quitada")
            } catch {
                lastErrorMessage = error.localizedDescription
            }
            return
        }
        guard let share = await existingZoneShare() else { return }
        let target = share.participants.first { participant in
            let identity = participant.userIdentity
            if let userRecordName = person.userRecordName, identity.userRecordID?.recordName == userRecordName { return true }
            let info = identity.lookupInfo
            return (person.email != nil && info?.emailAddress == person.email)
                || (person.phone != nil && info?.phoneNumber == person.phone)
        }
        guard let target, target.role != .owner else { return }
        share.removeParticipant(target)
        let database = cloudKitContainer.privateCloudDatabase
        _ = try? await database.modifyRecords(saving: [share], deleting: [])
        ShareDiagnostics.log("🚫 helper removido del share de delegación")
    }

    /// Turns delegation off: revokes the invitation and deletes the Firestore
    /// list (helpers lose access) and the CloudKit share. The principal's own
    /// alarms stay local and keep ringing.
    func disableDelegation() async {
        if let uid = firestorePrincipalUID {
            if let token = UserDefaults.standard.string(forKey: Self.inviteTokenKey) {
                try? await db.collection("invites").document(token).updateData(["revoked": true])
            }
            if let documents = try? await remindersRef(uid).getDocuments(source: .server).documents {
                for chunk in documents.chunked(into: Self.batchSize) {
                    let batch = db.batch()
                    chunk.forEach { batch.deleteDocument($0.reference) }
                    try? await batch.commit()
                }
            }
            try? await db.collection("delegations").document(uid).delete()
            ShareDiagnostics.log("👥 Firestore: lista de confianza borrada")
        }
        UserDefaults.standard.removeObject(forKey: Self.inviteTokenKey)
        UserDefaults.standard.removeObject(forKey: Self.firestoreUIDKey)
        UserDefaults.standard.removeObject(forKey: Self.lastPulledKey)
        if let share = await existingZoneShare() {
            let database = cloudKitContainer.privateCloudDatabase
            _ = try? await database.modifyRecords(saving: [], deleting: [share.recordID])
            ShareDiagnostics.log("👥 delegación desactivada (share borrado)")
        }
    }

    /// Otra cuenta entró en este teléfono, o se borró la cuenta (DESIGN.md ›
    /// «Cambio de cuenta»): la lista de Firestore era de la anterior, así que
    /// este teléfono la olvida (sus ayudantes siguen en esa cuenta, no en esta).
    /// La lista de CloudKit de antes de la 1.1 es de la cuenta de iCloud y sigue
    /// igual. Devuelve si queda una (y la delegación debe seguir encendida).
    func forgetFirebaseAccount() async -> Bool {
        UserDefaults.standard.removeObject(forKey: Self.inviteTokenKey)
        UserDefaults.standard.removeObject(forKey: Self.firestoreUIDKey)
        UserDefaults.standard.removeObject(forKey: Self.lastPulledKey)
        let keepsCloudKitList = await existingZoneShare() != nil
        ShareDiagnostics.log("🔄 cambio de cuenta: lista de confianza de Firestore olvidada\(keepsCloudKitList ? " (sigue la de iCloud)" : "")")
        return keepsCloudKitList
    }

    /// Principal on a version before 1.1: create the Firestore list and put its
    /// token in every CloudKit record, so helpers with the new app move over.
    /// The CloudKit share stays for helpers still on old versions.
    func migrateCloudKitDelegationIfNeeded() async {
        guard firestorePrincipalUID == nil,
              sharing.hasSharingIdentity,
              await existingZoneShare() != nil
        else { return }
        do {
            _ = try await ensureFirestoreDelegation()
            await mirrorAllLocalReminders()
            ShareDiagnostics.log("🔀 delegación migrada a Firestore")
        } catch {
            ShareDiagnostics.log("⚠️ migración de delegación pendiente: \(error.localizedDescription)")
        }
    }

    // MARK: - Principal: CloudKit zone (before 1.1)

    private var principalZoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    /// Returns the existing zone-wide share, or nil if there's none (lists
    /// created since 1.1 are only on Firestore).
    func existingZoneShare() async -> CKShare? {
        let database = cloudKitContainer.privateCloudDatabase
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: principalZoneID)
        return try? await database.record(for: shareID) as? CKShare
    }

    // MARK: - Principal: mirror local alarms up

    /// Pushes every local (owned) reminder to Firestore — and to the CloudKit
    /// zone while its share exists — so helpers see the full list. Idempotent
    /// (document/record name = reminder.id). Runs on enable and on app
    /// launch/foreground while delegation is on.
    func mirrorAllLocalReminders() async {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { !$0.isReceivedShare })
        guard let reminders = try? context.fetch(descriptor), !reminders.isEmpty else {
            ShareDiagnostics.log("delegación: sin alarmas locales que reflejar")
            return
        }
        await writeFirestore(reminders)
        await writeCloudKit(reminders)
        for reminder in reminders { lastSyncedUpdatedAt[reminder.id] = reminder.updatedAt }
        persistLastSynced()
        ShareDiagnostics.log("⬆️ delegación: \(reminders.count) alarma(s) reflejada(s)")
    }

    /// Incremental up-sync: pushes only locally-changed reminders (new or with a
    /// newer `updatedAt` than last synced), skipping ones just applied from a
    /// helper to avoid echo. Runs on launch/foreground; the write hooks push
    /// immediately.
    func reconcileUp() async {
        let zoneShare = await existingZoneShare()
        guard firestorePrincipalUID != nil || zoneShare != nil else { return }
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { !$0.isReceivedShare })
        guard let reminders = try? context.fetch(descriptor) else { return }
        let changed = reminders.filter { reminder in
            if recentlyAppliedFromZone.contains(reminder.id) { return false }
            if let synced = lastSyncedUpdatedAt[reminder.id], reminder.updatedAt <= synced.addingTimeInterval(1) {
                return false
            }
            return true
        }
        if !changed.isEmpty {
            await writeFirestore(changed)
            if zoneShare != nil { await writeCloudKit(changed) }
            for reminder in changed { lastSyncedUpdatedAt[reminder.id] = reminder.updatedAt }
            persistLastSynced()
            ShareDiagnostics.log("⬆️ reconcileUp: \(changed.count) push")
        }
        recentlyAppliedFromZone.removeAll()
    }

    /// Pushes a single reminder (owner edited/created). No-op if delegation
    /// isn't set up.
    func pushReminder(_ reminder: Reminder) async {
        guard !reminder.isReceivedShare else { return }
        await writeFirestore([reminder])
        if await existingZoneShare() != nil {
            await writeCloudKit([reminder])
        }
        lastSyncedUpdatedAt[reminder.id] = reminder.updatedAt
        persistLastSynced()
    }

    /// Deletes a reminder's mirror (owner deleted it). No-op if delegation isn't
    /// set up.
    func deleteZoneRecord(forReminderID id: UUID) async {
        if let uid = firestorePrincipalUID {
            try? await remindersRef(uid).document(id.uuidString).delete()
        }
        lastSyncedUpdatedAt[id] = nil
        guard await existingZoneShare() != nil else { return }
        let database = cloudKitContainer.privateCloudDatabase
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: principalZoneID)
        _ = try? await database.modifyRecords(saving: [], deleting: [recordID])
        ShareDiagnostics.log("⬆️ delegación: borrado \(id.uuidString)")
    }

    /// `delegations/{uid}/reminders/{id}` for each reminder, in batches.
    private func writeFirestore(_ reminders: [Reminder]) async {
        guard let uid = firestorePrincipalUID, !reminders.isEmpty else { return }
        for chunk in reminders.chunked(into: Self.batchSize) {
            let batch = db.batch()
            for reminder in chunk {
                let payload = sharing.makePayload(from: reminder)
                var data: [String: Any] = [
                    "alarm": FirestoreMapping.alarmMap(from: payload),
                    "deleted": false,
                    "revision": FieldValue.increment(Int64(1)),
                    "updatedAt": FieldValue.serverTimestamp(),
                    "updatedBy": uid,
                ]
                if let photo = payload.photoThumbnail, photo.count <= Self.maxPhotoBytes {
                    data["photo"] = photo
                } else {
                    data["photo"] = FieldValue.delete()
                }
                batch.setData(data, forDocument: remindersRef(uid).document(reminder.id.uuidString), merge: true)
            }
            do {
                try await batch.commit()
            } catch {
                ShareDiagnostics.log("❌ delegación (Firestore): \(error.localizedDescription)")
            }
        }
    }

    /// The CloudKit zone mirror (helpers on versions before 1.1), with the
    /// Firestore token inside each record so the new version moves over.
    private func writeCloudKit(_ reminders: [Reminder]) async {
        guard !reminders.isEmpty, await existingZoneShare() != nil else { return }
        let database = cloudKitContainer.privateCloudDatabase
        let token = UserDefaults.standard.string(forKey: Self.inviteTokenKey)
        var records: [CKRecord] = []
        for reminder in reminders {
            let recordID = CKRecord.ID(recordName: reminder.id.uuidString, zoneID: principalZoneID)
            // Update the existing record in place when present, to keep its etag.
            let record = (try? await database.record(for: recordID))
                ?? CKRecord(recordType: "CalarmSharedReminder", recordID: recordID)
            sharing.writeFields(from: reminder, to: record, firebaseToken: token)
            records.append(record)
        }
        // CloudKit caps batch size; chunk conservatively.
        for chunk in records.chunked(into: 200) {
            _ = try? await database.modifyRecords(saving: chunk, deleting: [])
        }
    }

    // MARK: - Principal: pull helper changes (down-sync)

    /// Pulls helper changes from Firestore (and, while it exists, from the
    /// CloudKit zone), applies them to local SwiftData with last-writer-wins and
    /// cancels alarms for deletions. The caller reschedules afterwards (so
    /// upserted alarms ring). No-op if not delegating.
    func pullPrincipalChanges() async {
        await pullFirestoreChanges()
        await pullCloudKitChanges()
    }

    private func pullFirestoreChanges() async {
        guard let uid = firestorePrincipalUID else { return }
        let defaults = UserDefaults.standard
        let lastPulled = defaults.object(forKey: Self.lastPulledKey) as? Date
        var query: Query = remindersRef(uid)
        if let lastPulled {
            // Con margen: dos escrituras casi a la vez pueden llegar desordenadas.
            query = query.whereField("updatedAt", isGreaterThan: lastPulled.addingTimeInterval(-5))
        }
        let snapshot: QuerySnapshot
        do {
            snapshot = try await query.getDocuments(source: .server)
        } catch {
            ShareDiagnostics.log("❌ delegación pull (Firestore): \(error.localizedDescription)")
            return
        }
        let context = modelContainer.mainContext
        var newest = lastPulled
        var deletedIDs: [UUID] = []
        var hardDeletes: [DocumentReference] = []
        var changed = false
        var helperNames: [String: String]?
        var notices: [(Reminder, String?)] = []
        var applied: [Reminder] = []
        for document in snapshot.documents {
            let data = FirestoreValues.document(document.data())
            let updatedAt = data["updatedAt"] as? Date
            if let updatedAt, updatedAt > (newest ?? .distantPast) { newest = updatedAt }
            // Lo que subió este mismo teléfono no se vuelve a aplicar.
            guard let author = data["updatedBy"] as? String, author != uid,
                  let localID = UUID(uuidString: document.documentID)
            else { continue }
            let descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.id == localID && !$0.isReceivedShare })
            let existing = try? context.fetch(descriptor).first
            if data["deleted"] as? Bool == true {
                if let existing {
                    context.delete(existing)
                    deletedIDs.append(localID)
                    changed = true
                }
                recentlyAppliedFromZone.insert(localID)
                lastSyncedUpdatedAt[localID] = nil
                hardDeletes.append(document.reference)
                continue
            }
            guard var payload = FirestoreMapping.payload(fromAlarm: data["alarm"], id: document.documentID, updatedAt: updatedAt) else { continue }
            // LWW: if local is newer than the helper's write, keep local
            // (reconcileUp re-pushes it). Tolerance absorbs clock jitter.
            if let existing, let updatedAt, existing.updatedAt > updatedAt.addingTimeInterval(1) { continue }
            // La foto viaja en el documento; si no vino, se queda la que había.
            payload.photoThumbnail = (data["photo"] as? Data) ?? existing?.photoData
            let before = existing.map(Self.scheduleSignature)
            let customCategoryID = sharing.ensureCustomCategory(payload.customCategory, in: context)
            let reminder: Reminder
            if let existing {
                reminder = existing
            } else {
                reminder = Reminder(id: localID)
                context.insert(reminder)
            }
            sharing.apply(payload, to: reminder, customCategoryID: customCategoryID, markAsReceivedShare: false)
            recentlyAppliedFromZone.insert(localID)
            lastSyncedUpdatedAt[localID] = reminder.updatedAt
            applied.append(reminder)
            changed = true
            // Una persona de confianza le cambió la hora: que se entere.
            if let before, before != Self.scheduleSignature(reminder), ShareChangeNotifier.isUpcoming(reminder) {
                if helperNames == nil { helperNames = await loadHelperNames(principal: uid) }
                notices.append((reminder, helperNames?[author]))
            }
        }
        if changed {
            try? context.save()
            CategoryStore.shared?.reload()
            ShareDiagnostics.log("⬇️ delegación: cambios de personas de confianza aplicados")
        }
        for id in deletedIDs { await scheduler.cancelAlarms(forReminderID: id) }
        // Las personas de confianza que siguen en la versión vieja (CloudKit)
        // también ven lo que cambió otra desde Firestore.
        await writeCloudKit(applied)
        if !deletedIDs.isEmpty, await existingZoneShare() != nil {
            let recordIDs = deletedIDs.map { CKRecord.ID(recordName: $0.uuidString, zoneID: principalZoneID) }
            _ = try? await cloudKitContainer.privateCloudDatabase.modifyRecords(saving: [], deleting: recordIDs)
        }
        // El borrado suave ya se aplicó aquí: el documento se va.
        for reference in hardDeletes { try? await reference.delete() }
        if let newest { defaults.set(newest, forKey: Self.lastPulledKey) }
        persistLastSynced()
        for (reminder, name) in notices {
            await ShareChangeNotifier.notifyScheduleChanged(reminder, ownerName: name)
        }
    }

    private func loadHelperNames(principal: String) async -> [String: String] {
        guard let snapshot = try? await db.collection("delegations").document(principal).getDocument() else { return [:] }
        let people = FirestoreMapping.people(in: FirestoreValues.document(snapshot.data())["helpers"], dateKey: "addedAt")
        return Dictionary(people.map { ($0.uid, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    /// What decides when an alarm rings, to tell a helper's time change apart
    /// from any other edit.
    private static func scheduleSignature(_ reminder: Reminder) -> [String] {
        reminder.allSchedules.map { "\(Int($0.date.timeIntervalSince1970))|\($0.recurrence)" }.sorted()
    }

    /// Pulls helper changes (upserts + deletions) from the principal's CloudKit
    /// delegation zone using a persisted change token. Only while that share
    /// exists (helpers on versions before 1.1).
    private func pullCloudKitChanges() async {
        guard await existingZoneShare() != nil else { return }
        let database = cloudKitContainer.privateCloudDatabase
        let zoneID = principalZoneID
        let context = modelContainer.mainContext
        var token = Self.loadToken()
        var deletedIDs: [UUID] = []
        var changed = false
        do {
            var more = true
            while more {
                let result = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
                for modResult in result.modificationResultsByID.values {
                    guard case .success(let mod) = modResult else { continue }
                    let record = mod.record
                    guard record.recordType == "CalarmSharedReminder" else { continue }
                    let outcome = applyHelperChange(record, in: context)
                    if outcome.changed { changed = true }
                    if let deleted = outcome.deletedID { deletedIDs.append(deleted) }
                }
                for deletion in result.deletions {
                    if let id = applyHelperDeletion(deletion.recordID, in: context) {
                        deletedIDs.append(id); changed = true
                    }
                }
                token = result.changeToken
                more = result.moreComing
            }
            try? context.save()
            Self.saveToken(token)
            persistLastSynced()
            for id in deletedIDs { await scheduler.cancelAlarms(forReminderID: id) }
            if changed {
                CategoryStore.shared?.reload()
                ShareDiagnostics.log("⬇️ delegación: cambios del ayudante aplicados")
                // A helper on an old version changed something: Firestore's
                // helpers see it too.
                await reconcileUp()
            }
        } catch {
            if let ckError = error as? CKError, ckError.code == .changeTokenExpired {
                Self.saveToken(nil) // reset → full re-pull next time
                ShareDiagnostics.log("⬇️ delegación: token expirado, reseteo")
            } else {
                ShareDiagnostics.log("❌ delegación pull: \(error.localizedDescription)")
            }
        }
    }

    /// Applies one helper-written record. Returns whether something changed and, if
    /// it was a (soft) delete, the local id removed.
    private func applyHelperChange(_ record: CKRecord, in context: ModelContext) -> (changed: Bool, deletedID: UUID?) {
        let payload = sharing.decodePayload(from: record)
        if payload.isDeleted == true {
            let id = applyHelperDeletion(record.recordID, in: context)
            return (id != nil, id)
        }
        let localID = UUID(uuidString: record.recordID.recordName) ?? UUID(uuidString: payload.id) ?? UUID()
        let descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.id == localID })
        let existing = try? context.fetch(descriptor).first
        // LWW: if local is newer than the incoming payload, keep local (reconcileUp
        // will re-push it). Tolerance absorbs Date round-trip jitter.
        if let existing, let payloadUpdated = payload.updatedAt,
           existing.updatedAt > payloadUpdated.addingTimeInterval(1) {
            return (false, nil)
        }
        let customCategoryID = sharing.ensureCustomCategory(payload.customCategory, in: context)
        let reminder: Reminder
        if let existing {
            reminder = existing
        } else {
            reminder = Reminder(id: localID)
            context.insert(reminder)
        }
        sharing.apply(payload, to: reminder, customCategoryID: customCategoryID, markAsReceivedShare: false)
        // Not added to `recentlyAppliedFromZone`: the Firestore mirror still has
        // to get it (the CloudKit echo is harmless, the content is the same).
        return (true, nil)
    }

    /// Deletes a local reminder a helper removed. Returns the id if one was deleted.
    @discardableResult
    private func applyHelperDeletion(_ recordID: CKRecord.ID, in context: ModelContext) -> UUID? {
        guard let localID = UUID(uuidString: recordID.recordName) else { return nil }
        let descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.id == localID })
        guard let existing = try? context.fetch(descriptor).first else { return nil }
        context.delete(existing)
        recentlyAppliedFromZone.insert(localID)
        lastSyncedUpdatedAt[localID] = nil
        if let uid = firestorePrincipalUID {
            Task { try? await remindersRef(uid).document(localID.uuidString).delete() }
        }
        return localID
    }

    /// Subscribes (private DB) to the CloudKit delegation zone so changes from
    /// helpers on old versions arrive via silent push. Firestore changes arrive
    /// through FCM (the Cloud Functions).
    func ensurePrincipalSubscription() async {
        guard await existingZoneShare() != nil else { return }
        let database = cloudKitContainer.privateCloudDatabase
        let subID = "delegation-zone-changes"
        if (try? await database.subscription(for: subID)) != nil { return }
        let subscription = CKRecordZoneSubscription(zoneID: principalZoneID, subscriptionID: subID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try? await database.save(subscription)
        ShareDiagnostics.log("🔔 suscripción a DelegationZone (privada) creada")
    }

    // MARK: - Helper side

    /// Joins a principal's list with a Firestore invitation. Nothing is ingested
    /// into local SwiftData: the helper only gains access to the principal's
    /// documents, surfaced read/write via `helperFetchReminders`.
    func joinFirestoreDelegation(_ invite: SharedRemindersService.FirestoreInvite) async throws {
        let (uid, name) = try await sharing.sharingIdentity()
        // Su propia invitación: nada que hacer.
        guard invite.kind == .delegation, invite.targetID != uid else { return }
        let ref = db.collection("delegations").document(invite.targetID)
        do {
            try await ref.updateData([
                FieldPath(["helpers", uid]): ["name": name, "addedAt": FieldValue.serverTimestamp()],
                "helperUids": FieldValue.arrayUnion([uid]),
                "joinToken": invite.token,
            ])
            ShareDiagnostics.log("🤝 Firestore: lista de confianza aceptada")
        } catch where FirestoreValues.isPermissionDenied(error) || FirestoreValues.isNotFound(error) {
            // Ya estaba (el mismo enlace otra vez): si puede leerla, es que sí.
            guard (try? await ref.getDocument(source: .server))?.exists == true else {
                throw SharedRemindersError.inviteInvalid
            }
        }
        // Nudge any open "Listas que administro" view to reload.
        NotificationCenter.default.post(name: .calarmSharedDataChanged, object: nil)
    }

    /// Accepts an incoming CloudKit DELEGATION share (an invitation sent before
    /// 1.1). Unlike a per-record reminder share, nothing is ingested into local
    /// SwiftData — the helper only gains access to the principal's shared zone.
    func acceptDelegationShare(metadata: CKShare.Metadata) async {
        do {
            let acceptedShare = try await cloudKitContainer.accept(metadata)
            ShareDiagnostics.log("🤝 delegación aceptada")
            // Que quien me invitó vea mi nombre en «Personas de confianza».
            sharing.announceMyself(in: acceptedShare)
            NotificationCenter.default.post(name: .calarmSharedDataChanged, object: nil)
        } catch {
            lastErrorMessage = SharedRemindersError.acceptFailed(error).errorDescription
            ShareDiagnostics.log("❌ aceptar delegación: \(error.localizedDescription)")
        }
    }

    /// Lists the principals whose alarm lists this device (as a helper) can
    /// manage: Firestore's, plus CloudKit zones of principals on old versions.
    /// A CloudKit list whose principal already moved to Firestore (the token
    /// is in its records) is joined there and left in CloudKit.
    func helperPrincipals() async -> [DelegationPrincipal] {
        var principals = await firestorePrincipals()
        var migrated = false
        let database = cloudKitContainer.sharedCloudDatabase
        if let zones = try? await database.allRecordZones() {
            for zone in zones where zone.zoneID.zoneName == Self.zoneName {
                if await migrateHelperZone(zone.zoneID) {
                    migrated = true
                    continue
                }
                let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zone.zoneID)
                let share = try? await database.record(for: shareID) as? CKShare
                let published = if let share { await sharing.ownerPerson(of: share)?.name } else { String?.none }
                let name = published ?? SharedRemindersService.displayName(share?.owner.userIdentity)
                principals.append(DelegationPrincipal(id: zone.zoneID.ownerName, source: .cloudKit(zone.zoneID), name: name))
            }
        }
        if migrated {
            principals = await firestorePrincipals() + principals.filter {
                if case .cloudKit = $0.source { true } else { false }
            }
        }
        return principals
    }

    private func firestorePrincipals() async -> [DelegationPrincipal] {
        guard let uid = FirebaseSession.shared.uid,
              let snapshot = try? await db.collection("delegations")
                .whereField("helperUids", arrayContains: uid)
                .getDocuments()
        else { return [] }
        return snapshot.documents.map { document in
            DelegationPrincipal(
                id: document.documentID,
                source: .firestore,
                name: FirestoreMapping.validName(document.data()["principalName"] as? String) ?? appLocalized("Alguien")
            )
        }
    }

    /// Helper side of the migration: joins the Firestore list with the token
    /// the principal wrote in the zone's records, then leaves the CloudKit share.
    /// True when the zone was moved.
    private func migrateHelperZone(_ zoneID: CKRecordZone.ID) async -> Bool {
        guard sharing.hasSharingIdentity,
              let token = await cloudKitReminders(in: zoneID, includeDeleted: true)
                .lazy.compactMap(\.payload.firebaseToken).first(where: InviteToken.isValid)
        else { return false }
        do {
            let invite = try await sharing.fetchInvite(token)
            guard invite.kind == .delegation else { return false }
            try await joinFirestoreDelegation(invite)
            // A participant leaves a zone-wide share by deleting it from their
            // shared database.
            let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
            _ = try? await cloudKitContainer.sharedCloudDatabase.deleteRecord(withID: shareID)
            ShareDiagnostics.log("🔀 lista de confianza migrada a Firestore (ayudante)")
            return true
        } catch {
            ShareDiagnostics.log("⚠️ migración de lista (ayudante): \(error.localizedDescription)")
            return false
        }
    }

    /// Reads the delegated alarms of a principal (helper view).
    func helperFetchReminders(for principal: DelegationPrincipal) async -> [DelegatedReminder] {
        switch principal.source {
        case .cloudKit(let zoneID):
            return await cloudKitReminders(in: zoneID, includeDeleted: false).sorted { $0.date < $1.date }
        case .firestore:
            guard let snapshot = try? await remindersRef(principal.id).getDocuments() else { return [] }
            return snapshot.documents.compactMap { document -> DelegatedReminder? in
                let data = FirestoreValues.document(document.data())
                guard data["deleted"] as? Bool != true,
                      let id = UUID(uuidString: document.documentID),
                      var payload = FirestoreMapping.payload(
                          fromAlarm: data["alarm"], id: document.documentID, updatedAt: data["updatedAt"] as? Date
                      )
                else { return nil }
                payload.photoThumbnail = data["photo"] as? Data
                return DelegatedReminder(id: id, source: .firestore(docID: document.documentID), payload: payload)
            }
            .sorted { $0.date < $1.date }
        }
    }

    private func cloudKitReminders(in zoneID: CKRecordZone.ID, includeDeleted: Bool) async -> [DelegatedReminder] {
        let database = cloudKitContainer.sharedCloudDatabase
        guard let changes = try? await database.recordZoneChanges(inZoneWith: zoneID, since: nil) else {
            return []
        }
        var result: [DelegatedReminder] = []
        for modResult in changes.modificationResultsByID.values {
            guard case .success(let modification) = modResult else { continue }
            let record = modification.record
            guard record.recordType == "CalarmSharedReminder" else { continue }
            let payload = sharing.decodePayload(from: record)
            if payload.isDeleted == true, !includeDeleted { continue }
            let id = UUID(uuidString: record.recordID.recordName) ?? UUID(uuidString: payload.id) ?? UUID()
            result.append(DelegatedReminder(id: id, source: .cloudKit(record.recordID), payload: payload))
        }
        return result
    }

    /// Creates or updates a delegated alarm. Stamps a fresh `updatedAt` so it
    /// wins by last-writer-wins on the principal.
    func helperUpsert(_ payload: SharePayload, for principal: DelegationPrincipal, existing: DelegatedReminder?) async {
        var payload = payload
        payload.updatedAt = Date()
        payload.isDeleted = nil
        switch principal.source {
        case .firestore:
            guard let uid = FirebaseSession.shared.uid else { return }
            var docID = payload.id
            if case .firestore(let existingID)? = existing?.source { docID = existingID }
            do {
                // `merge`: la foto que ya tenía (este editor no la cambia) se queda.
                try await remindersRef(principal.id).document(docID).setData([
                    "alarm": FirestoreMapping.alarmMap(from: payload),
                    "deleted": false,
                    "revision": FieldValue.increment(Int64(1)),
                    "updatedAt": FieldValue.serverTimestamp(),
                    "updatedBy": uid,
                ], merge: true)
                ShareDiagnostics.log("🤝⬆️ ayudante guardó '\(payload.title)'")
            } catch {
                lastErrorMessage = error.localizedDescription
                ShareDiagnostics.log("❌ ayudante guardar: \(error.localizedDescription)")
            }
        case .cloudKit(let zoneID):
            let database = cloudKitContainer.sharedCloudDatabase
            var recordID = CKRecord.ID(recordName: payload.id, zoneID: zoneID)
            if case .cloudKit(let existingID)? = existing?.source { recordID = existingID }
            let record = (try? await database.record(for: recordID))
                ?? CKRecord(recordType: "CalarmSharedReminder", recordID: recordID)
            sharing.writePayload(payload, to: record)
            _ = try? await database.modifyRecords(saving: [record], deleting: [])
            ShareDiagnostics.log("🤝⬆️ ayudante guardó '\(payload.title)'")
        }
    }

    /// Soft-deletes a delegated alarm (so it wins by `updatedAt` instead of racing
    /// a concurrent edit; the principal physically removes it).
    func helperDelete(_ item: DelegatedReminder, for principal: DelegationPrincipal) async {
        switch item.source {
        case .firestore(let docID):
            guard let uid = FirebaseSession.shared.uid else { return }
            do {
                try await remindersRef(principal.id).document(docID).updateData([
                    "deleted": true,
                    "revision": FieldValue.increment(Int64(1)),
                    "updatedAt": FieldValue.serverTimestamp(),
                    "updatedBy": uid,
                ])
                ShareDiagnostics.log("🤝🗑️ ayudante borró")
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        case .cloudKit(let recordID):
            let database = cloudKitContainer.sharedCloudDatabase
            guard let record = try? await database.record(for: recordID) else { return }
            var payload = sharing.decodePayload(from: record)
            payload.isDeleted = true
            payload.updatedAt = Date()
            sharing.writePayload(payload, to: record)
            _ = try? await database.modifyRecords(saving: [record], deleting: [])
            ShareDiagnostics.log("🤝🗑️ ayudante borró")
        }
    }

    // MARK: - Token / last-synced persistence

    private static func loadToken() -> CKServerChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: tokenKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private static func saveToken(_ token: CKServerChangeToken?) {
        guard let token else { UserDefaults.standard.removeObject(forKey: tokenKey); return }
        let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        UserDefaults.standard.set(data, forKey: tokenKey)
    }

    private static func loadLastSynced() -> [UUID: Date] {
        guard let raw = UserDefaults.standard.dictionary(forKey: lastSyncedKey) as? [String: Date] else { return [:] }
        var map: [UUID: Date] = [:]
        for (key, value) in raw { if let id = UUID(uuidString: key) { map[id] = value } }
        return map
    }

    private func persistLastSynced() {
        var raw: [String: Date] = [:]
        for (id, date) in lastSyncedUpdatedAt { raw[id.uuidString] = date }
        UserDefaults.standard.set(raw, forKey: Self.lastSyncedKey)
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
