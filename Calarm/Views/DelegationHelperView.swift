//
//  DelegationHelperView.swift
//  Calarm
//
//  Helper-side UI: lists the alarm lists this user has been trusted to manage and
//  lets them create/edit/delete alarms FOR that person. Everything is read/written
//  directly in the shared CloudKit zone — never inserted into the helper's own
//  store — so delegated alarms never ring on the helper's phone.
//

import CloudKit
import SwiftUI

struct DelegationHelperView: View {
    @Environment(DelegationService.self) private var delegation

    @State private var principals: [DelegationPrincipal] = []
    @State private var isLoading = true

    var body: some View {
        List {
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if principals.isEmpty {
                ContentUnavailableView(
                    "Sin listas para administrar",
                    systemImage: "person.2.slash",
                    description: Text("Cuando alguien te invite como persona de confianza y aceptes la invitación, sus alarmas aparecerán aquí.")
                )
            } else {
                ForEach(principals) { principal in
                    NavigationLink {
                        DelegationPrincipalAlarmsView(principal: principal)
                    } label: {
                        Label(principal.name, systemImage: "person.crop.circle.badge.checkmark")
                    }
                }
            }
        }
        .navigationTitle("Listas que administro")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .calarmSharedDataChanged)) { _ in
            Task { await reload() }
        }
    }

    private func reload() async {
        principals = await delegation.helperPrincipals()
        isLoading = false
    }
}

/// The alarms of one principal, fully editable by the helper.
struct DelegationPrincipalAlarmsView: View {
    @Environment(DelegationService.self) private var delegation
    let principal: DelegationPrincipal

    @State private var reminders: [DelegatedReminder] = []
    @State private var editorTarget: EditorTarget?
    @State private var isLoading = true

    enum EditorTarget: Identifiable {
        case new
        case existing(DelegatedReminder)
        var id: String {
            switch self {
            case .new: return "new"
            case .existing(let item): return item.id.uuidString
            }
        }
    }

    var body: some View {
        List {
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if reminders.isEmpty {
                ContentUnavailableView(
                    "Sin alarmas",
                    systemImage: "bell.slash",
                    description: Text("Toca + para crear una alarma para \(principal.name).")
                )
            } else {
                ForEach(reminders) { item in
                    Button {
                        editorTarget = .existing(item)
                    } label: {
                        HStack(spacing: DS.Spacing.md) {
                            ReminderIconView(
                                iconKind: ReminderIconKind(rawValue: item.payload.iconKindRaw) ?? .symbol,
                                iconValue: item.payload.symbolName,
                                photoData: item.payload.photoThumbnail,
                                tint: (ReminderCategory(rawValue: item.payload.categoryRaw) ?? .event).tint,
                                size: 36,
                                shape: .roundedRect(8)
                            )
                            .opacity(item.isEnabled ? 1 : 0.45)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                                Text(item.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await delete(item) }
                        } label: { Label("Borrar", systemImage: "trash") }
                    }
                }
            }
        }
        .navigationTitle(principal.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editorTarget = .new } label: { Image(systemName: "plus") }
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .calarmSharedDataChanged)) { _ in
            Task { await reload() }
        }
        .sheet(item: $editorTarget, onDismiss: { Task { await reload() } }) { target in
            switch target {
            case .new:
                DelegationHelperEditorView(principal: principal, existing: nil)
            case .existing(let item):
                DelegationHelperEditorView(principal: principal, existing: item)
            }
        }
    }

    private func reload() async {
        reminders = await delegation.helperFetchReminders(in: principal.zoneID)
        isLoading = false
    }

    private func delete(_ item: DelegatedReminder) async {
        await delegation.helperDelete(recordID: item.recordID)
        Haptics.warning()
        await reload()
    }
}
