//
//  ReminderScheduler.swift
//  Calarm
//

import Foundation
import Observation

/// Translates a `Reminder` into N concrete AlarmKit alarms based on its recurrence rule.
/// Owns reconciliation when reminders change: cancels old alarms, schedules new ones.
@Observable
@MainActor
final class ReminderScheduler {
    private(set) var lastError: String?
    private(set) var isWorking: Bool = false

    private let scheduler: AlarmScheduler
    private let settings: AppSettings
    private let occurrencesPerReminder: Int
    /// El calendario «Calarm» del Calendario del sistema. Solo actúa con
    /// `settings.calendarMirrorEnabled`; se engancha aquí porque por aquí pasa
    /// todo cambio de alarma, venga del editor, la lista, el asistente, Siri o
    /// una persona de confianza.
    private let mirror = CalendarMirrorService()

    /// Upper bound on concurrently-scheduled AlarmKit alarms per reminder across all
    /// of its schedules × lead times. Keeps multi-schedule alarms from exhausting the
    /// system's pending-alarm budget; the soonest are kept and the rest reprogrammed later.
    private static let maxScheduledFireDates = 32

    init(scheduler: AlarmScheduler, settings: AppSettings, occurrencesPerReminder: Int = 12) {
        self.scheduler = scheduler
        self.settings = settings
        self.occurrencesPerReminder = occurrencesPerReminder
    }

    /// (Re)programs all alarms for a single reminder.
    func syncAlarms(for reminder: Reminder) async {
        isWorking = true
        defer { isWorking = false }
        await applyReminder(reminder)
        if settings.calendarMirrorEnabled { mirror.apply(reminder) }
    }

    /// (Re)programs all alarms for every reminder in `reminders`.
    func syncAlarms(for reminders: [Reminder]) async {
        isWorking = true
        defer { isWorking = false }
        for reminder in reminders {
            await applyReminder(reminder)
        }
        // Con la lista completa se puede además quitar lo que sobre.
        if settings.calendarMirrorEnabled { mirror.reconcile(reminders) }
    }

    /// Cancels every alarm associated with the given reminder.
    func cancelAlarms(for reminder: Reminder) async {
        await cancelAlarms(forReminderID: reminder.id)
    }

    func cancelAlarms(forReminderID id: UUID) async {
        await scheduler.cancelAll(ownerID: Self.ownerID(forReminderID: id))
        await scheduler.cancelAll(ownerID: Self.backupOwnerID(forReminderID: id))
        WakeChallengeStore.forget(id)
        if settings.calendarMirrorEnabled { mirror.remove(reminderID: id) }
    }

    /// Al encender «Guardar mis alarmas en el Calendario»: pide el permiso si
    /// hace falta y vuelca todas las alarmas. `false` si no hay acceso total.
    func startCalendarMirror(reminders: [Reminder]) async -> Bool {
        guard await mirror.requestAccessIfNeeded() else { return false }
        mirror.reconcile(reminders)
        return true
    }

    /// Al apagarlo: el calendario «Calarm» se va con todas sus entradas.
    func stopCalendarMirror() {
        mirror.removeCalendar()
    }

    static func ownerID(forReminderID id: UUID) -> String {
        "reminder:\(id.uuidString)"
    }

    /// Dueño aparte para los refuerzos de un reto: así el sync normal de la
    /// alarma no los toca y se pueden cancelar todos de golpe al resolverlo.
    static func backupOwnerID(forReminderID id: UUID) -> String {
        "reminder:\(id.uuidString)#refuerzo"
    }

    /// La alarma de Calarm detrás de un `ownerID`, sea el principal o el de
    /// sus refuerzos. `nil` para los dueños del calendario.
    static func reminderID(fromOwnerID ownerID: String) -> UUID? {
        let prefix = "reminder:"
        guard ownerID.hasPrefix(prefix) else { return nil }
        var raw = ownerID.dropFirst(prefix.count)
        if let hash = raw.firstIndex(of: "#") { raw = raw[..<hash] }
        return UUID(uuidString: String(raw))
    }

