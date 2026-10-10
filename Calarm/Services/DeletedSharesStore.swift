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
//  the deleted invitation reappear.
//
//  Kept in iCloud key-value storage, not on the device: every device scans the
//  shared database on its own, so one that didn't know about the deletion
//  re-imported the invitation and SwiftData synced it back to the device where it
//  was deleted. A reinstall lost the list the same way.
//
//  One key per deleted invitation rather than one list: iCloud resolves a
//  conflict by keeping the last write of a key, so two devices saving a whole list
//  would drop each other's deletions.
//

import Foundation

enum DeletedSharesStore {
    /// Xcode builds talk to the CloudKit Development environment and TestFlight /
    /// App Store builds to Production; each sees different shares, so each keeps
    /// its own tombstones — a Development scan must not prune Production's.
    #if DEBUG
    private static let prefix = "deletedShare.development."
    #else
    private static let prefix = "deletedShare.production."
    #endif

    /// Where the list lived before it synced through iCloud (UserDefaults, one
    /// device only).
    private static let legacyKey = "calarm.deletedReceivedShares"

    private static var cloud: NSUbiquitousKeyValueStore { .default }

    /// Pulls the latest tombstones from iCloud and calls `onChange` whenever
    /// another device changes them — so an invitation deleted there disappears
    /// here too.
    static func startSyncing(onChange: @escaping @MainActor () async -> Void) {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { _ in
            Task { @MainActor in await onChange() }
        }
        cloud.synchronize()
        migrateLegacyList()
    }

    /// Marks a received-share reminder as deleted by the recipient.
    static func add(_ id: UUID) {
        cloud.set(true, forKey: key(for: id))
    }

    /// Whether the recipient previously deleted this received share.
    static func contains(_ id: UUID) -> Bool {
        cloud.bool(forKey: key(for: id))
    }

    /// Clears the tombstone — e.g. the user deliberately re-accepted the invitation,
    /// so it should be allowed back in.
    static func remove(_ id: UUID) {
        cloud.removeObject(forKey: key(for: id))
    }

    /// Drops tombstones whose shared record is no longer present, so a future
    /// re-share with the same id can be imported again. `presentIDs` are the ids
    /// of every shared record found during a SUCCESSFUL scan.
    static func prune(presentIDs: Set<UUID>) {
        let present = Set(presentIDs.map(key(for:)))
        for key in cloud.dictionaryRepresentation.keys where key.hasPrefix(prefix) && !present.contains(key) {
            cloud.removeObject(forKey: key)
        }
    }

    private static func key(for id: UUID) -> String {
        prefix + id.uuidString
    }

    /// Publishes this device's pre-iCloud list once. Only from Production builds:
    /// the old list mixed both environments, and that's the one real users run.
    private static func migrateLegacyList() {
        #if !DEBUG
        let defaults = UserDefaults.standard
        guard let ids = defaults.stringArray(forKey: legacyKey) else { return }
        for id in ids {
            cloud.set(true, forKey: prefix + id)
        }
        defaults.removeObject(forKey: legacyKey)
        #endif
    }
}
