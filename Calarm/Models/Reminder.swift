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
    var iconKindRaw: Int = ReminderIconKind.symbol.rawValue
    var symbolName: String? = nil
    @Attribute(.externalStorage) var photoData: Data? = nil
    /// Encoded `RecurrenceRule` (JSON). Empty data decodes to `.once` via getter.
    var recurrenceData: Data = Data()
    var leadTimeSeconds: Int = AlarmLeadTime.atStart.rawValue
    var isEnabled: Bool = true
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

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
        leadTime: AlarmLeadTime = .atStart,
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
        self.leadTimeSeconds = leadTime.rawValue
        self.isEnabled = isEnabled
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
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
}
