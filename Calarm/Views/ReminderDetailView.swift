//
//  ReminderDetailView.swift
//  Calarm
//

import CloudKit
import SwiftData
import SwiftUI
import UIKit

struct ReminderDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SharedRemindersService.self) private var sharedService

    let reminder: Reminder

    @State private var showingEditor = false
    @State private var isPreparingShare = false
    @State private var preparedShare: CKShare?
    @State private var showingShareSheet = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                headerSection
                detailsSection
                if !reminder.isReceivedShare {
                    shareSection
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(reminder.title)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Editar") { showingEditor = true }
                }
            }
            .sheet(isPresented: $showingEditor) {
                ReminderEditorView(editing: reminder)
            }
            .sheet(isPresented: $showingShareSheet, onDismiss: { preparedShare = nil }) {
                if let share = preparedShare {
                    CloudSharingView(
                        share: share,
                        container: CKContainer(identifier: sharedService.containerIdentifier)
                    ) { showingShareSheet = false }
                }
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

    @ViewBuilder
    private var headerSection: some View {
        Section {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(reminder.category.tint.opacity(0.15))
                        .frame(width: 56, height: 56)
                    if reminder.iconKind == .photo,
                       let data = reminder.photoData,
                       let img = UIImage(data: data) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        Image(systemName: reminder.symbolName ?? reminder.category.defaultSymbol)
                            .font(.title2)
                            .foregroundStyle(reminder.category.tint)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(reminder.title)
                        .font(.headline)
                    Text(reminder.category.localizedTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if reminder.isReceivedShare {
                        Label("Compartido contigo", systemImage: "person.2.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var detailsSection: some View {
        Section("Detalles") {
            LabeledContent("Fecha", value: reminder.date.formatted(date: .long, time: .omitted))
            LabeledContent("Hora", value: reminder.date.formatted(date: .omitted, time: .shortened))
            LabeledContent("Recurrencia", value: reminder.recurrence.localizedSummary)
            LabeledContent("Aviso", value: reminder.leadTime.shortTitle)
            if let notes = reminder.notes, !notes.isEmpty {
                LabeledContent("Notas") {
                    Text(notes).multilineTextAlignment(.trailing)
                }
            }
            LabeledContent("Alarma", value: reminder.isEnabled ? "Activa" : "Inactiva")
        }
    }

    @ViewBuilder
    private var shareSection: some View {
        Section("Compartir") {
            Button {
                Task { await inviteFriends() }
            } label: {
                HStack {
                    Label("Invitar amigos", systemImage: "person.badge.plus")
                    Spacer()
                    if isPreparingShare {
                        ProgressView()
                    }
                }
            }
            .disabled(isPreparingShare)
        }
    }

    @MainActor
    private func inviteFriends() async {
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            preparedShare = try await sharedService.prepareShare(for: reminder)
            showingShareSheet = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