    private func applyReminder(_ reminder: Reminder) async {
        let ownerID = ownerID(for: reminder)
        let backupOwnerID = Self.backupOwnerID(forReminderID: reminder.id)

        guard reminder.isEnabled, settings.alarmsEnabled else {
            await scheduler.cancelAll(ownerID: ownerID)
            await scheduler.cancelAll(ownerID: backupOwnerID)
            return
        }

        // One alarm per (schedule × occurrence × leadTime) combo, filtered to the
        // future. A reminder can have several schedules (different day/time), so we
        // union the occurrences of all of them.
        //
        // Con reto, interesan también las ocurrencias que acaban de sonar: sus
        // refuerzos siguen vivos aunque la hora ya haya pasado.
        let now = Date()
        let challenge = reminder.challenge.flatMap { $0.isReady ? $0 : nil }
        let horizon = challenge == nil ? now : now.addingTimeInterval(-WakeChallenge.backupWindow)
        let leadTimes = reminder.leadTimes
        var fireSet: Set<Date> = []
        for schedule in reminder.allSchedules {
            let occurrences = RecurrenceEngine.nextOccurrences(
                rule: schedule.recurrence,
                baseDate: schedule.date,
                count: occurrencesPerReminder,
                now: horizon
            )
            for occurrence in occurrences {
                for leadTime in leadTimes {
                    let fire = occurrence.addingTimeInterval(-leadTime.seconds)
                    if fire > horizon { fireSet.insert(fire) }
                }
            }
        }
        let candidates = fireSet.sorted()
        // Cap the total so many schedules can't blow past AlarmKit's pending-alarm
        // budget; keep the soonest. Far-future ones get scheduled on a later sync.
        let fireDates = Array(candidates.filter { $0 > now }.prefix(Self.maxScheduledFireDates))

        await scheduler.cancelOrphans(ownerID: ownerID, keepFireDates: Set(fireDates))

        for fireDate in fireDates {
            do {
                try await scheduleAlarm(
                    for: reminder,
                    ownerID: ownerID,
                    fireDate: fireDate,
                    countdown: settings.countdown,
                    challenge: challenge
                )
            } catch {
                lastError = error.localizedDescription
            }
        }

        await syncBackups(for: reminder, challenge: challenge, candidates: candidates, now: now)
    }

    /// Programa una alarma de `reminder` bajo `ownerID` con todo lo que la
    /// persona ve y oye (título, icono, tono, reto…).
    @discardableResult
    private func scheduleAlarm(
        for reminder: Reminder,
        ownerID: String,
        fireDate: Date,
        countdown: AlarmCountdown,
        challenge: WakeChallenge?
    ) async throws -> UUID {
        try await scheduler.schedule(
            ownerID: ownerID,
            fireDate: fireDate,
            title: reminder.title,
            // AlarmKit expects an SF Symbol name — fall back to the
            // category symbol when the reminder uses an emoji/photo icon.
            symbolName: (reminder.iconKind == .symbol ? reminder.symbolName : nil) ?? reminder.category.defaultSymbol,
            category: reminder.category,
            snooze: settings.snoozeInterval,
            // Sin tono propio, la alarma sigue el predeterminado de Ajustes.
            tone: reminder.tone ?? settings.alarmTone,
            countdown: countdown,
            meetingURL: nil,
            challenge: challenge
        )
    }

    // MARK: - Retos: insistencia

