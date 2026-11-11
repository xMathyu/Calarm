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
//  Titles follow the launch language (es, en or pt), because an alarm's title is user content:
//  the English screenshots need English alarms.
//

#if DEBUG
import EventKit
import Foundation
import SwiftData
import UIKit

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
    /// recurrence, tones, assistant, settings, helpers, calendar (month view),
    /// agenda (the events list), onboarding, countdowns (the Cuenta regresiva
    /// tab), countdownDetail, countdownEditor, countdownNew.
    /// Driving the captures this way keeps them deterministic — no tapping, same
    /// frame every run, in whichever language the app was launched with.
    static var requestedScreen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-demoScreen"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static var demoLanguage: String {
        String((Locale.preferredLanguages.first ?? "es").prefix(2))
    }

    /// The same title in Spanish, English and Brazilian Portuguese, picked by
    /// the launch language (`-AppleLanguages`).
    private static func t(_ es: String, _ en: String, _ pt: String) -> String {
        switch demoLanguage {
        case "es": es
        case "pt": pt
        default: en
        }
    }

    /// Wipes whatever is stored and writes the screenshot set. Destructive on
    /// purpose: repeated runs must produce the same screens.
    @MainActor
    static func seed(into container: ModelContainer, settings: AppSettings) {
        let context = container.mainContext
        try? context.delete(model: Reminder.self)
        try? context.delete(model: CustomCategory.self)
        try? context.delete(model: CountdownEvent.self)

        let health = CustomCategory(
            name: t("Salud", "Health", "Saúde"),
            colorHex: "#34C759",
            iconValue: "cross.case.fill",
            sortOrder: 0
        )
        context.insert(health)

        for reminder in reminders(healthCategory: health) {
            context.insert(reminder)
        }
        for countdown in countdowns() {
            context.insert(countdown)
        }
        try? context.save()

        // The onboarding sheet covers the whole app, so the captures of the app
        // itself skip it — unless the run is specifically about the welcome
        // slides (`-demoScreen onboarding`).
        settings.onboardingCompleted = requestedScreen != "onboarding"

        // La pestaña Calendario abre en la vista de mes; `agenda` pide la lista
        // de eventos de siempre (la captura del botón «Unirse en Teams»).
        UserDefaults.standard.set(
            (requestedScreen == "agenda" ? CalendarTabView.Mode.agenda : .month).rawValue,
            forKey: CalendarTabView.modeDefaultsKey
        )

        seedCalendarEvents()
    }

    /// Writes today's meetings into the device calendar, so the Calendario tab
    /// has something to show — including one with a Teams link, which is what
    /// makes the "Unirse" button appear.
    private static func seedCalendarEvents() {
        let store = EKEventStore()
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess,
              let calendar = store.defaultCalendarForNewEvents else { return }

        // Tomorrow at office hours, so every capture run shows the same three
        // meetings under «Mañana», whatever time it is. They used to be relative
        // to now, and a run at 9 p.m. put the team sync at midnight.
        let planned: [(String, Int, Int, Int, String?, String?)] = [
            (t("Revisión de diseño", "Design review", "Revisão de design"), 9, 30, 60, t("Oficina", "Office", "Escritório"), nil),
            (t("Reunión con el equipo", "Team sync", "Reunião com a equipe"), 11, 0, 30, nil,
             "https://teams.microsoft.com/l/meetup-join/19%3ameeting_demo%40thread.v2/0"),
            (t("Uno a uno con Ana", "One-on-one with Ana", "1:1 com a Ana"), 16, 30, 30, t("Sala 2", "Room 2", "Sala 2"), nil),
        ]

        // Clear anything a previous run left behind (today's included, from the
        // runs that seeded relative to now), so the tab looks the same every time.
        let dayStart = Calendar.current.startOfDay(for: Date())
        let rangeEnd = Calendar.current.date(byAdding: .day, value: 2, to: dayStart) ?? dayStart
        let existing = store.events(matching: store.predicateForEvents(
            withStart: dayStart, end: rangeEnd, calendars: [calendar]
        ))
        for event in existing { try? store.remove(event, span: .thisEvent) }

        for (title, hour, minute, minutes, location, url) in planned {
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = title
            event.startDate = at(hour: hour, minute: minute, dayOffset: 1)
            event.endDate = event.startDate.addingTimeInterval(TimeInterval(minutes * 60))
            event.location = location
            if let url { event.notes = url }
            try? store.save(event, span: .thisEvent)
        }
        try? store.commit()
    }

    private static func reminders(healthCategory: CustomCategory) -> [Reminder] {

        // La ficha se llama «AI Alarm Clock» y casi todos llegan buscando un
        // despertador: la primera captura tiene que enseñar uno, con su reto.
        // Diario y no de lunes a viernes, para que salga sea el día de la semana
        // que sea; anclado HOY a las 7, para ser la primera de la lista (que se
        // ordena por la fecha ancla) aunque su próxima vez sea mañana.
        let wakeUp = Reminder(
            title: t("Despertador", "Wake up", "Despertador"),
            date: at(hour: 7, minute: 0, dayOffset: 0),
            category: .reminder,
            symbolName: "alarm.fill",
            recurrence: .daily(interval: 1),
            leadTimes: [.atStart]
        )
        wakeUp.challenge = WakeChallenge(kind: .math)

        let pill = Reminder(
            title: t("Pastilla de la mañana", "Morning pill", "Remédio da manhã"),
            date: at(hour: 8, minute: 0, dayOffset: 1),
            category: .reminder,
            symbolName: "pills.fill",
            recurrence: .daily(interval: 1),
            leadTimes: [.atStart]
        )
        pill.customCategoryID = healthCategory.id

        let standup = Reminder(
            title: t("Reunión con el equipo", "Team sync", "Reunião com a equipe"),
            date: at(hour: 17, minute: 30, dayOffset: 0),
            category: .event,
            symbolName: "person.2.fill",
            recurrence: .weekly(interval: 1, weekdays: [.monday, .wednesday]),
            leadTimes: [.atStart, .min15]
        )

        let dentist = Reminder(
            title: t("Cita con el dentista", "Dentist appointment", "Consulta no dentista"),
            date: at(hour: 16, minute: 0, dayOffset: 3),
            category: .event,
            symbolName: "cross.case.fill",
            recurrence: .once,
            leadTimes: [.atStart, .hour1]
        )
        dentist.customCategoryID = healthCategory.id

        let training = Reminder(
            title: t("Entrenamiento", "Training", "Treino"),
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
            title: t("Pagar la renta", "Pay the rent", "Pagar o aluguel"),
            date: at(hour: 9, minute: 0, dayOffset: 12),
            category: .reminder,
            symbolName: "creditcard.fill",
            recurrence: .monthly(interval: 1),
            leadTimes: [.atStart, .day1]
        )

        let momBirthday = Reminder(
            title: t("Cumpleaños de mamá", "Mom's birthday", "Aniversário da mamãe"),
            date: at(hour: 9, minute: 0, dayOffset: 26),
            category: .birthday,
            symbolName: "birthday.cake.fill",
            recurrence: .yearly(interval: 1),
            leadTimes: [.atStart, .day1]
        )

        let anniversary = Reminder(
            title: t("Aniversario con Ana", "Anniversary with Ana", "Aniversário de casamento"),
            date: at(hour: 20, minute: 0, dayOffset: 48),
            category: .anniversary,
            symbolName: "heart.fill",
            recurrence: .yearly(interval: 1),
            leadTimes: [.atStart, .week1]
        )

        return [wakeUp, pill, standup, dentist, training, rent, momBirthday, anniversary]
    }

    /// The Cuenta regresiva tab: one with a photo, one counting the seconds,
    /// a yearly one and one that already passed.
    private static func countdowns() -> [CountdownEvent] {
        let concert = CountdownEvent(
            // Sin nombres de artistas reales: esto sale en las capturas de la tienda.
            title: t("Concierto en el estadio", "Stadium concert", "Show no estádio"),
            date: at(hour: 21, minute: 0, dayOffset: 23),
            includesTime: true,
            colorHex: "#5856D6",
            iconKind: .photo,
            iconValue: "🎤",
            photoData: demoPhoto()
        )
        let trip = CountdownEvent(
            title: t("Viaje a Japón", "Trip to Japan", "Viagem ao Japão"),
            date: Calendar.current.startOfDay(for: at(hour: 0, minute: 0, dayOffset: 74)),
            colorHex: "#FF3B30",
            iconKind: .emoji,
            iconValue: "🗾"
        )
        let birthday = CountdownEvent(
            title: t("Cumpleaños de Sofía", "Sofía's birthday", "Aniversário da Sofia"),
            date: Calendar.current.date(byAdding: .year, value: -29, to: at(hour: 0, minute: 0, dayOffset: 9))
                .map { Calendar.current.startOfDay(for: $0) } ?? Date(),
            repeatsYearly: true,
            colorHex: "#FF9500",
            iconKind: .emoji,
            iconValue: "🎂"
        )
        let match = CountdownEvent(
            title: t("Final del campeonato", "Championship final", "Final do campeonato"),
            date: at(hour: 18, minute: 30, dayOffset: 1),
            includesTime: true,
            colorHex: "#34C759",
            iconKind: .symbol,
            iconValue: "sportscourt.fill"
        )
        let graduation = CountdownEvent(
            title: t("Graduación", "Graduation", "Formatura"),
            date: Calendar.current.startOfDay(for: at(hour: 0, minute: 0, dayOffset: -12)),
            colorHex: "#007AFF",
            iconKind: .symbol,
            iconValue: "graduationcap.fill"
        )
        // Una que llegó por invitación: la tarjeta lleva el icono de compartida.
        let wedding = CountdownEvent(
            title: t("Boda de Ana y Luis", "Ana & Luis's wedding", "Casamento da Ana e do Luis"),
            date: Calendar.current.startOfDay(for: at(hour: 0, minute: 0, dayOffset: 41)),
            colorHex: "#AF52DE",
            iconKind: .emoji,
            iconValue: "💍"
        )
        wedding.isReceivedShare = true
        return [concert, trip, birthday, match, graduation, wedding]
    }

    /// A drawn «stage» (no bundled asset needed) so the photo card has a photo.
    private static func demoPhoto() -> Data? {
        let size = CGSize(width: 1200, height: 800)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            let colors = [UIColor(red: 0.16, green: 0.05, blue: 0.35, alpha: 1).cgColor,
                          UIColor(red: 0.85, green: 0.2, blue: 0.45, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            // Stage lights.
            for (index, hue) in [0.55, 0.8, 0.12, 0.95].enumerated() {
                let x = size.width * (0.15 + 0.23 * CGFloat(index))
                UIColor(hue: hue, saturation: 0.7, brightness: 1, alpha: 0.35).setFill()
                let beam = UIBezierPath()
                beam.move(to: CGPoint(x: x, y: 0))
                beam.addLine(to: CGPoint(x: x - 160, y: size.height))
                beam.addLine(to: CGPoint(x: x + 160, y: size.height))
                beam.close()
                beam.fill()
            }
            // The crowd.
            UIColor.black.withAlphaComponent(0.85).setFill()
            for i in 0..<40 {
                let x = CGFloat(i) * 32 - 10
                let height = CGFloat(60 + (i * 37) % 70)
                UIBezierPath(ovalIn: CGRect(x: x, y: size.height - height, width: 46, height: height + 40)).fill()
            }
        }
        return image.jpegData(compressionQuality: 0.85)
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
