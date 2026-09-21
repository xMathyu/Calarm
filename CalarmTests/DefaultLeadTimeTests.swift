//
//  DefaultLeadTimeTests.swift
//  CalarmTests
//

import Foundation
import Testing
@testable import Calarm

/// El aviso por defecto de Ajustes: quién lo hereda, quién no, y que la lectura
/// sin instancia (la que usa el `init` del editor) vea siempre lo mismo que el
/// ajuste.
@MainActor
struct DefaultLeadTimeTests {

    /// Un `UserDefaults` limpio por prueba: nada que arrastrar entre corridas ni
    /// desde la app instalada en el simulador.
    private func makeDefaults() -> UserDefaults {
        let suite = "tests.defaultLeadTime.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Sin nada guardado se mantiene el comportamiento de siempre: al momento.
    @Test func sinAjusteGuardadoElPredeterminadoEsAlMomento() {
        let defaults = makeDefaults()
        #expect(AppSettings.storedDefaultLeadTime(defaults: defaults) == .atStart)
        #expect(AppSettings(defaults: defaults).defaultLeadTime == .atStart)
    }

    /// Lo que elige la persona en Ajustes es lo que lee el editor de una alarma
    /// nueva, que no puede tocar el entorno desde su `init`.
    @Test func laLecturaSinInstanciaSigueAlAjuste() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)

        settings.defaultLeadTime = .min30

        #expect(AppSettings.storedDefaultLeadTime(defaults: defaults) == .min30)
        #expect(AppSettings(defaults: defaults).defaultLeadTime == .min30)
    }

    /// Un evento del calendario que nunca se editó suena con el predeterminado.
    @Test func eventoSinAjustesHeredaElPredeterminado() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        let store = MeetingPreferencesStore(defaults: defaults, settings: settings)

        settings.defaultLeadTime = .min30

        #expect(store.leadTimes(forEventID: "evento-nuevo") == [.min30])
        #expect(store.activeLeadTimes(forEventID: "evento-nuevo") == [.min30])
        #expect(store.hasOverride(forEventID: "evento-nuevo") == false)
    }

    /// Cambiar el predeterminado mueve a los eventos que lo heredan sin tocarlos
    /// uno por uno — es lo que hace que la sincronización los reprograme.
    @Test func cambiarElPredeterminadoMueveALosQueLoHeredan() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        let store = MeetingPreferencesStore(defaults: defaults, settings: settings)

        #expect(store.leadTimes(forEventID: "evento") == [.atStart])
        settings.defaultLeadTime = .hour1
        #expect(store.leadTimes(forEventID: "evento") == [.hour1])
    }

    /// Un evento con sus propios avisos no se entera de que el predeterminado
    /// cambió: lo que la persona configuró a mano manda.
    @Test func eventoConAvisosPropiosIgnoraElPredeterminado() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        let store = MeetingPreferencesStore(defaults: defaults, settings: settings)

        store.setLeadTimes([.min10], enabled: true, forEventID: "evento")
        settings.defaultLeadTime = .hour1

        #expect(store.leadTimes(forEventID: "evento") == [.min10])
        #expect(store.hasOverride(forEventID: "evento"))

        // Y al restablecerlo vuelve a heredar el predeterminado de ese momento.
        store.resetToDefault(forEventID: "evento")
        #expect(store.leadTimes(forEventID: "evento") == [.hour1])
    }

    /// Un evento apagado sigue apagado aunque herede un aviso predeterminado.
    @Test func eventoApagadoNoSuenaConElPredeterminado() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        let store = MeetingPreferencesStore(defaults: defaults, settings: settings)

        settings.defaultLeadTime = .min30
        store.setLeadTimes([], enabled: false, forEventID: "evento")

        #expect(store.activeLeadTimes(forEventID: "evento").isEmpty)
    }
}
