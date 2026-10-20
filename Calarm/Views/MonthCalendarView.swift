//
//  MonthCalendarView.swift
//  Calarm
//
//  Un mes de un vistazo: cada día lleva un punto por alarma propia (del color
//  de su categoría) y por evento del calendario del sistema (del color de su
//  calendario), y debajo va la lista del día elegido. Tocar una alarma abre su
//  editor; tocar un evento, su pantalla de avisos.
//

import SwiftData
import SwiftUI

struct MonthCalendarView: View {
    let coordinator: SyncCoordinator?
    @Binding var mode: CalendarTabView.Mode

    @Environment(AppSettings.self) private var settings
    @Environment(MeetingPreferencesStore.self) private var preferences
    @Environment(CategoryStore.self) private var categoryStore
    // Lo fija la raíz de la app según el idioma elegido en Ajustes.
    @Environment(\.locale) private var locale

    @Query(sort: [SortDescriptor(\Reminder.date)]) private var reminders: [Reminder]

    /// Cualquier instante del mes que se enseña.
    @State private var monthAnchor = Date()
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    /// Los eventos del mes visible, pasados incluidos (`coordinator.meetings`
    /// solo trae los que vienen).
    @State private var monthEvents: [Meeting] = []

    @State private var showingNewEditor = false
    @State private var editorReminder: Reminder?
    @State private var selectedMeeting: Meeting?

