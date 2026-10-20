//
//  ChallengeCoordinator.swift
//  Calarm
//

import AlarmKit
import Foundation
import Observation
import SwiftData

/// Une la alarma de AlarmKit que está sonando con la alarma de Calarm dueña y
/// su reto, y lleva la pantalla del reto: cuándo aparece, qué pasa al resolverlo
/// o posponerlo, y qué hacer cuando la persona detiene la alarma sin resolverlo.
@Observable
@MainActor
final class ChallengeCoordinator {
    struct Session: Identifiable {
        /// La alarma de AlarmKit que está sonando (o en cuenta tras posponer).
        let id: UUID
        let reminderID: UUID
        let title: String
        let challenge: WakeChallenge
        let snooze: SnoozeInterval
    }

    /// Mientras no sea `nil`, `ContentView` muestra la pantalla del reto.
    var session: Session?

    private let alarmScheduler: AlarmScheduler
    private let reminderScheduler: ReminderScheduler
    private let modelContainer: ModelContainer
    private let settings: AppSettings

    init(
        alarmScheduler: AlarmScheduler,
        reminderScheduler: ReminderScheduler,
        modelContainer: ModelContainer,
        settings: AppSettings
    ) {
        self.alarmScheduler = alarmScheduler
        self.reminderScheduler = reminderScheduler
        self.modelContainer = modelContainer
        self.settings = settings
    }

    // MARK: - Mostrar el reto

    /// «Resolver reto» en la alerta del sistema, el botón de la Live Activity o
    /// el enlace `calarm://challenge/<id>`.
    func present(alarmID: UUID) {
        guard let resolved = resolve(alarmID: alarmID) else {
            // La alarma ya no tiene reto (se quitó después de programarla) o no
            // es de Calarm: se apaga como siempre.
            alarmScheduler.stop(alarmID: alarmID)
            return
        }
        if session?.id == alarmID { return }
        session = Session(
            id: alarmID,
            reminderID: resolved.reminder.id,
            title: resolved.reminder.title,
            challenge: resolved.challenge,
            snooze: settings.snoozeInterval
        )
    }

    /// Al arrancar o volver a primer plano: si hay una alarma con reto sonando,
    /// la pantalla del reto sale sola, sin que haga falta tocar ningún botón.
    func presentIfAlerting() {
        if session != nil { return }
        if let pending = ChallengeRequest.alarmID {
            ChallengeRequest.clear()
            present(alarmID: pending)
            if session != nil { return }
        }
        for alarmID in alarmScheduler.alertingAlarmIDs() where resolve(alarmID: alarmID) != nil {
            present(alarmID: alarmID)
            return
        }
    }

    /// La alarma de la sesión dejó de existir en el sistema (la detuvieron
    /// desde otro sitio): la pantalla se cierra sola.
    func sessionAlarmEnded() {
        session = nil
    }

    // MARK: - Resultado

    /// Reto resuelto: se apaga todo lo que esté sonando de esa alarma (la
    /// principal y cualquier refuerzo) y se cancelan los refuerzos pendientes.
    func solve() async {
        guard let session else { return }
        self.session = nil
        // Primero se marca resuelto, para que el hook de «Detener» que pueda
        // dispararse al parar no vuelva a programarla.
        await reminderScheduler.challengeSolved(forReminderID: session.reminderID)
        alarmScheduler.stopActive(ownerID: ReminderScheduler.ownerID(forReminderID: session.reminderID))
        alarmScheduler.stopActive(ownerID: ReminderScheduler.backupOwnerID(forReminderID: session.reminderID))
        alarmScheduler.stop(alarmID: session.id)
        Haptics.success()
    }

    /// Posponer desde la pantalla del reto: la alarma entra en cuenta regresiva
    /// (como el «Posponer» de siempre) y los refuerzos se recalculan sobre la
    /// hora a la que volverá a sonar.
    func snooze() async {
        guard let session else { return }
        self.session = nil
        let reRingAt = Date().addingTimeInterval(session.snooze.seconds)
        alarmScheduler.snooze(alarmID: session.id)
        // Un refuerzo que estuviera sonando a la vez se calla; el que se pospuso
        // sigue en su cuenta.
        alarmScheduler.stopActive(
            ownerID: ReminderScheduler.backupOwnerID(forReminderID: session.reminderID),
            except: session.id
        )
        if let reminder = reminder(id: session.reminderID) {
            await reminderScheduler.challengeSnoozed(reminder, reRingAt: reRingAt)
        }
    }

    /// Hook de `StopAlarmIntent`: la persona detuvo la alarma desde la pantalla
    /// de bloqueo o el reloj sin resolver el reto. Vuelve a sonar al minuto.
    func userStopped(alarmID: UUID) async {
        guard let resolved = resolve(alarmID: alarmID) else { return }
        await reminderScheduler.insistAfterStop(resolved.reminder, stoppedAlarmFireDate: resolved.fireDate)
    }

    // MARK: - Private

    private func resolve(alarmID: UUID) -> (reminder: Reminder, challenge: WakeChallenge, fireDate: Date)? {
        guard let owner = alarmScheduler.owner(forAlarmID: alarmID),
              let reminderID = ReminderScheduler.reminderID(fromOwnerID: owner.ownerID),
              let reminder = reminder(id: reminderID),
              let challenge = reminder.challenge, challenge.isReady
        else { return nil }
        return (reminder, challenge, owner.fireDate)
    }

    private func reminder(id: UUID) -> Reminder? {
        let descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.id == id })
        return try? modelContainer.mainContext.fetch(descriptor).first
    }
}
