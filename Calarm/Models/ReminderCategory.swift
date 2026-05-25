//
//  ReminderCategory.swift
//  Calarm
//

import SwiftUI

enum ReminderCategory: Int, CaseIterable, Identifiable, Codable, Sendable {
    case birthday = 0
    case anniversary = 1
    case event = 2
    case reminder = 3
    case other = 4

    var id: Int { rawValue }

    /// Order shown in the UI. Default (`.reminder`) comes first so the
    /// most-common choice is easiest to reach. Raw values stay stable for
    /// persistence — only the presentation order changes here.
    static let displayOrder: [ReminderCategory] = [.reminder, .event, .birthday, .anniversary, .other]

    /// Maps a slug like "birthday" or "EVENT" to the matching category. Used
    /// when an external system (App Intent, AI parser) hands us a string.
    static func from(slug: String) -> ReminderCategory? {
        switch slug.lowercased() {
        case "birthday": .birthday
        case "anniversary": .anniversary
        case "event": .event
        case "reminder": .reminder
        case "other": .other
        default: nil
        }
    }

    var localizedTitle: String {
        switch self {
        case .birthday: String(localized: "Cumpleaños")
        case .anniversary: String(localized: "Aniversario")
        case .event: String(localized: "Evento")
        case .reminder: String(localized: "Recordatorio")
        case .other: String(localized: "Otro")
        }
    }

    var defaultSymbol: String {
        switch self {
        case .birthday: "birthday.cake.fill"
        case .anniversary: "heart.fill"
        case .event: "calendar"
        case .reminder: "bell.fill"
        case .other: "star.fill"
        }
    }

    var tint: Color {
        switch self {
        case .birthday: .pink
        case .anniversary: .red
        case .event: .blue
        case .reminder: .orange
        case .other: .purple
        }
    }

    /// SF Symbols suggested in the icon picker for this category.
    var suggestedSymbols: [String] {
        switch self {
        case .birthday:
            return ["birthday.cake.fill", "gift.fill", "party.popper.fill", "balloon.fill", "fork.knife", "music.note", "camera.fill", "heart.fill"]
        case .anniversary:
            return ["heart.fill", "heart.circle.fill", "rings.fill", "rosette", "champagne.bottle", "wineglass.fill", "gift.fill", "calendar"]
        case .event:
            return ["calendar", "calendar.badge.clock", "calendar.circle.fill", "person.2.fill", "airplane", "ticket.fill", "graduationcap.fill", "trophy.fill"]
        case .reminder:
            return ["bell.fill", "alarm.fill", "checkmark.circle.fill", "list.bullet.clipboard.fill", "pill.fill", "stethoscope", "creditcard.fill", "house.fill"]
        case .other:
            return ["star.fill", "flag.fill", "bookmark.fill", "tag.fill", "pencil", "lightbulb.fill", "leaf.fill", "globe"]
        }
    }
}
