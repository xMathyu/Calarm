//
//  CalendarSource.swift
//  Calarm
//

import Foundation

/// Abstraction over the calendar provider. EventKit is the initial implementation;
/// Microsoft Graph can be added later without touching the rest of the app.
protocol CalendarSource: Sendable {
    /// En qué punto está el permiso para leer el calendario.
    var access: CalendarAccess { get async }

    /// Requests authorization from the user if needed. Returns true if access was granted.
    func requestAccess() async throws -> Bool

    /// Los calendarios entre los que la persona puede elegir en Ajustes.
    func availableCalendars() async throws -> [CalendarInfo]

    /// Returns all Teams meetings starting within the given date range.
    /// `calendarIDs` nil significa "todos los calendarios del usuario"; un
    /// conjunto vacío significa que no eligió ninguno y no hay nada que leer.
    func upcomingMeetings(from start: Date, to end: Date, calendarIDs: Set<String>?) async throws -> [Meeting]

    /// An async stream that emits whenever the underlying calendar data changes.
    var changes: AsyncStream<Void> { get }
}

enum CalendarAccess: Sendable {
    /// Nunca se le preguntó a la persona: el aviso del sistema todavía puede salir.
    case notDetermined
    case granted
    /// Lo negó, lo dejó en "solo añadir eventos" o el dispositivo lo restringe.
    /// El aviso ya no vuelve a salir: solo se arregla desde la app Ajustes.
    case denied
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
