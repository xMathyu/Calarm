//
//  RecurrenceRule.swift
//  Calarm
//

import Foundation

enum Weekday: Int, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7

    var id: Int { rawValue }

    var localizedShort: String {
        switch self {
        case .sunday: "Dom"
        case .monday: "Lun"
        case .tuesday: "Mar"
        case .wednesday: "Mié"
        case .thursday: "Jue"
        case .friday: "Vie"
        case .saturday: "Sáb"
        }
    }
}

enum RecurrenceRule: Codable, Hashable, Sendable {
    case once
    case daily(interval: Int)
    case weekly(interval: Int, weekdays: Set<Weekday>)
    case monthly(interval: Int)
    case yearly(interval: Int)

    var isRecurring: Bool {
        switch self {
        case .once: false
        default: true
        }
    }

    var localizedSummary: String {
        switch self {
        case .once:
            return "Una vez"
        case .daily(let n):
            return n == 1 ? "Cada día" : "Cada \(n) días"
        case .weekly(let n, let days):
            let base = n == 1 ? "Cada semana" : "Cada \(n) semanas"
            guard !days.isEmpty else { return base }
            let sorted = days.sorted { $0.rawValue < $1.rawValue }
            return "\(base) (\(sorted.map(\.localizedShort).joined(separator: ", ")))"
        case .monthly(let n):
            return n == 1 ? "Cada mes" : "Cada \(n) meses"
        case .yearly(let n):
            return n == 1 ? "Cada año" : "Cada \(n) años"
        }
    }
}
