//
//  AlarmCountdown.swift
//  Calarm
//

import Foundation

/// Cuánto dura la cuenta regresiva que se ve en la Isla Dinámica y en la
/// pantalla bloqueada ANTES de que la alarma suene.
///
/// En AlarmKit es el `preAlert` de `Alarm.CountdownDuration`, y medido en un
/// iPhone 17 (iOS 26, 2026-09-21) funciona así: la alarma entra en cuenta
/// regresiva en la fecha programada y la alerta llega `preAlert` después. Por
/// eso `AlarmScheduler` programa la alarma esta duración ANTES de la hora real,
/// para que la cuenta termine justo cuando toca sonar.
enum AlarmCountdown: Int, CaseIterable, Identifiable, Codable, Sendable {
    case off = 0
    case min1 = 60
    case min2 = 120
    case min5 = 300
    case min10 = 600
    case min15 = 900

    static let `default`: AlarmCountdown = .off

    var id: Int { rawValue }

    /// `nil` cuando no hay cuenta regresiva, que es lo que espera AlarmKit.
    var seconds: TimeInterval? {
        self == .off ? nil : TimeInterval(rawValue)
    }

    var localizedTitle: String {
        switch self {
        case .off: appLocalized("Sin cuenta regresiva")
        case .min1: appLocalized("1 minuto antes")
        case .min2: appLocalized("2 minutos antes")
        case .min5: appLocalized("5 minutos antes")
        case .min10: appLocalized("10 minutos antes")
        case .min15: appLocalized("15 minutos antes")
        }
    }
}
