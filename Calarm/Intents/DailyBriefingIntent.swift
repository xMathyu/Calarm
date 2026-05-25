//
//  DailyBriefingIntent.swift
//  Calarm
//
//  Siri intent: "Hey Siri, Calarm qué tengo hoy". Reads today's enabled
//  reminders from SwiftData and asks Apple Intelligence to summarize them
//  into a natural spoken response.
//

import AppIntents
import FoundationModels
import Foundation
import SwiftData

struct DailyBriefingIntent: AppIntent {
    static let title: LocalizedStringResource = "Resumen del día"
    static let description = IntentDescription(
        "Calarm te dice qué alarmas tienes hoy con un resumen natural.",
        categoryName: "Alarmas"
    )
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reminders = try Self.fetchTodayReminders()

        guard !reminders.isEmpty else {
            return .result(dialog: "No tienes alarmas para hoy.")
        }

        let dialog = await Self.naturalSummary(for: reminders)
            ?? Self.fallbackSummary(for: reminders)

        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }

    // MARK: - Data

    @MainActor
    private static func fetchTodayReminders() throws -> [Reminder] {
        let container = try makeSharedContainer()
        let context = container.mainContext

        let calendar = Calendar.current
        let now = Date()
        let startOfDay = calendar.startOfDay(for: now)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay

        let descriptor = FetchDescriptor<Reminder>(
            sortBy: [SortDescriptor(\.date)]
        )
        let all = (try? context.fetch(descriptor)) ?? []

        // Include reminders whose `date` is today OR whose next occurrence is today.
        return all.filter { reminder in
            guard reminder.isEnabled else { return false }
            let baseHits = reminder.date >= startOfDay && reminder.date < endOfDay
            if baseHits { return true }
            let next = RecurrenceEngine.nextOccurrences(
                rule: reminder.recurrence,
                baseDate: reminder.date,
                count: 1
            ).first
            if let next, next >= startOfDay && next < endOfDay { return true }
            return false
        }
    }

    // MARK: - Summarization

    private static func naturalSummary(for reminders: [Reminder]) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else {
            return nil
        }

        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        timeFormatter.dateStyle = .none
        timeFormatter.locale = LocalizationManager.shared.currentLocale

        let lines = reminders.map { reminder -> String in
            let next = RecurrenceEngine.nextOccurrences(
                rule: reminder.recurrence,
                baseDate: reminder.date,
                count: 1
            ).first ?? reminder.date
            return "- \(timeFormatter.string(from: next)): \(reminder.title) [\(reminder.category.localizedTitle)]"
        }.joined(separator: "\n")

        let instructions = Instructions("""
        You are a personal assistant for the Calarm app. Given today's alarms, \
        produce a brief spoken summary in the user's language (under 60 words). \
        Group similar items when natural (e.g. "tienes 3 reuniones esta mañana"). \
        Use the locale's time format. Be warm but concise. Do NOT include a \
        greeting like "Hello" — start straight with the briefing. End with a \
        short closing if appropriate.
        """)

        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: instructions
        )

        let prompt = """
        User locale: \(LocalizationManager.shared.currentLocale.identifier)
        Number of alarms today: \(reminders.count)
        Today's alarms:
        \(lines)

        Generate the spoken summary now.
        """

        do {
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }

    /// Plain fallback when Apple Intelligence isn't available.
    private static func fallbackSummary(for reminders: [Reminder]) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        timeFormatter.dateStyle = .none
        timeFormatter.locale = LocalizationManager.shared.currentLocale

        let parts = reminders.prefix(5).map { reminder -> String in
            let next = RecurrenceEngine.nextOccurrences(
                rule: reminder.recurrence,
                baseDate: reminder.date,
                count: 1
            ).first ?? reminder.date
            return "\(timeFormatter.string(from: next)) \(reminder.title)"
        }

        return "Tienes \(reminders.count) alarmas hoy: \(parts.joined(separator: ", "))."
    }

    // MARK: - Container

    private static func makeSharedContainer() throws -> ModelContainer {
        let schema = Schema([Reminder.self])
        let cloudConfig = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
        do {
            return try ModelContainer(for: schema, configurations: cloudConfig)
        } catch {
            let localConfig = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            return try ModelContainer(for: schema, configurations: localConfig)
        }
    }
}
