//
//  AppSettings.swift
//  Calarm
//

import Foundation
import Observation
import SwiftUI

/// User-selectable appearance override.
enum AppearanceMode: Int, CaseIterable, Identifiable, Sendable {
    case system = 0
    case light = 1
    case dark = 2

    var id: Int { rawValue }

    var localizedTitle: String {
        switch self {
        case .system: appLocalized("Automático")
        case .light: appLocalized("Claro")
        case .dark: appLocalized("Oscuro")
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    /// Maps to SwiftUI's `preferredColorScheme`. `nil` = follow system.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// User-selectable language. `system` follows the iPhone's preferred language.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case spanish = "es"
    case english = "en"

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .system: appLocalized("Automático")
        case .spanish: appLocalized("Español")
        case .english: appLocalized("Inglés")
        }
    }

    var flag: String {
        switch self {
        case .system: "globe"
        case .spanish: "globe.europe.africa.fill"
        case .english: "globe.americas.fill"
        }
    }

    /// Language code used by `Bundle.path(forResource:ofType:)`. `nil` for system.
    var bundleLanguageCode: String? {
        switch self {
        case .system: nil
        case .spanish: "es"
        case .english: "en"
        }
    }
}

@Observable
final class AppSettings {
    private let defaults: UserDefaults

    private enum Key {
        static let snooze = "settings.snooze"
        static let alarmsEnabled = "settings.alarmsEnabled"
        static let onboardingCompleted = "settings.onboardingCompleted"
        static let teamsDetectionEnabled = "settings.teamsDetectionEnabled"
        static let appearance = "settings.appearance"
        static let language = "settings.language"
        static let accentColorHex = "settings.accentColorHex"
    }

    /// Curated accent presets shown in Settings. First is the app default.
    static let accentPresets: [String] = [
        "#FF6633", // default orange
        "#007AFF", // blue
        "#5856D6", // indigo
        "#AF52DE", // purple
        "#FF2D55", // pink
        "#FF3B30", // red
        "#34C759", // green
        "#00C7BE", // teal
        "#FFCC00", // yellow
        "#8E8E93", // gray
    ]

    var snoozeInterval: SnoozeInterval {
        didSet { defaults.set(snoozeInterval.rawValue, forKey: Key.snooze) }
    }

    var alarmsEnabled: Bool {
        didSet { defaults.set(alarmsEnabled, forKey: Key.alarmsEnabled) }
    }

    var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) }
    }

    var teamsDetectionEnabled: Bool {
        didSet { defaults.set(teamsDetectionEnabled, forKey: Key.teamsDetectionEnabled) }
    }

    var appearance: AppearanceMode {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Key.language)
            LocalizationManager.shared.apply(language)
        }
    }

    /// User-chosen accent color as a hex string, or nil to use the app default.
    var accentColorHex: String? {
        didSet {
            if let hex = accentColorHex {
                defaults.set(hex, forKey: Key.accentColorHex)
            } else {
                defaults.removeObject(forKey: Key.accentColorHex)
            }
            Theme.shared.accent = accentColor
        }
    }

    /// Resolved accent color — the custom one if set, otherwise the asset default.
    var accentColor: Color {
        accentColorHex.flatMap(Color.init(hex:)) ?? .accentColor
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedSnooze = defaults.object(forKey: Key.snooze) as? Int
        self.snoozeInterval = storedSnooze.flatMap(SnoozeInterval.init(rawValue:)) ?? .min5
        self.alarmsEnabled = defaults.object(forKey: Key.alarmsEnabled) as? Bool ?? true
        self.onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
        self.teamsDetectionEnabled = defaults.bool(forKey: Key.teamsDetectionEnabled)
        let storedAppearance = defaults.object(forKey: Key.appearance) as? Int
        self.appearance = storedAppearance.flatMap(AppearanceMode.init(rawValue:)) ?? .system
        self.accentColorHex = defaults.string(forKey: Key.accentColorHex)
        let storedLanguage = defaults.string(forKey: Key.language)
        let resolvedLanguage = storedLanguage.flatMap(AppLanguage.init(rawValue:)) ?? .system
        self.language = resolvedLanguage
        // Apply on launch so the very first frame renders in the right language.
        LocalizationManager.shared.apply(resolvedLanguage)
        // Seed the global theme so the first frame uses the saved accent.
        Theme.shared.accent = accentColor
    }
}
