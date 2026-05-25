//
//  AssistantTools.swift
//  Calarm
//
//  Tools exposed to the on-device language model so it can read and modify
//  the user's reminders directly while chatting. Each tool gets a typed
//  `Arguments` struct (the model generates an instance) and a `call` method
//  that runs in the host app.
//

import FoundationModels
import Foundation
import SwiftData

// MARK: - Shared helpers

private enum ToolHelpers {
    /// Maps "birthday"/"event"/etc strings to typed `ReminderCategory`.
    /// Returns `.reminder` when the slug is unknown.
    static func category(fromSlug slug: String?) -> ReminderCategory {
        guard let slug else { return .reminder }
        return ReminderCategory.from(slug: slug) ?? .reminder
    }

    static func recurrence(fromSlug slug: String?) -> RecurrenceRule {
        AlarmSuggestionsService.recurrence(fromSlug: slug ?? "once")
    }

    static func leadTimes(fromMinutes minutes: [Int]?) -> [AlarmLeadTime] {
        AlarmSuggestionsService.leadTimes(fromMinutes: minutes ?? [0])
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ iso: String) -> Date? {
        isoFormatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }

    static func formatDate(_ date: Date, locale: Locale) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.locale = locale
        return f.string(from: date)
    }
}

// MARK: - Create reminder

struct CreateReminderTool: Tool {
    let modelContainer: ModelContainer
    let scheduler: ReminderScheduler

    var name: String { "create_reminder" }
    var description: String {
        "Creates a new alarm/reminder in Calarm with title and date. Optional category, recurrence, and lead times. Use ISO 8601 dates."
    }

    @Generable
    struct Arguments: Sendable {
        @Guide(description: "Short, clear title for the alarm. Don't include the date or time.")
        let title: String

        @Guide(description: "When the alarm fires, ISO 8601 like 2026-03-15T08:00:00. Must be in the future.")
        let dateISO: String

        @Guide(description: "Category. One of: birthday, anniversary, event, reminder, other. Default reminder.")
        let category: String?

        @Guide(description: "Recurrence. One of: once, daily, weekly, monthly, yearly. Default once.")
        let recurrence: String?

        @Guide(description: "Lead times in minutes before. e.g. [0] or [0, 60] or [1440]. Default [0].")
        let leadTimesMinutes: [Int]?
    }

    @MainActor
    func call(arguments: Arguments) async throws -> String {
        guard let date = ToolHelpers.parseDate(arguments.dateISO) else {
            return "Error: invalid date \(arguments.dateISO). Use ISO 8601 like 2026-03-15T08:00:00."
        }

        let reminder = Reminder(
            title: arguments.title,
            date: date,
            category: ToolHelpers.category(fromSlug: arguments.category),
            recurrence: ToolHelpers.recurrence(fromSlug: arguments.recurrence),
            leadTimes: ToolHelpers.leadTimes(fromMinutes: arguments.leadTimesMinutes)
        )
        let context = modelContainer.mainContext
        context.insert(reminder)
        try context.save()
        await scheduler.syncAlarms(for: reminder)

        let dateStr = ToolHelpers.formatDate(date, locale: LocalizationManager.shared.currentLocale)
        return "Created reminder '\(arguments.title)' for \(dateStr). ID: \(reminder.id.uuidString)"
    }
}

// MARK: - List reminders

struct ListRemindersTool: Tool {
    let modelContainer: ModelContainer

    var name: String { "list_reminders" }
    var description: String {
        "Lists reminders in a given range. Use this to answer questions like 'what do I have today / this week / this month'. Returns array of (id, title, date, category)."
    }

    @Generable
    struct Arguments: Sendable {
        @Guide(description: "Range. One of: today, tomorrow, this_week, this_month, all. Default today.")
        let range: String?

        @Guide(description: "Optional category filter. One of: birthday, anniversary, event, reminder, other, or null for all.")
        let category: String?
    }

    @MainActor
    func call(arguments: Arguments) async throws -> String {
        let context = modelContainer.mainContext
        let all = (try? context.fetch(FetchDescriptor<Reminder>(sortBy: [SortDescriptor(\.date)]))) ?? []

        let calendar = Calendar.current
        let now = Date()
        let startOfDay = calendar.startOfDay(for: now)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        let startOfTomorrow = endOfDay
        let endOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfTomorrow)!
        let endOfWeek = calendar.date(byAdding: .day, value: 7, to: startOfDay)!
        let endOfMonth = calendar.date(byAdding: .month, value: 1, to: startOfDay)!

        let filtered = all.filter { reminder in
            guard reminder.isEnabled else { return false }
            // Category filter
            if let cat = arguments.category,
               let typed = ReminderCategory.from(slug: cat),
               reminder.category != typed {
                return false
            }
            // Compute next occurrence (handles recurrences)
            let next = RecurrenceEngine.nextOccurrences(
                rule: reminder.recurrence,
                baseDate: reminder.date,
                count: 1
            ).first ?? reminder.date

            switch (arguments.range ?? "today").lowercased() {
            case "today": return next >= startOfDay && next < endOfDay
            case "tomorrow": return next >= startOfTomorrow && next < endOfTomorrow
            case "this_week", "week": return next >= startOfDay && next < endOfWeek
            case "this_month", "month": return next >= startOfDay && next < endOfMonth
            default: return true
            }
        }

