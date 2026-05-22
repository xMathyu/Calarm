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
        return record
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
        // Use the record's name as the local UUID to avoid duplicates if accepted twice.
        let localID = UUID(uuidString: record.recordID.recordName) ?? UUID()
        let descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.id == localID })
        if let existing = try context.fetch(descriptor).first {
            existing.title = title
            existing.notes = notes?.isEmpty == true ? nil : notes
            existing.date = date
            existing.categoryRaw = categoryRaw
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
                leadTime: AlarmLeadTime(rawValue: leadTimeSeconds) ?? .atStart,
                isEnabled: isEnabled
            )
            reminder.isReceivedShare = true
            context.insert(reminder)
        }
        try context.save()
    }
}
