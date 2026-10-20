//
//  RecurrenceEngine.swift
//  Calarm
//

import Foundation

/// Pure logic to compute the occurrences of a `RecurrenceRule` from a base date.
enum RecurrenceEngine {
    /// Returns up to `count` future occurrences for the given rule.
    /// - Parameters:
    ///   - rule: The recurrence rule.
    ///   - baseDate: The reminder's anchor date (first occurrence's date and time).
    ///   - count: Maximum number of occurrences to return (default 12).
    ///   - now: Reference for "future" — only occurrences strictly after this are returned.
    static func nextOccurrences(
        rule: RecurrenceRule,
        baseDate: Date,
        count: Int = 12,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Date] {
        guard count > 0 else { return [] }

        switch rule {
        case .once:
            return baseDate > now ? [baseDate] : []

        case .daily(let interval):
            return advancing(from: baseDate, by: .day, step: max(1, interval), count: count, now: now, calendar: calendar)

        case .weekly(let interval, let weekdays):
            if weekdays.isEmpty {
                return advancing(from: baseDate, by: .day, step: 7 * max(1, interval), count: count, now: now, calendar: calendar)
            } else {
                return weeklyOnWeekdays(baseDate: baseDate, interval: max(1, interval), weekdays: weekdays, count: count, now: now, calendar: calendar)
            }

        case .monthly(let interval):
            return advancing(from: baseDate, by: .month, step: max(1, interval), count: count, now: now, calendar: calendar)

        case .yearly(let interval):
            return advancing(from: baseDate, by: .year, step: max(1, interval), count: count, now: now, calendar: calendar)
        }
    }

    /// Every occurrence that falls within `start ..< end`, past ones included.
    ///
    /// Es lo que pinta la vista de mes: ahí interesa también lo que ya sonó este
    /// mes, no solo lo que viene. Avanza igual que `nextOccurrences` (paso a paso
    /// desde la fecha ancla), así que marca en el calendario exactamente los días
    /// en que la alarma suena.
    static func occurrences(
        rule: RecurrenceRule,
        baseDate: Date,
        from start: Date,
        to end: Date,
        calendar: Calendar = .current
    ) -> [Date] {
        guard start < end else { return [] }

        switch rule {
        case .once:
            return baseDate >= start && baseDate < end ? [baseDate] : []

        case .daily(let interval):
            return stepping(from: baseDate, by: .day, step: max(1, interval), from: start, to: end, calendar: calendar)

        case .weekly(let interval, let weekdays):
            if weekdays.isEmpty {
                return stepping(from: baseDate, by: .day, step: 7 * max(1, interval), from: start, to: end, calendar: calendar)
            } else {
                return weeklyOnWeekdays(baseDate: baseDate, interval: max(1, interval), weekdays: weekdays, from: start, to: end, calendar: calendar)
            }

        case .monthly(let interval):
            return stepping(from: baseDate, by: .month, step: max(1, interval), from: start, to: end, calendar: calendar)

        case .yearly(let interval):
            return stepping(from: baseDate, by: .year, step: max(1, interval), from: start, to: end, calendar: calendar)
        }
    }

    // MARK: - Helpers

    private static func advancing(
        from baseDate: Date,
        by component: Calendar.Component,
        step: Int,
        count: Int,
        now: Date,
        calendar: Calendar
    ) -> [Date] {
        var results: [Date] = []
        var candidate = baseDate
        // Fast-forward past `now` if baseDate is in the past.
        while candidate <= now {
            guard let next = calendar.date(byAdding: component, value: step, to: candidate) else { return results }
            candidate = next
        }
        while results.count < count {
            results.append(candidate)
            guard let next = calendar.date(byAdding: component, value: step, to: candidate) else { break }
            candidate = next
        }
        return results
    }

