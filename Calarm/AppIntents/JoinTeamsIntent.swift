//
//  JoinTeamsIntent.swift
//  Calarm
//

import AppIntents
import Foundation
import UIKit

/// Opens a Microsoft Teams meeting URL. Used both from the in-app "Join" button and
/// (eventually) the Live Activity.
struct JoinTeamsIntent: AppIntent {
    static var title: LocalizedStringResource = "Unirse a reunión de Teams"
    static var description = IntentDescription("Abre el enlace de la reunión en Microsoft Teams.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Teams URL")
    var teamsURLString: String

    init() {
        self.teamsURLString = ""
    }

    init(teamsURLString: String) {
        self.teamsURLString = teamsURLString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let url = URL(string: teamsURLString) else {
            return .result()
        }
        await UIApplication.shared.open(url)
        return .result()
    }
}
