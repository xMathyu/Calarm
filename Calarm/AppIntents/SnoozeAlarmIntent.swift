//
//  SnoozeAlarmIntent.swift
//  Calarm
//

import AlarmKit
import AppIntents
import Foundation

/// Invoked by AlarmKit when the user taps the Snooze (secondary) button on an alerting alarm.
/// AlarmKit handles the actual countdown re-fire when `secondaryButtonBehavior == .countdown`;
/// this intent runs alongside so the app can react if needed.
struct SnoozeAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Posponer alarma"
    static var description = IntentDescription("Pospone la alarma según el intervalo configurado.")

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
            try? await AlarmManager.shared.countdown(id: id)
        }
        return .result()
    }
}
