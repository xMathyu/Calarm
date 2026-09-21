//
//  CalendarInfo.swift
//  Calarm
//

import Foundation

/// Un calendario del sistema, tal como se ofrece en Ajustes para elegir cuáles
/// mira Calarm. Es la vista mínima de un `EKCalendar`: lo justo para pintarlo en
/// una lista y guardarlo por identificador.
struct CalendarInfo: Identifiable, Hashable, Sendable {
    /// `EKCalendar.calendarIdentifier`.
    let id: String
    let title: String
    /// La cuenta a la que pertenece ("iCloud", "Gmail"…), para agrupar la lista.
    let sourceTitle: String
    /// El color del calendario en hexadecimal, si el sistema lo da.
    let colorHex: String?
}