    /// Qué mes y qué lectura del calendario alimentan `monthEvents`.
    private struct EventsKey: Equatable {
        let monthStart: Date
        let revision: Int
    }

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.locale = locale
        return calendar
    }

    var body: some View {
        let calendar = self.calendar
        let grid = MonthGrid(containing: monthAnchor, calendar: calendar)
        let itemsByDay = CalendarItem.byDay(
            alarms: CalendarItem.alarmItems(from: reminders, from: grid.monthStart, to: grid.monthEnd, calendar: calendar),
            events: monthEvents,
            calendar: calendar
        )
        let dayItems = itemsByDay[selectedDay] ?? []

        List {
            Section {
                monthHeader(grid, calendar: calendar)
                MonthGridView(
                    grid: grid,
                    marks: marks(for: itemsByDay),
                    selectedDay: $selectedDay,
                    calendar: calendar
                )
                .gesture(
                    DragGesture(minimumDistance: 30)
                        .onEnded { value in
                            guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                            shiftMonth(by: value.translation.width < 0 ? 1 : -1, grid: grid, calendar: calendar)
                        }
                )
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: DS.Spacing.sm, bottom: 0, trailing: DS.Spacing.sm))

            if let coordinator, coordinator.access != .granted {
                permissionSection(coordinator)
            }

            Section {
                if dayItems.isEmpty {
                    emptyDay(calendar: calendar)
                } else {
                    ForEach(dayItems) { item in
                        row(for: item)
                    }
                }
            } header: {
                HStack(spacing: DS.Spacing.xs) {
                    Text(CalendarDayTitle.string(for: selectedDay, calendar: calendar))
                    if !dayItems.isEmpty {
                        Text("\(dayItems.count)")
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.dsFill, in: Capsule())
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .animation(DS.Motion.smooth, value: grid.monthStart)
        .refreshable {
            await coordinator?.sync()
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !isShowingToday(grid: grid, calendar: calendar) {
                    Button("Hoy") {
                        goToToday(calendar: calendar)
                    }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if coordinator != nil {
                    Button {
                        Haptics.selection()
                        mode = .agenda
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .accessibilityLabel("Lista de eventos")
                }
                Button {
                    Haptics.light()
                    showingNewEditor = true
                } label: {
                    Image(systemName: "plus")
                        .symbolEffect(.bounce, options: .nonRepeating, value: showingNewEditor)
                }
                .accessibilityLabel("Nueva alarma")
            }
        }
        .sheet(isPresented: $showingNewEditor) {
            ReminderEditorView(editing: nil, initialDate: suggestedNewAlarmDate(calendar: calendar))
        }
        .sheet(item: $editorReminder) { reminder in
            ReminderEditorView(editing: reminder)
        }
        .sheet(item: $selectedMeeting) { meeting in
            if let coordinator {
                MeetingDetailView(meeting: meeting)
                    .environment(coordinator)
            }
        }
        .task(id: EventsKey(monthStart: grid.monthStart, revision: coordinator?.syncRevision ?? -1)) {
            await loadEvents(for: grid)
        }
    }

    // MARK: - Header

    private func monthHeader(_ grid: MonthGrid, calendar: Calendar) -> some View {
        HStack {
            Button {
                shiftMonth(by: -1, grid: grid, calendar: calendar)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Mes anterior")

            Spacer()

            Text(monthTitle(grid.monthStart, calendar: calendar))
                .font(.title3.weight(.semibold))
                .contentTransition(.numericText())

            Spacer()

            Button {
                shiftMonth(by: 1, grid: grid, calendar: calendar)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Mes siguiente")
        }
        // Sin esto la List trata la fila entera como un solo botón.
        .buttonStyle(.borderless)
        .padding(.horizontal, DS.Spacing.xs)
        .padding(.top, DS.Spacing.sm)
    }

    private func monthTitle(_ monthStart: Date, calendar: Calendar) -> String {
        let style = Date.FormatStyle(
            locale: calendar.locale ?? .current,
            calendar: calendar,
            capitalizationContext: .beginningOfSentence
        )
        .month(.wide)
        .year()
        return monthStart.formatted(style)
    }

    // MARK: - Day list

    @ViewBuilder
    private func row(for item: CalendarItem) -> some View {
        switch item {
        case .alarm(let reminder, let occurrence):
            Button {
                Haptics.light()
                editorReminder = reminder
            } label: {
                ReminderRowView(reminder: reminder, nextOccurrence: occurrence, showsDay: false)
            }
            .buttonStyle(.pressable)

        case .event(let meeting):
            Button {
                Haptics.light()
                selectedMeeting = meeting
            } label: {
                MeetingRowView(
                    meeting: meeting,
                    leadTimes: preferences.activeLeadTimes(for: meeting),
                    alarmsEnabled: settings.alarmsEnabled && preferences.isEnabled(forEventID: meeting.id)
                )
            }
            .buttonStyle(.pressable)
        }
    }

    private func emptyDay(calendar: Calendar) -> some View {
        VStack(spacing: DS.Spacing.sm) {
            Image(systemName: "calendar.badge.plus")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Nada este día")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            // Un día pasado no admite alarma nueva.
            if selectedDay >= calendar.startOfDay(for: Date()) {
                Button {
                    Haptics.light()
                    showingNewEditor = true
                } label: {
                    Text("Nueva alarma")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.md)
    }

    private func permissionSection(_ coordinator: SyncCoordinator) -> some View {
        Section {
            HStack(spacing: DS.Spacing.md) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.title3)
                    .foregroundStyle(Color.appAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(coordinator.access == .denied
                         ? appLocalized("Sin acceso al calendario")
                         : appLocalized("Conecta tu calendario"))
                        .font(.subheadline.weight(.semibold))
                    Text("Tus eventos del Calendario saldrán aquí junto a tus alarmas.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: DS.Spacing.sm)
                Button {
                    Haptics.light()
                    if coordinator.access == .denied {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } else {
                        Task { await coordinator.requestAccessIfNeeded() }
                    }
                } label: {
                    Text(coordinator.access == .denied ? appLocalized("Abrir Ajustes") : appLocalized("Permitir"))
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.vertical, DS.Spacing.xs)
        }
    }

    // MARK: - Marks

    private func marks(for itemsByDay: [Date: [CalendarItem]]) -> [Date: [DayMark]] {
        itemsByDay.mapValues { items in
            var seen = Set<DayMark>()
            var marks: [DayMark] = []
            for item in items {
                let mark: DayMark
                switch item {
                case .alarm(let reminder, _):
                    mark = DayMark(color: categoryStore.style(for: reminder).color, isHollow: !reminder.isEnabled)
                case .event(let meeting):
                    mark = DayMark(color: meeting.calendarColorHex.flatMap(Color.init(hex:)) ?? .secondary, isHollow: false)
                }
                if seen.insert(mark).inserted { marks.append(mark) }
            }
            return marks
        }
    }

    // MARK: - Navigation

    private func isShowingToday(grid: MonthGrid, calendar: Calendar) -> Bool {
        calendar.isDateInToday(selectedDay)
            && calendar.isDate(grid.monthStart, equalTo: Date(), toGranularity: .month)
    }

    private func goToToday(calendar: Calendar) {
        Haptics.selection()
        withAnimation(DS.Motion.smooth) {
            monthAnchor = Date()
            selectedDay = calendar.startOfDay(for: Date())
        }
    }

    private func shiftMonth(by months: Int, grid: MonthGrid, calendar: Calendar) {
        guard let target = calendar.date(byAdding: .month, value: months, to: grid.monthStart) else { return }
        Haptics.selection()
        withAnimation(DS.Motion.smooth) {
            monthAnchor = target
            // Al volver al mes actual se elige hoy; en cualquier otro, su día 1.
            selectedDay = calendar.isDate(target, equalTo: Date(), toGranularity: .month)
                ? calendar.startOfDay(for: Date())
                : target
        }
    }

    /// Una alarma nueva creada desde otro día empieza ese día a las 9:00; desde
    /// hoy, el editor pone su hora de siempre (dentro de una hora).
    private func suggestedNewAlarmDate(calendar: Calendar) -> Date? {
        guard !calendar.isDateInToday(selectedDay) else { return nil }
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: selectedDay)
    }

    // MARK: - Events

    private func loadEvents(for grid: MonthGrid) async {
        guard let coordinator else {
            monthEvents = []
            return
        }
        let events = await coordinator.meetings(from: grid.monthStart, to: grid.monthEnd)
        guard !Task.isCancelled else { return }
        monthEvents = events
    }
}
