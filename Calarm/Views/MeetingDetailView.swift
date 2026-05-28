//
//  MeetingDetailView.swift
//  Calarm
//

import SwiftUI

struct MeetingDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(MeetingPreferencesStore.self) private var preferences
    @Environment(SyncCoordinator.self) private var coordinator

    let meeting: Meeting

    @State private var leadTimes: [AlarmLeadTime] = []
    @State private var isEnabled: Bool = true
    @State private var showingPicker = false
    @State private var hasLoaded = false

    private var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        f.locale = LocalizationManager.shared.currentLocale
        return f
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Inicio") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(dateFormatter.string(from: meeting.startDate))
                                .multilineTextAlignment(.trailing)
                            Text("hasta \(Self.timeFormatter.string(from: meeting.endDate))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let organizer = meeting.organizer {
                        LabeledContent("Organizador", value: organizer)
                    }
                    if let location = meeting.location, !location.isEmpty, meeting.teamsURL == nil {
                        Button {
                            openMaps(query: location)
                        } label: {
                            LabeledContent("Ubicación") {
                                HStack(spacing: 4) {
                                    Text(location)
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.caption)
                                }
                                .foregroundStyle(.tint)
                                .multilineTextAlignment(.trailing)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(meeting.title).font(.headline).textCase(nil)
                }

                if let teamsURL = meeting.teamsURL {
                    Section {
                        Button {
                            openURL(teamsURL)
                        } label: {
                            Label("Unirse en Teams", systemImage: "video.fill")
                        }
                    }
                }

                Section {
                    Toggle("Alarma activa", isOn: $isEnabled)
                } footer: {
                    Text("Cuando esté apagado, esta alarma no sonará aunque tengas avisos configurados.")
                }

                Section {
                    if leadTimes.isEmpty {
                        Text("Sin avisos. Esta alarma no sonará.")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    } else {
                        ForEach(leadTimes) { value in
                            HStack {
                                Image(systemName: "bell.fill")
                                    .foregroundStyle(isEnabled ? Color.appAccent : Color.secondary)
                                Text(value.localizedTitle)
                                    .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                                Spacer()
                                Text(Self.timeFormatter.string(from: meeting.startDate.addingTimeInterval(-value.seconds)))
                                    .foregroundStyle(.secondary)
                                    .font(.subheadline)
                            }
                        }
                        .onDelete { offsets in
                            leadTimes.remove(atOffsets: offsets)
                        }
                    }
                    if leadTimes.count < MeetingPreferencesStore.maxAlarmsPerEvent {
                        Button {
                            showingPicker = true
                        } label: {
                            Label("Agregar aviso", systemImage: "plus.circle.fill")
                        }
                    }
                } header: {
                    Text("Avisos (máximo \(MeetingPreferencesStore.maxAlarmsPerEvent))")
                } footer: {
                    Text("La alarma sonará en cada uno de estos momentos antes del inicio del evento. Si el evento tiene ubicación, en la alarma aparecerá un botón ‘Ir’ que la detiene y abre Maps con direcciones.")
                }

                if preferences.hasOverride(forEventID: meeting.id) {
                    Section {
                        Button(role: .destructive) {
                            preferences.resetToDefault(forEventID: meeting.id)
                            leadTimes = preferences.leadTimes(forEventID: meeting.id)
                            isEnabled = preferences.isEnabled(forEventID: meeting.id)
                        } label: {
                            Label("Restablecer al valor por defecto", systemImage: "arrow.uturn.backward")
                        }
                    }
                }
            }
            .navigationTitle("Evento")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Guardar") {
                        Task { await save() }
                    }
                    .bold()
                }
            }
            .sheet(isPresented: $showingPicker) {
                LeadTimePickerSheet(
                    excluded: Set(leadTimes),
                    onSelect: { picked in
                        leadTimes.append(picked)
                        leadTimes.sort { $0.rawValue < $1.rawValue }
                    }
                )
                .presentationDetents([.medium])
            }
        }
        .onAppear {
            guard !hasLoaded else { return }
            leadTimes = preferences.leadTimes(forEventID: meeting.id)
            isEnabled = preferences.isEnabled(forEventID: meeting.id)
            hasLoaded = true
        }
    }

    private func openMaps(query: String) {
        guard
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
            let url = URL(string: "http://maps.apple.com/?q=\(encoded)&dirflg=d")
        else { return }
        openURL(url)
    }

    private func save() async {
        preferences.setLeadTimes(leadTimes, enabled: isEnabled, forEventID: meeting.id)
        await coordinator.sync()
        Haptics.success()
        dismiss()
    }
}

