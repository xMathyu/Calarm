//
//  CalendarItem.swift
//  Calarm
//
//  Lo que la vista de mes pinta en un día: una ocurrencia de una alarma propia
//  o un evento del calendario del sistema, ordenables por hora entre sí. Y la
//  rejilla del mes (semanas × días) que los acomoda.
//

import Foundation

enum CalendarItem: Identifiable {
    case alarm(Reminder, occurrence: Date)
    case event(Meeting)

    var id: String {
        switch self {
        case .alarm(let reminder, let occurrence):
            "alarm:\(reminder.id.uuidString):\(occurrence.timeIntervalSinceReferenceDate)"
        case .event(let meeting):
            "event:\(meeting.id)"
        }
    }

    var date: Date {
        switch self {
        case .alarm(_, let occurrence): occurrence
        case .event(let meeting): meeting.startDate
        }
    }

    /// A la misma hora, la alarma va antes que el evento: es lo que suena.
    private var tieBreak: Int {
        switch self {
        case .alarm: 0
        case .event: 1
        }
    }

    /// Every occurrence of every schedule of `reminders` within `start ..< end`,
    /// one item per distinct instant (two schedules that coincide count once,
    /// as they ring once).
    static func alarmItems(
        from reminders: [Reminder],
        from start: Date,
        to end: Date,
        calendar: Calendar = .current
    ) -> [CalendarItem] {
        var seen = Set<String>()
        var items: [CalendarItem] = []
        for reminder in reminders {
            for schedule in reminder.allSchedules {
                let occurrences = RecurrenceEngine.occurrences(
                    rule: schedule.recurrence,
                    baseDate: schedule.date,
                    from: start,
                    to: end,
                    calendar: calendar
                )
                for occurrence in occurrences {
                    let item = CalendarItem.alarm(reminder, occurrence: occurrence)
                    if seen.insert(item.id).inserted { items.append(item) }
                }
            }
        }
        return items
    }

    /// Alarms and events together, grouped by day and sorted by time.
    static func byDay(
        alarms: [CalendarItem],
        events: [Meeting],
        calendar: Calendar = .current
    ) -> [Date: [CalendarItem]] {
        let all = (alarms + events.map(CalendarItem.event)).sorted { a, b in
            a.date == b.date ? a.tieBreak < b.tieBreak : a.date < b.date
        }
        return Dictionary(grouping: all) { calendar.startOfDay(for: $0.date) }
    }
}

/// The weeks of one month laid out for a 7-column grid, honoring the
/// calendar's first weekday. `nil` cells pad the first and last week.
struct MonthGrid: Equatable {
    /// First instant of the month.
    let monthStart: Date
    /// First instant of the next month (exclusive end of the range).
    let monthEnd: Date
    /// Rows of 7 — `nil` where the cell belongs to a neighbouring month.
    let weeks: [[Date?]]

    init(containing date: Date, calendar: Calendar) {
        let interval = calendar.dateInterval(of: .month, for: date)
            ?? DateInterval(start: calendar.startOfDay(for: date), duration: 0)
        monthStart = interval.start
        monthEnd = interval.end

        let dayCount = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        let leading = (calendar.component(.weekday, from: monthStart) - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<dayCount {
            cells.append(calendar.date(byAdding: .day, value: offset, to: monthStart))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        weeks = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }

    /// Weekday initials in grid order, starting at the calendar's first weekday.
    static func weekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }
}
