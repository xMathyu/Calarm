//
//  StopAlarmIntent.swift
//  Calarm
//

import AlarmKit
import AppIntents
import Foundation

/// Invoked by AlarmKit when the user taps the Stop button on an alerting alarm.
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
        }
        return .result()
    }
}
