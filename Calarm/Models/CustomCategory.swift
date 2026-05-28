//
//  CustomCategory.swift
//  Calarm
//
//  User-created categories that coexist with the built-in `ReminderCategory`
//  set. CloudKit-compatible: every stored property has a default so SwiftData
//  can synthesize empty records when syncing.
//

import Foundation
import SwiftData
import SwiftUI

@Model
final class CustomCategory {
    var id: UUID = UUID()
    var name: String = ""
    var colorHex: String = "#AF52DE"
    var iconKindRaw: Int = ReminderIconKind.symbol.rawValue
    /// SF Symbol name or emoji string, depending on `iconKind`.
    var iconValue: String = "star.fill"
    var sortOrder: Int = 0
    var createdAt: Date = Date()

    init(
        id: UUID = UUID(),
        name: String = "",
        colorHex: String = "#AF52DE",
        iconKind: ReminderIconKind = .symbol,
        iconValue: String = "star.fill",
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.iconKindRaw = iconKind.rawValue
        self.iconValue = iconValue
        self.sortOrder = sortOrder
        self.createdAt = Date()
    }

    var iconKind: ReminderIconKind {
        get { ReminderIconKind(rawValue: iconKindRaw) ?? .symbol }
        set { iconKindRaw = newValue.rawValue }
    }

    var color: Color { Color(hex: colorHex) ?? .accentColor }

    /// Lowercased, trimmed name used for matching against AI/intent strings.
    var slug: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Identifies a reminder's category: one of the built-in cases, or a custom one
/// by id. Used as the picker selection and for save/restore.
enum CategorySelection: Hashable {
    case builtin(ReminderCategory)
    case custom(UUID)
}

/// Resolved presentation for either a built-in or custom category, so views and
/// services can render uniformly without caring which kind it is.
struct CategoryStyle: Identifiable {
    let selection: CategorySelection
    let title: String
    let color: Color
    /// Default icon for the category (symbol or emoji). A reminder may still
    /// override its own icon.
    let iconKind: ReminderIconKind
    let iconValue: String

    var id: CategorySelection { selection }

    init(builtin category: ReminderCategory) {
        self.selection = .builtin(category)
        self.title = category.localizedTitle
        self.color = category.tint
        self.iconKind = .symbol
        self.iconValue = category.defaultSymbol
    }

    init(custom category: CustomCategory) {
        self.selection = .custom(category.id)
        self.title = category.name
        self.color = category.color
        self.iconKind = category.iconKind
        self.iconValue = category.iconValue
    }
}
