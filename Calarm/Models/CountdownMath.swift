//
//  CountdownMath.swift
//  Calarm
//
//  Cuántos días faltan para una cuenta regresiva. COMPARTIDO con la extensión
//  CalarmWidgets (referencia explícita en el proyecto): solo Foundation, y
//  `nonisolated` para que el widget lo use fuera del hilo principal.
//

import Foundation

/// En qué punto está una cuenta, en días de calendario (no en bloques de 24 h:
/// un evento mañana a las 8 «falta 1 día» aunque sean las 23:00 de hoy).
nonisolated enum CountdownStatus: Equatable, Sendable {
    case upcoming(days: Int)
    case today
    case past(days: Int)

    var isPast: Bool {
        if case .past = self { return true }
        return false
    }
}

nonisolated enum CountdownMath {
    /// El día al que apunta la cuenta: la fecha guardada o, para los anuales, el
    /// próximo aniversario (hoy incluido, para que el día del evento diga «Hoy»).
    /// Un 29 de febrero cae el 28 en los años que no son bisiestos.
    static func target(
        date: Date,
        includesTime: Bool,
        repeatsYearly: Bool,
        now: Date,
        calendar: Calendar = .current
    ) -> Date {
        let anchor = includesTime ? date : calendar.startOfDay(for: date)
        let startOfToday = calendar.startOfDay(for: now)
        // Uno anual con fecha futura empieza ese día: antes no hay aniversario.
        guard repeatsYearly, anchor < startOfToday else { return anchor }

        var match = calendar.dateComponents([.month, .day], from: date)
        if includesTime {
            let time = calendar.dateComponents([.hour, .minute], from: date)
            match.hour = time.hour
            match.minute = time.minute
        } else {
            match.hour = 0
            match.minute = 0
        }
        // Un segundo antes del inicio de hoy, para que hoy mismo cuente.
        return calendar.nextDate(
            after: startOfToday.addingTimeInterval(-1),
            matching: match,
            matchingPolicy: .previousTimePreservingSmallerComponents
        ) ?? anchor
    }

    static func status(to target: Date, now: Date, calendar: Calendar = .current) -> CountdownStatus {
        let days = dayDelta(from: now, to: target, calendar: calendar)
        if days > 0 { return .upcoming(days: days) }
        if days == 0 { return .today }
        return .past(days: -days)
    }

    /// Días de calendario entre las dos fechas (negativo si `target` ya pasó).
    static func dayDelta(from now: Date, to target: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: target)
        ).day ?? 0
    }
}
