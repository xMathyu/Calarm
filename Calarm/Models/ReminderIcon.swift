//
//  ReminderIcon.swift
//  Calarm
//

import Foundation

enum ReminderIconKind: Int, Codable, Sendable {
    case symbol = 0
    case photo = 1
    case emoji = 2
}

/// Heuristic: does this string start with an emoji scalar? Used to tell an
/// emoji icon apart from an SF Symbol name (both are stored in `symbolName`).
func isEmojiIcon(_ value: String?) -> Bool {
    guard let scalar = value?.unicodeScalars.first else { return false }
    return scalar.properties.isEmojiPresentation || (scalar.properties.isEmoji && scalar.value > 0x238C)
}
