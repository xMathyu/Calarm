//
//  DelegationService.swift
//  Calarm
//
//  "Personas de confianza" (delegation). The principal shares their ENTIRE alarm
//  list, read/write, with trusted helpers (an assistant, a partner). Helpers can
//  create/edit/delete alarms that RING on the principal's phone.
//
//  Architecture:
//  - A dedicated custom zone `DelegationZone` in the principal's private DB, shared
//    via a ZONE-WIDE CKShare with helpers as .readWrite participants. This is a
//    SEPARATE zone from `SharedRemindersZone` (a zone can't mix per-record and
//    zone-wide sharing).
//  - The principal's SwiftData store stays the source of truth (so alarms ring).
//    Reminders are mirrored into the zone; helper changes are pulled back in.
//  - The HELPER never inserts into their own SwiftData — they read/write the shared
//    zone directly — so delegated alarms never ring on the helper's phone.
//  - Reuses SharedRemindersService's payload codec (makePayload/writeFields/
//    decodePayload/apply/ensureCustomCategory) and the `CalarmSharedReminder`
//    record type + `payload` envelope (already in Production — no schema change).
//

import CloudKit
import Foundation
import Observation
import os
import SwiftData

/// A delegated reminder as seen by a helper (backed by a CloudKit record, never a
/// local `Reminder`).
struct DelegatedReminder: Identifiable {
    let id: UUID
    let recordID: CKRecord.ID
    let payload: SharePayload

    var title: String { payload.title }
    var date: Date { payload.date }
    var isEnabled: Bool { payload.isEnabled }
}

/// A principal whose alarm list a helper has been granted access to.
struct DelegationPrincipal: Identifiable {
    let id: String          // zone owner name (stable per principal)
    let zoneID: CKRecordZone.ID
    let name: String        // owner display name
}

@Observable
@MainActor
final class DelegationService {
    static let zoneName = "DelegationZone"
    static let shareType = "com.mathyusolutions.calarm.delegation"

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

    private(set) var lastErrorMessage: String?

    /// IDs just written locally from a remote (helper) change — skipped by the next
    /// up-sync pass so we don't echo them straight back to the zone (ping-pong).
    private var recentlyAppliedFromZone: Set<UUID> = []
    /// Per-reminder last-synced timestamp, the up-sync change detector.
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

    // MARK: - Principal: zone + zone-wide share

    private var principalZoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    private func ensureDelegationZone() async throws -> CKRecordZone {
        let database = cloudKitContainer.privateCloudDatabase
        if let existing = try? await database.recordZone(for: principalZoneID) {
            return existing
        }
        let zone = CKRecordZone(zoneID: principalZoneID)
        _ = try await database.modifyRecordZones(saving: [zone], deleting: [])
        return zone
    }

