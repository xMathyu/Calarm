//
//  SettingsView.swift
//  Calarm
//

import AlarmKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    let alarmScheduler: AlarmScheduler
    let onTeamsToggleChanged: (Bool) -> Void

    @State private var testAlarmResult: String?
    @State private var isSchedulingTest = false

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section {
                    Toggle("Alarmas activas", isOn: $settings.alarmsEnabled)
                } footer: {
                    Text("Interruptor general. Cuando esté apagado, no sonará ninguna alarma.")
                }

                Section("Posponer") {
                    Picker("Intervalo de snooze", selection: $settings.snoozeInterval) {
                        ForEach(SnoozeInterval.allCases) { value in
                            Text(value.localizedTitle).tag(value)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section {
                    Toggle("Programar alarmas para eventos del calendario", isOn: $settings.teamsDetectionEnabled)
                        .onChange(of: settings.teamsDetectionEnabled) { _, newValue in
                            onTeamsToggleChanged(newValue)
                        }
                } header: {
                    Text("Calendario de Apple")
                } footer: {
                    Text("Cuando esté activo, Calarm leerá los eventos de tu app Calendario y programará una alarma 10 minutos antes de cada uno. Si el evento tiene un enlace de Microsoft Teams, aparecerá un botón para unirte.")
                }

                Section {
                    LabeledContent("Permiso de alarmas") {
                        Text(authorizationStatusText)
                            .foregroundStyle(authorizationStatusColor)
                    }
                    Button {
                        Task { await runTestAlarm() }
                    } label: {
                        if isSchedulingTest {
                            HStack { ProgressView(); Text("Programando…") }
                        } else {
                            Label("Probar alarma en 1 minuto", systemImage: "bell.badge.fill")
                        }
                    }
                    .disabled(isSchedulingTest)
                    if let testAlarmResult {
                        Text(testAlarmResult).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Diagnóstico")
                }

                Section {
                    LabeledContent("Versión") { Text(Bundle.main.shortVersion) }
                } header: {
                    Text("Acerca de")
                } footer: {
                    Text("Calarm es una app de alarmas para eventos personales: cumpleaños, aniversarios, recordatorios y más.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Ajustes")
        }
    }

    private var authorizationStatusText: String {
        switch alarmScheduler.authorizationState {
        case .authorized: "Autorizado"
        case .denied: "Denegado"
        case .notDetermined: "Sin determinar"
        @unknown default: "Desconocido"
        }
    }

    private var authorizationStatusColor: Color {
        switch alarmScheduler.authorizationState {
        case .authorized: .green
        case .denied: .red
        case .notDetermined: .orange
        @unknown default: .secondary
        }
    }

    private func runTestAlarm() async {
        isSchedulingTest = true
        defer { isSchedulingTest = false }
        _ = try? await alarmScheduler.requestAuthorization()
        do {
            let id = try await alarmScheduler.scheduleTestAlarm(in: 60)
            testAlarmResult = "✓ Alarma programada (\(id.uuidString.prefix(8))…). Debería sonar en 1 minuto."
        } catch {
            let ns = error as NSError
            testAlarmResult = "✗ \(ns.domain) code \(ns.code): \(ns.localizedDescription)"
        }
    }
}

private extension Bundle {
    var shortVersion: String {
        (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
    }
}
