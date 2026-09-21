//
//  CalendarRulesTests.swift
//  CalarmTests
//

import Foundation
import Testing
@testable import Calarm

/// Las dos reglas que deciden si un evento del calendario suena, y la cuenta
/// atrás que adelanta la entrega de la alarma al sistema.
@MainActor
struct CalendarRulesTests {

    private func makeDefaults() -> UserDefaults {
        let suite = "tests.calendarRules.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func meeting(id: String = "evento", participating: Bool) -> Meeting {
        Meeting(
            id: id,
            title: "Corte del árbol",
            startDate: Date().addingTimeInterval(3600),
            endDate: Date().addingTimeInterval(7200),
            meetingLink: nil,
            organizer: nil,
            location: nil,
            isParticipating: participating
        )
    }

    // MARK: - Solo eventos a los que asisto

    /// Con la regla apagada suena todo, como antes.
    @Test func conLaReglaApagadaSuenaTambienLoQueNoEsTuyo() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        let store = MeetingPreferencesStore(defaults: defaults, settings: settings)
        settings.defaultLeadTime = .min30

        #expect(store.activeLeadTimes(for: meeting(participating: false)) == [.min30])
    }

    /// Con la regla encendida, lo que no es tuyo se queda sin alarma.
    @Test func laReglaDejaSinAlarmaLoQueNoEsTuyo() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        let store = MeetingPreferencesStore(defaults: defaults, settings: settings)
        settings.defaultLeadTime = .min30
        settings.onlyAttendingEvents = true

        #expect(store.activeLeadTimes(for: meeting(participating: false)).isEmpty)
        #expect(store.activeLeadTimes(for: meeting(participating: true)) == [.min30])
    }

    /// Lo que la persona configuró a mano manda sobre la regla general.
    @Test func unEventoConfiguradoAManoSuenaAunqueNoSeasParte() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        let store = MeetingPreferencesStore(defaults: defaults, settings: settings)
        settings.onlyAttendingEvents = true
        store.setLeadTimes([.min15], enabled: true, forEventID: "evento")

        #expect(store.activeLeadTimes(for: meeting(participating: false)) == [.min15])
    }

    /// Y el interruptor del propio evento sigue por encima de todo.
    @Test func elEventoApagadoNoSuenaAunqueSeasParte() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        let store = MeetingPreferencesStore(defaults: defaults, settings: settings)
        store.setLeadTimes([.min15], enabled: false, forEventID: "evento")

        #expect(store.activeLeadTimes(for: meeting(participating: true)).isEmpty)
    }

    // MARK: - Cuenta regresiva

    /// Sin cuenta regresiva no se adelanta nada: la alarma se entrega a su hora.
    @Test func sinCuentaRegresivaNoSeAdelantaLaEntrega() {
        let fire = Date().addingTimeInterval(3600)
        #expect(AlarmScheduler.countdownStart(fireDate: fire, countdown: .off) == nil)
    }

    /// Con cuenta regresiva se entrega ANTES, para que la cuenta termine justo
    /// a la hora de sonar (AlarmKit alerta `preAlert` después de lo programado).
    @Test func laCuentaRegresivaAdelantaLaEntregaSuDuracion() {
        let now = Date()
        let fire = now.addingTimeInterval(3600)
        let start = AlarmScheduler.countdownStart(fireDate: fire, countdown: .min10, now: now)

        #expect(start == fire.addingTimeInterval(-600))
    }

    /// Si no cabe —la alarma es antes de que la cuenta pudiera empezar— se
    /// programa a secas: sonar a su hora vale más que la animación.
    @Test func sinHuecoParaLaCuentaLaAlarmaSeProgramaASecas() {
        let now = Date()
        let fire = now.addingTimeInterval(120)
        #expect(AlarmScheduler.countdownStart(fireDate: fire, countdown: .min10, now: now) == nil)
    }

    /// El caso límite: el arranque cae justo ahora, que ya no es futuro.
    @Test func elArranqueExactamenteAhoraNoCuentaComoHueco() {
        let now = Date()
        let fire = now.addingTimeInterval(600)
        #expect(AlarmScheduler.countdownStart(fireDate: fire, countdown: .min10, now: now) == nil)
    }

    // MARK: - Calendarios elegidos

    /// Arranca sin selección: mira todos, incluidos los que se agreguen luego.
    @Test func sinSeleccionMiraTodosLosCalendarios() {
        let defaults = makeDefaults()
        #expect(AppSettings(defaults: defaults).selectedCalendarIDs == nil)
    }

    /// La selección sobrevive a un reinicio de la app.
    @Test func laSeleccionDeCalendariosSeGuarda() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.selectedCalendarIDs = ["trabajo", "casa"]

        #expect(AppSettings(defaults: defaults).selectedCalendarIDs == ["trabajo", "casa"])

        settings.selectedCalendarIDs = nil
        #expect(AppSettings(defaults: defaults).selectedCalendarIDs == nil)
    }
}
