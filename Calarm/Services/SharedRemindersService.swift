//
//  SharedRemindersService.swift
//  Calarm
//
//  Wraps CloudKit sharing operations for Reminder records.
//
//  SwiftData persists Reminders to a CloudKit private database via NSPersistentCloudKitContainer
//  under the hood. For sharing, we drop down to direct CloudKit APIs: create a CKShare anchored
//  to a custom record zone, and present the share via UICloudSharingController / ShareLink.
//

import CloudKit
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
    case shareCreationFailed(any Error)
    case acceptFailed(any Error)

    var errorDescription: String? {
        switch self {
        case .noCloudKitAccount:
            return "Inicia sesión en iCloud para compartir alarmas."
        case .shareUnavailable:
            return "No se pudo preparar la alarma para compartirla."
        case .shareCreationFailed(let error):
            return "Error al compartir: \(error.localizedDescription)"
        case .acceptFailed(let error):
            return "Error al aceptar la invitación: \(error.localizedDescription)"
        }
    }
}

/// A share participant rendered for the UI: who they are and whether they joined.
struct ShareParticipantInfo: Identifiable {
    let id = UUID()
    let name: String
    let email: String?
    let phone: String?
    let status: CKShare.ParticipantAcceptanceStatus
    let isOwner: Bool

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
    private let cloudKitContainer: CKContainer
    private let modelContainer: ModelContainer

    /// Latest error message surfaced to the UI when an operation fails.
    private(set) var lastErrorMessage: String?
    /// Set when accepting an incoming invitation fails, so the app can alert the
    /// user instead of leaving them staring at a list that never updates.
    private(set) var acceptErrorMessage: String?

    private static let log = Logger(subsystem: "MathyuSolutions.Calarm", category: "sharing")

    init(modelContainer: ModelContainer, containerIdentifier: String = "iCloud.MathyuSolutions.Calarm") {
        self.modelContainer = modelContainer
        self.containerIdentifier = containerIdentifier
        self.cloudKitContainer = CKContainer(identifier: containerIdentifier)
    }

    func clearAcceptError() {
        acceptErrorMessage = nil
    }

    // MARK: - Owner side

