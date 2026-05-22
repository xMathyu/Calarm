//
//  SyncCoordinator.swift
//  Calarm
//
//  Optional Apple Calendar events sync. Only instantiated when AppSettings.teamsDetectionEnabled.
//

import Foundation
import Observation

@Observable
@MainActor
final class SyncCoordinator {
    private(set) var meetings: [Meeting] = []
    private(set) var isSyncing: Bool = false
    private(set) var lastError: String?

    private let source: CalendarSource
    private let scheduler: AlarmScheduler
    private let settings: AppSettings
    private let preferences: MeetingPreferencesStore
    private var changeObserverTask: Task<Void, Never>?

    init(
        source: CalendarSource,
        scheduler: AlarmScheduler,
        settings: AppSettings,
        preferences: MeetingPreferencesStore
    ) {
        self.source = source
        self.scheduler = scheduler
        self.settings = settings
        self.preferences = preferences
    }

    func start() {
        changeObserverTask?.cancel()
        changeObserverTask = Task { [weak self] in
            guard let self else { return }
            for await _ in await self.source.changes {
                await self.sync()
            }
        }
        Task { await sync() }
    }

    func stop() {
        changeObserverTask?.cancel()
        changeObserverTask = nil
        Task { await cancelAllCalendarAlarms() }
    }

    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            let now = Date()
            // Look ahead 90 days so events scheduled months in advance show up.
            let horizon = now.addingTimeInterval(90 * 24 * 60 * 60)
            let fetched = try await source.upcomingMeetings(from: now, to: horizon)
            self.meetings = fetched
            self.lastError = nil

            guard settings.alarmsEnabled else {
                await cancelAllCalendarAlarms()
                return
            }

            let snooze = settings.snoozeInterval

            for meeting in fetched {
                let leadTimes = preferences.leadTimes(forEventID: meeting.id)
                let fireDates = leadTimes
                    .map { meeting.startDate.addingTimeInterval(-$0.seconds) }
                    .filter { $0 > now }

                let ownerID = Self.ownerID(for: meeting.id)
                // Cancel any alarms previously scheduled for this event that no longer match.
                await scheduler.cancelOrphans(ownerID: ownerID, keepFireDates: Set(fireDates))

                for fireDate in fireDates {
                    do {
                        _ = try await scheduler.schedule(
                            ownerID: ownerID,
                            fireDate: fireDate,
                            title: meeting.title,
                            symbolName: meeting.teamsURL != nil ? "video.fill" : "calendar",
                            category: .event,
                            snooze: snooze,
                            teamsURL: meeting.teamsURL
                        )
                    } catch {
                        self.lastError = error.localizedDescription
                    }
                }
            }

            // Cancel alarms for events that vanished from the calendar.
            let validOwnerIDs = Set(fetched.map { Self.ownerID(for: $0.id) })
            for entry in await scheduler.storedEntriesOwnedByCalendar() where !validOwnerIDs.contains(entry.ownerID) {
                await scheduler.cancelAll(ownerID: entry.ownerID)
            }

            // Tidy up preferences for events that no longer exist.
            preferences.reconcile(keepingEventIDs: Set(fetched.map(\.id)))
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    func reschedule() async {
        await cancelAllCalendarAlarms()
        await sync()
    }

    /// Cancels every alarm scheduled by the calendar feature.
    private func cancelAllCalendarAlarms() async {
        for entry in await scheduler.storedEntriesOwnedByCalendar() {
            await scheduler.cancelAll(ownerID: entry.ownerID)
        }
        meetings = []
    }

    static func ownerID(for eventID: String) -> String {
        "calendar:\(eventID)"
    }

    static let ownerIDPrefix = "calendar:"
}
