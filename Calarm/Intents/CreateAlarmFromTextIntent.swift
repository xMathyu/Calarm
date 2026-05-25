//
//  CreateAlarmFromTextIntent.swift
//  Calarm
//
//  App Intent that accepts a free-form natural-language description and uses
//  Apple Intelligence (Foundation Models) to parse it into a Reminder.
//
//  Example: "Cumple de mi mamá el 15 de marzo todos los años a las 8am, recuérdame 1 día antes"
//    →  title=Cumpleaños de mamá, yearly, leadTimes=[atStart, day1], category=birthday
//

import AppIntents
import Foundation
import SwiftData

struct CreateAlarmFromTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Crear alarma con IA"
    static let description = IntentDescription(
        "Describe la alarma en lenguaje natural y Calarm la crea con Apple Intelligence.",
        categoryName: "Alarmas"
    )
    static let openAppWhenRun: Bool = false

    @Parameter(
        title: "Instrucción",
        description: "Describe la alarma en lenguaje natural"
    )
    var instruction: String

    static var parameterSummary: some ParameterSummary {
        Summary("Crear alarma con IA: \(\.$instruction)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw $instruction.needsValueError("¿Qué quieres recordar?")
        }

        let parsed = try await ParseAlarmService.shared.parse(
            trimmed,
            locale: LocalizationManager.shared.currentLocale
        )

        // Map AI output → typed domain values.
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let resolvedDate = isoFormatter.date(from: parsed.dateISO)
            ?? ISO8601DateFormatter().date(from: parsed.dateISO)
            ?? Date().addingTimeInterval(60 * 60)

        let category = ReminderCategory.from(slug: parsed.category) ?? .reminder
        let recurrence = Self.recurrence(fromSlug: parsed.recurrence)
        let leadTimes = Self.leadTimes(fromMinutes: parsed.leadTimesMinutes)

        // Persist + schedule, matching CreateAlarmIntent's flow.
        let container = try Self.makeSharedContainer()
        let context = container.mainContext
        let reminder = Reminder(
            title: parsed.title,
            date: resolvedDate,
            category: category,
            recurrence: recurrence,
            leadTimes: leadTimes
        )
        context.insert(reminder)
        try context.save()

        let alarmStore = AlarmStore()
        let alarmScheduler = AlarmScheduler(store: alarmStore)
        let settings = AppSettings()
        let scheduler = ReminderScheduler(scheduler: alarmScheduler, settings: settings)
        _ = try? await alarmScheduler.requestAuthorization()
        await scheduler.syncAlarms(for: reminder)

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.locale = LocalizationManager.shared.currentLocale
        let formattedDate = formatter.string(from: resolvedDate)

        return .result(
            dialog: "Listo, '\(parsed.title)' programada para \(formattedDate)"
        )
    }

    // MARK: - Mappers

    private static func recurrence(fromSlug slug: String) -> RecurrenceRule {
        switch slug.lowercased() {
        case "daily": .daily(interval: 1)
        case "weekly": .weekly(interval: 1, weekdays: [])
        case "monthly": .monthly(interval: 1)
        case "yearly": .yearly(interval: 1)
        default: .once
        }
    }

    /// Snaps the AI's free-form minute counts onto the closest fixed
    /// `AlarmLeadTime` cases. Anything past 1 day rounds down to 1 day.
    private static func leadTimes(fromMinutes minutes: [Int]) -> [AlarmLeadTime] {
        guard !minutes.isEmpty else { return [.atStart] }
        let allCases = AlarmLeadTime.allCases
        let mapped = minutes.compactMap { mins -> AlarmLeadTime? in
            let seconds = max(0, mins) * 60
            return allCases.min { lhs, rhs in
                abs(lhs.rawValue - seconds) < abs(rhs.rawValue - seconds)
            }
        }
        // Dedupe while preserving order.
        var seen = Set<AlarmLeadTime>()
        let unique = mapped.filter { seen.insert($0).inserted }
        return unique.isEmpty ? [.atStart] : unique
    }

    // MARK: - Shared container

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
