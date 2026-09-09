//
//  DemoData.swift
//  Calarm
//
//  Fills a fresh install with the alarms used for the App Store screenshots, so
//  the captures show the real app with plausible content instead of an empty
//  list — and so a new set can be regenerated later without tapping through the
//  editor eight times.
//
//  DEBUG only, and only when asked for explicitly:
//    xcrun simctl launch booted MathyuSolutions.Calarm -seedDemoData -AppleLanguages "(es)"
//
//  Titles follow the launch language, because an alarm's title is user content:
//  the English screenshots need English alarms.
//

#if DEBUG
import EventKit
import Foundation
import SwiftData

enum DemoData {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-seedDemoData")
    }

    /// Slide inicial de la bienvenida, con `-demoPage N`, para capturarlas una
    /// por una sin depender de gestos.
    static var requestedPage: Int? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-demoPage"), i + 1 < args.count else { return nil }
        return Int(args[i + 1])
    }

    /// Screen to open straight away, from `-demoScreen <name>`: list, editor,
    /// recurrence, tones, assistant, settings, helpers, calendar, onboarding.
    /// Driving the captures this way keeps them deterministic — no tapping, same
    /// frame every run, in whichever language the app was launched with.
    static var requestedScreen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-demoScreen"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static var isSpanish: Bool {
        (Locale.preferredLanguages.first ?? "es").hasPrefix("es")
    }

    /// Wipes whatever is stored and writes the screenshot set. Destructive on
    /// purpose: repeated runs must produce the same screens.
    @MainActor
    static func seed(into container: ModelContainer, settings: AppSettings) {
        let context = container.mainContext
        try? context.delete(model: Reminder.self)
        try? context.delete(model: CustomCategory.self)

        let health = CustomCategory(
            name: isSpanish ? "Salud" : "Health",
            colorHex: "#34C759",
            iconValue: "cross.case.fill",
            sortOrder: 0
        )
        context.insert(health)

        for reminder in reminders(healthCategory: health) {
            context.insert(reminder)
        }
        try? context.save()

        // The onboarding sheet covers the whole app, so the captures of the app
        // itself skip it — unless the run is specifically about the welcome
        // slides (`-demoScreen onboarding`).
        settings.onboardingCompleted = requestedScreen != "onboarding"

        seedCalendarEvents()
    }

    /// Writes today's meetings into the device calendar, so the Calendario tab
    /// has something to show — including one with a Teams link, which is what
    /// makes the "Unirse" button appear.
    private static func seedCalendarEvents() {
        let store = EKEventStore()
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess,
              let calendar = store.defaultCalendarForNewEvents else { return }

        let es = isSpanish
        // Relative to now (rounded to the half hour) so every capture run shows
        // the three of them as upcoming, whatever time it is.
        let planned: [(String, Double, Int, String?, String?)] = [
            (es ? "Revisión de diseño" : "Design review", 1.5, 60, es ? "Oficina" : "Office", nil),
            (es ? "Reunión con el equipo" : "Team sync", 3.5, 30, nil,
             "https://teams.microsoft.com/l/meetup-join/19%3ameeting_demo%40thread.v2/0"),
            (es ? "Uno a uno con Ana" : "One-on-one with Ana", 5.5, 30, es ? "Sala 2" : "Room 2", nil),
        ]

        // Clear anything a previous run left behind, so the tab looks the same
        // on every capture.
        let dayStart = Calendar.current.startOfDay(for: Date())
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let existing = store.events(matching: store.predicateForEvents(
            withStart: dayStart, end: dayEnd, calendars: [calendar]
        ))
        for event in existing { try? store.remove(event, span: .thisEvent) }

        let halfHour: TimeInterval = 1800
        let base = Date(timeIntervalSince1970:
            (Date().timeIntervalSince1970 / halfHour).rounded(.down) * halfHour)

        for (title, hoursAhead, minutes, location, url) in planned {
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = title
            event.startDate = base.addingTimeInterval(hoursAhead * 3600)
            event.endDate = event.startDate.addingTimeInterval(TimeInterval(minutes * 60))
            event.location = location
            if let url { event.notes = url }
            try? store.save(event, span: .thisEvent)
        }
        try? store.commit()
    }

    private static func reminders(healthCategory: CustomCategory) -> [Reminder] {
        let es = isSpanish

        let pill = Reminder(
            title: es ? "Pastilla de la mañana" : "Morning pill",
            date: at(hour: 8, minute: 0, dayOffset: 1),
            category: .reminder,
            symbolName: "pills.fill",
            recurrence: .daily(interval: 1),
            leadTimes: [.atStart]
        )
        pill.customCategoryID = healthCategory.id

        let standup = Reminder(
            title: es ? "Reunión con el equipo" : "Team sync",
            date: at(hour: 17, minute: 30, dayOffset: 0),
            category: .event,
            symbolName: "person.2.fill",
            recurrence: .weekly(interval: 1, weekdays: [.monday, .wednesday]),
            leadTimes: [.atStart, .min15]
        )

        let dentist = Reminder(
            title: es ? "Cita con el dentista" : "Dentist appointment",
            date: at(hour: 16, minute: 0, dayOffset: 3),
            category: .event,
            symbolName: "cross.case.fill",
            recurrence: .once,
            leadTimes: [.atStart, .hour1]
        )
        dentist.customCategoryID = healthCategory.id

        let training = Reminder(
            title: es ? "Entrenamiento" : "Training",
            date: at(hour: 17, minute: 0, dayOffset: 2),
            category: .other,
            symbolName: "figure.run",
            recurrence: .weekly(interval: 1, weekdays: [.monday, .friday]),
            leadTimes: [.atStart]
        )
        // Same alarm, two different days and times — the feature no other
        // alarm app has, so it belongs in the screenshot.
        training.additionalSchedules = [
            AlarmSchedule(
                id: UUID(),
                date: at(hour: 11, minute: 0, dayOffset: 5),
                recurrence: .weekly(interval: 1, weekdays: [.saturday])
            )
        ]

        let rent = Reminder(
            title: es ? "Pagar la renta" : "Pay the rent",
            date: at(hour: 9, minute: 0, dayOffset: 12),
            category: .reminder,
            symbolName: "creditcard.fill",
            recurrence: .monthly(interval: 1),
            leadTimes: [.atStart, .day1]
        )

        let momBirthday = Reminder(
            title: es ? "Cumpleaños de mamá" : "Mom's birthday",
            date: at(hour: 9, minute: 0, dayOffset: 26),
            category: .birthday,
            symbolName: "birthday.cake.fill",
            recurrence: .yearly(interval: 1),
            leadTimes: [.atStart, .day1]
        )

        let anniversary = Reminder(
            title: es ? "Aniversario con Ana" : "Anniversary with Ana",
            date: at(hour: 20, minute: 0, dayOffset: 48),
            category: .anniversary,
            symbolName: "heart.fill",
            recurrence: .yearly(interval: 1),
            leadTimes: [.atStart, .week1]
        )

        return [pill, standup, dentist, training, rent, momBirthday, anniversary]
    }

    /// A wall-clock time on a day relative to today, so the list always shows
    /// the same grouping (hoy / mañana / esta semana / más adelante).
    private static func at(hour: Int, minute: Int, dayOffset: Int) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date()
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }
}
#endif
