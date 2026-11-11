//
//  AlarmTemplate.swift
//  Calarm
//
//  Las alarmas de arranque que ofrece la lista vacía. Quien acaba de instalar
//  Calarm y ve «Sin alarmas» tenía que imaginarse qué crear y llenar el editor
//  entero —fecha, hora, repetición— antes de ver sonar nada. Con una plantilla,
//  un toque abre el editor ya armado y cerrarlo la guarda tal cual.
//
//  La lista abre con el despertador porque la ficha de la tienda se llama
//  «AI Alarm Clock» y la mayoría llega buscando eso.
//

import Foundation

struct AlarmTemplate: Identifiable {
    let id: String
    /// Lo que dice la tarjeta.
    let label: String
    let detail: String
    /// El nombre de la alarma que se crea. Es contenido de la persona: sale en
    /// el idioma de la app al crearla y después no cambia con él.
    let title: String
    let symbol: String
    let category: ReminderCategory
    let recurrence: RecurrenceRule
    let hour: Int
    let minute: Int
    let leadTimes: [AlarmLeadTime]
    let challenge: WakeChallenge?
    /// La tarjeta enseña la hora; el cumpleaños no, porque ahí lo que hay que
    /// poner es la fecha.
    let showsTime: Bool

    /// La próxima vez que el reloj marca `hour:minute`: hoy si todavía no pasó,
    /// si no mañana. Con días de la semana, el motor de recurrencia salta solo
    /// al primero que toque.
    func firstDate(now: Date = .now, calendar: Calendar = .current) -> Date {
        let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        if today > now { return today }
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }

    /// Se construyen al pedirlas para que sigan el idioma de la app.
    static var starters: [AlarmTemplate] {
        let weekdays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
        return [
            AlarmTemplate(
                id: "wake",
                label: appLocalized("Despertador"),
                detail: appLocalized("De lunes a viernes"),
                title: appLocalized("Despertador"),
                symbol: "alarm.fill",
                category: .reminder,
                recurrence: .weekly(interval: 1, weekdays: weekdays),
                hour: 7, minute: 0,
                leadTimes: [.atStart],
                challenge: nil,
                showsTime: true
            ),
            AlarmTemplate(
                id: "wake-challenge",
                label: appLocalized("Despertador con reto"),
                detail: appLocalized("Resuelve un juego para apagarla"),
                title: appLocalized("Despertador"),
                symbol: "gamecontroller.fill",
                category: .reminder,
                recurrence: .weekly(interval: 1, weekdays: weekdays),
                hour: 7, minute: 0,
                leadTimes: [.atStart],
                challenge: WakeChallenge(kind: .math),
                showsTime: true
            ),
            AlarmTemplate(
                id: "pill",
                label: appLocalized("Pastilla"),
                detail: appLocalized("Todos los días"),
                title: appLocalized("Pastilla"),
                symbol: "pills.fill",
                category: .reminder,
                recurrence: .daily(interval: 1),
                hour: 9, minute: 0,
                leadTimes: [.atStart],
                challenge: nil,
                showsTime: true
            ),
            AlarmTemplate(
                id: "birthday",
                label: appLocalized("Cumpleaños"),
                detail: appLocalized("Se repite cada año, con su foto"),
                title: appLocalized("Cumpleaños"),
                symbol: ReminderCategory.birthday.defaultSymbol,
                category: .birthday,
                recurrence: .yearly(interval: 1),
                hour: 9, minute: 0,
                leadTimes: [.atStart, .day1],
                challenge: nil,
                showsTime: false
            ),
        ]
    }
}
