//
//  RemindersListView.swift
//  Calarm
//

import SwiftData
import SwiftUI

struct RemindersListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ReminderScheduler.self) private var reminderScheduler

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
                            Section("Filtrar") {
                                ForEach(ReminderCategory.allCases) { category in
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
                            }
                        } label: {
                            Image(systemName: filterCategories.isEmpty
                                  ? "line.3.horizontal.decrease.circle"
                                  : "line.3.horizontal.decrease.circle.fill")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingNewEditor = true
                        } label: {
                            Image(systemName: "plus")
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
                    Section(group.title) {
                        ForEach(group.items, id: \.reminder.id) { item in
                            Button {
                                detailReminder = item.reminder
                            } label: {
                                ReminderRowView(
                                    reminder: item.reminder,
                                    nextOccurrence: item.nextOccurrence
                                )
                            }
                            .buttonStyle(.plain)
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
                        }
                    }
                }
                if !shared.isEmpty {
                    Section("Compartidos conmigo") {
                        ForEach(shared) { reminder in
                            Button {
                                detailReminder = reminder
                            } label: {
                                ReminderRowView(
                                    reminder: reminder,
                                    nextOccurrence: nextOccurrence(for: reminder)
                                )
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { await delete(reminder) }
                                } label: { Label("Borrar", systemImage: "trash") }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .animation(.snappy, value: reminders.count)
            .animation(.snappy, value: filterCategories)
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
        if !today.isEmpty { result.append(Group(title: "Hoy", items: today)) }
        if !tomorrow.isEmpty { result.append(Group(title: "Mañana", items: tomorrow)) }
        if !thisWeek.isEmpty { result.append(Group(title: "Esta semana", items: thisWeek)) }
        if !later.isEmpty { result.append(Group(title: "Más adelante", items: later)) }
        if !unscheduled.isEmpty { result.append(Group(title: "Sin próxima fecha", items: unscheduled)) }
        return result
    }

    private func delete(_ reminder: Reminder) async {
        await reminderScheduler.cancelAlarms(for: reminder)
        modelContext.delete(reminder)
        try? modelContext.save()
        Haptics.warning()
    }

    private func toggleEnabled(_ reminder: Reminder) async {
        reminder.isEnabled.toggle()
        reminder.updatedAt = Date()
        try? modelContext.save()
        await reminderScheduler.syncAlarms(for: reminder)
        Haptics.light()
    }
}
