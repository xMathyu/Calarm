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
        "Crea una nueva alarma en Calarm. Solo la hora es necesaria; el nombre es opcional.",
        categoryName: "Alarmas"
    )
    /// Run silently (no Calarm UI). The result dialog is what Siri speaks back.
    static let openAppWhenRun: Bool = false

    // Both optional so Siri never blocks on a missing name and can still fill the
    // time from the spoken phrase ("…a las 4pm"). When neither is given (bare
    // "pon una alarma en Calarm"), `perform()` asks for the time first, then the
    // name — see below.
    @Parameter(title: "Hora", kind: .dateTime)
    var date: Date?

    @Parameter(title: "Título", description: "Para qué es la alarma (opcional)")
    var titleParam: String?

    @Parameter(title: "Categoría")
    var category: ReminderCategoryAppEnum?

    @Parameter(title: "Aviso", description: "Con cuánta anticipación avisar")
    var leadTime: AlarmLeadTimeAppEnum?

    @Parameter(title: "Repetición", description: "Cada cuánto se repite")
    var recurrence: RecurrenceAppEnum?

    static var parameterSummary: some ParameterSummary {
        Summary("Crear alarma \(\.$titleParam) para \(\.$date)") {
            \.$category
            \.$leadTime
            \.$recurrence
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // The time is the only thing we truly need. If the user didn't say one,
        // ask for it now (Siri prompt). We remember whether we had to ask, to
        // decide below whether to also prompt for the name.
        let timeWasGiven = (date != nil)
        let resolvedDate: Date
        if let date {
            resolvedDate = date
        } else {
            resolvedDate = try await $date.requestValue("¿A qué hora?")
        }

        // The name is optional:
        //  • Given inline ("…con nombre Examen") → use it.
        //  • Bare invocation (we had to ask the time) → guide the user and ask the
        //    name too, but accept a blank answer.
        //  • Time given inline but no name → just default it, don't nag.
        let providedTitle = titleParam?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed: String
        if let providedTitle, !providedTitle.isEmpty {
            trimmed = providedTitle
        } else if !timeWasGiven {
            let asked = (try? await $titleParam.requestValue("¿Cómo se llama la alarma?")) ?? ""
            let askedTrimmed = asked.trimmingCharacters(in: .whitespacesAndNewlines)
            trimmed = askedTrimmed.isEmpty ? appLocalized("Alarma") : askedTrimmed
        } else {
            trimmed = appLocalized("Alarma")
        }

        let resolvedCategory = category?.category ?? .reminder
        let resolvedLeadTime = leadTime?.leadTime ?? .atStart
        let resolvedRecurrence = recurrence?.rule(basedOn: resolvedDate) ?? .once

        // Match the main app's SwiftData configuration so the reminder appears
        // in the list and syncs to iCloud the same way as one created manually.
        let container = try Self.makeSharedContainer()
        let context = container.mainContext

        let reminder = Reminder(
            title: trimmed,
            date: resolvedDate,
            category: resolvedCategory,
            recurrence: resolvedRecurrence,
            leadTimes: [resolvedLeadTime]
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
        let formattedDate = formatter.string(from: resolvedDate)

        // Keep the dialog a single localizable string (it already has an English
        // translation in the catalog); the recurrence/lead time are applied to the
        // alarm even though the spoken confirmation stays concise.
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
