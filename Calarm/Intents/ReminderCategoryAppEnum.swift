//
//  ReminderCategoryAppEnum.swift
//  Calarm
//
//  App Intents wrapper around `ReminderCategory`. Lets Siri / Shortcuts users
//  pick a category as a parameter ("Cumpleaños", "Aniversario", etc.).
//

import AppIntents
import Foundation

enum ReminderCategoryAppEnum: String, AppEnum {
    case birthday
    case anniversary
    case event
    case reminder
    case other

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Categoría"

    static let caseDisplayRepresentations: [ReminderCategoryAppEnum: DisplayRepresentation] = [
        .birthday:    "Cumpleaños",
        .anniversary: "Aniversario",
        .event:       "Evento",
        .reminder:    "Recordatorio",
        .other:       "Otro",
    ]

    /// Maps the AppIntent enum to the underlying domain model.
    var category: ReminderCategory {
        switch self {
        case .birthday: .birthday
        case .anniversary: .anniversary
        case .event: .event
        case .reminder: .reminder
        case .other: .other
        }
    }
}
