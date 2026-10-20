//
//  CalendarTabView.swift
//  Calarm
//
//  La pestaña Calendario: por defecto la vista de mes (alarmas propias y
//  eventos del calendario del sistema juntos) y, cuando la lectura del
//  calendario está encendida, la lista de eventos próximos de siempre detrás
//  de un botón. Cada modo pone sus propios botones en la barra.
//

import SwiftUI

struct CalendarTabView: View {
    /// `nil` mientras «Programar alarmas para eventos del calendario» esté
    /// apagado: entonces solo hay vista de mes, sin eventos.
    let coordinator: SyncCoordinator?

    enum Mode: String {
        case month
        case agenda
    }

    /// Dónde se guarda el modo elegido; `DemoData` lo escribe para abrir la
    /// lista directamente en las capturas.
    static let modeDefaultsKey = "calendar.viewMode"

    @AppStorage(CalendarTabView.modeDefaultsKey) private var storedMode: String = Mode.month.rawValue

    private var mode: Binding<Mode> {
        Binding(
            get: { Mode(rawValue: storedMode) ?? .month },
            set: { storedMode = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if mode.wrappedValue == .agenda, let coordinator {
                    MeetingsListView(mode: mode)
                        .environment(coordinator)
                } else {
                    MonthCalendarView(coordinator: coordinator, mode: mode)
                }
            }
            .navigationTitle("Calendario")
        }
    }
}
