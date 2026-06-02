//
//  NextAlarmIntent.swift
//  Calarm
//
//  App Intent for "¿cuál es mi próxima alarma?" — Siri reads back the soonest
//  upcoming alarm. Runs silently, computing the next occurrence the same way the
//  app's list does.
//

import AppIntents
import Foundation
import SwiftData

struct NextAlarmIntent: AppIntent {
    static let title: LocalizedStringResource = "Próxima alarma"
    static let description = IntentDescription(
        "Dice cuál es tu próxima alarma en Calarm.",
        categoryName: "Alarmas"
    )
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = try Self.makeSharedContainer()
        let reminders = (try? container.mainContext.fetch(FetchDescriptor<Reminder>())) ?? []
        let now = Date()

        let next = reminders
            .filter(\.isEnabled)
            .compactMap { reminder -> (reminder: Reminder, date: Date)? in
                guard let occurrence = RecurrenceEngine.nextOccurrences(
                    rule: reminder.recurrence, baseDate: reminder.date, count: 1
                ).first, occurrence > now else { return nil }
                return (reminder, occurrence)
            }
            .min { $0.date < $1.date }

        guard let next else {
            return .result(dialog: "No tienes alarmas próximas.")
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        formatter.locale = LocalizationManager.shared.currentLocale
        let formattedDate = formatter.string(from: next.date)

        return .result(dialog: "Tu próxima alarma es '\(next.reminder.title)' el \(formattedDate).")
    }

    private static func makeSharedContainer() throws -> ModelContainer {
        let schema = Schema([Reminder.self, CustomCategory.self])
        let cloudConfig = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
        do {
            return try ModelContainer(for: schema, configurations: cloudConfig)
        } catch {
            let localConfig = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            return try ModelContainer(for: schema, configurations: localConfig)
        }
    }
}