    /// Prepares (creating if needed) a `CKShare` for the given reminder and returns it
    /// together with the shared record's CKRecord. Used by ShareLink's preparation handler.
    func prepareShare(for reminder: Reminder) async throws -> CKShare {
        // Convert the reminder to a CKRecord stored in a dedicated, shareable zone.
        let zone = try await ensureSharingZone()
        let recordID = CKRecord.ID(recordName: reminder.id.uuidString, zoneID: zone.zoneID)
        let database = cloudKitContainer.privateCloudDatabase

        // Fetch existing share for this record if it already exists.
        if let existingShare = try? await fetchExistingShare(for: recordID) {
            // Shares created before public-link support used `.none`, which denies
            // anyone opening the invite link ("Item Unavailable / no permission").
            // Upgrade such a share in place so re-sharing an old alarm just works.
            if existingShare.publicPermission == .none {
                existingShare.publicPermission = .readOnly
                if let results = try? await database.modifyRecords(saving: [existingShare], deleting: []),
                   case .success(let saved) = results.saveResults[existingShare.recordID],
                   let savedShare = saved as? CKShare {
                    return savedShare
                }
            }
            return existingShare
        }

        let record = makeRecord(from: reminder, recordID: recordID)
        let share = CKShare(rootRecord: record, shareID: CKRecord.ID(
            recordName: "share-\(reminder.id.uuidString)",
            zoneID: zone.zoneID
        ))
        share[CKShare.SystemFieldKey.title] = reminder.title as CKRecordValue
        share[CKShare.SystemFieldKey.shareType] = "com.mathyusolutions.calarm.reminder" as CKRecordValue
        // Custom thumbnail so the rich link preview in iMessage/Mail shows the
        // reminder's photo or its category icon — not the generic iCloud cloud.
        if let thumbnail = makeShareThumbnail(for: reminder) {
            share[CKShare.SystemFieldKey.thumbnailImageData] = thumbnail as CKRecordValue
        }
        // Anyone who receives the invite link must be able to open it. We deliver
        // the raw share URL over Messages / the share sheet without adding each
        // recipient as an explicit participant, so the share has to grant access
        // to public (link-based) users. With `.none`, link recipients are denied
        // with "Item Unavailable / you don't have permission to open it".
        share.publicPermission = .readOnly

        do {
            let results = try await database.modifyRecords(saving: [record, share], deleting: [])
            // Return the server-updated share, which has the .url property populated.
            if case .success(let saved) = results.saveResults[share.recordID],
               let savedShare = saved as? CKShare {
                return savedShare
            }
            return share
        } catch {
            throw SharedRemindersError.shareCreationFailed(error)
        }
    }

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
            ShareParticipantInfo(
                name: Self.displayName(participant.userIdentity),
                email: participant.userIdentity.lookupInfo?.emailAddress,
                phone: participant.userIdentity.lookupInfo?.phoneNumber,
                status: participant.acceptanceStatus,
                isOwner: participant.role == .owner
            )
        }
    }

    /// Builds a `SharedByPerson` from a share's owner identity (recipient side).
    static func owner(from metadata: CKShare.Metadata) -> SharedByPerson {
        SharedByPerson(
            name: displayName(metadata.ownerIdentity),
            email: metadata.ownerIdentity.lookupInfo?.emailAddress,
            phone: metadata.ownerIdentity.lookupInfo?.phoneNumber
        )
    }

    /// Best-effort human name for a CloudKit identity: full name if shared,
    /// otherwise the email/phone, otherwise a generic placeholder.
    static func displayName(_ identity: CKUserIdentity?) -> String {
        if let components = identity?.nameComponents {
            let formatted = PersonNameComponentsFormatter().string(from: components)
            if !formatted.isEmpty { return formatted }
        }
        if let email = identity?.lookupInfo?.emailAddress, !email.isEmpty { return email }
        if let phone = identity?.lookupInfo?.phoneNumber, !phone.isEmpty { return phone }
        return appLocalized("Alguien")
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
        let zoneID = CKRecordZone.ID(zoneName: Self.sharingZoneName, ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: reminder.id.uuidString, zoneID: zoneID)
        let database = cloudKitContainer.privateCloudDatabase
        guard let record = try? await database.record(for: recordID) else { return }
        writeFields(from: reminder, to: record)
        _ = try? await database.modifyRecords(saving: [record], deleting: [])
        ShareDiagnostics.log("↻ push update '\(reminder.title)'")
    }

    /// If the owner deleted a shared reminder, remove its CloudKit record + share so
    /// participants lose access and their copy is reconciled away on next sync.
    /// Takes the id (not the `Reminder`) since the local object is deleted first.
    func deleteSharedRecord(forReminderID id: UUID) async {
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

    /// Accepts an incoming share invitation, fetches the shared record, and creates a local
    /// `Reminder` row marked as shared.
    func acceptShare(metadata: CKShare.Metadata) async throws {
        Self.log.info("acceptShare: accepting invitation")
        ShareDiagnostics.log("▶️ acceptShare: aceptando…")
        do {
            _ = try await cloudKitContainer.accept(metadata)
            ShareDiagnostics.log("✅ accept() OK")
            try await ingestSharedRecord(from: metadata)
            acceptErrorMessage = nil
            Self.log.info("acceptShare: ingested shared reminder OK")
            ShareDiagnostics.log("✅ ingesta completa")
        } catch {
            let wrapped = SharedRemindersError.acceptFailed(error)
            acceptErrorMessage = wrapped.errorDescription
            Self.log.error("acceptShare failed: \(error.localizedDescription, privacy: .public)")
            ShareDiagnostics.log("❌ acceptShare error: \(error.localizedDescription)")
            throw wrapped
        }
    }

    // MARK: - Private helpers

    private static let sharingZoneName = "SharedRemindersZone"

    private func ensureSharingZone() async throws -> CKRecordZone {
        let zoneID = CKRecordZone.ID(zoneName: Self.sharingZoneName, ownerName: CKCurrentUserDefaultName)
        let database = cloudKitContainer.privateCloudDatabase
        do {
            let existing = try await database.recordZone(for: zoneID)
            return existing
        } catch {
            // Zone doesn't exist yet — create it.
            let zone = CKRecordZone(zoneID: zoneID)
            _ = try await database.modifyRecordZones(saving: [zone], deleting: [])
            return zone
        }
    }

    private func fetchExistingShare(for recordID: CKRecord.ID) async throws -> CKShare? {
        let database = cloudKitContainer.privateCloudDatabase
        guard let record = try? await database.record(for: recordID) else { return nil }
        guard let shareReference = record.share else { return nil }
        return try? await database.record(for: shareReference.recordID) as? CKShare
    }

    private func makeRecord(from reminder: Reminder, recordID: CKRecord.ID) -> CKRecord {
        let record = CKRecord(recordType: "CalarmSharedReminder", recordID: recordID)
        writeFields(from: reminder, to: record)
        return record
    }

    /// Writes a reminder's data onto a (new or existing) shared record. Reused when
    /// the owner edits a shared reminder so the same record is updated in place,
    /// preserving its `CKShare` association.
    func writeFields(from reminder: Reminder, to record: CKRecord) {
        // Authoritative copy: a single versioned JSON envelope (the `payload` Bytes
        // field). Adding a new shared property means adding a field to `SharePayload`
        // and bumping its version — never another CloudKit schema change.
        if let data = try? JSONEncoder().encode(makePayload(from: reminder)) {
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
    func makePayload(from reminder: Reminder) -> SharePayload {
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
            photoThumbnail: photoThumbnailData(from: reminder)
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

    @MainActor
    private func ingestSharedRecord(from metadata: CKShare.Metadata) async throws {
        // `hierarchicalRootRecordID` is the modern accessor; fall back to the
        // deprecated `rootRecordID` so we always resolve the shared record's ID.
        let rootRecordID = metadata.hierarchicalRootRecordID ?? metadata.rootRecordID
        let database = cloudKitContainer.sharedCloudDatabase
        ShareDiagnostics.log("ingest: rootRecord=\(rootRecordID.recordName)")

        // Right after accepting, the shared record can take a moment to appear in
        // the shared database. Retry a few times before giving up so the reminder
        // doesn't silently fail to import.
        var fetched: CKRecord?
        for attempt in 1...5 {
            do {
                fetched = try await database.record(for: rootRecordID)
                break
            } catch {
                Self.log.info("Fetch shared record attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)")
                ShareDiagnostics.log("ingest: fetch intento \(attempt) falló: \(error.localizedDescription)")
                if attempt < 5 {
                    try? await Task.sleep(nanoseconds: 600_000_000) // 0.6s
                }
            }
        }
        guard let record = fetched else {
            Self.log.error("Shared record unavailable after retries for \(rootRecordID.recordName, privacy: .public)")
            ShareDiagnostics.log("❌ ingest: record no disponible tras 5 intentos")
            throw SharedRemindersError.shareUnavailable
        }
        ShareDiagnostics.log("ingest: record OK (payload=\(record["payload"] != nil))")

        let context = modelContainer.mainContext
        let applied = applyRecord(record, owner: Self.owner(from: metadata), in: context)
        try context.save()
        CategoryStore.shared?.reload()
        ShareDiagnostics.log("✅ ingest: reminder guardado '\(applied.title)'")
    }

    /// Scans the shared database for `CalarmSharedReminder` records and imports
    /// any found. This is the RELIABLE path: it runs on launch / activation and
    /// doesn't depend on the `userDidAcceptCloudKitShareWith` callback, which iOS
    /// frequently fails to deliver to SwiftUI apps. Accepting a share (tapping
    /// "Open") makes the owner's zone appear in the recipient's shared database,
    /// so we just read whatever is there.
    func importAllSharedReminders() async {
        let database = cloudKitContainer.sharedCloudDatabase
        do {
            let zones = try await database.allRecordZones()
            ShareDiagnostics.log("scan: \(zones.count) zona(s) compartida(s)")
            let context = modelContainer.mainContext
            var imported = 0
            var presentIDs: Set<UUID> = []
            for zone in zones {
                // SAFETY: never ingest the delegation zone here. Those records are
                // someone else's alarms that this device (acting as a helper) only
                // MANAGES — ingesting them into local SwiftData would make them ring
                // on the helper's phone. They're handled separately by DelegationService.
                guard zone.zoneID.zoneName != DelegationService.zoneName else { continue }
                let changes = try await database.recordZoneChanges(inZoneWith: zone.zoneID, since: nil)
                for modResult in changes.modificationResultsByID.values {
                    guard case .success(let modification) = modResult else { continue }
                    let record = modification.record
                    guard record.recordType == "CalarmSharedReminder" else { continue }
                    let applied = applyRecord(record, owner: nil, in: context)
                    presentIDs.insert(applied.id)
                    imported += 1
                }
            }
            if imported > 0 {
                try? context.save()
                CategoryStore.shared?.reload()
                ShareDiagnostics.log("✅ scan: \(imported) recordatorio(s) importado(s)")
            } else {
                ShareDiagnostics.log("scan: sin recordatorios compartidos")
            }
            // Scan completed without error → safe to remove copies the owner
            // deleted or unshared (their record is no longer present).
            reconcileDeletedShares(presentIDs: presentIDs, in: context)
        } catch {
            Self.log.error("importAllSharedReminders failed: \(error.localizedDescription, privacy: .public)")
            ShareDiagnostics.log("❌ scan error: \(error.localizedDescription)")
        }
    }

    /// Upserts a shared `CalarmSharedReminder` CKRecord into a local `Reminder`
    /// (marked as a received share). Caller is responsible for saving the context.
    /// `owner` (when known, i.e. from the accept metadata) is remembered so the
    /// recipient can see who shared it. Returns the local id + title.
    @discardableResult
    private func applyRecord(_ record: CKRecord, owner: SharedByPerson?, in context: ModelContext) -> (id: UUID, title: String) {
        let payload = decodePayload(from: record)
        let customCategoryID = ensureCustomCategory(payload.customCategory, in: context)
        // Reuse the record name as the local UUID so importing twice updates the
        // reminder in place instead of duplicating it.
        let localID = UUID(uuidString: record.recordID.recordName)
            ?? UUID(uuidString: payload.id)
            ?? UUID()
        let descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.id == localID })
        let reminder: Reminder
        if let existing = try? context.fetch(descriptor).first {
            reminder = existing
        } else {
            reminder = Reminder(id: localID)
            context.insert(reminder)
        }
        apply(payload, to: reminder, customCategoryID: customCategoryID)
        // Only overwrite the remembered owner when we actually know it (accept
        // path), so the scan fallback doesn't wipe a previously captured name.
        if let owner {
            ShareOwnerStore.set(owner, for: localID)
        }
        return (localID, payload.title)
    }

    /// Removes local received-share reminders whose shared record is no longer
    /// present (owner deleted it or stopped sharing). Only call after a SUCCESSFUL
    /// scan, never on error, so a transient fetch failure can't wipe valid copies.
    private func reconcileDeletedShares(presentIDs: Set<UUID>, in context: ModelContext) {
        let descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.isReceivedShare })
        guard let received = try? context.fetch(descriptor) else { return }
        var removed = 0
        for reminder in received where !presentIDs.contains(reminder.id) {
            context.delete(reminder)
            removed += 1
        }
        if removed > 0 {
            try? context.save()
            CategoryStore.shared?.reload()
            ShareDiagnostics.log("🗑️ scan: \(removed) compartido(s) eliminado(s) por el dueño")
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
        let leadTimes = payload.leadTimeSeconds.compactMap { AlarmLeadTime(rawValue: $0) }
        reminder.leadTimes = leadTimes.isEmpty ? [.atStart] : leadTimes
        reminder.isEnabled = payload.isEnabled
        reminder.updatedAt = payload.updatedAt ?? Date()
        reminder.isReceivedShare = markAsReceivedShare
    }

    // MARK: - Share thumbnail

    /// Produces a square PNG used as the rich-link preview in Messages, Mail,
    /// AirDrop, etc. Uses the reminder's photo if present, otherwise renders a
    /// circle with the category's tint + symbol so the preview matches the
    /// in-app avatar instead of showing Apple's generic iCloud icon.
    private func makeShareThumbnail(for reminder: Reminder) -> Data? {
        let tint = reminder.category.tint
        // Prefer the user-attached photo when available.
        if reminder.iconKind == .photo,
           let data = reminder.photoData,
           let image = UIImage(data: data) {
            return resized(image, to: 256).pngData()
        }
        if reminder.iconKind == .emoji, let emoji = reminder.symbolName, !emoji.isEmpty {
            return renderIconThumbnail(tint: tint) {
                Text(emoji).font(.system(size: 150))
            }
        }
        return renderIconThumbnail(tint: tint) {
            Image(systemName: reminder.symbolName ?? reminder.category.defaultSymbol)
                .font(.system(size: 128, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    /// Center-crops + scales `image` to `size × size`. Keeps the thumbnail tight
    /// to where the subject lives without distortion.
    private func resized(_ image: UIImage, to size: CGFloat) -> UIImage {
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

    /// Renders a tinted square badge with arbitrary icon content (SF Symbol or
    /// emoji) to PNG data for use as the share thumbnail.
    private func renderIconThumbnail<Content: View>(tint: Color, @ViewBuilder content: () -> Content) -> Data? {
        let view = ZStack {
            RoundedRectangle(cornerRadius: 56, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint, tint.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            content()
        }
        .frame(width: 256, height: 256)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        return renderer.uiImage?.pngData()
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

    struct CustomCategoryInfo: Codable {
        var id: String
        var name: String
        var colorHex: String
        var iconKindRaw: Int
        var iconValue: String
    }
}
