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

    func availableCalendars() async throws -> [CalendarInfo] {
        guard await isAuthorized else { throw CalendarSourceError.accessDenied }
        return selectableCalendars().map { calendar in
            CalendarInfo(
                id: calendar.calendarIdentifier,
                title: calendar.title,
                sourceTitle: calendar.source?.title ?? "",
                colorHex: calendar.cgColor.flatMap(Self.hex(from:))
            )
        }
        .sorted { ($0.sourceTitle, $0.title) < ($1.sourceTitle, $1.title) }
    }

    /// Los calendarios que Calarm ofrece: los del usuario, sin los suscritos
    /// (festivos, calendarios deportivos) ni el de cumpleaños de Contactos, que
    /// no son eventos que alguien haya agendado.
    private func selectableCalendars() -> [EKCalendar] {
        eventStore.calendars(for: .event).filter { calendar in
            calendar.type != .subscription && calendar.type != .birthday
        }
    }

    private static func hex(from color: CGColor) -> String? {
        guard let components = color.components, components.count >= 3 else { return nil }
        let parts = components.prefix(3).map { Int((max(0, min(1, $0)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", parts[0], parts[1], parts[2])
    }

    func upcomingMeetings(from start: Date, to end: Date, calendarIDs: Set<String>?) async throws -> [Meeting] {
        guard await isAuthorized else { throw CalendarSourceError.accessDenied }

        let available = selectableCalendars()
        var userCalendars = available
        if let wanted = Self.calendarsToRead(
            selection: calendarIDs,
            available: available.map(\.calendarIdentifier)
        ) {
            guard !wanted.isEmpty else { return [] }
            userCalendars = available.filter { wanted.contains($0.calendarIdentifier) }
        }
        guard !userCalendars.isEmpty else { return [] }
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: userCalendars)
        let events = eventStore.events(matching: predicate)

        return events.compactMap { event -> Meeting? in
            guard let startDate = event.startDate,
                  let endDate = event.endDate,
                  let identifier = event.eventIdentifier else { return nil }

            // Skip all-day events — typically holidays, anniversaries from contacts,
            // or informational entries the user doesn't want as alarms.
            if event.isAllDay { return nil }

            // Detect an optional Teams/Zoom/Google Meet link to enable a join button.
            let meetingLink = MeetingLinkDetector.extractMeetingLink(
                url: event.url,
                location: event.location,
                notes: event.notes
            )

            return Meeting(
                id: identifier,
                title: event.title ?? "Evento sin título",
                startDate: startDate,
                endDate: endDate,
                meetingLink: meetingLink,
                organizer: event.organizer?.name,
                location: event.location,
                isParticipating: Self.isParticipating(in: event)
            )
        }
        .sorted { $0.startDate < $1.startDate }
    }

    /// Qué calendarios hay que leer, dada la selección guardada. `nil` = todos.
    ///
    /// Una selección vacía es una elección —"ninguno"— y se respeta. Pero una
    /// selección cuyos identificadores ya no existen NO es una elección: los de
    /// EventKit rotan al quitar y volver a poner una cuenta, o al restaurar el
    /// iPhone de un backup, y entonces la persona se quedaría sin alarmas de
    /// calendario para siempre sin que nada se lo diga. En ese caso se leen
    /// todos: en una app de alarmas, sonar de más se ve; no sonar, no.
    static func calendarsToRead(selection: Set<String>?, available: [String]) -> Set<String>? {
        guard let selection else { return nil }
        guard !selection.isEmpty else { return [] }
        let alive = selection.intersection(available)
        return alive.isEmpty ? nil : alive
    }

    /// Si la persona cuenta como parte del evento.
    ///
    /// Un evento sin invitados es suyo (lo creó ella) y siempre cuenta. Con
    /// invitados manda su propia respuesta: declinado no cuenta. Y si hay lista
    /// de invitados pero EventKit no la encuentra en ella, el evento es de otra
    /// persona —el calendario compartido de la pareja, por ejemplo— y tampoco
    /// cuenta.
    private static func isParticipating(in event: EKEvent) -> Bool {
        guard let attendees = event.attendees, !attendees.isEmpty else { return true }
        guard let me = attendees.first(where: { $0.isCurrentUser }) else { return false }
        return me.participantStatus != .declined
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
