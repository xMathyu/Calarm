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

    /// Stops sharing — removes the share record from CloudKit. The owner's local Reminder stays.
    func stopSharing(_ share: CKShare) async throws {
        let database = cloudKitContainer.privateCloudDatabase
        do {
            _ = try await database.modifyRecords(saving: [], deleting: [share.recordID])
        } catch {
            throw SharedRemindersError.shareCreationFailed(error)
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
        return record
    }

    /// Builds the current-version envelope from a reminder. Denormalizes the
    /// custom category (color/icon) so the recipient — who won't have it in their
    /// own catalog — can reconstruct it.
    private func makePayload(from reminder: Reminder) -> SharePayload {
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
            customCategory: custom
        )
    }

    /// Reads the versioned envelope, falling back to the legacy per-field layout
    /// for any shares created before the envelope existed.
    private func decodePayload(from record: CKRecord) -> SharePayload {
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
    private func ensureCustomCategory(_ info: SharePayload.CustomCategoryInfo?, in context: ModelContext) -> UUID? {
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
        let title = applyRecord(record, in: context)
        try context.save()
        CategoryStore.shared?.reload()
        ShareDiagnostics.log("✅ ingest: reminder guardado '\(title)'")
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
            for zone in zones {
                let changes = try await database.recordZoneChanges(inZoneWith: zone.zoneID, since: nil)
                for modResult in changes.modificationResultsByID.values {
                    guard case .success(let modification) = modResult else { continue }
                    let record = modification.record
                    guard record.recordType == "CalarmSharedReminder" else { continue }
                    _ = applyRecord(record, in: context)
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
        } catch {
            Self.log.error("importAllSharedReminders failed: \(error.localizedDescription, privacy: .public)")
            ShareDiagnostics.log("❌ scan error: \(error.localizedDescription)")
        }
    }

    /// Upserts a shared `CalarmSharedReminder` CKRecord into a local `Reminder`
    /// (marked as a received share). Caller is responsible for saving the context.
    /// Returns the reminder title for logging.
    @discardableResult
    private func applyRecord(_ record: CKRecord, in context: ModelContext) -> String {
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
        return payload.title
    }

    /// Copies an envelope onto a local reminder, marking it as a received share.
    private func apply(_ payload: SharePayload, to reminder: Reminder, customCategoryID: UUID?) {
        reminder.title = payload.title
        reminder.notes = payload.notes?.isEmpty == true ? nil : payload.notes
        reminder.date = payload.date
        reminder.categoryRaw = payload.categoryRaw
        reminder.customCategoryID = customCategoryID
        reminder.iconKindRaw = payload.iconKindRaw
        reminder.symbolName = payload.symbolName?.isEmpty == true ? nil : payload.symbolName
        reminder.recurrenceData = payload.recurrenceData
        let leadTimes = payload.leadTimeSeconds.compactMap { AlarmLeadTime(rawValue: $0) }
        reminder.leadTimes = leadTimes.isEmpty ? [.atStart] : leadTimes
        reminder.isEnabled = payload.isEnabled
        reminder.updatedAt = Date()
        reminder.isReceivedShare = true
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
private struct SharePayload: Codable {
    static let currentVersion = 1

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

    struct CustomCategoryInfo: Codable {
        var id: String
        var name: String
        var colorHex: String
        var iconKindRaw: Int
        var iconValue: String
    }
}
