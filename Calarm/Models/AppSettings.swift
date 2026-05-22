//
//  AppSettings.swift
//  Calarm
//

import Foundation
import Observation

@Observable
final class AppSettings {
    private let defaults: UserDefaults

    private enum Key {
        static let snooze = "settings.snooze"
        static let alarmsEnabled = "settings.alarmsEnabled"
        static let onboardingCompleted = "settings.onboardingCompleted"
        static let teamsDetectionEnabled = "settings.teamsDetectionEnabled"
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedSnooze = defaults.object(forKey: Key.snooze) as? Int
        self.snoozeInterval = storedSnooze.flatMap(SnoozeInterval.init(rawValue:)) ?? .min5
        self.alarmsEnabled = defaults.object(forKey: Key.alarmsEnabled) as? Bool ?? true
        self.onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
        self.teamsDetectionEnabled = defaults.bool(forKey: Key.teamsDetectionEnabled)
    }
}
