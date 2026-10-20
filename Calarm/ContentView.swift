//
//  ContentView.swift
//  Calarm
//

import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(AppSettings.self) private var settings

    let alarmScheduler: AlarmScheduler
    let onTeamsToggleChanged: (Bool) -> Void
    let teamsCoordinatorProvider: () -> SyncCoordinator?
    /// Reprograma las alarmas propias cuando un ajuste cambia la hora a la que
    /// el sistema tiene que recibirlas (hoy, la cuenta regresiva).
    let onCountdownChanged: () -> Void

    enum TabID: String, Hashable {
        case alarms, calendar, assistant, settings
    }

    @State private var selection: TabID = .alarms

    #if DEBUG
    // Screenshot runs open a screen directly with `-demoScreen <name>`; see DemoData.
    @Query(sort: [SortDescriptor(\Reminder.date)]) private var demoReminders: [Reminder]
    @State private var demoTone: AlarmTone? = .marimba
    @State private var demoRecurrence: RecurrenceRule = .weekly(interval: 1, weekdays: [.monday, .wednesday])
    #endif

    var body: some View {
        TabView(selection: $selection) {
            Tab("Alarmas", systemImage: "bell.fill", value: TabID.alarms) {
                RemindersListView()
            }
            // Siempre visible: la vista de mes enseña las alarmas propias aunque
            // la lectura del calendario esté apagada (entonces va sin eventos).
            Tab("Calendario", systemImage: "calendar", value: TabID.calendar) {
                CalendarTabView(coordinator: teamsCoordinatorProvider())
            }
            Tab("Asistente", systemImage: "sparkles", value: TabID.assistant) {
                CalarmChatView()
            }
            Tab("Ajustes", systemImage: "gearshape", value: TabID.settings) {
                SettingsView(
                    alarmScheduler: alarmScheduler,
                    onTeamsToggleChanged: onTeamsToggleChanged,
                    teamsCoordinatorProvider: teamsCoordinatorProvider,
                    onCountdownChanged: onCountdownChanged
                )
            }
        }
        .sheet(isPresented: .constant(!settings.onboardingCompleted)) {
            OnboardingView(alarmScheduler: alarmScheduler)
        }
        .modifier(DemoScreenModifier(selection: $selection))
        .onReceive(NotificationCenter.default.publisher(for: .calarmOpenReminder)) { _ in
            selection = .alarms
        }
        #if DEBUG
        .sheet(isPresented: .constant(DemoData.requestedScreen == "editor")) {
            if let birthday = demoReminders.first(where: { $0.category == .birthday }) {
                ReminderEditorView(editing: birthday)
            }
        }
        .sheet(isPresented: .constant(DemoData.requestedScreen == "recurrence")) {
            NavigationStack {
                RecurrencePickerView(rule: $demoRecurrence, baseDate: Date())
            }
        }
        .sheet(isPresented: .constant(DemoData.requestedScreen == "tones")) {
            NavigationStack {
                TonePickerView(selection: $demoTone, fallback: .chime)
            }
        }
        .sheet(isPresented: .constant(DemoData.requestedScreen == "helpers")) {
            NavigationStack {
                DelegationSettingsView()
            }
        }
        #endif
    }
}

/// Selects the tab a screenshot run asked for. Does nothing in release builds.
private struct DemoScreenModifier: ViewModifier {
    @Binding var selection: ContentView.TabID

    func body(content: Content) -> some View {
        #if DEBUG
        content.task {
            switch DemoData.requestedScreen {
            case "calendar", "agenda": selection = .calendar
            case "assistant": selection = .assistant
            case "settings", "helpers": selection = .settings
            default: break
            }
        }
        #else
        content
        #endif
    }
}
