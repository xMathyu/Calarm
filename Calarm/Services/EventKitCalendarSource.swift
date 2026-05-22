//
//  EventKitCalendarSource.swift
//  Calarm
//

import EventKit
import Foundation

final class EventKitCalendarSource: CalendarSource, @unchecked Sendable {
    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    var isAuthorized: Bool {
        get async {
            EKEventStore.authorizationStatus(for: .event) == .fullAccess
        }
    }

    func requestAccess() async throws -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return true
        case .denied, .restricted, .writeOnly:
            throw CalendarSourceError.accessDenied
        case .notDetermined:
            return try await eventStore.requestFullAccessToEvents()
        @unknown default:
            return false
        }
    }

    func upcomingMeetings(from start: Date, to end: Date) async throws -> [Meeting] {
        guard await isAuthorized else { throw CalendarSourceError.accessDenied }

        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = eventStore.events(matching: predicate)

        return events.compactMap { event -> Meeting? in
            guard let teamsURL = TeamsMeetingDetector.extractTeamsURL(
                url: event.url,
                location: event.location,
                notes: event.notes
            ) else { return nil }

            guard let startDate = event.startDate,
                  let endDate = event.endDate,
                  let identifier = event.eventIdentifier else { return nil }

            return Meeting(
                id: identifier,
                title: event.title ?? "Reunión sin título",
                startDate: startDate,
                endDate: endDate,
                teamsURL: teamsURL,
                organizer: event.organizer?.name,
                location: event.location
            )
        }
        .sorted { $0.startDate < $1.startDate }
    }

    var changes: AsyncStream<Void> {
        AsyncStream { continuation in
            let observer = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: eventStore,
                queue: nil
            ) { _ in
                continuation.yield()
            }
            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}
