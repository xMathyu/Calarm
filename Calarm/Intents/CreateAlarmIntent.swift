//
//  CreateAlarmIntent.swift
//  Calarm
//
//  App Intent invoked when Siri or Shortcuts asks Calarm to create an alarm.
//  Siri triggers: "Hey Siri, Calarm pon una alarma a las 7", etc.
//

import AlarmKit
import AppIntents
import Foundation
import SwiftData

struct CreateAlarmIntent: AppIntent {
    static let title: LocalizedStringResource = "Crear alarma"
    static let description = IntentDescription(
        "Crea una nueva alarma en Calarm con título y hora.",
        categoryName: "Alarmas"
    )
    /// Run silently (no Calarm UI). The result dialog is what Siri speaks back.
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Título", description: "Para qué es la alarma")
    var titleParam: String

    @Parameter(title: "Hora", kind: .dateTime)
    var date: Date

    @Parameter(title: "Categoría")
    var category: ReminderCategoryAppEnum?

    static var parameterSummary: some ParameterSummary {
        When(\.$category, .hasAnyValue) {
            Summary("Crear alarma \(\.$titleParam) para \(\.$date)") {
                \.$category
            }
        } otherwise: {
            Summary("Crear alarma \(\.$titleParam) para \(\.$date)")
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = titleParam.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw $titleParam.needsValueError("¿Cómo quieres llamar a la alarma?")
        }

        let resolvedCategory = category?.category ?? .reminder

        // Match the main app's SwiftData configuration so the reminder appears
        // in the list and syncs to iCloud the same way as one created manually.
        let container = try Self.makeSharedContainer()
        let context = container.mainContext

        let reminder = Reminder(
            title: trimmed,
            date: date,
            category: resolvedCategory,
            leadTimes: [.atStart]
        )
        context.insert(reminder)
        try context.save()

        // Schedule the actual AlarmKit alarm immediately. The user expects the
        // alarm to ring even if they never open the Calarm app after this.
        let alarmStore = AlarmStore()
        let alarmScheduler = AlarmScheduler(store: alarmStore)
        let settings = AppSettings()
        let scheduler = ReminderScheduler(scheduler: alarmScheduler, settings: settings)
        // Ensure permission. If denied, the alarm is still saved and will sync
        // next time the user opens the app and grants permission.
        _ = try? await alarmScheduler.requestAuthorization()
        await scheduler.syncAlarms(for: reminder)

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.locale = LocalizationManager.shared.currentLocale
        let formattedDate = formatter.string(from: date)

        return .result(
            dialog: "Listo, alarma '\(trimmed)' creada para \(formattedDate)"
        )
    }

    // MARK: - Shared container

    /// Builds a `ModelContainer` configured identically to `CalarmApp` so the
    /// intent writes to the same SwiftData store the app reads from.
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
