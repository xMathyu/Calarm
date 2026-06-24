//
//  DeletedSharesStore.swift
//  Calarm
//
//  Remembers received-share reminders ("invitations") the recipient deleted, so
//  the background scan (`SharedRemindersService.importAllSharedReminders`) doesn't
//  re-create them on the next launch while the owner's shared record still exists.
//
//  Without this, deleting a shared reminder only removed the local SwiftData copy;
//  the next scan found the owner's record still present and re-imported it, making
//  the deleted invitation reappear. Stored locally (UserDefaults) — it's a local
//  preference, not part of the SwiftData/CloudKit schema.
//

import Foundation

enum DeletedSharesStore {
    private static let key = "calarm.deletedReceivedShares"

    /// Marks a received-share reminder as deleted by the recipient.
    static func add(_ id: UUID) {
        var ids = load()
        ids.insert(id.uuidString)
        save(ids)
    }

    /// Whether the recipient previously deleted this received share.
    static func contains(_ id: UUID) -> Bool {
        load().contains(id.uuidString)
    }

    /// Clears the tombstone — e.g. the user deliberately re-accepted the invitation,
    /// so it should be allowed back in.
    static func remove(_ id: UUID) {
        var ids = load()
        guard ids.remove(id.uuidString) != nil else { return }
        save(ids)
    }

    /// Drops tombstones whose shared record is no longer present, so a future
    /// re-share with the same id can be imported again. `presentIDs` are the ids
    /// of every shared record found during a SUCCESSFUL scan.
    static func prune(presentIDs: Set<UUID>) {
        let present = Set(presentIDs.map(\.uuidString))
        let ids = load()
        let kept = ids.intersection(present)
        if kept.count != ids.count { save(kept) }
    }

    private static func load() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    private static func save(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids), forKey: key)
    }
}
