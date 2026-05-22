//
//  MeetingsListView.swift
//  Calarm
//

import SwiftUI

struct MeetingsListView: View {
    @Environment(SyncCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var settings
    @Environment(MeetingPreferencesStore.self) private var preferences

    @State private var selectedMeeting: Meeting?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Calendario")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await coordinator.sync() }
                        } label: {
                            if coordinator.isSyncing {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .accessibilityLabel("Actualizar")
                    }
                }
                .refreshable {
                    await coordinator.sync()
                }
                .sheet(item: $selectedMeeting) { meeting in
                    MeetingDetailView(meeting: meeting)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if coordinator.meetings.isEmpty {
            EmptyStateView(
                systemImage: "calendar.badge.exclamationmark",
                title: "Sin eventos próximos",
                message: "Cuando tengas eventos agendados en tu app Calendario aparecerán aquí con su alarma programada.",
                actionTitle: "Actualizar"
            ) {
                Task { await coordinator.sync() }
            }
        } else {
            List {
                ForEach(groupedMeetings, id: \.day) { group in
                    Section {
                        ForEach(group.meetings) { meeting in
                            Button {
                                selectedMeeting = meeting
                            } label: {
                                MeetingRowView(
                                    meeting: meeting,
                                    leadTimes: preferences.leadTimes(forEventID: meeting.id),
                                    alarmsEnabled: settings.alarmsEnabled
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text(headerTitle(for: group.day))
                    }
                }
            }
            .listStyle(.insetGrouped)
            // Trigger view refresh when preferences change.
            .id(preferences.revision)
        }
    }

    private struct MeetingGroup {
        let day: Date
        let meetings: [Meeting]
    }

    private var groupedMeetings: [MeetingGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: coordinator.meetings) { meeting in
            calendar.startOfDay(for: meeting.startDate)
        }
        return grouped.keys.sorted().map { day in
            MeetingGroup(day: day, meetings: grouped[day]?.sorted(by: { $0.startDate < $1.startDate }) ?? [])
        }
    }

    private func headerTitle(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Hoy" }
        if calendar.isDateInTomorrow(day) { return "Mañana" }
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.locale = Locale(identifier: "es_ES")
        return formatter.string(from: day).capitalized
    }
}
