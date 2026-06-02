//
//  AlarmIntentEnums.swift
//  Calarm
//
//  App Intents wrappers so Siri / Shortcuts users can set how far ahead an alarm
//  warns them ("avísame 10 minutos antes") and how it repeats ("que se repita
//  cada día") when creating an alarm by voice.
//

import AppIntents
import Foundation

/// Voice-pickable lead time, mirroring `AlarmLeadTime`.
enum AlarmLeadTimeAppEnum: String, AppEnum {
    case atStart, min5, min10, min15, min30, min45
    case hour1, hour2, hour3, hour6, hour12
    case day1, day2, week1

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Aviso"

    static let caseDisplayRepresentations: [AlarmLeadTimeAppEnum: DisplayRepresentation] = [
        .atStart: "Al momento",
        .min5: "5 minutos antes",
        .min10: "10 minutos antes",
        .min15: "15 minutos antes",
        .min30: "30 minutos antes",
        .min45: "45 minutos antes",
        .hour1: "1 hora antes",
        .hour2: "2 horas antes",
        .hour3: "3 horas antes",
        .hour6: "6 horas antes",
        .hour12: "12 horas antes",
        .day1: "1 día antes",
        .day2: "2 días antes",
        .week1: "1 semana antes",
    ]

    var leadTime: AlarmLeadTime {
        switch self {
        case .atStart: .atStart
        case .min5: .min5
        case .min10: .min10
        case .min15: .min15
        case .min30: .min30
        case .min45: .min45
        case .hour1: .hour1
        case .hour2: .hour2
        case .hour3: .hour3
        case .hour6: .hour6
        case .hour12: .hour12
        case .day1: .day1
        case .day2: .day2
        case .week1: .week1
        }
    }
}

/// Voice-pickable repetition, mapping to `RecurrenceRule` with sensible defaults.
enum RecurrenceAppEnum: String, AppEnum {
    case once, daily, weekly, monthly, yearly

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Repetición"

    static let caseDisplayRepresentations: [RecurrenceAppEnum: DisplayRepresentation] = [
        .once: "Una vez",
        .daily: "Cada día",
        .weekly: "Cada semana",
        .monthly: "Cada mes",
        .yearly: "Cada año",
    ]

    /// Builds the rule; weekly anchors to the alarm date's weekday.
    func rule(basedOn date: Date) -> RecurrenceRule {
        switch self {
        case .once: return .once
        case .daily: return .daily(interval: 1)
        case .weekly:
            let weekday = Weekday(rawValue: Calendar.current.component(.weekday, from: date))
            return .weekly(interval: 1, weekdays: weekday.map { [$0] } ?? [])
        case .monthly: return .monthly(interval: 1)
        case .yearly: return .yearly(interval: 1)
        }
    }
}