    /// Returns the existing zone-wide share, or nil if delegation isn't set up.
    func existingZoneShare() async -> CKShare? {
        let database = cloudKitContainer.privateCloudDatabase
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: principalZoneID)
        return try? await database.record(for: shareID) as? CKShare
    }

    /// Creates (or returns) the zone-wide share for the principal's alarms. The
    /// caller presents `CloudSharingView` with the returned share to invite helpers
    /// (set their permission to read/write there).
    func prepareZoneShare() async throws -> CKShare {
        let zone = try await ensureDelegationZone()
        let database = cloudKitContainer.privateCloudDatabase
        if let existing = await existingZoneShare() { return existing }

        let share = CKShare(recordZoneID: zone.zoneID)
        share[CKShare.SystemFieldKey.title] = "Mis alarmas (Calarm)" as CKRecordValue
        share[CKShare.SystemFieldKey.shareType] = Self.shareType as CKRecordValue
        share.publicPermission = .none // only explicitly invited, trusted helpers
        do {
            let result = try await database.modifyRecords(saving: [share], deleting: [])
            if case .success(let saved) = result.saveResults[share.recordID],
               let savedShare = saved as? CKShare {
                ShareDiagnostics.log("👥 zone-wide share de delegación creado")
                return savedShare
            }
            return share
        } catch {
            lastErrorMessage = SharedRemindersError.shareCreationFailed(error).errorDescription
            throw error
        }
    }

    /// Participants of the delegation share (for the management UI). Excludes the
    /// owner (the principal themselves).
    func participantInfos() async -> [ShareParticipantInfo] {
        guard let share = await existingZoneShare() else { return [] }
        return sharing.participantInfos(of: share).filter { !$0.isOwner }
    }

    /// Removes a helper (by matching email/phone) from the share.
    func removeHelper(email: String?, phone: String?) async {
        guard let share = await existingZoneShare() else { return }
        let target = share.participants.first { participant in
            let info = participant.userIdentity.lookupInfo
            return (email != nil && info?.emailAddress == email)
                || (phone != nil && info?.phoneNumber == phone)
        }
        guard let target, target.role != .owner else { return }
        share.removeParticipant(target)
        let database = cloudKitContainer.privateCloudDatabase
        _ = try? await database.modifyRecords(saving: [share], deleting: [])
        ShareDiagnostics.log("🚫 helper removido del share de delegación")
    }

    /// Turns delegation off: removes the zone-wide share (revokes all helpers). The
    /// principal's own alarms stay local and keep ringing.
    func disableDelegation() async {
        guard let share = await existingZoneShare() else { return }
        let database = cloudKitContainer.privateCloudDatabase
        _ = try? await database.modifyRecords(saving: [], deleting: [share.recordID])
        ShareDiagnostics.log("👥 delegación desactivada (share borrado)")
    }

    // MARK: - Principal: mirror local alarms up to the zone

    /// Pushes every local (owned) reminder into the delegation zone so helpers see
    /// the full list. Idempotent (record name = reminder.id). Runs on enable and on
    /// app launch/foreground while delegation is on.
    func mirrorAllLocalReminders() async {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { !$0.isReceivedShare })
        guard let reminders = try? context.fetch(descriptor), !reminders.isEmpty else {
            ShareDiagnostics.log("delegación: sin alarmas locales que reflejar")
            return
        }
        guard (try? await ensureDelegationZone()) != nil else { return }
        let database = cloudKitContainer.privateCloudDatabase
        let zoneID = principalZoneID
        var records: [CKRecord] = []
        for reminder in reminders {
            let recordID = CKRecord.ID(recordName: reminder.id.uuidString, zoneID: zoneID)
            // Update the existing record in place when present, to keep its etag.
            let record = (try? await database.record(for: recordID))
                ?? CKRecord(recordType: "CalarmSharedReminder", recordID: recordID)
            sharing.writeFields(from: reminder, to: record)
            records.append(record)
        }
        // CloudKit caps batch size; chunk conservatively.
        for chunk in records.chunked(into: 200) {
            _ = try? await database.modifyRecords(saving: chunk, deleting: [])
        }
        for reminder in reminders { lastSyncedUpdatedAt[reminder.id] = reminder.updatedAt }
        persistLastSynced()
        ShareDiagnostics.log("⬆️ delegación: \(records.count) alarma(s) reflejada(s) a la zona")
    }

    /// Incremental up-sync: pushes only locally-changed reminders (new or with a
    /// newer `updatedAt` than last synced), skipping ones just applied from the zone
    /// to avoid echo. Runs on launch/foreground; the write hooks push immediately.
    func reconcileUp() async {
        guard await existingZoneShare() != nil else { return }
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { !$0.isReceivedShare })
        guard let reminders = try? context.fetch(descriptor) else { return }
        let database = cloudKitContainer.privateCloudDatabase
        var toPush: [CKRecord] = []
        for reminder in reminders {
            if recentlyAppliedFromZone.contains(reminder.id) { continue }
            if let synced = lastSyncedUpdatedAt[reminder.id], reminder.updatedAt <= synced.addingTimeInterval(1) {
                continue
            }
            let recordID = CKRecord.ID(recordName: reminder.id.uuidString, zoneID: principalZoneID)
            let record = (try? await database.record(for: recordID))
                ?? CKRecord(recordType: "CalarmSharedReminder", recordID: recordID)
            sharing.writeFields(from: reminder, to: record)
            toPush.append(record)
            lastSyncedUpdatedAt[reminder.id] = reminder.updatedAt
        }
        for chunk in toPush.chunked(into: 200) {
            _ = try? await database.modifyRecords(saving: chunk, deleting: [])
        }
        if !toPush.isEmpty {
            persistLastSynced()
            ShareDiagnostics.log("⬆️ reconcileUp: \(toPush.count) push")
        }
        recentlyAppliedFromZone.removeAll()
    }

    // MARK: - Principal: pull helper changes (down-sync)

    /// Pulls helper changes (upserts + deletions) from the principal's delegation
    /// zone (private DB) using a persisted change token, applies them to local
    /// SwiftData with last-writer-wins, and cancels alarms for deletions. The caller
    /// reschedules afterwards (so upserted alarms ring). No-op if not delegating.
    func pullPrincipalChanges() async {
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
        recentlyAppliedFromZone.insert(localID)
        lastSyncedUpdatedAt[localID] = reminder.updatedAt
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
        return localID
    }

    /// Subscribes (private DB) to the delegation zone so helper changes arrive via
    /// silent push. Distinct from the shared-DB subscription used elsewhere.
    func ensurePrincipalSubscription() async {
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

    // MARK: - Helper side: write into the principal's shared zone

    /// Creates or updates a delegated alarm in the principal's shared zone. Writes a
    /// fresh `updatedAt` so it wins by last-writer-wins on the principal.
    func helperUpsert(_ payload: SharePayload, in zoneID: CKRecordZone.ID, existingRecordID: CKRecord.ID?) async {
        var payload = payload
        payload.updatedAt = Date()
        payload.isDeleted = nil
        let database = cloudKitContainer.sharedCloudDatabase
        let recordID = existingRecordID ?? CKRecord.ID(recordName: payload.id, zoneID: zoneID)
        let record = (try? await database.record(for: recordID))
            ?? CKRecord(recordType: "CalarmSharedReminder", recordID: recordID)
        sharing.writePayload(payload, to: record)
        _ = try? await database.modifyRecords(saving: [record], deleting: [])
        ShareDiagnostics.log("🤝⬆️ ayudante guardó '\(payload.title)'")
    }

    /// Soft-deletes a delegated alarm (writes `isDeleted` so it wins by `updatedAt`
    /// instead of racing a concurrent edit; the principal physically removes it).
    func helperDelete(recordID: CKRecord.ID) async {
        let database = cloudKitContainer.sharedCloudDatabase
        guard let record = try? await database.record(for: recordID) else { return }
        var payload = sharing.decodePayload(from: record)
        payload.isDeleted = true
        payload.updatedAt = Date()
        sharing.writePayload(payload, to: record)
        _ = try? await database.modifyRecords(saving: [record], deleting: [])
        ShareDiagnostics.log("🤝🗑️ ayudante borró")
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

    /// Pushes a single reminder to the zone (owner edited/created). No-op if
    /// delegation isn't set up.
    func pushReminder(_ reminder: Reminder) async {
        guard !reminder.isReceivedShare else { return }
        guard await existingZoneShare() != nil else { return } // delegation not active
        let database = cloudKitContainer.privateCloudDatabase
        let recordID = CKRecord.ID(recordName: reminder.id.uuidString, zoneID: principalZoneID)
        let record = (try? await database.record(for: recordID))
            ?? CKRecord(recordType: "CalarmSharedReminder", recordID: recordID)
        sharing.writeFields(from: reminder, to: record)
        _ = try? await database.modifyRecords(saving: [record], deleting: [])
        ShareDiagnostics.log("⬆️ delegación: push '\(reminder.title)'")
    }

    /// Deletes a reminder's mirror record from the zone (owner deleted it).
    func deleteZoneRecord(forReminderID id: UUID) async {
        guard await existingZoneShare() != nil else { return }
        let database = cloudKitContainer.privateCloudDatabase
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: principalZoneID)
        _ = try? await database.modifyRecords(saving: [], deleting: [recordID])
        ShareDiagnostics.log("⬆️ delegación: borrado en zona \(id.uuidString)")
    }

    // MARK: - Helper side (managing someone else's alarms)

    /// Accepts an incoming DELEGATION share. Unlike a per-record reminder share, we
    /// do NOT ingest anything into local SwiftData — the helper only gains access to
    /// the principal's shared zone, surfaced read/write via `helperFetch…`.
    func acceptDelegationShare(metadata: CKShare.Metadata) async {
        do {
            _ = try await cloudKitContainer.accept(metadata)
            ShareDiagnostics.log("🤝 delegación aceptada de \(SharedRemindersService.displayName(metadata.ownerIdentity))")
        } catch {
            lastErrorMessage = SharedRemindersError.acceptFailed(error).errorDescription
            ShareDiagnostics.log("❌ aceptar delegación: \(error.localizedDescription)")
        }
    }

    /// Lists the principals whose alarm lists this device (as a helper) can manage.
    func helperPrincipals() async -> [DelegationPrincipal] {
        let database = cloudKitContainer.sharedCloudDatabase
        guard let zones = try? await database.allRecordZones() else { return [] }
        var principals: [DelegationPrincipal] = []
        for zone in zones where zone.zoneID.zoneName == Self.zoneName {
            let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zone.zoneID)
            let share = try? await database.record(for: shareID) as? CKShare
            let name = SharedRemindersService.displayName(share?.owner.userIdentity)
            principals.append(DelegationPrincipal(id: zone.zoneID.ownerName, zoneID: zone.zoneID, name: name))
        }
        return principals
    }

    /// Reads the delegated alarms in a principal's shared zone (helper view).
    func helperFetchReminders(in zoneID: CKRecordZone.ID) async -> [DelegatedReminder] {
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
            if payload.isDeleted == true { continue }
            let id = UUID(uuidString: record.recordID.recordName) ?? UUID(uuidString: payload.id) ?? UUID()
            result.append(DelegatedReminder(id: id, recordID: record.recordID, payload: payload))
        }
        return result.sorted { $0.date < $1.date }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
