//
//  ReviewPrompt.swift
//  Calarm
//
//  Decides when to ask for an App Store rating.
//
//  The rule: only ask once Calarm has actually done its job — the user keeps a
//  few alarms and has already stopped a couple that rang — and never more than
//  once per version. Asking at launch, or after a single alarm, is what turns a
//  five-star moment into a one-star review.
//

import Foundation

enum ReviewPrompt {
    private enum Key {
        /// Written from `StopAlarmIntent`, which is also compiled into the
        /// widgets target and therefore cannot reach this app-only type — the
        /// literal there must stay in sync with this key.
        static let alarmsStopped = "review.alarmsStopped"
        static let promptedVersion = "review.promptedVersion"
    }

    private static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
    }

    /// How many ringing alarms the user has stopped, from the system alert, the
    /// Live Activity or the app.
    static var alarmsStopped: Int {
        UserDefaults.standard.integer(forKey: Key.alarmsStopped)
    }

    /// True when Calarm has earned the question and this version hasn't asked yet.
    /// `alarmCount` is how many alarms the user currently keeps.
    static func shouldAsk(alarmCount: Int) -> Bool {
        guard alarmsStopped >= 2, alarmCount >= 3 else { return false }
        return UserDefaults.standard.string(forKey: Key.promptedVersion) != currentVersion
    }

    /// Records that this version already asked. Call it right before asking:
    /// the system decides whether the sheet actually appears, and a version that
    /// asked and got silently throttled should not ask again.
    static func markAsked() {
        UserDefaults.standard.set(currentVersion, forKey: Key.promptedVersion)
    }
}
