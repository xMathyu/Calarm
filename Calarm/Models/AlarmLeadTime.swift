//
//  AlarmLeadTime.swift
//  Calarm
//

import Foundation

/// How far ahead of the reminder time an alarm should fire.
/// Raw values are seconds — kept monotonically ascending so the
/// "closest match" snapping logic in `AlarmSuggestionsService` behaves
/// predictably.
enum AlarmLeadTime: Int, CaseIterable, Identifiable, Codable, Sendable {
    case atStart = 0
    case min5 = 300
    case min10 = 600
    case min15 = 900
    case min30 = 1800
    case min45 = 2700
    case hour1 = 3600
    case hour2 = 7200
    case hour3 = 10800
    case hour6 = 21600
    case hour12 = 43200
    case day1 = 86400
    case day2 = 172800
    case week1 = 604800

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }

    var localizedTitle: String {
        switch self {
        case .atStart: appLocalized("Al momento")
        case .min5: appLocalized("5 minutos antes")
        case .min10: appLocalized("10 minutos antes")
        case .min15: appLocalized("15 minutos antes")
        case .min30: appLocalized("30 minutos antes")
        case .min45: appLocalized("45 minutos antes")
        case .hour1: appLocalized("1 hora antes")
        case .hour2: appLocalized("2 horas antes")
        case .hour3: appLocalized("3 horas antes")
        case .hour6: appLocalized("6 horas antes")
        case .hour12: appLocalized("12 horas antes")
        case .day1: appLocalized("1 día antes")
        case .day2: appLocalized("2 días antes")
        case .week1: appLocalized("1 semana antes")
        }
    }

    var shortTitle: String {
        switch self {
        case .atStart: appLocalized("Al inicio")
        case .min5: appLocalized("5 min")
        case .min10: appLocalized("10 min")
        case .min15: appLocalized("15 min")
        case .min30: appLocalized("30 min")
        case .min45: appLocalized("45 min")
        case .hour1: appLocalized("1 h")
        case .hour2: appLocalized("2 h")
        case .hour3: appLocalized("3 h")
        case .hour6: appLocalized("6 h")
        case .hour12: appLocalized("12 h")
        case .day1: appLocalized("1 día")
        case .day2: appLocalized("2 días")
        case .week1: appLocalized("1 sem")
        }
    }
}
