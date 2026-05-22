//
//  AlarmScheduler.swift
//  Calarm
//

import ActivityKit
import AlarmKit
import AppIntents
import Foundation
import SwiftUI

/// Static metadata travelling with each AlarmKit alarm. Used by the optional widget extension
/// (Live Activity) and by app-side handlers.
struct CalarmAlarmMetadata: AlarmMetadata {
    let ownerID: String
    let title: String
    let symbolName: String
    let categoryRaw: Int
    let teamsURLString: String?

    var teamsURL: URL? {
        guard let s = teamsURLString, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    var category: ReminderCategory? {
        ReminderCategory(rawValue: categoryRaw)
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
        teamsURL: URL? = nil
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
            teamsURL: teamsURL,
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
    func cancelOrphans(ownerID: String, keepFireDates: Set<Date>) async {
        let keepTimestamps = keepFireDates.map { $0.timeIntervalSince1970 }
        for entry in store.allEntries(forOwner: ownerID) {
            let matches = keepTimestamps.contains { abs($0 - entry.fireDate.timeIntervalSince1970) < 1 }
            if !matches {
                try? await manager.cancel(id: entry.alarmID)
                store.remove(ownerID: ownerID, fireDate: entry.fireDate)
            }
        }
    }

    /// Cancels every alarm tracked in the store.
    func cancelAllStored() async {
        for entry in store.allEntries() {
            try? await manager.cancel(id: entry.alarmID)
        }
        store.clearAll()
    }

    /// Test alarm used by the diagnostic UI.
    @discardableResult
    func scheduleTestAlarm(in seconds: TimeInterval = 60) async throws -> UUID {
        let alarmID = UUID()
        let fireDate = Date().addingTimeInterval(seconds)

        let alertContent = AlarmPresentation.Alert(
            title: "Alarma de prueba",
            stopButton: AlarmButton(
                text: "Detener",
                textColor: .white,
                systemImageName: "stop.fill"
            )
        )
        let presentation = AlarmPresentation(alert: alertContent)

        let metadata = CalarmAlarmMetadata(
            ownerID: "test-\(alarmID.uuidString)",
            title: "Alarma de prueba",
            symbolName: "alarm.fill",
            categoryRaw: ReminderCategory.reminder.rawValue,
            teamsURLString: nil
        )

        let attributes = AlarmAttributes(
            presentation: presentation,
            metadata: metadata,
            tintColor: Color.accentColor
        )

        let configuration = AlarmManager.AlarmConfiguration.alarm(
            schedule: .fixed(fireDate),
            attributes: attributes,
            stopIntent: nil,
            secondaryIntent: nil,
            sound: .default
        )

        _ = try await manager.schedule(id: alarmID, configuration: configuration)
        return alarmID
    }

    // MARK: - Private

    private func makeConfiguration(
        title: String,
        symbolName: String,
        category: ReminderCategory,
        fireDate: Date,
        snooze: SnoozeInterval,
        ownerID: String,
        teamsURL: URL?,
        alarmID: UUID
    ) -> AlarmManager.AlarmConfiguration<CalarmAlarmMetadata> {
        let alertContent = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: title),
            stopButton: AlarmButton(
                text: "Detener",
                textColor: .white,
                systemImageName: "stop.fill"
            ),
            secondaryButton: AlarmButton(
                text: "Posponer",
                textColor: .white,
                systemImageName: "zzz"
            ),
            secondaryButtonBehavior: .countdown
        )

        let countdownContent = AlarmPresentation.Countdown(
            title: LocalizedStringResource(stringLiteral: title),
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
            title: title,
            symbolName: symbolName,
            categoryRaw: category.rawValue,
            teamsURLString: teamsURL?.absoluteString
        )

        let attributes = AlarmAttributes(
            presentation: presentation,
            metadata: metadata,
            tintColor: category.tint
        )

        let snoozeIntent = SnoozeAlarmIntent(alarmID: alarmID.uuidString)
        let stopIntent = StopAlarmIntent(alarmID: alarmID.uuidString)

        return AlarmManager.AlarmConfiguration(
            countdownDuration: Alarm.CountdownDuration(preAlert: nil, postAlert: snooze.seconds),
            schedule: .fixed(fireDate),
            attributes: attributes,
            stopIntent: stopIntent,
            secondaryIntent: snoozeIntent,
            sound: .default
        )
    }
}
