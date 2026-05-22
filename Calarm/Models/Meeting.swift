//
//  Meeting.swift
//  Calarm
//

import Foundation

/// A calendar event that has been detected as a Microsoft Teams meeting.
struct Meeting: Identifiable, Hashable, Sendable {
    /// Stable identifier from the underlying calendar event (e.g. `EKEvent.eventIdentifier`).
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let teamsURL: URL?
    let organizer: String?
    let location: String?

    var duration: TimeInterval {
        endDate.timeIntervalSince(startDate)
    }

    /// Returns true when the meeting starts on the given calendar day.
    func occurs(on day: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(startDate, inSameDayAs: day)
    }

    /// Computes the alarm fire date given a desired lead time.
    func fireDate(leadTime: AlarmLeadTime) -> Date {
        startDate.addingTimeInterval(-leadTime.seconds)
    }
}
