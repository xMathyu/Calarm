//
//  CategoryStore.swift
//  Calarm
//
//  Owns the user's custom categories and resolves a reminder's category into a
//  uniform `CategoryStyle` (built-in or custom). Injected into the environment
//  for views and exposed via `shared` for non-view code (scheduler, sharing,
//  assistant tools).
//

import Foundation
import Observation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class CategoryStore {
    /// Set on init so non-view code (AlarmScheduler, SharedRemindersService,
    /// AssistantTools) can resolve categories without an environment.
    static private(set) var shared: CategoryStore?

    private let context: ModelContext
    private(set) var customCategories: [CustomCategory] = []

    init(context: ModelContext) {
        self.context = context
        reload()
        CategoryStore.shared = self
    }

    func reload() {
        let descriptor = FetchDescriptor<CustomCategory>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
        )
        customCategories = (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Resolution

    /// Every selectable category: built-ins first, then custom ones.
    func allStyles() -> [CategoryStyle] {
        ReminderCategory.displayOrder.map(CategoryStyle.init(builtin:))
        + customCategories.map(CategoryStyle.init(custom:))
    }

    func customCategory(id: UUID) -> CustomCategory? {
        customCategories.first { $0.id == id }
    }

    /// The resolved style for a reminder — its custom category if set and known,
    /// otherwise the built-in derived from `categoryRaw`.
    func style(for reminder: Reminder) -> CategoryStyle {
        if let cid = reminder.customCategoryID, let cat = customCategory(id: cid) {
            return CategoryStyle(custom: cat)
        }
        return CategoryStyle(builtin: reminder.category)
    }

    func style(for selection: CategorySelection) -> CategoryStyle {
        switch selection {
        case .builtin(let c):
            return CategoryStyle(builtin: c)
        case .custom(let id):
            if let cat = customCategory(id: id) { return CategoryStyle(custom: cat) }
            return CategoryStyle(builtin: .other)
        }
    }

    /// The current selection for a reminder.
    func selection(for reminder: Reminder) -> CategorySelection {
        if let cid = reminder.customCategoryID, customCategory(id: cid) != nil {
            return .custom(cid)
        }
        return .builtin(reminder.category)
    }

    /// Applies a selection to a reminder. Custom selections also set
    /// `categoryRaw` to `.other` so built-in filters/AlarmKit still behave.
    func apply(_ selection: CategorySelection, to reminder: Reminder) {
        switch selection {
        case .builtin(let c):
            reminder.category = c
            reminder.customCategoryID = nil
        case .custom(let id):
            reminder.customCategoryID = id
            reminder.category = .other
        }
    }

    /// Matches a free-form string (AI/intent output) to a category — custom
    /// names first (case-insensitive), then built-in slugs.
    func resolve(slug raw: String) -> CategorySelection? {
        let needle = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        if let match = customCategories.first(where: { $0.slug == needle }) {
            return .custom(match.id)
        }
        if let builtin = ReminderCategory.from(slug: needle) {
            return .builtin(builtin)
        }
        return nil
    }

    // MARK: - CRUD

    @discardableResult
    func add(name: String, colorHex: String, iconKind: ReminderIconKind, iconValue: String) -> CustomCategory {
        let category = CustomCategory(
            name: name,
            colorHex: colorHex,
            iconKind: iconKind,
            iconValue: iconValue,
            sortOrder: (customCategories.map(\.sortOrder).max() ?? 0) + 1
        )
        context.insert(category)
        try? context.save()
        reload()
        return category
    }

    func update(_ category: CustomCategory, name: String, colorHex: String, iconKind: ReminderIconKind, iconValue: String) {
        category.name = name
        category.colorHex = colorHex
        category.iconKind = iconKind
        category.iconValue = iconValue
        try? context.save()
        reload()
    }

    /// Deletes a custom category. Reminders that referenced it fall back to
    /// their built-in `categoryRaw` (already `.other`).
    func delete(_ category: CustomCategory) {
        context.delete(category)
        try? context.save()
        reload()
    }
}
