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
            if settings.teamsDetectionEnabled, let coordinator = teamsCoordinatorProvider() {
                Tab("Calendario", systemImage: "calendar", value: TabID.calendar) {
                    MeetingsListView()
                        .environment(coordinator)
                }
            }
            Tab("Asistente", systemImage: "sparkles", value: TabID.assistant) {
                CalarmChatView()
            }
            Tab("Ajustes", systemImage: "gearshape", value: TabID.settings) {
                SettingsView(
                    alarmScheduler: alarmScheduler,
                    onTeamsToggleChanged: onTeamsToggleChanged
                )
            }
        }
        .sheet(isPresented: .constant(!settings.onboardingCompleted)) {
            OnboardingView(alarmScheduler: alarmScheduler)
        }
        .modifier(DemoScreenModifier(selection: $selection))
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
            case "calendar": selection = .calendar
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
