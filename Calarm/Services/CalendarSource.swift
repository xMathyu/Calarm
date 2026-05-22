//
//  CalendarSource.swift
//  Calarm
//

import Foundation

/// Abstraction over the calendar provider. EventKit is the initial implementation;
/// Microsoft Graph can be added later without touching the rest of the app.
protocol CalendarSource: Sendable {
    /// Whether the source currently has authorization to read calendar data.
    var isAuthorized: Bool { get async }

    /// Requests authorization from the user if needed. Returns true if access was granted.
    func requestAccess() async throws -> Bool

    /// Returns all Teams meetings starting within the given date range.
    func upcomingMeetings(from start: Date, to end: Date) async throws -> [Meeting]

    /// An async stream that emits whenever the underlying calendar data changes.
    var changes: AsyncStream<Void> { get }
}

enum CalendarSourceError: Error, LocalizedError {
    case accessDenied
    case unavailable

    var errorDescription: String? {
        switch self {
        case .accessDenied: "Calarm necesita acceso a tu calendario para detectar reuniones."
        case .unavailable: "El calendario no está disponible en este dispositivo."
        }
    }
}