        if filtered.isEmpty { return "[]" }
        let lines = filtered.map { reminder -> String in
            let next = RecurrenceEngine.nextOccurrences(
                rule: reminder.recurrence, baseDate: reminder.date, count: 1
            ).first ?? reminder.date
            let dateStr = ToolHelpers.formatDate(next, locale: LocalizationManager.shared.currentLocale)
            return "- id=\(reminder.id.uuidString) | \(reminder.title) | \(dateStr) | category=\(reminder.category.rawValue)"
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Search reminders

struct SearchRemindersTool: Tool {
    let modelContainer: ModelContainer

    var name: String { "search_reminders" }
    var description: String {
        "Searches reminders by title or notes (case-insensitive contains). Returns up to 10 matches. Use this when the user references a specific reminder by name."
    }

    @Generable
    struct Arguments: Sendable {
        @Guide(description: "The text to search for in titles and notes.")
        let query: String
    }

    @MainActor
    func call(arguments: Arguments) async throws -> String {
        let context = modelContainer.mainContext
        let q = arguments.query.lowercased()
        let all = (try? context.fetch(FetchDescriptor<Reminder>())) ?? []
        let matches = all.filter {
            $0.title.lowercased().contains(q) || ($0.notes ?? "").lowercased().contains(q)
        }.prefix(10)

        if matches.isEmpty { return "[]" }
        let lines = matches.map { reminder -> String in
            let dateStr = ToolHelpers.formatDate(reminder.date, locale: LocalizationManager.shared.currentLocale)
            return "- id=\(reminder.id.uuidString) | \(reminder.title) | \(dateStr) | category=\(reminder.category.rawValue)"
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Update reminder

struct UpdateReminderTool: Tool {
    let modelContainer: ModelContainer
    let scheduler: ReminderScheduler

    var name: String { "update_reminder" }
    var description: String {
        "Updates fields on an existing reminder by id (UUID string from list/search). Only provided fields are changed; pass null for fields you don't want to modify."
    }

    @Generable
    struct Arguments: Sendable {
        @Guide(description: "UUID of the reminder to update — get this from list_reminders or search_reminders.")
        let id: String

        @Guide(description: "New title, or null to keep current.")
        let title: String?

        @Guide(description: "New date ISO 8601, or null to keep current.")
        let dateISO: String?

        @Guide(description: "New category slug, or null to keep current.")
        let category: String?

        @Guide(description: "New recurrence slug, or null to keep current.")
        let recurrence: String?

        @Guide(description: "New lead times in minutes, or null to keep current.")
        let leadTimesMinutes: [Int]?

        @Guide(description: "Enable or disable. Null to keep current.")
        let isEnabled: Bool?
    }

    @MainActor
    func call(arguments: Arguments) async throws -> String {
        guard let uuid = UUID(uuidString: arguments.id) else {
            return "Error: invalid id \(arguments.id)"
        }
        let context = modelContainer.mainContext
        let all = (try? context.fetch(FetchDescriptor<Reminder>())) ?? []
        guard let reminder = all.first(where: { $0.id == uuid }) else {
            return "Error: reminder not found with id \(arguments.id)"
        }

        if let title = arguments.title { reminder.title = title }
        if let dateISO = arguments.dateISO, let date = ToolHelpers.parseDate(dateISO) {
            reminder.date = date
        }
        if let cat = arguments.category, let typed = ReminderCategory.from(slug: cat) {
            reminder.category = typed
            reminder.symbolName = typed.defaultSymbol
        }
        if let rec = arguments.recurrence {
            reminder.recurrence = ToolHelpers.recurrence(fromSlug: rec)
        }
        if let leads = arguments.leadTimesMinutes {
            reminder.leadTimes = ToolHelpers.leadTimes(fromMinutes: leads)
        }
        if let enabled = arguments.isEnabled {
            reminder.isEnabled = enabled
        }
        reminder.updatedAt = Date()
        try context.save()
        await scheduler.syncAlarms(for: reminder)

        return "Updated reminder '\(reminder.title)'."
    }
}

// MARK: - Delete reminder

struct DeleteReminderTool: Tool {
    let modelContainer: ModelContainer
    let scheduler: ReminderScheduler

    var name: String { "delete_reminder" }
    var description: String {
        "Deletes a reminder by id (UUID string). Cancels its scheduled alarms. Always confirm with the user before calling this."
    }

    @Generable
    struct Arguments: Sendable {
        @Guide(description: "UUID of the reminder to delete.")
        let id: String
    }

    @MainActor
    func call(arguments: Arguments) async throws -> String {
        guard let uuid = UUID(uuidString: arguments.id) else {
            return "Error: invalid id \(arguments.id)"
        }
        let context = modelContainer.mainContext
        let all = (try? context.fetch(FetchDescriptor<Reminder>())) ?? []
        guard let reminder = all.first(where: { $0.id == uuid }) else {
            return "Error: reminder not found with id \(arguments.id)"
        }
        let titleCopy = reminder.title
        await scheduler.cancelAlarms(for: reminder)
        context.delete(reminder)
        try context.save()
        return "Deleted reminder '\(titleCopy)'."
    }
}
