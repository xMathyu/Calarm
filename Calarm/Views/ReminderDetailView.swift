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
    @Environment(CategoryStore.self) private var categoryStore

    let reminder: Reminder

    private var style: CategoryStyle { categoryStore.style(for: reminder) }

    @State private var showingEditor = false
    @State private var isPreparingShare = false
    @State private var pendingInvite: InviteDelivery?
    /// The existing CloudKit share, if this reminder is already shared. Drives
    /// whether "Gestionar compartido" is offered.
    @State private var existingShare: CKShare?
    @State private var showingManageSheet = false
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
            // Single sheet: opens Messages with the link — same flow as create.
            .inviteDelivery($pendingInvite) {
                Task { await refreshShare() }
            }
            // Native CloudKit management sheet (add/remove people, permissions,
            // stop sharing) — only reachable once a share exists.
            .sheet(isPresented: $showingManageSheet, onDismiss: { Task { await refreshShare() } }) {
                if let share = existingShare {
                    CloudSharingView(
                        share: share,
                        container: CKContainer(identifier: sharedService.containerIdentifier)
                    ) { showingManageSheet = false }
                }
            }
            .task { await refreshShare() }
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
                ReminderIconView(
                    iconKind: reminder.iconKind,
                    iconValue: reminder.symbolName,
                    photoData: reminder.photoData,
                    fallbackSymbol: style.iconKind == .symbol ? style.iconValue : "bell.fill",
                    tint: style.color,
                    size: 64,
                    shape: .roundedRect(DS.Radius.md)
                )
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text(reminder.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    HStack(spacing: 4) {
                        CategoryGlyph(iconKind: style.iconKind, iconValue: style.iconValue)
                        Text(style.title)
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, 3)
                    .foregroundStyle(style.color)
                    .background(style.color.opacity(0.13), in: Capsule())
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
                      value: reminder.leadTimes
                        .map(\.shortTitle)
                        .joined(separator: " · "))
            if let notes = reminder.notes, !notes.isEmpty {
                detailRow(icon: "note.text", title: "Notas",
                          value: notes, allowsMultiline: true)
            }
            detailRow(
                icon: reminder.isEnabled ? "bell.fill" : "bell.slash.fill",
                title: "Alarma",
                value: reminder.isEnabled
                    ? appLocalized("Activa")
                    : appLocalized("Inactiva"),
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
        Section {
            Button {
                Haptics.light()
                Task { await invite() }
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

            // Only offered once the reminder is actually shared — lets the owner
            // manage participants, permissions, or stop sharing.
            if existingShare != nil {
                Button {
                    Haptics.light()
                    showingManageSheet = true
                } label: {
                    Label("Gestionar compartido", systemImage: "person.2.badge.gearshape")
                }
            }
        } header: {
            Text("Compartir")
        }
    }

    /// Prepares the share and opens Messages with the link — recipients are
    /// chosen in Messages, so this is a single sheet.
    @MainActor
    private func invite() async {
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            let share = try await sharedService.prepareShare(for: reminder)
            existingShare = share
            guard let url = share.url else {
                errorMessage = SharedRemindersError.shareUnavailable.errorDescription
                return
            }
            pendingInvite = InviteDelivery(title: reminder.title, url: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Refreshes whether this reminder currently has a share (without creating one).
    @MainActor
    private func refreshShare() async {
        existingShare = await sharedService.existingShare(for: reminder)
    }
}
