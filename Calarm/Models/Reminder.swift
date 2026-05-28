//
//  Reminder.swift
//  Calarm
//
//  CloudKit-compatible: every stored property has a default value so SwiftData
//  can synthesize empty records when syncing with iCloud private database.
//

import Foundation
import SwiftData

@Model
final class Reminder {
    var id: UUID = UUID()
    var title: String = ""
    var notes: String? = nil
    var date: Date = Date()
    var categoryRaw: Int = ReminderCategory.reminder.rawValue
    /// Set when this reminder uses a user-created `CustomCategory`. `nil` means
    /// it uses the built-in `categoryRaw`. Additive/optional for CloudKit compat.
    var customCategoryID: UUID? = nil
    var iconKindRaw: Int = ReminderIconKind.symbol.rawValue
    var symbolName: String? = nil
    @Attribute(.externalStorage) var photoData: Data? = nil
    /// Encoded `RecurrenceRule` (JSON). Empty data decodes to `.once` via getter.
    var recurrenceData: Data = Data()
    var leadTimeSeconds: Int = AlarmLeadTime.atStart.rawValue
    /// Additional lead times beyond `leadTimeSeconds` (the primary one).
    /// JSON-encoded `[Int]` of seconds. New field — older CloudKit records
    /// arrive as empty `Data()` which decodes to `[]`, behaving exactly like a
    /// single-lead-time reminder.
    var additionalLeadTimesData: Data = Data()
    var isEnabled: Bool = true
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// True when this reminder was received via a CloudKit share (not created locally).
    var isReceivedShare: Bool = false

    init(
        id: UUID = UUID(),
        title: String = "",
        notes: String? = nil,
        date: Date = Date(),
        category: ReminderCategory = .reminder,
        iconKind: ReminderIconKind = .symbol,
        symbolName: String? = nil,
        photoData: Data? = nil,
        recurrence: RecurrenceRule = .once,
        leadTimes: [AlarmLeadTime] = [.atStart],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.date = date
        self.categoryRaw = category.rawValue
        self.iconKindRaw = iconKind.rawValue
        self.symbolName = symbolName ?? category.defaultSymbol
        self.photoData = photoData
        self.recurrenceData = (try? JSONEncoder().encode(recurrence)) ?? Data()
        self.leadTimeSeconds = AlarmLeadTime.atStart.rawValue
        self.additionalLeadTimesData = Data()
        self.isEnabled = isEnabled
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
        // Use the computed setter so the same split logic is applied.
        self.leadTimes = leadTimes
    }

    var category: ReminderCategory {
        get { ReminderCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    var iconKind: ReminderIconKind {
        get { ReminderIconKind(rawValue: iconKindRaw) ?? .symbol }
        set { iconKindRaw = newValue.rawValue }
    }

    var recurrence: RecurrenceRule {
        get { (try? JSONDecoder().decode(RecurrenceRule.self, from: recurrenceData)) ?? .once }
        set { recurrenceData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var leadTime: AlarmLeadTime {
        get { AlarmLeadTime(rawValue: leadTimeSeconds) ?? .atStart }
        set { leadTimeSeconds = newValue.rawValue }
    }

    /// All lead times for this reminder (the primary one plus any additional).
    /// Always returns at least one element (defaulting to `.atStart`), sorted
    /// by seconds ascending so the closest-to-event alert comes first.
    var leadTimes: [AlarmLeadTime] {
        get {
            var result: Set<AlarmLeadTime> = [leadTime]
            if !additionalLeadTimesData.isEmpty,
               let extras = try? JSONDecoder().decode([Int].self, from: additionalLeadTimesData) {
                for raw in extras {
                    if let lt = AlarmLeadTime(rawValue: raw) { result.insert(lt) }
                }
            }
            return result.sorted { $0.rawValue < $1.rawValue }
        }
        set {
            let unique = Array(Set(newValue)).sorted { $0.rawValue < $1.rawValue }
            guard let first = unique.first else {
                leadTimeSeconds = AlarmLeadTime.atStart.rawValue
                additionalLeadTimesData = Data()
                return
            }
            leadTimeSeconds = first.rawValue
            let extras = unique.dropFirst().map(\.rawValue)
            additionalLeadTimesData = (try? JSONEncoder().encode(Array(extras))) ?? Data()
        }
    }
}
