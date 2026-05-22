//
//  MeetingPreferencesStore.swift
//  Calarm
//

import Foundation
import Observation

struct MeetingPrefs: Codable, Equatable {
    /// Raw values from `AlarmLeadTime.seconds`.
    var leadTimes: [Int]
    var enabled: Bool

    init(leadTimes: [Int], enabled: Bool) {
        self.leadTimes = leadTimes
        self.enabled = enabled
    }
}

/// Per-event user preferences for calendar events.
/// Default when an event has no entry: enabled with `[.atStart]`.
@Observable
@MainActor
final class MeetingPreferencesStore {
    static let maxAlarmsPerEvent = 3
    static let defaultLeadTimes: [AlarmLeadTime] = [.atStart]

    private let defaults: UserDefaults
    private let keyV1 = "meetingPreferences.v1"
    private let keyV2 = "meetingPreferences.v2"
    private var cache: [String: MeetingPrefs]
    /// Bumped on changes so consumers can react via @Observable.
    private(set) var revision: Int = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.cache = Self.loadInitial(defaults: defaults, keyV1: keyV1, keyV2: keyV2)
    }

    private static func loadInitial(defaults: UserDefaults, keyV1: String, keyV2: String) -> [String: MeetingPrefs] {
        if let data = defaults.data(forKey: keyV2),
           let decoded = try? JSONDecoder().decode([String: MeetingPrefs].self, from: data) {
            return decoded
        }
        // Migrate from v1: [eventID: [Int]] → [eventID: MeetingPrefs(leadTimes:, enabled: true)]
        if let data = defaults.data(forKey: keyV1),
           let legacy = try? JSONDecoder().decode([String: [Int]].self, from: data) {
            let migrated = legacy.mapValues { MeetingPrefs(leadTimes: $0, enabled: true) }
            if let encoded = try? JSONEncoder().encode(migrated) {
                defaults.set(encoded, forKey: keyV2)
                defaults.removeObject(forKey: keyV1)
            }
            return migrated
        }
        return [:]
    }

    func leadTimes(forEventID eventID: String) -> [AlarmLeadTime] {
        if let entry = cache[eventID] {
            return entry.leadTimes.compactMap { AlarmLeadTime(rawValue: $0) }
        }
        return Self.defaultLeadTimes
    }

    func isEnabled(forEventID eventID: String) -> Bool {
        cache[eventID]?.enabled ?? true
    }

    func hasOverride(forEventID eventID: String) -> Bool {
        cache[eventID] != nil
    }

    /// Returns the lead times that should actually fire (respects the enabled flag).
    func activeLeadTimes(forEventID eventID: String) -> [AlarmLeadTime] {
        guard isEnabled(forEventID: eventID) else { return [] }
        return leadTimes(forEventID: eventID)
    }

    func setLeadTimes(_ leadTimes: [AlarmLeadTime], enabled: Bool, forEventID eventID: String) {
        let unique = Array(Set(leadTimes))
            .sorted(by: { $0.rawValue < $1.rawValue })
            .prefix(Self.maxAlarmsPerEvent)
        cache[eventID] = MeetingPrefs(
            leadTimes: Array(unique).map(\.rawValue),
            enabled: enabled
        )
        persist()
    }

    func resetToDefault(forEventID eventID: String) {
        cache.removeValue(forKey: eventID)
        persist()
    }

    func reconcile(keepingEventIDs ids: Set<String>) {
        let removed = cache.keys.filter { !ids.contains($0) }
        guard !removed.isEmpty else { return }
        for key in removed { cache.removeValue(forKey: key) }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: keyV2)
        }
        revision &+= 1
    }
}
