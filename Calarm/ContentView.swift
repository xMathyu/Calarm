//
//  ContentView.swift
//  Calarm
//

import SwiftUI

struct ContentView: View {
    @Environment(AppSettings.self) private var settings

    let alarmScheduler: AlarmScheduler
    let onTeamsToggleChanged: (Bool) -> Void
    let teamsCoordinatorProvider: () -> SyncCoordinator?

    var body: some View {
        TabView {
            Tab("Alarmas", systemImage: "bell.fill") {
                RemindersListView()
            }
            if settings.teamsDetectionEnabled, let coordinator = teamsCoordinatorProvider() {
                Tab("Teams", systemImage: "video.fill") {
                    MeetingsListView()
                        .environment(coordinator)
                }
            }
            Tab("Ajustes", systemImage: "gearshape") {
                SettingsView(
                    alarmScheduler: alarmScheduler,
                    onTeamsToggleChanged: onTeamsToggleChanged
                )
            }
        }
        .sheet(isPresented: .constant(!settings.onboardingCompleted)) {
            OnboardingView(alarmScheduler: alarmScheduler)
        }
    }
}
