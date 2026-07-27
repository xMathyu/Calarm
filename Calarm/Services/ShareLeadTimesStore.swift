//
//  ShareLeadTimesStore.swift
//  Calarm
//
//  Keeps the recipient's OWN avisos (lead times) on a received share from being
//  wiped by the background scan.
//
//  A received share's local copy is re-written from the owner's payload on every
//  `SharedRemindersService.importAllSharedReminders()` (launch, foreground, silent
//  push). That is correct for what/when the alarm is — the owner owns that — but
//  it also erased any aviso the recipient added for themselves ("avísame 2 horas
//  antes"), so the edit silently vanished on the next scan.
//
//  Avisos are PERSONAL: they only decide when this device rings, and they are
//  never pushed back to the owner (`pushUpdateIfShared` skips received shares).
//  So they're remembered here, keyed by the local reminder id, and re-applied
//  after each import.
//
//  Stored in UserDefaults — like `ShareOwnerStore` / `DeletedSharesStore` — to
//  avoid adding a SwiftData property, which would mean another CloudKit
//  Production schema deploy.
//

import Foundation

enum ShareLeadTimesStore {
    private static let key = "calarm.shareLeadTimes"

    /// What we remember per received share: the owner's avisos as last seen in
    /// the payload, and the recipient's personal replacement (if they edited).
    private struct Entry: Codable {
        var shared: [Int]?
        var personal: [Int]?

        var isEmpty: Bool { shared == nil && personal == nil }
    }

    // MARK: - Ingest side

    /// Records the avisos the owner's payload carried, so a later edit can tell
    /// whether the recipient actually diverged from it.
    static func recordShared(_ leadTimes: [AlarmLeadTime], for id: UUID) {
        var map = load()
        var entry = map[id.uuidString] ?? Entry()
        let seconds = leadTimes.map(\.rawValue).sorted()
        guard entry.shared != seconds else { return }
        entry.shared = seconds
        map[id.uuidString] = entry
        save(map)
    }

    /// The recipient's personal avisos for this received share, if they set any.
    /// `nil` means "follow the owner's".
    static func personal(for id: UUID) -> [AlarmLeadTime]? {
        guard let seconds = load()[id.uuidString]?.personal else { return nil }
        let leadTimes = seconds.compactMap { AlarmLeadTime(rawValue: $0) }
        return leadTimes.isEmpty ? nil : leadTimes
    }

    // MARK: - Edit side

    /// Remembers the avisos the recipient chose for a received share. Setting them
    /// back to the owner's list clears the override, so the alarm follows the
    /// owner's avisos again.
    static func setPersonal(_ leadTimes: [AlarmLeadTime], for id: UUID) {
        var map = load()
        var entry = map[id.uuidString] ?? Entry()
        let seconds = leadTimes.map(\.rawValue).sorted()
        entry.personal = (entry.shared == seconds) ? nil : seconds
        if entry.isEmpty {
            map.removeValue(forKey: id.uuidString)
        } else {
            map[id.uuidString] = entry
        }
        save(map)
    }

    // MARK: - Cleanup

    /// Drops everything remembered for a reminder — the recipient deleted it.
    static func forget(_ id: UUID) {
        var map = load()
        guard map.removeValue(forKey: id.uuidString) != nil else { return }
        save(map)
    }

    /// Drops entries whose shared record is gone (owner deleted or unshared it),
    /// so a future re-share starts from the owner's avisos. `presentIDs` are the
    /// ids found during a SUCCESSFUL scan.
    static func prune(presentIDs: Set<UUID>) {
        let present = Set(presentIDs.map(\.uuidString))
        let map = load()
        let kept = map.filter { present.contains($0.key) }
        if kept.count != map.count { save(kept) }
    }

    // MARK: - Storage

    private static func load() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    private static func save(_ map: [String: Entry]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(map), forKey: key)
    }
}
