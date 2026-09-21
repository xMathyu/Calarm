//
//  CalendarPickerView.swift
//  Calarm
//

import SwiftUI

/// Elige qué calendarios mira Calarm. Mientras "Todos los calendarios" esté
/// activo no se guarda ninguna selección (`selectedCalendarIDs` = nil), que es
/// como se comportaba la app antes de que esto existiera y lo que hace que un
/// calendario nuevo entre solo.
struct CalendarPickerView: View {
    @Environment(AppSettings.self) private var settings

    /// Los calendarios del sistema. Llega como closure porque el coordinador del
    /// calendario solo existe cuando la sincronización está encendida.
    let load: () async -> [CalendarInfo]
    /// Se llama al cambiar la selección, para reprogramar las alarmas.
    let onChange: () -> Void

    @State private var calendars: [CalendarInfo] = []
    @State private var hasLoaded = false

    private var groups: [(source: String, calendars: [CalendarInfo])] {
        Dictionary(grouping: calendars, by: \.sourceTitle)
            .map { (source: $0.key, calendars: $0.value.sorted { $0.title < $1.title }) }
            .sorted { $0.source < $1.source }
    }

    private var isAllSelected: Bool { settings.selectedCalendarIDs == nil }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: allBinding) {
                    Label("Todos los calendarios", systemImage: "calendar")
                }
            } footer: {
                Text(isAllSelected
                     ? "Calarm mira todos tus calendarios, incluidos los que agregues después."
                     : "Solo suenan los eventos de los calendarios marcados.")
            }

            if !isAllSelected {
                if calendars.isEmpty && hasLoaded {
                    Section {
                        Text("No encontré calendarios en este iPhone.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(groups, id: \.source) { group in
                    Section {
                        ForEach(group.calendars) { calendar in
                            row(for: calendar)
                        }
                    } header: {
                        Text(group.source.isEmpty ? "Otros" : group.source)
                            .textCase(nil)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Calendarios")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !hasLoaded else { return }
            calendars = await load()
            hasLoaded = true
        }
    }

    @ViewBuilder
    private func row(for calendar: CalendarInfo) -> some View {
        let isOn = settings.selectedCalendarIDs?.contains(calendar.id) ?? true
        Button {
            toggle(calendar)
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Circle()
                    .fill(calendar.colorHex.flatMap(Color.init(hex:)) ?? .secondary)
                    .frame(width: 10, height: 10)
                Text(calendar.title)
                    .foregroundStyle(.primary)
                Spacer()
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.appAccent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Apagar "todos" congela la selección actual —todos los calendarios de hoy—
    /// para que nadie pierda una alarma solo por abrir esta pantalla.
    private var allBinding: Binding<Bool> {
        Binding(
            get: { isAllSelected },
            set: { wantsAll in
                withAnimation(DS.Motion.snappy) {
                    settings.selectedCalendarIDs = wantsAll ? nil : Set(calendars.map(\.id))
                }
                Haptics.selection()
                onChange()
            }
        )
    }

    private func toggle(_ calendar: CalendarInfo) {
        var current = settings.selectedCalendarIDs ?? Set(calendars.map(\.id))
        if current.contains(calendar.id) {
            current.remove(calendar.id)
        } else {
            current.insert(calendar.id)
        }
        withAnimation(DS.Motion.snappy) {
            settings.selectedCalendarIDs = current
        }
        Haptics.light()
        onChange()
    }
}
