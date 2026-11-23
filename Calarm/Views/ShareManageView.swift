//
//  ShareManageView.swift
//  Calarm
//
//  «Gestionar compartido» de una alarma o cuenta regresiva: quién la tiene,
//  quitar a alguien y dejar de compartir. Sustituye a la hoja de iCloud
//  (`UICloudSharingController`), que solo sabe de un `CKShare`: lo compartido
//  ahora vive en Firestore (y quien entró por una invitación de antes de la 1.1
//  sigue en el `CKShare`; los dos salen en la misma lista).
//

import CloudKit
import SwiftUI

struct ShareManageView: View {
    @Environment(SharedRemindersService.self) private var sharedService
    @Environment(\.dismiss) private var dismiss

    let itemID: UUID
    /// Vuelve a leer quién la tiene (después de quitar a alguien).
    let load: () async -> SharedRemindersService.ShareOverview

    @State private var overview: SharedRemindersService.ShareOverview
    @State private var confirmingStop = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    init(
        itemID: UUID,
        overview: SharedRemindersService.ShareOverview,
        load: @escaping () async -> SharedRemindersService.ShareOverview
    ) {
        self.itemID = itemID
        self.load = load
        self._overview = State(initialValue: overview)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if overview.people.isEmpty {
                        Text("Aún no se ha unido nadie.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(overview.people) { person in
                            row(person)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        Task { await remove(person) }
                                    } label: {
                                        Label("Quitar", systemImage: "person.fill.xmark")
                                    }
                                }
                        }
                    }
                } header: {
                    HStack(spacing: DS.Spacing.xs) {
                        Image(systemName: "person.2.fill").font(.caption2)
                        Text("Personas")
                    }
                } footer: {
                    if !overview.people.isEmpty {
                        Text("Desliza a la izquierda sobre una persona para quitarla.")
                    }
                }

                if overview.isShared {
                    Section {
                        Button(role: .destructive) {
                            Haptics.light()
                            confirmingStop = true
                        } label: {
                            HStack {
                                Label("Dejar de compartir", systemImage: "xmark.circle")
                                Spacer()
                                if isWorking { ProgressView() }
                            }
                        }
                        .disabled(isWorking)
                    } footer: {
                        Text("Quienes la tienen dejarán de recibirla. Tu copia se queda.")
                    }
                }
            }
            .navigationTitle(appLocalized("Gestionar compartido"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
            .refreshable { overview = await load() }
            .confirmationDialog(
                appLocalized("¿Dejar de compartir?"),
                isPresented: $confirmingStop,
                titleVisibility: .visible
            ) {
                Button(appLocalized("Dejar de compartir"), role: .destructive) {
                    Task { await stopSharing() }
                }
            } message: {
                Text("Quienes la tienen dejarán de recibirla. Tu copia se queda.")
            }
            .alert("Error al compartir", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func row(_ person: ShareParticipantInfo) -> some View {
        HStack(spacing: DS.Spacing.md) {
            PersonAvatarView(name: person.name, email: person.email, phone: person.phone, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(person.statusLabel)
                    .font(.caption)
                    .foregroundStyle(person.status == .accepted ? .green : .secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func remove(_ person: ShareParticipantInfo) async {
        do {
            try await sharedService.removeParticipant(person, from: overview, id: itemID)
            Haptics.warning()
        } catch {
            errorMessage = error.localizedDescription
        }
        overview = await load()
    }

    private func stopSharing() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await sharedService.stopSharing(id: itemID, overview: overview)
            Haptics.warning()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            overview = await load()
        }
    }
}
