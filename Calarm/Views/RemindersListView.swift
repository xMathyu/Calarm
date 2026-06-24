//
//  RemindersListView.swift
//  Calarm
//

import SwiftData
import SwiftUI

struct RemindersListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ReminderScheduler.self) private var reminderScheduler
    @Environment(SharedRemindersService.self) private var sharedService
    @Environment(DelegationService.self) private var delegation
    @Environment(AppSettings.self) private var settings

    @Query(sort: [SortDescriptor(\Reminder.date)]) private var reminders: [Reminder]

    @State private var showingNewEditor = false
    @State private var detailReminder: Reminder?
    @State private var filterCategories: Set<ReminderCategory> = []

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Alarmas")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Section {
                                ForEach(ReminderCategory.displayOrder) { category in
                                    Toggle(isOn: Binding(
                                        get: { filterCategories.contains(category) },
                                        set: { isOn in
                                            if isOn { filterCategories.insert(category) }
                                            else { filterCategories.remove(category) }
                                        }
                                    )) {
                                        Label(category.localizedTitle, systemImage: category.defaultSymbol)
                                    }
                                }
                                if !filterCategories.isEmpty {
                                    Button("Limpiar filtros") { filterCategories.removeAll() }
                                }
                            } header: {
                                Text("Filtrar")
                            }
                        } label: {
                            Image(systemName: filterCategories.isEmpty
                                  ? "line.3.horizontal.decrease.circle"
                                  : "line.3.horizontal.decrease.circle.fill")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Haptics.light()
                            showingNewEditor = true
                        } label: {
                            Image(systemName: "plus")
                                .symbolEffect(.bounce, options: .nonRepeating, value: showingNewEditor)
                        }
                    }
                }
                .sheet(isPresented: $showingNewEditor) {
                    ReminderEditorView(editing: nil)
                }
                .sheet(item: $detailReminder) { reminder in
                    ReminderDetailView(reminder: reminder)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        let visible = filteredReminders
        let shared = sharedWithMeReminders
        if visible.isEmpty && shared.isEmpty {
            EmptyStateView(
                systemImage: "bell.badge.fill",
                title: filterCategories.isEmpty ? "Sin alarmas" : "Sin resultados",
                message: filterCategories.isEmpty
                    ? "Toca + para crear tu primera alarma — cumpleaños, aniversario, recordatorio, lo que necesites."
                    : "Ningún recordatorio coincide con tus filtros.",
                actionTitle: filterCategories.isEmpty ? "Nueva alarma" : nil
            ) {
                showingNewEditor = true
            }
        } else {
            List {
                ForEach(groups(from: visible), id: \.title) { group in
                    Section {
                        ForEach(group.items, id: \.reminder.id) { item in
                            Button {
                                Haptics.light()
                                detailReminder = item.reminder
                            } label: {
                                ReminderRowView(
                                    reminder: item.reminder,
                                    nextOccurrence: item.nextOccurrence
                                )
                            }
                            .buttonStyle(.pressable)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { await delete(item.reminder) }
                                } label: { Label("Borrar", systemImage: "trash") }
                                Button {
                                    Task { await toggleEnabled(item.reminder) }
                                } label: {
                                    Label(item.reminder.isEnabled ? "Desactivar" : "Activar",
                                          systemImage: item.reminder.isEnabled ? "bell.slash" : "bell")
                                }
                                .tint(.orange)
                            }
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.95).combined(with: .opacity),
                                removal: .opacity
                            ))
                        }
                    } header: {
                        sectionHeader(title: group.title, count: group.items.count)
                    }
                }
                if !shared.isEmpty {
                    Section {
                        ForEach(shared) { reminder in
                            Button {
                                Haptics.light()
                                detailReminder = reminder
                            } label: {
                                ReminderRowView(
                                    reminder: reminder,
                                    nextOccurrence: nextOccurrence(for: reminder)
                                )
                            }
                            .buttonStyle(.pressable)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { await delete(reminder) }
                                } label: { Label("Borrar", systemImage: "trash") }
                            }
                        }
                    } header: {
                        sectionHeader(title: appLocalized("Compartidos conmigo"), count: shared.count, systemImage: "person.2.fill")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .animation(DS.Motion.smooth, value: reminders.count)
            .animation(DS.Motion.smooth, value: filterCategories)
        }
    }

    private func sectionHeader(title: String, count: Int, systemImage: String? = nil) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2)
            }
            Text(title)
            Text("\(count)")
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.dsFill, in: Capsule())
        }
    }

    private var ownedReminders: [Reminder] {
        reminders.filter { !$0.isReceivedShare }
    }

    private var sharedWithMeReminders: [Reminder] {
        reminders.filter { $0.isReceivedShare }
    }

    private var filteredReminders: [Reminder] {
        guard !filterCategories.isEmpty else { return ownedReminders }
        return ownedReminders.filter { filterCategories.contains($0.category) }
    }

    private func nextOccurrence(for reminder: Reminder) -> Date? {
        RecurrenceEngine.nextOccurrences(rule: reminder.recurrence, baseDate: reminder.date, count: 1).first
    }

    private struct Group {
        let title: String
        let items: [Item]
    }
    private struct Item {
        let reminder: Reminder
        let nextOccurrence: Date?
    }

    private func groups(from reminders: [Reminder]) -> [Group] {
        let calendar = Calendar.current
        let now = Date()
        let endOfWeek = calendar.date(byAdding: .day, value: 7, to: now) ?? now

        var today: [Item] = []
        var tomorrow: [Item] = []
        var thisWeek: [Item] = []
        var later: [Item] = []
        var unscheduled: [Item] = []

        for reminder in reminders {
            let next = nextOccurrence(for: reminder)
            let item = Item(reminder: reminder, nextOccurrence: next)
            guard let date = next else {
                unscheduled.append(item)
                continue
            }
            if calendar.isDateInToday(date) { today.append(item) }
            else if calendar.isDateInTomorrow(date) { tomorrow.append(item) }
            else if date <= endOfWeek { thisWeek.append(item) }
            else { later.append(item) }
        }

        var result: [Group] = []
        if !today.isEmpty { result.append(Group(title: appLocalized("Hoy"), items: today)) }
        if !tomorrow.isEmpty { result.append(Group(title: appLocalized("Mañana"), items: tomorrow)) }
        if !thisWeek.isEmpty { result.append(Group(title: appLocalized("Esta semana"), items: thisWeek)) }
        if !later.isEmpty { result.append(Group(title: appLocalized("Más adelante"), items: later)) }
        if !unscheduled.isEmpty { result.append(Group(title: appLocalized("Sin próxima fecha"), items: unscheduled)) }
        return result
    }

    private func delete(_ reminder: Reminder) async {
        // If the owner is deleting a shared reminder, also remove it from CloudKit
        // so participants' copies are reconciled away on their next sync/push.
        let wasOwnedShare = !reminder.isReceivedShare
        let id = reminder.id
        // Remember a deleted invitation so the shared-DB scan doesn't re-import it
        // on the next launch while the owner's record still exists (bug: reappears).
        if reminder.isReceivedShare {
            DeletedSharesStore.add(id)
        }
        await reminderScheduler.cancelAlarms(for: reminder)
        modelContext.delete(reminder)
        try? modelContext.save()
        Haptics.warning()
        if wasOwnedShare {
            await sharedService.deleteSharedRecord(forReminderID: id)
            if settings.delegationEnabled {
                await delegation.deleteZoneRecord(forReminderID: id)
            }
        }
    }

    private func toggleEnabled(_ reminder: Reminder) async {
        reminder.isEnabled.toggle()
        reminder.updatedAt = Date()
        try? modelContext.save()
        await reminderScheduler.syncAlarms(for: reminder)
        // Propagate the on/off change to participants if this reminder is shared.
        await sharedService.pushUpdateIfShared(reminder)
        if settings.delegationEnabled, !reminder.isReceivedShare {
            await delegation.pushReminder(reminder)
        }
        Haptics.light()
    }
}
