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
    /// El permiso del calendario según la última sincronización. Arranca como
    /// concedido para que la pestaña no enseñe un aviso de permiso durante el
    /// instante que tarda la primera lectura.
    private(set) var access: CalendarAccess = .granted

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
        meetings = []
        Task { await cancelAllCalendarAlarms() }
    }

    /// Saca el aviso del sistema si nunca se pidió el permiso, y sincroniza con
    /// lo que la persona conteste. Si ya contestó, no hace nada: iOS no vuelve a
    /// preguntar.
    func requestAccessIfNeeded() async {
        guard await source.access == .notDetermined else { return }
        _ = try? await source.requestAccess()
        await sync()
    }

    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        access = await source.access
        guard access == .granted else {
            meetings = []
            return
        }

        do {
            let now = Date()
            // Look ahead 90 days so events scheduled months in advance show up.
            let horizon = now.addingTimeInterval(90 * 24 * 60 * 60)
            let fetched = try await source.upcomingMeetings(
                from: now,
                to: horizon,
                calendarIDs: settings.selectedCalendarIDs
            )
            self.meetings = fetched
            self.lastError = nil

            guard settings.alarmsEnabled else {
                await cancelAllCalendarAlarms()
                return
            }

            let snooze = settings.snoozeInterval
            let tone = settings.alarmTone
            let countdown = settings.countdown

            for meeting in fetched {
                let leadTimes = preferences.activeLeadTimes(for: meeting)
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
                            symbolName: meeting.meetingLink != nil ? "video.fill" : "calendar",
                            category: .event,
                            snooze: snooze,
                            tone: tone,
                            countdown: countdown,
                            meetingURL: meeting.meetingLink?.url,
                            location: meeting.location
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

    /// Los calendarios entre los que se puede elegir en Ajustes.
    func availableCalendars() async -> [CalendarInfo] {
        (try? await source.availableCalendars()) ?? []
    }

    func reschedule() async {
        await cancelAllCalendarAlarms()
        await sync()
    }

    /// Cancels every alarm scheduled by the calendar feature.
    ///
    /// Solo las alarmas: la lista de eventos se queda. Con el interruptor general
    /// apagado los eventos se siguen viendo, cada uno con la campana tachada; antes
    /// esto vaciaba la lista y la pestaña decía "Sin eventos próximos".
    private func cancelAllCalendarAlarms() async {
        for entry in await scheduler.storedEntriesOwnedByCalendar() {
            await scheduler.cancelAll(ownerID: entry.ownerID)
        }
    }

    static func ownerID(for eventID: String) -> String {
        "calendar:\(eventID)"
    }

    static let ownerIDPrefix = "calendar:"
}
