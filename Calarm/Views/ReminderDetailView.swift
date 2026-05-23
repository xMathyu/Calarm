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
            HStack(spacing: DS.Spacing.lg) {
                ZStack {
                    RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    reminder.category.tint.opacity(0.30),
                                    reminder.category.tint.opacity(0.12)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 64, height: 64)
                    if reminder.iconKind == .photo,
                       let data = reminder.photoData,
                       let img = UIImage(data: data) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                    } else {
                        Image(systemName: reminder.symbolName ?? reminder.category.defaultSymbol)
                            .font(.title)
                            .foregroundStyle(reminder.category.tint)
                            .symbolEffect(.bounce, options: .nonRepeating)
                    }
                }
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text(reminder.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Label(reminder.category.localizedTitle, systemImage: reminder.category.defaultSymbol)
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, 3)
                        .foregroundStyle(reminder.category.tint)
                        .background(reminder.category.tint.opacity(0.13), in: Capsule())
                    if reminder.isReceivedShare {
                        Label("Compartido contigo", systemImage: "person.2.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, DS.Spacing.xs)
        }
    }

    @ViewBuilder
    private var detailsSection: some View {
        Section {
            detailRow(icon: "calendar", title: "Fecha",
                      value: reminder.date.formatted(date: .long, time: .omitted))
            detailRow(icon: "clock", title: "Hora",
                      value: reminder.date.formatted(date: .omitted, time: .shortened))
            detailRow(icon: "repeat", title: "Recurrencia",
                      value: reminder.recurrence.localizedSummary)
            detailRow(icon: "bell.badge", title: "Aviso",
                      value: reminder.leadTime.shortTitle)
            if let notes = reminder.notes, !notes.isEmpty {
                detailRow(icon: "note.text", title: "Notas",
                          value: notes, allowsMultiline: true)
            }
            detailRow(
                icon: reminder.isEnabled ? "bell.fill" : "bell.slash.fill",
                title: "Alarma",
                value: reminder.isEnabled
                    ? String(localized: "Activa")
                    : String(localized: "Inactiva"),
                valueColor: reminder.isEnabled ? .green : .secondary
            )
        } header: {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "info.circle.fill")
                    .font(.caption2)
                Text("Detalles")
            }
        }
    }

    private func detailRow(icon: String, title: LocalizedStringKey, value: String, valueColor: Color = .primary, allowsMultiline: Bool = false) -> some View {
        LabeledContent {
            Text(value)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(allowsMultiline ? nil : 1)
        } label: {
            Label(title, systemImage: icon)
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
