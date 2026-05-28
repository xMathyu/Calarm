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

    init(modelContainer: ModelContainer, containerIdentifier: String = "iCloud.MathyuSolutions.Calarm") {
        self.modelContainer = modelContainer
        self.containerIdentifier = containerIdentifier
        self.cloudKitContainer = CKContainer(identifier: containerIdentifier)
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
        share.publicPermission = .none

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
        do {
            _ = try await cloudKitContainer.accept(metadata)
            try await ingestSharedRecord(from: metadata)
        } catch {
            throw SharedRemindersError.acceptFailed(error)
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
        // Carry the custom category (if any) denormalized so the recipient can
        // reconstruct it — they won't have it in their own catalog.
        if let cid = reminder.customCategoryID {
            record["customCategoryID"] = cid.uuidString as CKRecordValue
            if let cat = CategoryStore.shared?.customCategory(id: cid) {
                record["customCategoryName"] = cat.name as CKRecordValue
                record["customCategoryColorHex"] = cat.colorHex as CKRecordValue
                record["customCategoryIconKindRaw"] = cat.iconKindRaw as CKRecordValue
                record["customCategoryIconValue"] = cat.iconValue as CKRecordValue
            }
        }
        return record
    }

    /// Ensures the recipient has a local `CustomCategory` matching a shared one
    /// (deduped by id), so the received reminder renders with its real color/icon.
    private func ensureCustomCategory(from record: CKRecord, in context: ModelContext) -> UUID? {
        guard let cidString = record["customCategoryID"] as? String,
              let cid = UUID(uuidString: cidString) else { return nil }
        let descriptor = FetchDescriptor<CustomCategory>(predicate: #Predicate { $0.id == cid })
        let name = (record["customCategoryName"] as? String) ?? "Categoría"
        let colorHex = (record["customCategoryColorHex"] as? String) ?? "#AF52DE"
        let iconKindRaw = (record["customCategoryIconKindRaw"] as? Int) ?? ReminderIconKind.symbol.rawValue
        let iconValue = (record["customCategoryIconValue"] as? String) ?? "star.fill"
        if let existing = try? context.fetch(descriptor).first {
            existing.name = name
            existing.colorHex = colorHex
            existing.iconKindRaw = iconKindRaw
            existing.iconValue = iconValue
        } else {
            context.insert(CustomCategory(
                id: cid, name: name, colorHex: colorHex,
                iconKind: ReminderIconKind(rawValue: iconKindRaw) ?? .symbol,
                iconValue: iconValue
            ))
        }
        return cid
    }

    @MainActor
    private func ingestSharedRecord(from metadata: CKShare.Metadata) async throws {
        guard let rootRecordID = metadata.hierarchicalRootRecordID else { return }
        let database = cloudKitContainer.sharedCloudDatabase
        guard let record = try? await database.record(for: rootRecordID) else { return }

        // Convert the shared CKRecord into a local Reminder copy (read-only by convention;
        // changes flow back to CloudKit owner if needed via subsequent commits).
        let title = (record["title"] as? String) ?? ""
        let notes = record["notes"] as? String
        let date = (record["date"] as? Date) ?? Date()
        let categoryRaw = (record["categoryRaw"] as? Int) ?? ReminderCategory.event.rawValue
        let iconKindRaw = (record["iconKindRaw"] as? Int) ?? ReminderIconKind.symbol.rawValue
        let symbolName = record["symbolName"] as? String
        let leadTimeSeconds = (record["leadTimeSeconds"] as? Int) ?? AlarmLeadTime.atStart.rawValue
        let isEnabled = ((record["isEnabled"] as? Int) ?? 1) == 1
        let recurrenceData = (record["recurrenceData"] as? Data) ?? Data()

        let context = modelContainer.mainContext
        let customCategoryID = ensureCustomCategory(from: record, in: context)
        // Use the record's name as the local UUID to avoid duplicates if accepted twice.
        let localID = UUID(uuidString: record.recordID.recordName) ?? UUID()
        let descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.id == localID })
        if let existing = try context.fetch(descriptor).first {
            existing.title = title
            existing.notes = notes?.isEmpty == true ? nil : notes
            existing.date = date
            existing.categoryRaw = categoryRaw
            existing.customCategoryID = customCategoryID
            existing.iconKindRaw = iconKindRaw
            existing.symbolName = symbolName?.isEmpty == true ? nil : symbolName
            existing.leadTimeSeconds = leadTimeSeconds
            existing.isEnabled = isEnabled
            existing.recurrenceData = recurrenceData
            existing.updatedAt = Date()
            existing.isReceivedShare = true
        } else {
            let reminder = Reminder(
                id: localID,
                title: title,
                notes: notes?.isEmpty == true ? nil : notes,
                date: date,
                category: ReminderCategory(rawValue: categoryRaw) ?? .event,
                iconKind: ReminderIconKind(rawValue: iconKindRaw) ?? .symbol,
                symbolName: symbolName?.isEmpty == true ? nil : symbolName,
                photoData: nil,
                recurrence: (try? JSONDecoder().decode(RecurrenceRule.self, from: recurrenceData)) ?? .once,
                leadTimes: [AlarmLeadTime(rawValue: leadTimeSeconds) ?? .atStart],
                isEnabled: isEnabled
            )
            reminder.customCategoryID = customCategoryID
            reminder.isReceivedShare = true
            context.insert(reminder)
        }
        try context.save()
        CategoryStore.shared?.reload()
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
