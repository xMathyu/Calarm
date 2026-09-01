//
//  AlarmScheduler.swift
//  Calarm
//

import ActivityKit
import AlarmKit
import AppIntents
import Foundation
import SwiftUI

// `CalarmAlarmMetadata` lives in its own file (Models/CalarmAlarmMetadata.swift)
// so it can be shared, as the SAME type, with the widget extension that renders
// the AlarmKit Live Activity (countdown). ActivityKit matches activities by the
// attributes type, so the struct must compile into both targets.

extension CalarmAlarmMetadata {
    /// App-side convenience. Kept out of the shared file so the widget target
    /// doesn't have to depend on `ReminderCategory`.
    var category: ReminderCategory? {
        ReminderCategory(rawValue: categoryRaw)
    }
}

extension LocalizedStringResource {
    /// Texto que sale de los datos de la persona (el nombre de su alarma), no del
    /// catálogo de la app: viaja como ARGUMENTO de un formato `%@` en vez de como
    /// clave de localización.
    ///
    /// `LocalizedStringResource(stringLiteral:)` toma la cadena como clave, y
    /// AlarmKit la resuelve tarde — cuando la alarma suena, en otro proceso y con
    /// el locale del sistema. Una alarma llamada "Recordatorio" o "Detener"
    /// (claves que sí existen en `Localizable.xcstrings`) se mostraría traducida,
    /// y un título con "%" pasaría por el formateador. Interpolando, el texto va
    /// como dato dentro del propio recurso y sale tal cual se escribió.
    static func verbatim(_ text: String) -> LocalizedStringResource {
        LocalizedStringResource("\(text)")
    }
}

/// Low-level wrapper over `AlarmManager.shared`. Schedules and cancels individual alarms.
final class AlarmScheduler {
    private let manager: AlarmManager
    private let store: AlarmStore

    init(manager: AlarmManager = .shared, store: AlarmStore) {
        self.manager = manager
        self.store = store
    }

    var authorizationState: AlarmManager.AuthorizationState {
        manager.authorizationState
    }

    func isAuthorized() async -> Bool {
        manager.authorizationState == .authorized
    }

    func requestAuthorization() async throws -> Bool {
        let state = try await manager.requestAuthorization()
        return state == .authorized
    }

    /// Schedules a single alarm at `fireDate` and tracks it under `ownerID`.
    @discardableResult
    func schedule(
        ownerID: String,
        fireDate: Date,
        title: String,
        symbolName: String,
        category: ReminderCategory,
        snooze: SnoozeInterval,
        meetingURL: URL? = nil,
        location: String? = nil
    ) async throws -> UUID {
        if let existing = store.alarmID(forOwner: ownerID, fireDate: fireDate) {
            return existing
        }
        let alarmID = UUID()
        let configuration = makeConfiguration(
            title: title,
            symbolName: symbolName,
            category: category,
            fireDate: fireDate,
            snooze: snooze,
            ownerID: ownerID,
            meetingURL: meetingURL,
            location: location,
            alarmID: alarmID
        )
        _ = try await manager.schedule(id: alarmID, configuration: configuration)
        store.store(alarmID: alarmID, forOwner: ownerID, fireDate: fireDate)
        return alarmID
    }

    /// Cancels every alarm scheduled for the given owner.
    func cancelAll(ownerID: String) async {
        for entry in store.allEntries(forOwner: ownerID) {
            try? await manager.cancel(id: entry.alarmID)
        }
        store.removeAll(forOwner: ownerID)
    }

    /// Cancels alarms for the owner whose fireDate is NOT in `validFireDates`.
    ///
    /// Alarms the system currently has ALERTING or in a snooze COUNTDOWN are left
    /// alone: their original fireDate is already in the past, so they never appear
    /// in `keepFireDates`, but cancelling them would kill the countdown Live
    /// Activity and silently drop the re-ring (this ran on every app foreground, so
    /// merely tapping the Live Activity used to cancel the snoozed alarm). Their
    /// store entries get cleaned up by a later sync, once the alarm has finished
    /// and left the system's list.
    func cancelOrphans(ownerID: String, keepFireDates: Set<Date>) async {
        let keepTimestamps = keepFireDates.map { $0.timeIntervalSince1970 }
        let activeIDs = activeAlarmIDs()
        for entry in store.allEntries(forOwner: ownerID) {
            if activeIDs.contains(entry.alarmID) { continue }
            let matches = keepTimestamps.contains { abs($0 - entry.fireDate.timeIntervalSince1970) < 1 }
            if !matches {
                try? await manager.cancel(id: entry.alarmID)
                store.remove(ownerID: ownerID, fireDate: entry.fireDate)
            }
        }
    }

    /// Returns all stored entries whose ownerID starts with the calendar prefix.
    func storedEntriesOwnedByCalendar() async -> [(ownerID: String, alarmID: UUID, fireDate: Date)] {
        store.allEntries().filter { $0.ownerID.hasPrefix(SyncCoordinator.ownerIDPrefix) }
    }

