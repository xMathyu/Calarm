//
//  AlarmLeadTime.swift
//  Calarm
//

import Foundation

/// How far ahead of the reminder time an alarm should fire.
enum AlarmLeadTime: Int, CaseIterable, Identifiable, Codable, Sendable {
    case atStart = 0
    case min5 = 300
    case min10 = 600
    case min15 = 900
    case min30 = 1800
    case hour1 = 3600
    case hour2 = 7200
    case day1 = 86400

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }

    var localizedTitle: String {
        switch self {
        case .atStart: "Al momento"
        case .min5: "5 minutos antes"
        case .min10: "10 minutos antes"
        case .min15: "15 minutos antes"
        case .min30: "30 minutos antes"
        case .hour1: "1 hora antes"
        case .hour2: "2 horas antes"
        case .day1: "1 día antes"
        }
    }

    var shortTitle: String {
        switch self {
        case .atStart: "0 min"
        case .min5: "5 min"
        case .min10: "10 min"
        case .min15: "15 min"
        case .min30: "30 min"
        case .hour1: "1 h"
        case .hour2: "2 h"
        case .day1: "1 día"
        }
    }
}
