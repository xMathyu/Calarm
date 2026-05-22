//
//  NavigateToEventIntent.swift
//  Calarm
//

import AlarmKit
import AppIntents
import Foundation
import UIKit

/// Invoked from the alarm UI's secondary button when an event has a location.
/// Stops the alarm and opens Apple Maps with driving directions to the location.
struct NavigateToEventIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Ir al evento"
    static var description = IntentDescription("Detiene la alarma y abre el mapa con direcciones al lugar del evento.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Alarm ID")
    var alarmID: String

    @Parameter(title: "Location")
    var locationQuery: String

    init() {
        self.alarmID = ""
        self.locationQuery = ""
    }

    init(alarmID: String, locationQuery: String) {
        self.alarmID = alarmID
        self.locationQuery = locationQuery
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: alarmID) {
            try? AlarmManager.shared.stop(id: id)
        }
        guard
            let encoded = locationQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
            let url = URL(string: "http://maps.apple.com/?q=\(encoded)&dirflg=d")
        else {
            return .result()
        }
        await UIApplication.shared.open(url)
        return .result()
    }
}