    /// Mantiene los refuerzos de una alarma con reto: copias de la alarma a los
    /// 2, 5 y 10 minutos de la ocurrencia «ancla», programadas de antemano porque
    /// el sistema no siempre avisa cuando la persona la detiene (cerrar el aviso,
    /// botones de volumen…). Se cancelan al resolver el reto. Solo la ocurrencia
    /// más próxima lleva refuerzos: muchas alarmas seguidas hacen que AlarmKit
    /// las entregue tarde o se las salte.
    private func syncBackups(for reminder: Reminder, challenge: WakeChallenge?, candidates: [Date], now: Date) async {
        let backupOwnerID = Self.backupOwnerID(forReminderID: reminder.id)
        guard let challenge else {
            await scheduler.cancelAll(ownerID: backupOwnerID)
            return
        }
        let window = WakeChallenge.backupWindow

        // Ancla: la hora a la que vuelve a sonar tras posponer, si la hay y sigue
        // vigente; si no, la ocurrencia más próxima, por venir o recién sonada.
        var anchor: Date? = WakeChallengeStore.anchorOverride(for: reminder.id)
            .flatMap { $0 > now.addingTimeInterval(-window) ? $0 : nil }
            ?? candidates.first
        // Una ocurrencia ya resuelta no insiste más.
        if let current = anchor, let solved = WakeChallengeStore.solvedAt(for: reminder.id), solved >= current {
            anchor = nil
        }

        var desired: [Date] = []
        if let anchor {
            desired = WakeChallenge.backupOffsets
                .map { anchor.addingTimeInterval($0) }
                .filter { date in
                    // Nunca encima de otra alarma de la misma lista (p. ej. un
                    // aviso 10 minutos antes y otro a la hora).
                    date > now && !candidates.contains { abs($0.timeIntervalSince(date)) < 30 }
                }
        }
        // Lo que ya esté programado para esta ocurrencia se conserva: ahí vive
        // el «vuelve a sonar al minuto» de `insistAfterStop`.
        let existing = scheduler.storedFireDates(ownerID: backupOwnerID).filter { date in
            guard let anchor else { return false }
            return date > now
                && date > anchor.addingTimeInterval(30)
                && date <= anchor.addingTimeInterval(WakeChallenge.maxInsistence)
        }
        await scheduler.cancelOrphans(ownerID: backupOwnerID, keepFireDates: Set(desired + existing))

        for date in desired {
            do {
                try await scheduleAlarm(
                    for: reminder,
                    ownerID: backupOwnerID,
                    fireDate: date,
                    countdown: .off,
                    challenge: challenge
                )
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Reto resuelto: la ocurrencia queda cerrada y los refuerzos se van.
    func challengeSolved(forReminderID id: UUID) async {
        WakeChallengeStore.markSolved(id)
        await scheduler.cancelAll(ownerID: Self.backupOwnerID(forReminderID: id))
    }

    /// Pospuesto desde la pantalla del reto: los refuerzos se recalculan sobre
    /// la hora a la que volverá a sonar.
    func challengeSnoozed(_ reminder: Reminder, reRingAt date: Date) async {
        WakeChallengeStore.setAnchorOverride(date, for: reminder.id)
        WakeChallengeStore.setInsistingSince(nil, for: reminder.id)
        await applyReminder(reminder)
    }

    /// «Detener» sin resolver el reto: vuelve a sonar al minuto, con un tope de
    /// media hora desde la primera vez por si la persona no puede llegar a la app.
    func insistAfterStop(_ reminder: Reminder, stoppedAlarmFireDate: Date) async {
        guard let challenge = reminder.challenge, challenge.isReady,
              reminder.isEnabled, settings.alarmsEnabled
        else { return }
        let now = Date()
        if let solved = WakeChallengeStore.solvedAt(for: reminder.id),
           solved >= stoppedAlarmFireDate.addingTimeInterval(-1) {
            return
        }
        var since = WakeChallengeStore.insistingSince(for: reminder.id)
        // Una insistencia vieja es de otra ocurrencia: se empieza de cero.
        if let started = since, stoppedAlarmFireDate > started.addingTimeInterval(WakeChallenge.maxInsistence) {
            since = nil
        }
        if since == nil { WakeChallengeStore.setInsistingSince(now, for: reminder.id) }
        guard now.timeIntervalSince(since ?? now) < WakeChallenge.maxInsistence else { return }

        do {
            try await scheduleAlarm(
                for: reminder,
                ownerID: Self.backupOwnerID(forReminderID: reminder.id),
                fireDate: now.addingTimeInterval(WakeChallenge.reRingDelay),
                countdown: .off,
                challenge: challenge
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func ownerID(for reminder: Reminder) -> String {
        Self.ownerID(forReminderID: reminder.id)
    }
}