    /// Reconciles the system's scheduled alarms against the store and the app's data.
    ///
    /// Two kinds of orphans are removed:
    /// 1. Store entries whose owner no longer exists (`isValidOwner` returns false) —
    ///    e.g. the reminder was deleted but a cancellation failed silently.
    /// 2. System alarms the store doesn't know about — e.g. scheduled by an old app
    ///    version with a pre-v2 store format. Without this they ring forever because
    ///    no normal flow can ever reach them.
    func reconcileWithSystem(isValidOwner: (String) -> Bool) async {
        for entry in store.allEntries() where !isValidOwner(entry.ownerID) {
            try? manager.cancel(id: entry.alarmID)
            store.remove(ownerID: entry.ownerID, fireDate: entry.fireDate)
        }

        guard let systemAlarms = try? manager.alarms else { return }
        let knownIDs = Set(store.allEntries().map(\.alarmID))
        for alarm in systemAlarms where !knownIDs.contains(alarm.id) {
            try? manager.cancel(id: alarm.id)
        }
    }

    /// Cancels every alarm tracked in the store.
    func cancelAllStored() async {
        for entry in store.allEntries() {
            try? await manager.cancel(id: entry.alarmID)
        }
        store.clearAll()
    }

    // MARK: - Private

    /// IDs of alarms in a non-`.scheduled` state: alerting right now, or counting
    /// down / paused after a snooze.
    private func activeAlarmIDs() -> Set<UUID> {
        guard let alarms = try? manager.alarms else { return [] }
        return Set(alarms.filter { $0.state != .scheduled }.map(\.id))
    }

    private func makeConfiguration(
        title: String,
        symbolName: String,
        category: ReminderCategory,
        fireDate: Date,
        snooze: SnoozeInterval,
        ownerID: String,
        meetingURL: URL?,
        location: String?,
        alarmID: UUID
    ) -> AlarmManager.AlarmConfiguration<CalarmAlarmMetadata> {
        let hasLocation = (location?.isEmpty == false) && meetingURL == nil

        // When the event has a physical location, the secondary button navigates to it
        // (stopping the alarm). Otherwise we keep snooze.
        let secondaryButton: AlarmButton
        let secondaryBehavior: AlarmPresentation.Alert.SecondaryButtonBehavior
        let secondaryIntent: any LiveActivityIntent
        if hasLocation, let location {
            secondaryButton = AlarmButton(
                text: "Ir",
                textColor: .white,
                systemImageName: "location.fill"
            )
            secondaryBehavior = .custom
            secondaryIntent = NavigateToEventIntent(alarmID: alarmID.uuidString, locationQuery: location)
        } else {
            secondaryButton = AlarmButton(
                text: "Posponer",
                textColor: .white,
                systemImageName: "zzz"
            )
            secondaryBehavior = .countdown
            secondaryIntent = SnoozeAlarmIntent(alarmID: alarmID.uuidString)
        }

        // The system alert only has room for a title — it shows it next to the app
        // name — so an empty one leaves just "Calarm" on the Lock Screen and on the
        // Apple Watch. Never hand AlarmKit a blank title.
        let safeTitle: String = {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? category.localizedTitle : trimmed
        }()

        // Append location to the title so the user sees where to go in the alert UI.
        let alertTitle: String = {
            guard hasLocation, let location else { return safeTitle }
            return "\(safeTitle) · \(location)"
        }()

        let alertContent = AlarmPresentation.Alert(
            title: .verbatim(alertTitle),
            stopButton: AlarmButton(
                text: "Detener",
                textColor: .white,
                systemImageName: "stop.fill"
            ),
            secondaryButton: secondaryButton,
            secondaryButtonBehavior: secondaryBehavior
        )

        let countdownContent = AlarmPresentation.Countdown(
            title: .verbatim(safeTitle),
            pauseButton: AlarmButton(
                text: "Pausar",
                textColor: .white,
                systemImageName: "pause.fill"
            )
        )

        let pausedContent = AlarmPresentation.Paused(
            title: "En pausa",
            resumeButton: AlarmButton(
                text: "Reanudar",
                textColor: .white,
                systemImageName: "play.fill"
            )
        )

        let presentation = AlarmPresentation(
            alert: alertContent,
            countdown: countdownContent,
            paused: pausedContent
        )

        let metadata = CalarmAlarmMetadata(
            ownerID: ownerID,
            title: safeTitle,
            symbolName: symbolName,
            categoryRaw: category.rawValue,
            teamsURLString: meetingURL?.absoluteString,
            location: location
        )

        let attributes = AlarmAttributes(
            presentation: presentation,
            metadata: metadata,
            tintColor: category.tint
        )

        let stopIntent = StopAlarmIntent(alarmID: alarmID.uuidString)

        return AlarmManager.AlarmConfiguration(
            countdownDuration: Alarm.CountdownDuration(preAlert: nil, postAlert: snooze.seconds),
            schedule: .fixed(fireDate),
            attributes: attributes,
            stopIntent: stopIntent,
            secondaryIntent: secondaryIntent,
            sound: .default
        )
    }
}
