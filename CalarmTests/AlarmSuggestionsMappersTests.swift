//
//  AlarmSuggestionsMappersTests.swift
//  CalarmTests
//
//  Covers the slug → domain mappers the AI paths (chat tools + "crear alarma
//  con IA" intent) run their output through.
//

import Foundation
import Testing
@testable import Calarm

@MainActor
struct AlarmSuggestionsMappersTests {

    // MARK: - Weekday parsing

    @Test func parsesEnglishAndSpanishWeekdays() {
        #expect(Weekday.from(slug: "monday") == .monday)
        #expect(Weekday.from(slug: "Monday") == .monday)
        #expect(Weekday.from(slug: "mondays") == .monday)
        #expect(Weekday.from(slug: "lunes") == .monday)
        #expect(Weekday.from(slug: " Lunes ") == .monday)
        #expect(Weekday.from(slug: "miércoles") == .wednesday)
        #expect(Weekday.from(slug: "miercoles") == .wednesday)
        #expect(Weekday.from(slug: "sábados") == .saturday)
        #expect(Weekday.from(slug: "thu") == .thursday)
    }

    @Test func rejectsNonWeekdays() {
        #expect(Weekday.from(slug: "daily") == nil)
        #expect(Weekday.from(slug: "") == nil)
        #expect(Weekday.from(slug: "someday") == nil)
    }

    @Test func weekdaysFromNamesDropsGarbage() {
        let result = AlarmSuggestionsService.weekdays(fromNames: ["monday", "nope", "jueves"])
        #expect(result == [.monday, .thursday])
        #expect(AlarmSuggestionsService.weekdays(fromNames: nil).isEmpty)
        #expect(AlarmSuggestionsService.weekdays(fromNames: []).isEmpty)
    }

    // MARK: - Recurrence with weekdays

    @Test func namedWeekdaysOverrideAMislabelledSlug() {
        // "Pon una alarma de mi daily todos los lunes" — the model reads "daily"
        // out of the title, but the named weekday is the real frequency.
        let rule = AlarmSuggestionsService.recurrence(fromSlug: "daily", weekdays: [.monday])
        #expect(rule == .weekly(interval: 1, weekdays: [.monday]))
    }

    @Test func noWeekdaysKeepsPlainSlugBehaviour() {
        #expect(AlarmSuggestionsService.recurrence(fromSlug: "daily", weekdays: []) == .daily(interval: 1))
        #expect(AlarmSuggestionsService.recurrence(fromSlug: "yearly", weekdays: []) == .yearly(interval: 1))
        #expect(AlarmSuggestionsService.recurrence(fromSlug: "nonsense", weekdays: []) == .once)
    }

    @Test func multipleWeekdaysBecomeOneWeeklyRule() {
        let rule = AlarmSuggestionsService.recurrence(fromSlug: "weekly", weekdays: [.tuesday, .thursday])
        #expect(rule == .weekly(interval: 1, weekdays: [.tuesday, .thursday]))
    }

    // MARK: - Date snapping

    @Test func snapsForwardToTheNamedWeekday() {
        // 2026-08-07 is a Friday; the next Monday is 2026-08-10.
        let friday = date("2026-08-07 09:00")
        let snapped = AlarmSuggestionsService.snap(friday, toFirstOf: [.monday], calendar: calendar)
        #expect(snapped == date("2026-08-10 09:00"))
    }

    @Test func snapKeepsADateAlreadyOnAMatchingWeekday() {
        let monday = date("2026-08-10 09:00")
        let snapped = AlarmSuggestionsService.snap(monday, toFirstOf: [.monday, .wednesday], calendar: calendar)
        #expect(snapped == monday)
    }

    @Test func snapPicksTheSoonestOfSeveralWeekdays() {
        // Friday → Saturday is closer than Monday.
        let friday = date("2026-08-07 09:00")
        let snapped = AlarmSuggestionsService.snap(friday, toFirstOf: [.monday, .saturday], calendar: calendar)
        #expect(snapped == date("2026-08-08 09:00"))
    }

