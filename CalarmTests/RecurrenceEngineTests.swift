//
//  RecurrenceEngineTests.swift
//  CalarmTests
//

import Foundation
import Testing
@testable import Calarm

struct RecurrenceEngineTests {

    // MARK: - .once

    @Test func onceFutureReturnsSingle() {
        let now = date("2026-01-01 10:00")
        let base = date("2026-06-01 09:00")
        let result = RecurrenceEngine.nextOccurrences(rule: .once, baseDate: base, count: 12, now: now, calendar: calendar)
        #expect(result == [base])
    }

    @Test func oncePastReturnsEmpty() {
        let now = date("2026-06-02 10:00")
        let base = date("2026-06-01 09:00")
        let result = RecurrenceEngine.nextOccurrences(rule: .once, baseDate: base, count: 12, now: now, calendar: calendar)
        #expect(result.isEmpty)
    }

    // MARK: - .daily

    @Test func dailyEveryTwoDays() {
        let now = date("2026-01-01 00:00")
        let base = date("2026-01-01 10:00")
        let result = RecurrenceEngine.nextOccurrences(rule: .daily(interval: 2), baseDate: base, count: 3, now: now, calendar: calendar)
        #expect(result.count == 3)
        #expect(result[0] == date("2026-01-01 10:00"))
        #expect(result[1] == date("2026-01-03 10:00"))
        #expect(result[2] == date("2026-01-05 10:00"))
    }

    @Test func dailyFastForwardsPastBaseDate() {
        let now = date("2026-01-10 12:00")
        let base = date("2026-01-01 10:00")
        let result = RecurrenceEngine.nextOccurrences(rule: .daily(interval: 3), baseDate: base, count: 2, now: now, calendar: calendar)
        // Sequence from base: 01, 04, 07, 10, 13...
        // After now (Jan 10 12:00), the next 10:00 is Jan 13.
        #expect(result.first == date("2026-01-13 10:00"))
        #expect(result.count == 2)
    }

    // MARK: - .weekly with specific weekdays

    @Test func weeklyMondayWednesdayFridayInterval1() {
        // 2026-01-04 is a Sunday. Anchor at Sunday 09:00.
        let now = date("2026-01-04 00:00")
        let base = date("2026-01-04 09:00") // Sunday
        let weekdays: Set<Weekday> = [.monday, .wednesday, .friday]
        let result = RecurrenceEngine.nextOccurrences(rule: .weekly(interval: 1, weekdays: weekdays), baseDate: base, count: 4, now: now, calendar: calendar)
        #expect(result.count == 4)
        // First Monday after base
        let weekdayValues = result.map { calendar.component(.weekday, from: $0) }
        // weekday 1=Sun ... 7=Sat. Monday=2, Wednesday=4, Friday=6
        #expect(weekdayValues.allSatisfy { [2, 4, 6].contains($0) })
        // Ascending
        for i in 1..<result.count {
            #expect(result[i] > result[i - 1])
        }
    }

    @Test func weeklyInterval2SkipsAWeek() {
        let now = date("2026-01-04 00:00") // Sunday
        let base = date("2026-01-04 09:00")
        let weekdays: Set<Weekday> = [.tuesday]
        let result = RecurrenceEngine.nextOccurrences(rule: .weekly(interval: 2, weekdays: weekdays), baseDate: base, count: 3, now: now, calendar: calendar)
        #expect(result.count == 3)
        // Diff between consecutive should be 14 days.
        for i in 1..<result.count {
            let days = calendar.dateComponents([.day], from: result[i - 1], to: result[i]).day ?? 0
            #expect(days == 14)
        }
    }

    @Test func weeklyEmptyWeekdaysFallsBackToInterval() {
        // No specific weekdays → treated as "every N weeks on base weekday"
        let now = date("2026-01-04 00:00")
        let base = date("2026-01-04 09:00") // Sunday
        let result = RecurrenceEngine.nextOccurrences(rule: .weekly(interval: 1, weekdays: []), baseDate: base, count: 3, now: now, calendar: calendar)
        #expect(result.count == 3)
        for i in 1..<result.count {
            let days = calendar.dateComponents([.day], from: result[i - 1], to: result[i]).day ?? 0
            #expect(days == 7)
        }
    }

    // MARK: - .monthly

    @Test func monthlyHandlesEndOfMonth() {
        // Jan 31 → Feb 28 (or 29 leap) → Mar 31...
        let now = date("2026-01-01 00:00")
        let base = date("2026-01-31 09:00")
        let result = RecurrenceEngine.nextOccurrences(rule: .monthly(interval: 1), baseDate: base, count: 3, now: now, calendar: calendar)
        #expect(result.count == 3)
        #expect(result[0] == date("2026-01-31 09:00"))
        // Calendar.date(byAdding: .month, value:) clamps to last valid day
        let secondMonth = calendar.component(.month, from: result[1])
        #expect(secondMonth == 2)
        let thirdMonth = calendar.component(.month, from: result[2])
        #expect(thirdMonth == 3)
    }

    // MARK: - .yearly

    @Test func yearlyAnnualBirthday() {
        let now = date("2026-01-01 00:00")
        let base = date("2026-07-14 09:00")
        let result = RecurrenceEngine.nextOccurrences(rule: .yearly(interval: 1), baseDate: base, count: 5, now: now, calendar: calendar)
        #expect(result.count == 5)
        let years = result.map { calendar.component(.year, from: $0) }
        #expect(years == [2026, 2027, 2028, 2029, 2030])
    }

    @Test func yearlyLeapDay() {
        let now = date("2024-01-01 00:00")
        let base = date("2024-02-29 09:00")
        let result = RecurrenceEngine.nextOccurrences(rule: .yearly(interval: 1), baseDate: base, count: 4, now: now, calendar: calendar)
        #expect(result.count == 4)
        // Non-leap years clamp to Feb 28
        let months = result.map { calendar.component(.month, from: $0) }
        #expect(months == [2, 2, 2, 2])
    }

    // MARK: - Helpers

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Mexico_City") ?? .current
        return cal
    }

    private func date(_ string: String) -> Date {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: string)!
    }
}
