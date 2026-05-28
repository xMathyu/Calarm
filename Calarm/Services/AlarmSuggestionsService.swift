//
//  AlarmSuggestionsService.swift
//  Calarm
//
//  Lightweight wrapper around Foundation Models that suggests sensible
//  defaults for a new alarm based purely on its title.
//
//  Example: "Cumpleaños de Ana" → category=birthday, recurrence=yearly,
//           leadTimesMinutes=[0, 1440]   (at-start + 1 day before)
//

import FoundationModels
import Foundation

/// Result of the AI suggestion. All fields use slug-style strings so the
/// model has a small, well-known vocabulary to pick from.
@Generable
struct AlarmSuggestion: Sendable, Equatable {
    @Guide(description: "Best matching category. Pick exactly one of: birthday, anniversary, event, reminder, other.")
    let category: String

    @Guide(description: "Best matching recurrence. Pick exactly one of: once, daily, weekly, monthly, yearly.")
    let recurrence: String

    @Guide(description: "Lead times in minutes before the alarm. Examples: [0] for at-start only; [0, 60] for at-start + 1 hour before; [1440] for 1 day before only. Default to [0] when uncertain.")
    let leadTimesMinutes: [Int]

    @Guide(description: "Confidence 0.0-1.0. Set to 0.0 when the title is too vague to suggest anything specific (e.g. 'tarea', 'cosa', 'algo').")
    let confidence: Double
}

@MainActor
final class AlarmSuggestionsService {
    static let shared = AlarmSuggestionsService()
    private init() {}

    /// True when Apple Intelligence is set up and the device can run the model.
    var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Returns a structured suggestion or nil if the model is unavailable /
    /// the title is too vague (confidence below threshold).
    func suggest(for title: String, locale: Locale) async -> AlarmSuggestion? {
        guard isAvailable else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return nil }

        let customNames = (CategoryStore.shared?.customCategories.map(\.name) ?? [])
            .filter { !$0.isEmpty }
        let categoryLine = customNames.isEmpty
            ? "- category: pick the single best fit from [birthday, anniversary, event, reminder, other]"
            : "- category: pick the single best fit from the built-ins [birthday, anniversary, event, reminder, other] OR one of the user's CUSTOM categories (output the exact name): [\(customNames.joined(separator: ", "))]. Prefer a custom category when it clearly matches the title."

        let instructions = Instructions("""
        You analyze short alarm titles and predict the most natural defaults for them.
        \(categoryLine)
        - recurrence: pick the single best fit from [once, daily, weekly, monthly, yearly]
        - leadTimesMinutes: list of minutes-before. Birthdays and anniversaries → [0, 1440] (at-start + 1 day before). Meetings/events → [0, 15]. Pills/medication → [0]. Default [0].
        - confidence: how confident you are. Title like 'Cumpleaños de Ana' → 0.95. Title like 'reunión' → 0.6. Title like 'cosa' → 0.2.
        Respect the user's language.
        """)

        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: instructions
        )

        let prompt = """
        User locale: \(locale.identifier)
        Alarm title: "\(trimmed)"
        Predict the structured fields.
        """

        do {
            let response = try await session.respond(
                to: prompt,
                generating: AlarmSuggestion.self
            )
            let suggestion = response.content
            // Only return suggestions we're reasonably confident about, so the
            // UI doesn't badge weak guesses on top of the user's input.
            return suggestion.confidence >= 0.5 ? suggestion : nil
        } catch {
            return nil
        }
    }

    // MARK: - Mappers (string slug → typed value)

    static func leadTimes(fromMinutes minutes: [Int]) -> [AlarmLeadTime] {
        guard !minutes.isEmpty else { return [.atStart] }
        let all = AlarmLeadTime.allCases
        let mapped = minutes.compactMap { mins -> AlarmLeadTime? in
            let seconds = max(0, mins) * 60
            return all.min { abs($0.rawValue - seconds) < abs($1.rawValue - seconds) }
        }
        var seen = Set<AlarmLeadTime>()
        let unique = mapped.filter { seen.insert($0).inserted }
        return unique.isEmpty ? [.atStart] : unique
    }

    static func recurrence(fromSlug slug: String) -> RecurrenceRule {
        switch slug.lowercased() {
        case "daily": .daily(interval: 1)
        case "weekly": .weekly(interval: 1, weekdays: [])
        case "monthly": .monthly(interval: 1)
        case "yearly": .yearly(interval: 1)
        default: .once
        }
    }
}
