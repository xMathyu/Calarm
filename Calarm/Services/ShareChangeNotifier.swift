//
//  ShareChangeNotifier.swift
//  Calarm
//
//  Tells the recipient of a shared alarm when the owner moves it to another day
//  or time, or deletes it.
//
//  The owner's edit already reached this device (silent CloudKit push, or the
//  launch/foreground scan) and the alarm was quietly rescheduled or removed — but
//  nothing told the person, so they kept counting on the old time. Each received
//  payload's schedule is now compared with the one seen last time, and a change
//  posts a local notification; so does a deletion the scan reconciles.
//
//  The comparison is against the OWNER's last payload, not the local reminder:
//  the scan rewrites the local copy from the payload every time, so diffing it
//  would also fire whenever it undid an edit the recipient made themselves.
//  Stored in UserDefaults — like `ShareLeadTimesStore` / `ShareOwnerStore` — to
//  avoid a SwiftData property and another CloudKit Production schema deploy.
//

import Foundation
import UIKit
import UserNotifications

enum ShareChangeNotifier {
    private static let key = "calarm.shareSchedules"

    /// What decides when a shared alarm rings, as the owner's payload last had it.
    private struct Entry: Codable {
        var schedules: [Schedule]
        /// The payload's `updatedAt`, so a scan that finishes after a newer one
        /// can't report the old time as a change. Nil for owners on v1 builds.
        var updatedAt: Date?

        struct Schedule: Codable {
            var date: Date
            var recurrence: RecurrenceRule

            /// Same rule and time. A sub-second gap is a JSON round trip, not an edit.
            func matches(_ other: Schedule) -> Bool {
                recurrence == other.recurrence && abs(date.timeIntervalSince(other.date)) < 1
            }
        }

        init(_ payload: SharePayload) {
            let primary = Schedule(date: payload.date, recurrence: Self.rule(payload.recurrenceData))
            let extras = (payload.additionalSchedules ?? []).map {
                Schedule(date: $0.date, recurrence: Self.rule($0.recurrenceData))
            }
            // Order-insensitive: only the set of schedules matters.
            schedules = [primary] + extras.sorted { $0.date < $1.date }
            updatedAt = payload.updatedAt
        }

        func hasSameSchedules(as other: Entry) -> Bool {
            schedules.count == other.schedules.count
                && zip(schedules, other.schedules).allSatisfy { $0.matches($1) }
        }

        /// Same fallback as `Reminder.recurrence`, so an undecodable rule compares
        /// the way the alarm actually behaves.
        private static func rule(_ data: Data) -> RecurrenceRule {
            (try? JSONDecoder().decode(RecurrenceRule.self, from: data)) ?? .once
        }
    }

    // MARK: - Ingest side

    /// Remembers the schedule `payload` carries for the received share `id` and
    /// says whether the owner changed it since this device last saw it. The first
    /// sighting (a new invitation, or the first scan after updating the app)
    /// only records it.
    static func recordSchedule(of payload: SharePayload, for id: UUID) -> Bool {
        var map = load()
        let incoming = Entry(payload)
        guard let previous = map[id.uuidString] else {
            map[id.uuidString] = incoming
            save(map)
            return false
        }
        // Older than what's already recorded: two scans finished out of order.
        if let new = incoming.updatedAt, let old = previous.updatedAt, new < old {
            return false
        }
        let changed = !incoming.hasSameSchedules(as: previous)
        if changed || incoming.updatedAt != previous.updatedAt {
            map[id.uuidString] = incoming
            save(map)
        }
        return changed
    }

    /// What a notice needs from a received alarm, copied out so it outlives the
    /// reminder — a deleted one is gone by the time its notice is posted.
    struct Alarm {
        var id: UUID
        var title: String
        var emoji: String?

        init(_ reminder: Reminder) {
            id = reminder.id
            title = reminder.title
            emoji = reminder.iconKind == .emoji ? reminder.symbolName : nil
        }
    }

    /// Posts "<owner> changed the schedule" for a received share whose schedule
    /// just changed. `reminder` must already carry the new schedule. Awaited, so a
    /// background wake doesn't end before the notification is handed to iOS.
    static func notifyScheduleChanged(_ reminder: Reminder) async {
        let owner = ownerName(of: reminder.id)
        let body: String
        if let next = nextRing(of: reminder) {
            let when = next.formatted(
                .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()
                    .locale(LocalizationManager.shared.currentLocale)
            )
            // No closing period: Spanish times already end in one ("9:00 a. m.").
            body = appLocalized("\(owner) cambió el horario. Sonará el \(when)")
        } else {
            body = appLocalized("\(owner) cambió el horario y ya no volverá a sonar.")
        }
        await post(body, about: Alarm(reminder), log: "cambio")
    }

    /// Posts "<owner> deleted it" for a received share the owner removed.
    static func notifyDeleted(_ alarm: Alarm) async {
        let owner = ownerName(of: alarm.id)
        await post(appLocalized("\(owner) la borró, así que ya no sonará."), about: alarm, log: "borrado")
    }

    /// Whether the alarm was still going to ring. Deleting one that wasn't (an
    /// expired one-off the owner cleaned up, or one switched off) changes nothing
    /// for the person, so it isn't worth a notification.
    static func isUpcoming(_ reminder: Reminder) -> Bool {
        reminder.isEnabled && nextRing(of: reminder) != nil
    }

    private static func nextRing(of reminder: Reminder) -> Date? {
        reminder.allSchedules
            .compactMap { RecurrenceEngine.nextOccurrences(rule: $0.recurrence, baseDate: $0.date, count: 1).first }
            .min()
    }

    private static func ownerName(of id: UUID) -> String {
        ShareOwnerStore.get(id)?.name ?? appLocalized("Alguien")
    }

    private static func post(_ body: String, about alarm: Alarm, log kind: String) async {
        let content = UNMutableNotificationContent()
        let title = alarm.title.isEmpty ? appLocalized("Alarma") : alarm.title
        if let emoji = alarm.emoji, !emoji.isEmpty {
            content.title = "\(emoji) \(title)"
        } else {
            content.title = title
        }
        content.body = body
        content.sound = .default
        content.threadIdentifier = "calarm.share-changes"
        content.userInfo = ["reminderID": alarm.id.uuidString]

        // One identifier per alarm: a newer notice replaces the previous one (a
        // second change, or the deletion) instead of stacking a stale time.
        let request = UNNotificationRequest(
            identifier: "calarm.share-change.\(alarm.id.uuidString)",
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            ShareDiagnostics.log("🔔 aviso de \(kind) enviado '\(alarm.title)'")
        } catch {
            ShareDiagnostics.log("❌ aviso de \(kind) '\(alarm.title)': \(error.localizedDescription)")
        }
    }

    /// Asks for notification permission the first time it matters — once the
    /// person has an alarm someone shared with them. Only while the app is on
    /// screen: a background wake can't show the prompt.
    static func requestAuthorizationIfNeeded() async {
        guard UIApplication.shared.applicationState == .active else { return }
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        ShareDiagnostics.log("🔔 permiso de notificaciones: \(granted ? "concedido" : "denegado")")
    }

    // MARK: - Cleanup

    /// Drops entries whose shared record is gone (owner deleted or unshared it).
    /// `presentIDs` are the ids found during a SUCCESSFUL scan.
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
