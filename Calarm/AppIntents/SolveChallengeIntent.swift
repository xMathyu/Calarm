//
//  SolveChallengeIntent.swift
//  Calarm
//

import AppIntents
import Foundation

extension Notification.Name {
    /// La persona quiere resolver el reto de una alarma; `object` es el UUID de
    /// la alarma de AlarmKit.
    static let calarmSolveChallenge = Notification.Name("CalarmSolveChallenge")
}

/// Punto de entrada único para «quiero resolver el reto de esta alarma», venga
/// del botón de la alerta del sistema (este intent), del botón de la Live
/// Activity (un enlace `calarm://challenge/<id>`) o de abrir la app a mano.
///
/// Guarda el id por si la app arranca en frío por el intent y la ventana aún
/// no está suscrita a la notificación (mismo patrón que `PendingShare`).
enum ChallengeRequest {
    nonisolated(unsafe) private(set) static var alarmID: UUID?

    static func post(_ id: UUID) {
        alarmID = id
        NotificationCenter.default.post(name: .calarmSolveChallenge, object: id)
    }

    static func clear() { alarmID = nil }

    /// `calarm://challenge/<uuid>`, el enlace que usa la Live Activity.
    static func alarmID(from url: URL) -> UUID? {
        guard url.scheme == "calarm", url.host == "challenge" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
}

/// Botón «Resolver reto» de la alerta de AlarmKit (`secondaryIntent` con
/// comportamiento `.custom`). NO detiene la alarma: abre la app con la pantalla
/// del reto, y es resolverlo lo que la detiene (`ChallengeCoordinator.solve`).
struct SolveChallengeIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Resolver reto"
    static var description = IntentDescription("Abre Calarm para resolver el reto que apaga la alarma.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Alarm ID")
    var alarmID: String

    init() {
        self.alarmID = ""
    }

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: alarmID) {
            ChallengeRequest.post(id)
        }
        return .result()
    }
}
