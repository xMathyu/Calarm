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

    @State private var testAlarmResult: TestResult?
    @State private var isSchedulingTest = false

    private enum TestResult {
        case success(String)
        case failure(String)
    }

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $settings.alarmsEnabled) {
                        Label("Alarmas activas", systemImage: "bell.fill")
                            .symbolEffect(.bounce, options: .nonRepeating, value: settings.alarmsEnabled)
                    }
                } footer: {
                    Text("Interruptor general. Cuando esté apagado, no sonará ninguna alarma.")
                }

                Section {
                    appearancePicker(selection: $settings.appearance)
                } header: {
                    sectionHeader("Apariencia", systemImage: "paintpalette.fill")
                } footer: {
                    Text("Elige el tema. \"Automático\" sigue la configuración del sistema.")
                }

                accentColorSection

                Section {
                    NavigationLink {
                        CategoryManagementView()
                    } label: {
                        Label("Categorías", systemImage: "tag.fill")
                    }
                } header: {
                    sectionHeader("Categorías", systemImage: "square.grid.2x2.fill")
                } footer: {
                    Text("Crea categorías propias con su color y emoji o ícono.")
                }

                Section {
                    languagePicker(selection: $settings.language)
                } header: {
                    sectionHeader("Idioma", systemImage: "character.bubble.fill")
                } footer: {
                    Text("El idioma de la app. \"Automático\" sigue el idioma de tu iPhone.")
                }

                Section {
                    Picker(selection: $settings.snoozeInterval) {
                        ForEach(SnoozeInterval.allCases) { value in
                            Text(value.localizedTitle).tag(value)
                        }
                    } label: {
                        Label("Intervalo de snooze", systemImage: "zzz")
                    }
                    .pickerStyle(.menu)
                } header: {
                    sectionHeader("Posponer", systemImage: "moon.zzz.fill")
                } footer: {
                    Text("Tiempo entre repeticiones cuando pospones una alarma.")
                }

                Section {
                    Toggle(isOn: $settings.teamsDetectionEnabled) {
                        Label("Programar alarmas para eventos del calendario", systemImage: "calendar.badge.clock")
                    }
                    .onChange(of: settings.teamsDetectionEnabled) { _, newValue in
                        Haptics.selection()
                        onTeamsToggleChanged(newValue)
                    }
                } header: {
                    sectionHeader("Calendario de Apple", systemImage: "calendar")
                } footer: {
                    Text("Cuando esté activo, Calarm leerá los eventos de tu app Calendario y programará una alarma 10 minutos antes de cada uno. Si el evento tiene un enlace de Microsoft Teams, aparecerá un botón para unirte.")
                }

                Section {
                    LabeledContent {
                        HStack(spacing: DS.Spacing.xs) {
                            Circle()
                                .fill(authorizationStatusColor)
                                .frame(width: 8, height: 8)
                            Text(authorizationStatusText)
                                .foregroundStyle(authorizationStatusColor)
                                .font(.subheadline.weight(.medium))
                        }
                    } label: {
                        Label("Permiso de alarmas", systemImage: "lock.shield.fill")
                    }

                    Button {
                        Task { await runTestAlarm() }
                    } label: {
                        if isSchedulingTest {
                            HStack {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Programando…")
                            }
                        } else {
                            Label("Probar alarma en 1 minuto", systemImage: "bell.badge.fill")
                                .symbolEffect(.bounce, options: .nonRepeating, value: testAlarmResult.map { _ in true })
                        }
                    }
                    .disabled(isSchedulingTest)

                    if let testAlarmResult {
                        switch testAlarmResult {
                        case .success(let msg):
                            Label(msg, systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        case .failure(let msg):
                            Label(msg, systemImage: "xmark.octagon.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                } header: {
                    sectionHeader("Diagnóstico", systemImage: "stethoscope")
                }

                Section {
                    LabeledContent {
                        Text(Bundle.main.shortVersion)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } label: {
                        Label("Versión", systemImage: "info.circle")
                    }
                } header: {
                    sectionHeader("Acerca de", systemImage: "sparkles")
                } footer: {
                    Text("Calarm es una app de alarmas para eventos personales: cumpleaños, aniversarios, recordatorios y más.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Ajustes")
            .animation(DS.Motion.snappy, value: testAlarmResult.map { _ in true })
            .animation(DS.Motion.snappy, value: alarmScheduler.authorizationState)
        }
    }

    /// Lets the user pick the app's accent color: a curated palette plus a
    /// free ColorPicker, with a reset to the default. Only tints app chrome —
    /// categories keep their own colors.
    @ViewBuilder
    private var accentColorSection: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.md), count: 5)
        let currentHex = (settings.accentColorHex ?? AppSettings.accentPresets[0]).uppercased()
        Section {
            LazyVGrid(columns: columns, spacing: DS.Spacing.md) {
                ForEach(AppSettings.accentPresets, id: \.self) { hex in
                    let isSelected = hex.uppercased() == currentHex
                    Button {
                        withAnimation(DS.Motion.snappy) {
                            settings.accentColorHex = (hex == AppSettings.accentPresets[0]) ? nil : hex
                        }
                        Haptics.selection()
                    } label: {
                        Circle()
                            .fill(Color(hex: hex) ?? .accentColor)
                            .frame(width: 34, height: 34)
                            .overlay {
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .overlay {
                                Circle().strokeBorder(.primary.opacity(isSelected ? 0.5 : 0), lineWidth: 2)
                            }
                            .scaleEffect(isSelected ? 1.12 : 1.0)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, DS.Spacing.xs)

            ColorPicker(selection: accentColorBinding, supportsOpacity: false) {
                Label("Personalizado", systemImage: "eyedropper.halffull")
            }

            if settings.accentColorHex != nil {
                Button(role: .destructive) {
                    withAnimation(DS.Motion.snappy) { settings.accentColorHex = nil }
                    Haptics.light()
                } label: {
                    Label("Restablecer color", systemImage: "arrow.uturn.backward")
                }
            }
        } header: {
            sectionHeader("Color de la app", systemImage: "paintbrush.fill")
        } footer: {
            Text("Tinta botones, acentos y resaltados. Las categorías mantienen sus propios colores.")
        }
    }

    private var accentColorBinding: Binding<Color> {
        Binding(
            get: { settings.accentColor },
            set: { settings.accentColorHex = $0.toHex() }
        )
    }

    private func sectionHeader(_ title: LocalizedStringKey, systemImage: String) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: systemImage)
                .font(.caption2)
            Text(title)
        }
    }

    /// Visual segmented picker for language. Same layout as the appearance
    /// picker so the two settings feel consistent.
    private func languagePicker(selection: Binding<AppLanguage>) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            ForEach(AppLanguage.allCases) { language in
                let isSelected = selection.wrappedValue == language
                Button {
                    withAnimation(DS.Motion.snappy) {
                        selection.wrappedValue = language
                    }
                    Haptics.selection()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: language.flag)
                            .font(.title3)
                            .symbolEffect(.bounce, options: .nonRepeating, value: isSelected)
                        Text(language.localizedTitle)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Spacing.md)
                    .foregroundStyle(isSelected ? .white : .primary)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                            .fill(isSelected ? Color.appAccent : Color.dsFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color.appAccent : Color.clear,
                                lineWidth: 1.5
                            )
                    )
                    .scaleEffect(isSelected ? 1.03 : 1.0)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, DS.Spacing.xs)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: DS.Spacing.lg, bottom: 0, trailing: DS.Spacing.lg))
    }

    /// Visual segmented picker for appearance mode — each option has an icon
    /// so the choice is recognizable at a glance without reading the label.
    private func appearancePicker(selection: Binding<AppearanceMode>) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            ForEach(AppearanceMode.allCases) { mode in
                let isSelected = selection.wrappedValue == mode
                Button {
                    withAnimation(DS.Motion.snappy) {
                        selection.wrappedValue = mode
                    }
                    Haptics.selection()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: mode.systemImage)
                            .font(.title3)
                            .symbolEffect(.bounce, options: .nonRepeating, value: isSelected)
                        Text(mode.localizedTitle)
                            .font(.caption.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Spacing.md)
                    .foregroundStyle(isSelected ? .white : .primary)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                            .fill(isSelected ? Color.appAccent : Color.dsFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color.appAccent : Color.clear,
                                lineWidth: 1.5
                            )
                    )
                    .scaleEffect(isSelected ? 1.03 : 1.0)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, DS.Spacing.xs)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: DS.Spacing.lg, bottom: 0, trailing: DS.Spacing.lg))
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
        Haptics.light()
        defer { isSchedulingTest = false }
        _ = try? await alarmScheduler.requestAuthorization()
        do {
            let id = try await alarmScheduler.scheduleTestAlarm(in: 60)
            testAlarmResult = .success("Programada (\(id.uuidString.prefix(8))…). Suena en 1 minuto.")
            Haptics.success()
        } catch {
            let ns = error as NSError
            testAlarmResult = .failure("\(ns.domain) code \(ns.code): \(ns.localizedDescription)")
            Haptics.error()
        }
    }
}

private extension Bundle {
    var shortVersion: String {
        (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
    }
}
