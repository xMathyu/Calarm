//
//  NewAlarmControlIntent.swift
//  Calarm
//
//  El botón «Nueva alarma» del Centro de control (y de la pantalla bloqueada o
//  el botón de Acción). COMPARTIDO con CalarmWidgets: el control vive en la
//  extensión, pero como abre la app, el sistema ejecuta el intent en el
//  proceso de la app, y por eso tiene que compilar en los dos.
//

import AppIntents
import Foundation

extension Notification.Name {
    /// Abrir el editor de una alarma nueva.
    nonisolated static let calarmNewAlarm = Notification.Name("CalarmNewAlarm")
}

/// Guarda la petición por si la app arranca en frío y la lista aún no está
/// escuchando (mismo patrón que `ChallengeRequest`).
nonisolated enum NewAlarmRequest {
    nonisolated(unsafe) private static var pending = false

    static func post() {
        pending = true
        NotificationCenter.default.post(name: .calarmNewAlarm, object: nil)
    }

    /// `true` una sola vez por petición.
    static func consume() -> Bool {
        defer { pending = false }
        return pending
    }
}

struct NewAlarmControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Nueva alarma"
    static let description = IntentDescription("Abre Calarm con una alarma nueva lista para llenar.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NewAlarmRequest.post()
        return .result()
    }
}
