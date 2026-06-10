//
//  ReminderScheduler.swift
//  Calarm
//

import Foundation
import Observation

/// Translates a `Reminder` into N concrete AlarmKit alarms based on its recurrence rule.
/// Owns reconciliation when reminders change: cancels old alarms, schedules new ones.
@Observable
@MainActor
final class ReminderScheduler {
    private(set) var lastError: String?
    private(set) var isWorking: Bool = false

    private let scheduler: AlarmScheduler
    private let settings: AppSettings
    private let occurrencesPerReminder: Int

    init(scheduler: AlarmScheduler, settings: AppSettings, occurrencesPerReminder: Int = 12) {
        self.scheduler = scheduler
        self.settings = settings
        self.occurrencesPerReminder = occurrencesPerReminder
    }

    /// (Re)programs all alarms for a single reminder.
    func syncAlarms(for reminder: Reminder) async {
        isWorking = true
        defer { isWorking = false }
        await applyReminder(reminder)
    }

    /// (Re)programs all alarms for every reminder in `reminders`.
    func syncAlarms(for reminders: [Reminder]) async {
        isWorking = true
        defer { isWorking = false }
        for reminder in reminders {
            await applyReminder(reminder)
        }
    }

    /// Cancels every alarm associated with the given reminder.
    func cancelAlarms(for reminder: Reminder) async {
        await scheduler.cancelAll(ownerID: ownerID(for: reminder))
    }

    func cancelAlarms(forReminderID id: UUID) async {
        await scheduler.cancelAll(ownerID: Self.ownerID(forReminderID: id))
    }

    static func ownerID(forReminderID id: UUID) -> String {
        "reminder:\(id.uuidString)"
    }

    private func applyReminder(_ reminder: Reminder) async {
        let ownerID = ownerID(for: reminder)

        guard reminder.isEnabled, settings.alarmsEnabled else {
            await scheduler.cancelAll(ownerID: ownerID)
            return
        }

        let occurrences = RecurrenceEngine.nextOccurrences(
            rule: reminder.recurrence,
            baseDate: reminder.date,
            count: occurrencesPerReminder
        )

        // One alarm per (occurrence × leadTime) combo, filtered to future dates.
        let now = Date()
        let leadTimes = reminder.leadTimes
        var fireDates: [Date] = []
        for occurrence in occurrences {
            for leadTime in leadTimes {
                let fire = occurrence.addingTimeInterval(-leadTime.seconds)
                if fire > now { fireDates.append(fire) }
            }
        }

        await scheduler.cancelOrphans(ownerID: ownerID, keepFireDates: Set(fireDates))

        for fireDate in fireDates {
            do {
                _ = try await scheduler.schedule(
                    ownerID: ownerID,
                    fireDate: fireDate,
                    title: reminder.title,
                    // AlarmKit expects an SF Symbol name — fall back to the
                    // category symbol when the reminder uses an emoji/photo icon.
                    symbolName: (reminder.iconKind == .symbol ? reminder.symbolName : nil) ?? reminder.category.defaultSymbol,
                    category: reminder.category,
                    snooze: settings.snoozeInterval,
                    meetingURL: nil
                )
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func ownerID(for reminder: Reminder) -> String {
        Self.ownerID(forReminderID: reminder.id)
    }
}
