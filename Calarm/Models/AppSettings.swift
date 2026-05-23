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
        case .system: "Automático"
        case .light: "Claro"
        case .dark: "Oscuro"
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

@Observable
final class AppSettings {
    private let defaults: UserDefaults

    private enum Key {
        static let snooze = "settings.snooze"
        static let alarmsEnabled = "settings.alarmsEnabled"
        static let onboardingCompleted = "settings.onboardingCompleted"
        static let teamsDetectionEnabled = "settings.teamsDetectionEnabled"
        static let appearance = "settings.appearance"
    }

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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedSnooze = defaults.object(forKey: Key.snooze) as? Int
        self.snoozeInterval = storedSnooze.flatMap(SnoozeInterval.init(rawValue:)) ?? .min5
        self.alarmsEnabled = defaults.object(forKey: Key.alarmsEnabled) as? Bool ?? true
        self.onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
        self.teamsDetectionEnabled = defaults.bool(forKey: Key.teamsDetectionEnabled)
        let storedAppearance = defaults.object(forKey: Key.appearance) as? Int
        self.appearance = storedAppearance.flatMap(AppearanceMode.init(rawValue:)) ?? .system
    }
}
