//
//  WakeChallengeStore.swift
//  Calarm
//
//  Estado de la insistencia de los retos, por alarma. En UserDefaults, como
//  `ShareLeadTimesStore`: es estado de ESTE dispositivo (qué sonó aquí y si se
//  resolvió), no un dato de la alarma, así que no toca SwiftData ni CloudKit.
//

import Foundation

enum WakeChallengeStore {
    private static let key = "calarm.wakeChallenge.state"

    private struct Entry: Codable {
        /// Cuándo se resolvió el reto por última vez. Una ocurrencia anterior a
        /// esa hora ya no recibe refuerzos.
        var solvedAt: Date?
        /// Hora a la que vuelve a sonar tras posponer desde la pantalla del reto:
        /// los refuerzos se recalculan sobre ella, no sobre la hora original.
        var anchorOverride: Date?
        /// Cuándo empezó a insistir (primer «Detener» sin resolver), para que la
        /// cadena de «vuelve a sonar al minuto» tenga un tope.
        var insistingSince: Date?

        var isEmpty: Bool { solvedAt == nil && anchorOverride == nil && insistingSince == nil }
    }

    static func solvedAt(for id: UUID) -> Date? {
        load()[id.uuidString]?.solvedAt
    }

    /// Reto resuelto: la ocurrencia queda cerrada y se olvida cualquier
    /// posposición o insistencia en curso.
    static func markSolved(_ id: UUID, at date: Date = Date()) {
        var map = load()
        map[id.uuidString] = Entry(solvedAt: date, anchorOverride: nil, insistingSince: nil)
        save(map)
    }

    static func anchorOverride(for id: UUID) -> Date? {
        load()[id.uuidString]?.anchorOverride
    }

    static func setAnchorOverride(_ date: Date?, for id: UUID) {
        update(id) { $0.anchorOverride = date }
    }

    static func insistingSince(for id: UUID) -> Date? {
        load()[id.uuidString]?.insistingSince
    }

    static func setInsistingSince(_ date: Date?, for id: UUID) {
        update(id) { $0.insistingSince = date }
    }

    /// Al borrar la alarma.
    static func forget(_ id: UUID) {
        var map = load()
        guard map.removeValue(forKey: id.uuidString) != nil else { return }
        save(map)
    }

    // MARK: - Private

    private static func update(_ id: UUID, _ change: (inout Entry) -> Void) {
        var map = load()
        var entry = map[id.uuidString] ?? Entry()
        change(&entry)
        if entry.isEmpty {
            map.removeValue(forKey: id.uuidString)
        } else {
            map[id.uuidString] = entry
        }
        save(map)
    }

    private static func load() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    private static func save(_ map: [String: Entry]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(map), forKey: key)
    }
}
