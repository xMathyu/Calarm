//
//  AlarmStore.swift
//  Calarm
//

import Foundation

/// Tracks AlarmKit alarm IDs scheduled for each (ownerID, fireDate) pair.
/// `ownerID` is reminder UUID string for manual reminders, or event identifier for Teams meetings.
/// One owner can have multiple alarms (one per recurrence occurrence).
final class AlarmStore {
    private struct Entry: Codable {
        let alarmID: UUID
        let fireDate: Date
    }

    private let defaults: UserDefaults
    private let key = "alarmStore.entries.v2"
    /// ownerID → list of entries.
    private var cache: [String: [Entry]]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: [Entry]].self, from: data) {
            self.cache = decoded
        } else {
            self.cache = [:]
        }
    }

    func alarmID(forOwner ownerID: String, fireDate: Date) -> UUID? {
        cache[ownerID]?.first(where: { abs($0.fireDate.timeIntervalSince(fireDate)) < 1 })?.alarmID
    }

    func allEntries(forOwner ownerID: String) -> [(alarmID: UUID, fireDate: Date)] {
        (cache[ownerID] ?? []).map { ($0.alarmID, $0.fireDate) }
    }

    func store(alarmID: UUID, forOwner ownerID: String, fireDate: Date) {
        var list = cache[ownerID] ?? []
        list.removeAll { abs($0.fireDate.timeIntervalSince(fireDate)) < 1 }
        list.append(Entry(alarmID: alarmID, fireDate: fireDate))
        cache[ownerID] = list
        persist()
    }

    func remove(ownerID: String, fireDate: Date) {
        guard var list = cache[ownerID] else { return }
        list.removeAll { abs($0.fireDate.timeIntervalSince(fireDate)) < 1 }
        if list.isEmpty {
            cache.removeValue(forKey: ownerID)
        } else {
            cache[ownerID] = list
        }
        persist()
    }

    func removeAll(forOwner ownerID: String) {
        cache.removeValue(forKey: ownerID)
        persist()
    }

    /// Returns all (ownerID, alarmID, fireDate) tuples.
    func allEntries() -> [(ownerID: String, alarmID: UUID, fireDate: Date)] {
        cache.flatMap { owner, list in
            list.map { (owner, $0.alarmID, $0.fireDate) }
        }
    }

    func clearAll() {
        cache.removeAll()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: key)
    }
}
