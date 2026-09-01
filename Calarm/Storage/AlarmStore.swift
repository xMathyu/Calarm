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
        /// Huella de lo que se ve y se oye de la alarma (título, icono, tono…).
        /// Detecta la alarma ya programada que quedó desactualizada: la fecha no
        /// cambió, pero el contenido sí. Opcional porque las entradas guardadas
        /// por builds anteriores no la traen — esas se reprograman una vez, en el
        /// primer sync después de actualizar.
        let contentHash: String?
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

    /// La alarma ya programada para ese instante y su huella de contenido.
    /// `contentHash` es `nil` en entradas escritas por builds anteriores.
    func entry(forOwner ownerID: String, fireDate: Date) -> (alarmID: UUID, contentHash: String?)? {
        guard let entry = cache[ownerID]?.first(where: { abs($0.fireDate.timeIntervalSince(fireDate)) < 1 })
        else { return nil }
        return (entry.alarmID, entry.contentHash)
    }

    func allEntries(forOwner ownerID: String) -> [(alarmID: UUID, fireDate: Date)] {
        (cache[ownerID] ?? []).map { ($0.alarmID, $0.fireDate) }
    }

    func store(alarmID: UUID, forOwner ownerID: String, fireDate: Date, contentHash: String) {
        var list = cache[ownerID] ?? []
        list.removeAll { abs($0.fireDate.timeIntervalSince(fireDate)) < 1 }
        list.append(Entry(alarmID: alarmID, fireDate: fireDate, contentHash: contentHash))
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
