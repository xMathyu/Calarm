//
//  Meeting.swift
//  Calarm
//

import Foundation

/// Video-meeting service whose join links Calarm recognizes in calendar events.
enum MeetingProvider: String, Hashable, Sendable {
    case teams
    case zoom
    case googleMeet

    /// Brand name shown on the join button ("Unirse en Zoom"). Proper nouns — not localized.
    var displayName: String {
        switch self {
        case .teams: "Teams"
        case .zoom: "Zoom"
        case .googleMeet: "Google Meet"
        }
    }
}

/// A join link detected in a calendar event, tagged with its provider.
struct MeetingLink: Hashable, Sendable {
    let provider: MeetingProvider
    let url: URL
}

/// A calendar event surfaced in the meetings list, optionally with a video-meeting join link.
struct Meeting: Identifiable, Hashable, Sendable {
    /// Stable identifier from the underlying calendar event (e.g. `EKEvent.eventIdentifier`).
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let meetingLink: MeetingLink?
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
