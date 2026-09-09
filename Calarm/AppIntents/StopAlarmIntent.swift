//
//  StopAlarmIntent.swift
//  Calarm
//

import AlarmKit
import AppIntents
import Foundation

/// Invoked when the user taps Detener — either on the system alert (AlarmKit's
/// `stopIntent`) or on the Live Activity's stop button during a snooze countdown.
/// SHARED source file: compiled into both the app and CalarmWidgets targets so the
/// widget can construct it; as a `LiveActivityIntent` it always PERFORMS in the
/// app's process, where AlarmKit authorization lives.
struct StopAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Detener alarma"
    static var description = IntentDescription("Detiene la alarma de la reunión.")

    @Parameter(title: "Alarm ID")
    var alarmID: String

    init() {
        self.alarmID = ""
    }

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: alarmID) {
            try? await AlarmManager.shared.stop(id: id)
            recordStopForReviewPrompt()
        }
        return .result()
    }

    /// Counts the alarms Calarm has seen through: the rating prompt only appears
    /// after a couple of them (see `ReviewPrompt`, app target). Written with a
    /// literal key because this file also compiles into CalarmWidgets, where
    /// `ReviewPrompt` doesn't exist.
    private func recordStopForReviewPrompt() {
        let key = "review.alarmsStopped"
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
    }
}