    /// Las fechas de `baseDate + k·step` que caen en `start ..< end`.
    private static func stepping(
        from baseDate: Date,
        by component: Calendar.Component,
        step: Int,
        from start: Date,
        to end: Date,
        calendar: Calendar
    ) -> [Date] {
        var candidate = baseDate
        // Sumar días nunca recorta la fecha (sumar meses sí: 31 de enero + 1 mes
        // = 28 de febrero, y de ahí se sigue el 28), así que para los pasos de
        // días se puede saltar de golpe hasta justo antes de `start` y caer en
        // las mismas fechas que avanzando de uno en uno. Para meses y años se
        // avanza paso a paso desde el ancla, que son pocos pasos.
        if component == .day, candidate < start,
           let days = calendar.dateComponents([.day], from: candidate, to: start).day,
           days >= step,
           let jumped = calendar.date(byAdding: .day, value: (days / step) * step, to: candidate) {
            candidate = jumped
        }
        var results: [Date] = []
        var steps = 0
        while candidate < end, steps < 10_000 {
            if candidate >= start { results.append(candidate) }
            guard let next = calendar.date(byAdding: component, value: step, to: candidate) else { break }
            candidate = next
            steps += 1
        }
        return results
    }

    private static func weeklyOnWeekdays(
        baseDate: Date,
        interval: Int,
        weekdays: Set<Weekday>,
        count: Int,
        now: Date,
        calendar: Calendar
    ) -> [Date] {
        // Anchor week start at the week of `baseDate`. Each "cycle" is `interval` weeks.
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: baseDate)?.start else { return [] }
        let time = calendar.dateComponents([.hour, .minute, .second], from: baseDate)
        var results: [Date] = []
        var cycleStart = weekStart

        // Safety cap to avoid infinite loops.
        let maxCycles = max(count * 4, 52)
        var cycleCount = 0

        while results.count < count, cycleCount < maxCycles {
            for candidate in weeklyCandidates(cycleStart: cycleStart, weekdays: weekdays, time: time, calendar: calendar)
            where candidate > now {
                results.append(candidate)
                if results.count >= count { return results }
            }
            guard let nextCycle = calendar.date(byAdding: .weekOfYear, value: interval, to: cycleStart) else { break }
            cycleStart = nextCycle
            cycleCount += 1
        }
        return results
    }

    private static func weeklyOnWeekdays(
        baseDate: Date,
        interval: Int,
        weekdays: Set<Weekday>,
        from start: Date,
        to end: Date,
        calendar: Calendar
    ) -> [Date] {
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: baseDate)?.start else { return [] }
        let time = calendar.dateComponents([.hour, .minute, .second], from: baseDate)
        var cycleStart = weekStart
        // Salta de golpe al ciclo que contiene `start`; los anteriores no caen
        // en el rango de todos modos.
        if cycleStart < start,
           let weeks = calendar.dateComponents([.weekOfYear], from: cycleStart, to: start).weekOfYear,
           weeks >= interval,
           let jumped = calendar.date(byAdding: .weekOfYear, value: (weeks / interval) * interval, to: cycleStart) {
            cycleStart = jumped
        }
        var results: [Date] = []
        var cycles = 0
        while cycleStart < end, cycles < 1_000 {
            for candidate in weeklyCandidates(cycleStart: cycleStart, weekdays: weekdays, time: time, calendar: calendar)
            where candidate >= baseDate && candidate >= start && candidate < end {
                results.append(candidate)
            }
            guard let nextCycle = calendar.date(byAdding: .weekOfYear, value: interval, to: cycleStart) else { break }
            cycleStart = nextCycle
            cycles += 1
        }
        return results
    }

    /// The chosen weekdays of ONE week, at the alarm's time, in date order.
    ///
    /// El desplazamiento se normaliza a 0…6 para que cada día caiga dentro de
    /// su propia semana. Antes, con la semana empezando en lunes, el domingo
    /// salía con desplazamiento −1: el domingo ANTERIOR al lunes. Cada semana
    /// daba igual, pero "cada 2 semanas" sonaba el domingo de la semana que no
    /// tocaba.
    private static func weeklyCandidates(
        cycleStart: Date,
        weekdays: Set<Weekday>,
        time: DateComponents,
        calendar: Calendar
    ) -> [Date] {
        let startWeekday = calendar.component(.weekday, from: cycleStart)
        return weekdays
            .compactMap { weekday -> Date? in
                let offset = (weekday.rawValue - startWeekday + 7) % 7
                guard let day = calendar.date(byAdding: .day, value: offset, to: cycleStart) else { return nil }
                var components = calendar.dateComponents([.year, .month, .day], from: day)
                components.hour = time.hour
                components.minute = time.minute
                components.second = time.second
                return calendar.date(from: components)
            }
            .sorted()
    }
}
