//
//  SnoozeInterval.swift
//  Calarm
//

import Foundation

/// How long to wait before re-alerting when the user taps the snooze button.
enum SnoozeInterval: Int, CaseIterable, Identifiable, Codable, Sendable {
    case min1 = 60
    case min5 = 300
    case min9 = 540

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }

    var localizedTitle: String {
        switch self {
        case .min1: appLocalized("1 minuto")
        case .min5: appLocalized("5 minutos")
        case .min9: appLocalized("9 minutos")
        }
    }
}