    @Test func snapIsANoOpWithoutWeekdays() {
        let friday = date("2026-08-07 09:00")
        #expect(AlarmSuggestionsService.snap(friday, toFirstOf: [], calendar: calendar) == friday)
    }

    // MARK: - End to end: the reported bug

    @Test func dailyStandupEveryMondayFiresOnlyOnMondays() {
        let rule = AlarmSuggestionsService.recurrence(fromSlug: "daily", weekdays: [.monday])
        let base = AlarmSuggestionsService.snap(date("2026-08-07 09:00"), toFirstOf: [.monday], calendar: calendar)
        let occurrences = RecurrenceEngine.nextOccurrences(
            rule: rule,
            baseDate: base,
            count: 4,
            now: date("2026-08-07 10:00"),
            calendar: calendar
        )
        #expect(occurrences.count == 4)
        #expect(occurrences.allSatisfy { calendar.component(.weekday, from: $0) == Weekday.monday.rawValue })
        #expect(occurrences.first == date("2026-08-10 09:00"))
    }

    // MARK: - Rolling a past date into the future

    @Test func bareTimeAlreadyGoneMovesToTomorrow() {
        // "Pon una alarma a las 9" typed at 23:00 — the model answers with today
        // at 09:00, which would never ring.
        let rolled = AlarmSuggestionsService.rollIntoFuture(
            date("2026-08-07 09:00"),
            recurrence: .once,
            now: date("2026-08-07 23:00"),
            calendar: calendar
        )
        #expect(rolled == date("2026-08-08 09:00"))
    }

    @Test func futureDatesAreLeftAlone() {
        let future = date("2026-08-08 09:00")
        #expect(
            AlarmSuggestionsService.rollIntoFuture(
                future,
                recurrence: .once,
                now: date("2026-08-07 23:00"),
                calendar: calendar
            ) == future
        )
    }

    @Test func aDateFromAnEarlierDayIsNotSilentlyMoved() {
        // Over 24 h in the past is a date the user really gave, not a bare time:
        // moving it a day would invent a schedule they never asked for.
        let old = date("2026-08-01 09:00")
        #expect(
            AlarmSuggestionsService.rollIntoFuture(
                old,
                recurrence: .once,
                now: date("2026-08-07 23:00"),
                calendar: calendar
            ) == old
        )
    }

    @Test func recurringAlarmsKeepTheirAnchor() {
        // A weekly alarm moves a week, a monthly one a month — so the day of the
        // week (or of the month) the user picked survives the roll.
        let weekly = AlarmSuggestionsService.rollIntoFuture(
            date("2026-08-07 09:00"),
            recurrence: .weekly(interval: 1, weekdays: []),
            now: date("2026-08-07 23:00"),
            calendar: calendar
        )
        #expect(weekly == date("2026-08-14 09:00"))

        let monthly = AlarmSuggestionsService.rollIntoFuture(
            date("2026-08-07 09:00"),
            recurrence: .monthly(interval: 1),
            now: date("2026-08-07 23:00"),
            calendar: calendar
        )
        #expect(monthly == date("2026-09-07 09:00"))
    }

    @Test func weeklyOnNamedDaysRollsThenSnapsBackOntoTheDay() {
        // Friday 23:00, "todos los viernes a las 9": +1 day lands on Saturday and
        // `snap` walks it to the next Friday.
        let rule = AlarmSuggestionsService.recurrence(fromSlug: "weekly", weekdays: [.friday])
        let rolled = AlarmSuggestionsService.rollIntoFuture(
            date("2026-08-07 09:00"),
            recurrence: rule,
            now: date("2026-08-07 23:00"),
            calendar: calendar
        )
        let snapped = AlarmSuggestionsService.snap(rolled, toFirstOf: [.friday], calendar: calendar)
        #expect(snapped == date("2026-08-14 09:00"))
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
