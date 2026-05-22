//
//  RecurrenceEngine.swift
//  Calarm
//

import Foundation

/// Pure logic to compute the next N occurrences of a `RecurrenceRule` from a base date.
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
        let baseHour = calendar.component(.hour, from: baseDate)
        let baseMinute = calendar.component(.minute, from: baseDate)
        let baseSecond = calendar.component(.second, from: baseDate)

        let sortedWeekdays = weekdays.sorted { $0.rawValue < $1.rawValue }
        var results: [Date] = []
        var cycleStart = weekStart

        // Safety cap to avoid infinite loops.
        let maxCycles = max(count * 4, 52)
        var cycleCount = 0

        while results.count < count, cycleCount < maxCycles {
            for weekday in sortedWeekdays {
                let offset = weekday.rawValue - calendar.component(.weekday, from: cycleStart)
                guard let dayDate = calendar.date(byAdding: .day, value: offset, to: cycleStart) else { continue }
                var components = calendar.dateComponents([.year, .month, .day], from: dayDate)
                components.hour = baseHour
                components.minute = baseMinute
                components.second = baseSecond
                guard let candidate = calendar.date(from: components) else { continue }
                if candidate > now {
                    results.append(candidate)
                    if results.count >= count { return results }
                }
            }
            guard let nextCycle = calendar.date(byAdding: .weekOfYear, value: interval, to: cycleStart) else { break }
            cycleStart = nextCycle
            cycleCount += 1
        }
        return results
    }
}
