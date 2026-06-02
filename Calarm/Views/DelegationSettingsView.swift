//
//  DelegationSettingsView.swift
//  Calarm
//
//  Principal-side UI for "Personas de confianza": turn delegation on/off, invite
//  trusted helpers (read/write to the whole alarm list), and revoke them.
//

import CloudKit
import SwiftUI

struct DelegationSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DelegationService.self) private var delegation

    /// Wraps a CKShare so it can drive `.sheet(item:)` (CKShare isn't Identifiable).
    private struct SharePresentation: Identifiable { let id = UUID(); let share: CKShare }

    @State private var participants: [ShareParticipantInfo] = []
    @State private var shareToPresent: SharePresentation?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showingDisableConfirm = false

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { settings.delegationEnabled },
                    set: { newValue in
                        if newValue { enable() } else { showingDisableConfirm = true }
                    }
                )) {
                    Label("Permitir personas de confianza", systemImage: "person.2.badge.key.fill")
                }
                .disabled(isWorking)
            } header: {
                sectionHeader("Delegación", systemImage: "person.badge.key.fill")
            } footer: {
                Text("Las personas que invites podrán ver, crear, editar y borrar TODAS tus alarmas en tu nombre. Lo que ellas programen sonará en tu teléfono. Tú puedes revocar el acceso en cualquier momento.")
            }

            if settings.delegationEnabled {
                Section {
                    Button {
                        Haptics.light()
                        invite()
                    } label: {
                        HStack {
                            Label("Invitar persona de confianza", systemImage: "person.badge.plus")
                            Spacer()
                            if isWorking { ProgressView() }
                        }
                    }
                    .disabled(isWorking)
                } footer: {
                    Text("Comparte el enlace por Mensajes. Al aceptarlo, esa persona podrá administrar tus alarmas.")
                }

                Section {
                    if participants.isEmpty {
                        Text("Aún no has invitado a nadie.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(participants) { person in
                            HStack(spacing: DS.Spacing.md) {
                                PersonAvatarView(name: person.name, email: person.email, phone: person.phone, size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(person.name).font(.subheadline).lineLimit(1)
                                    Text(person.statusLabel)
                                        .font(.caption)
                                        .foregroundStyle(person.status == .accepted ? .green : .secondary)
                                }
                                Spacer()
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await revoke(person) }
                                } label: { Label("Revocar", systemImage: "person.fill.xmark") }
                            }
                        }
                    }
                } header: {
                    HStack(spacing: DS.Spacing.xs) {
                        Image(systemName: "person.2.fill").font(.caption2)
                        Text("Personas con acceso")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Personas de confianza")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshParticipants() }
        .sheet(item: $shareToPresent, onDismiss: { Task { await refreshParticipants() } }) { presentation in
            CloudSharingView(
                share: presentation.share,
                container: CKContainer(identifier: delegation.containerIdentifier),
                availablePermissions: [.allowPrivate, .allowReadWrite]
            ) { shareToPresent = nil }
        }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .confirmationDialog(
            "¿Desactivar delegación?",
            isPresented: $showingDisableConfirm,
            titleVisibility: .visible
        ) {
            Button("Desactivar", role: .destructive) { disable() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Tus personas de confianza dejarán de ver y administrar tus alarmas. Tus alarmas siguen intactas.")
        }
    }

    private func enable() {
        isWorking = true
        Task {
            do {
                _ = try await delegation.prepareZoneShare()
                await delegation.mirrorAllLocalReminders()
                settings.delegationEnabled = true
                await refreshParticipants()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func invite() {
        isWorking = true
        Task {
            do {
                let share = try await delegation.prepareZoneShare()
                shareToPresent = SharePresentation(share: share)
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func disable() {
        Task {
            await delegation.disableDelegation()
            settings.delegationEnabled = false
            participants = []
        }
    }

    private func revoke(_ person: ShareParticipantInfo) async {
        await delegation.removeHelper(email: person.email, phone: person.phone)
        await refreshParticipants()
        Haptics.warning()
    }

    private func refreshParticipants() async {
        guard settings.delegationEnabled else { participants = []; return }
        participants = await delegation.participantInfos()
    }

    private func sectionHeader(_ title: LocalizedStringKey, systemImage: String) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: systemImage).font(.caption2)
            Text(title)
        }
    }
}
