//
//  ReminderEditorView.swift
//  Calarm
//

import CloudKit
import Observation
import SwiftData
import SwiftUI

/// Everything the editor can change, in one comparable value — the trigger for a
/// debounced save and the payload written to the reminder.
private struct EditSnapshot: Equatable {
    var title: String
    var notes: String
    var date: Date
    var category: CategorySelection
    var iconKind: ReminderIconKind
    var symbolName: String
    var photoData: Data?
    var recurrence: RecurrenceRule
    var additionalSchedules: [AlarmSchedule]
    var leadTimes: [AlarmLeadTime]
    /// Tono propio de la alarma; nil = seguir el predeterminado de Ajustes.
    var tone: AlarmTone?
    var isEnabled: Bool

    var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Autosave bookkeeping, held by reference so a queued save and the flush on
/// dismiss can't both insert a duplicate — and so a delete can't be undone by a
/// save that was already in flight.
@Observable
private final class AutosaveBox {
    /// The alarm created for a brand-new editor (nil while editing an existing one).
    var reminder: Reminder?
    /// What's already on the record — edits equal to this are a no-op.
    var lastCommitted: EditSnapshot?
    /// A local save happened that participants/helpers haven't seen yet.
    var needsRemotePush = false
    var isDeleted = false
}

struct ReminderEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ReminderScheduler.self) private var reminderScheduler
    @Environment(SharedRemindersService.self) private var sharedService
    @Environment(DelegationService.self) private var delegation
    @Environment(AppSettings.self) private var settings
    @Environment(CategoryStore.self) private var categoryStore

    // nil = creating new; otherwise editing existing
    let editingReminder: Reminder?

    @State private var title: String
    @State private var notes: String
    @State private var date: Date
    @State private var categorySelection: CategorySelection
    @State private var iconKind: ReminderIconKind
    @State private var symbolName: String
    @State private var photoData: Data?
    @State private var recurrence: RecurrenceRule
    /// Extra schedules (different day/time) beyond the primary `date`/`recurrence`.
    @State private var additionalSchedules: [AlarmSchedule]
    @State private var leadTimes: [AlarmLeadTime]
    @State private var tone: AlarmTone?
    @State private var showingLeadTimePicker = false
    @State private var showingIconPicker = false
    @State private var isEnabled: Bool

    // No title, no alarm: instead of closing the editor with nothing saved, the
    // field turns red and asks for a name.
    @State private var showTitleError = false
    @FocusState private var titleFocused: Bool

    /// Which calendar is expanded (nil = none). The primary schedule uses
    /// `primaryScheduleID`; the extra ones use their own id.
    @State private var openCalendarID: UUID?
    private static let primaryScheduleID = UUID()

    // Autosave: edits are committed automatically (debounced) instead of behind a
    // Save button. For a brand-new alarm the reminder is created on the first
    // commit with a non-empty title, and every later commit updates that same
    // object — the box keeps its identity so we never insert a duplicate.
    @State private var autosave = AutosaveBox()
    @State private var autosaveTask: Task<Void, Never>?

    // AI suggestion state
    @State private var pendingSuggestion: AlarmSuggestion?
    @State private var suggestionTask: Task<Void, Never>?
    @State private var dismissedSuggestion: Bool = false

    private static let maxLeadTimes = 5

    // Sharing on create
    @State private var isPreparingShare = false
    @State private var pendingInvite: InviteDelivery?
    @State private var shareError: String?

    // Sharing for an EXISTING alarm (tap-to-edit replaced the old detail view):
    // owner sees invite/manage/participants; recipient sees who shared it.
    @State private var existingShare: CKShare?
    @State private var participants: [ShareParticipantInfo] = []
    @State private var sharedBy: SharedByPerson?
    @State private var showingManageSheet = false

    init(editing reminder: Reminder? = nil) {
        self.editingReminder = reminder
        if let r = reminder {
            _title = State(initialValue: r.title)
            _notes = State(initialValue: r.notes ?? "")
            _date = State(initialValue: r.date)
            if let cid = r.customCategoryID {
                _categorySelection = State(initialValue: .custom(cid))
            } else {
                _categorySelection = State(initialValue: .builtin(r.category))
            }
            _iconKind = State(initialValue: r.iconKind)
            _symbolName = State(initialValue: r.symbolName ?? r.category.defaultSymbol)
            _photoData = State(initialValue: r.photoData)
            _recurrence = State(initialValue: r.recurrence)
            _additionalSchedules = State(initialValue: r.additionalSchedules)
            _leadTimes = State(initialValue: r.leadTimes)
            _tone = State(initialValue: r.tone)
            _isEnabled = State(initialValue: r.isEnabled)
        } else {
            let initialCategory = ReminderCategory.reminder
            _title = State(initialValue: "")
            _notes = State(initialValue: "")
            _date = State(initialValue: Date().addingTimeInterval(60 * 60))
            _categorySelection = State(initialValue: .builtin(initialCategory))
            _iconKind = State(initialValue: .symbol)
            _symbolName = State(initialValue: initialCategory.defaultSymbol)
            _photoData = State(initialValue: nil)
            _recurrence = State(initialValue: .once)
            _additionalSchedules = State(initialValue: [])
            // El aviso predeterminado de Ajustes, leído sin el entorno (aquí
            // todavía no existe). Queda visible en la fila "Aviso" antes de
            // guardar, así que nadie se entera tarde de que la alarma se adelanta.
            _leadTimes = State(initialValue: [AppSettings.storedDefaultLeadTime()])
            _tone = State(initialValue: nil)
            _isEnabled = State(initialValue: true)
        }
    }

    /// Resolved presentation for the current selection (built-in or custom).
    private var style: CategoryStyle { categoryStore.style(for: categorySelection) }

    /// SF Symbols suggested in the icon picker — the built-in category's set, or
    /// a generic set for custom categories.
    private var suggestedSymbols: [String] {
        if case .builtin(let c) = categorySelection { return c.suggestedSymbols }
        return ReminderCategory.other.suggestedSymbols
    }

    private var fallbackSymbol: String {
        style.iconKind == .symbol ? style.iconValue : "star.fill"
    }

    private var isTitleEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The reminder these edits are being written to: the one we opened, or the
    /// one autosave created for a new alarm. `nil` until a new alarm is titled.
    private var targetReminder: Reminder? { editingReminder ?? autosave.reminder }

    /// Binding for one aviso row: replaces that value in place, merging
    /// duplicates and keeping the list ascending (soonest lead time first).
    private func leadTimeBinding(for value: AlarmLeadTime) -> Binding<AlarmLeadTime> {
        Binding {
            value
        } set: { newValue in
            withAnimation(DS.Motion.snappy) {
                var updated = leadTimes
                if let index = updated.firstIndex(of: value) {
                    updated[index] = newValue
                }
                leadTimes = Array(Set(updated)).sorted { $0.rawValue < $1.rawValue }
            }
            Haptics.selection()
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                titleSection

                if let suggestion = pendingSuggestion {
                    suggestionSection(suggestion)
                }

                scheduleSection
                soundSection
                categorySection
                statusSection

                if let target = targetReminder {
                    if target.isReceivedShare {
                        sharedBySection
                    } else {
                        existingShareSection
                    }
                    deleteSection
                }
            }
            // appLocalized so the in-app language override applies — a `cond ? a : b`
            // of string literals resolves to a plain String, which navigationTitle
            // shows verbatim (no localization) otherwise.
            .navigationTitle(appLocalized(editingReminder == nil ? "Nueva alarma" : "Editar alarma"))
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .animation(DS.Motion.smooth, value: pendingSuggestion)
            .animation(DS.Motion.smooth, value: autosave.reminder?.id)
            // Remember what's already stored so closing an untouched editor
            // doesn't re-save (and re-push) the alarm.
            .onAppear {
                if autosave.lastCommitted == nil { autosave.lastCommitted = snapshot }
            }
            .onChange(of: title) { _, newValue in
                scheduleSuggestionFetch(for: newValue)
                if showTitleError, !isTitleEmpty {
                    withAnimation(DS.Motion.quick) { showTitleError = false }
                }
            }
            // Every edit schedules a debounced save; leaving the editor flushes
            // whatever is still pending (including a swipe-down dismissal).
            .onChange(of: snapshot) { _, newValue in
                scheduleAutosave(newValue)
            }
            .onDisappear {
                suggestionTask?.cancel()
                autosaveTask?.cancel()
                let pending = snapshot
                Task { await commit(pending, pushRemote: true) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Group {
                        if isPreparingShare {
                            ProgressView()
                        } else {
                            Button("Listo") { handleDone() }
                                .bold()
                        }
                    }
                }
            }
            .sheet(isPresented: $showingLeadTimePicker) {
                LeadTimePickerSheet(excluded: Set(leadTimes)) { picked in
                    withAnimation(DS.Motion.snappy) {
                        leadTimes.append(picked)
                        leadTimes.sort { $0.rawValue < $1.rawValue }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingIconPicker) {
                NavigationStack {
                    Form {
                        Section {
                            iconEditor
                        }
                    }
                    .navigationTitle(appLocalized("Icono"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Listo") { showingIconPicker = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            // Shared invite delivery (Messages, with generic share fallback). For a
            // NEW alarm this closes the editor (the reminder was just saved); when
            // sharing an EXISTING one we stay and refresh who has access.
            .inviteDelivery($pendingInvite) {
                if editingReminder == nil { dismiss() }
                else { Task { await refreshShare() } }
            }
            // Native CloudKit sharing management for an already-shared alarm.
            .sheet(isPresented: $showingManageSheet, onDismiss: { Task { await refreshShare() } }) {
                if let share = existingShare {
                    CloudSharingView(
                        share: share,
                        container: CKContainer(identifier: sharedService.containerIdentifier)
                    ) { showingManageSheet = false }
                }
            }
            .alert("Error al compartir", isPresented: Binding(
                get: { shareError != nil },
                set: { if !$0 { shareError = nil } }
            )) {
                Button("OK") { shareError = nil; if editingReminder == nil { dismiss() } }
            } message: {
                Text(shareError ?? "")
            }
            .task { await refreshShare() }
        }
    }

    @ViewBuilder
    private var titleSection: some View {
        Section {
            HStack(alignment: .top, spacing: DS.Spacing.md) {
                // Tap the icon to change it directly (no longer buried in "More options").
                Button {
                    Haptics.light()
                    showingIconPicker = true
                } label: {
                    ReminderIconView(
                        iconKind: iconKind,
                        iconValue: symbolName,
                        photoData: photoData,
                        fallbackSymbol: fallbackSymbol,
                        tint: style.color,
                        size: 56,
                        shape: .roundedRect(DS.Radius.md),
                        bounceValue: isEnabled
                    )
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.body)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, style.color)
                            .background(Circle().fill(Color(.systemBackground)).padding(1))
                            .offset(x: 5, y: 5)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(appLocalized("Cambiar icono")))

                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    TextField("Título", text: $title)
                        .font(.title3.weight(.semibold))
                        .focused($titleFocused)
                        .padding(DS.Spacing.xs)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                                .fill(Color.red.opacity(showTitleError ? 0.12 : 0))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                                .strokeBorder(.red, lineWidth: showTitleError ? 1.5 : 0)
                        )
                        // Puts the field back where it was: the box is only decoration.
                        .padding(-DS.Spacing.xs)
                    TextField("Notas (opcional)", text: $notes, axis: .vertical)
                        .lineLimit(1...3)
                }
            }
            .padding(.vertical, DS.Spacing.xs)
        } footer: {
            if showTitleError {
                Label("Ponle un nombre a la alarma para poder guardarla.", systemImage: "exclamationmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
            } else if isTitleEmpty {
                Text("Ponle un nombre para reconocerla, por ejemplo «Tomar pastilla».")
            }
        }
    }

    @ViewBuilder
    private var scheduleSection: some View {
        // Primary schedule (date + time + recurrence).
        Section {
            schedulePickers(id: Self.primaryScheduleID, date: $date, recurrence: $recurrence)
        } header: {
            Text(additionalSchedules.isEmpty ? appLocalized("Cuándo") : "\(appLocalized("Horario")) 1")
        }

        // Additional schedules — same alarm, different day/time.
        ForEach($additionalSchedules) { $sched in
            Section {
                schedulePickers(id: sched.id, date: $sched.date, recurrence: $sched.recurrence)
                Button(role: .destructive) {
                    withAnimation(DS.Motion.snappy) {
                        additionalSchedules.removeAll { $0.id == sched.id }
                    }
                    Haptics.light()
                } label: {
                    Label("Quitar horario", systemImage: "trash")
                }
            } header: {
                Text("\(appLocalized("Horario")) \((additionalSchedules.firstIndex { $0.id == sched.id } ?? 0) + 2)")
            }
        }

        // Add another schedule + the (shared) lead time.
        Section {
            Button {
                Haptics.light()
                withAnimation(DS.Motion.snappy) {
                    additionalSchedules.append(AlarmSchedule(date: newScheduleDate(), recurrence: .once))
                }
            } label: {
                Label("Agregar horario", systemImage: "calendar.badge.plus")
            }
            avisoControl
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if leadTimes.count > 1 {
                    Text("La alarma sonará una vez por cada aviso configurado.")
                } else {
                    Text("Agrega días y horas distintos para la misma alarma (p. ej. lunes y sábado).")
                }
                // Avisos on a received share stay on this device only.
                if editingReminder?.isReceivedShare == true {
                    Text("Tus avisos son solo tuyos: no cambian la alarma de quien la compartió.")
                }
            }
        }
    }

    /// The date + time + recurrence controls for one schedule, bound to the given state.
    @ViewBuilder
    private func schedulePickers(id: UUID, date: Binding<Date>, recurrence: Binding<RecurrenceRule>) -> some View {
        // A repeating alarm that already knows its days (weekly on Mon/Sat, or
        // every day) doesn't need a date — only the time. It stays for the rules
        // where the date really decides when it rings, labelled as the start.
        if showsDate(for: recurrence.wrappedValue) {
            // Row that expands the calendar. The compact DatePicker stays open
            // after picking a day; this one closes as soon as one is picked.
            Button {
                Haptics.light()
                withAnimation(DS.Motion.snappy) {
                    openCalendarID = (openCalendarID == id) ? nil : id
                }
            } label: {
                LabeledContent {
                    HStack(spacing: DS.Spacing.xs) {
                        Text(date.wrappedValue.formatted(date: .abbreviated, time: .omitted))
                            .foregroundStyle(openCalendarID == id ? style.color : .secondary)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(openCalendarID == id ? -180 : 0))
                    }
                } label: {
                    Label(
                        recurrence.wrappedValue.isRecurring ? "Desde" : "Fecha",
                        systemImage: "calendar"
                    )
                }
            }
            .buttonStyle(.plain)

            if openCalendarID == id {
                DatePicker("", selection: date, displayedComponents: [.date])
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    // Picking a day closes the calendar; paging months doesn't.
                    .onChange(of: Calendar.current.startOfDay(for: date.wrappedValue)) { _, _ in
                        Haptics.selection()
                        withAnimation(DS.Motion.snappy) { openCalendarID = nil }
                    }
            }
        }

        DatePicker(selection: date, displayedComponents: [.hourAndMinute]) {
            Label("Hora", systemImage: "clock.fill")
        }
        .datePickerStyle(.compact)

        NavigationLink {
            RecurrencePickerView(rule: recurrence, baseDate: date.wrappedValue)
        } label: {
            LabeledContent {
                Text(recurrence.wrappedValue.localizedSummary)
                    .foregroundStyle(.secondary)
            } label: {
                Label("Repetir", systemImage: "repeat")
            }
        }

        // A one-off alarm with a past date never gets scheduled: say so here
        // instead of letting it turn up under "Vencidas" with no explanation.
        if neverRings(date: date.wrappedValue, recurrence: recurrence.wrappedValue) {
            Label("Esa fecha y hora ya pasaron: la alarma no sonará.", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    /// A schedule with no future occurrence: it saves, but it never rings.
    private func neverRings(date: Date, recurrence: RecurrenceRule) -> Bool {
        RecurrenceEngine.nextOccurrences(rule: recurrence, baseDate: date, count: 1).isEmpty
    }

    /// Lead-time controls, shared across all schedules and edited right here —
    /// one picker row per aviso, plus add/remove, so nothing hides in "More options".
    @ViewBuilder
    private var avisoControl: some View {
        ForEach(Array(leadTimes.enumerated()), id: \.element) { index, value in
            HStack {
                Picker(selection: leadTimeBinding(for: value)) {
                    ForEach(AlarmLeadTime.allCases) { option in
                        Text(option.localizedTitle).tag(option)
                    }
                } label: {
                    Label {
                        Text(index == 0 ? appLocalized("Aviso") : "\(appLocalized("Aviso")) \(index + 1)")
                    } icon: {
                        Image(systemName: index == 0 ? "bell.fill" : "bell.badge")
                    }
                }
                .pickerStyle(.menu)

                if leadTimes.count > 1 {
                    Button {
                        removeLeadTime(value)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Quitar \(value.localizedTitle)"))
                }
            }
        }

        if leadTimes.count < Self.maxLeadTimes {
            Button {
                Haptics.light()
                showingLeadTimePicker = true
            } label: {
                Label("Agregar aviso", systemImage: "plus.circle.fill")
            }
        }
    }

    /// Whether the date picker earns its row: it does when the day itself decides
    /// when the alarm rings (one-off, monthly, yearly, weekly with no weekdays
    /// picked) or anchors a multi-week/day cycle. `RecurrenceEngine` only reads
    /// the time-of-day from it in the other cases.
    private func showsDate(for rule: RecurrenceRule) -> Bool {
        switch rule {
        case .daily(let interval):
            return interval > 1
        case .weekly(let interval, let weekdays):
            return weekdays.isEmpty || interval > 1
        default:
            return true
        }
    }

    /// A sensible default for a freshly-added schedule: the day after the primary
    /// date, same time, so the user just tweaks it.
    private func newScheduleDate() -> Date {
        Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date
    }

    /// El tono de esta alarma. Por omisión sigue el de Ajustes, así que la fila
    /// muestra el tono que realmente va a sonar, no la palabra "Predeterminado".
    @ViewBuilder
    private var soundSection: some View {
        let effective = tone ?? settings.alarmTone
        Section {
            NavigationLink {
                TonePickerView(selection: $tone, fallback: settings.alarmTone)
            } label: {
                LabeledContent {
                    Text(effective.localizedTitle)
                        .foregroundStyle(.secondary)
                } label: {
                    Label("Sonido", systemImage: effective.systemImage)
                }
            }
        } footer: {
            if tone == nil {
                Text("Sigue el tono predeterminado de Ajustes.")
            }
        }
    }

    @ViewBuilder
    private var categorySection: some View {
        Section {
            CategoryPickerView(selection: $categorySelection)
                .onChange(of: categorySelection) { _, _ in
                    // Default the icon to the newly-picked category's icon;
                    // the user can still override it below.
                    let s = style
                    iconKind = s.iconKind
                    symbolName = s.iconValue
                }
        } header: {
            Text("Categoría")
        }
    }

    /// The on/off switch, front and center — no "more options" detour.
    @ViewBuilder
    private var statusSection: some View {
        Section {
            Toggle(isOn: $isEnabled) {
                Label(
                    "Alarma activa",
                    systemImage: isEnabled ? "bell.fill" : "bell.slash.fill"
                )
                .symbolEffect(.bounce, options: .nonRepeating, value: isEnabled)
            }
            .tint(style.color)
        } footer: {
            Text(isEnabled
                 ? "La alarma sonará según los horarios y avisos de arriba."
                 : "La alarma está apagada: no sonará hasta que la enciendas.")
        }
    }

    private var iconEditor: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            IconPickerView(
                tint: style.color,
                suggestedSymbols: suggestedSymbols,
                defaultSymbol: fallbackSymbol,
                iconKind: $iconKind,
                symbolName: $symbolName,
                photoData: $photoData
            )
        }
    }

    @ViewBuilder
    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                Task { await deleteReminder() }
            } label: {
                Label("Borrar alarma", systemImage: "trash")
            }
        }
    }

    // MARK: - Sharing (existing alarm)

    /// Owner-side: invite people, manage an existing share, and see who joined.
    @ViewBuilder
    private var existingShareSection: some View {
        Section {
            Button {
                Haptics.light()
                Task { await inviteExisting() }
            } label: {
                HStack {
                    Label("Invitar amigos", systemImage: "person.badge.plus")
                    Spacer()
                    if isPreparingShare { ProgressView() }
                }
            }
            .disabled(isPreparingShare || isTitleEmpty)

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
        } footer: {
            Text("Se abrirá Messages con el link para que tus invitados la acepten.")
        }

        if !participants.isEmpty {
            Section {
                ForEach(participants) { person in
                    participantRow(person)
                }
            } header: {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "person.2.fill").font(.caption2)
                    Text("Personas")
                }
            }
        }
    }

    /// Recipient-side: who shared this alarm with me.
    @ViewBuilder
    private var sharedBySection: some View {
        Section {
            if let sharedBy {
                HStack(spacing: DS.Spacing.md) {
                    PersonAvatarView(name: sharedBy.name, email: sharedBy.email, phone: sharedBy.phone, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sharedBy.name)
                            .font(.subheadline.weight(.semibold))
                        Text("Te compartió esta alarma")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            } else {
                Label("Compartido contigo", systemImage: "person.2.fill")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Compartido")
        }
    }

    private func participantRow(_ person: ShareParticipantInfo) -> some View {
        HStack(spacing: DS.Spacing.md) {
            PersonAvatarView(name: person.name, email: person.email, phone: person.phone, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(person.statusLabel)
                    .font(.caption)
                    .foregroundStyle(statusColor(person.status))
            }
            Spacer()
            if person.status == .accepted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }

    private func statusColor(_ status: CKShare.ParticipantAcceptanceStatus) -> Color {
        switch status {
        case .accepted: return .green
        case .pending: return .orange
        default: return .secondary
        }
    }

    /// Loads share state for an existing alarm: who shared it (recipient) or who
    /// has joined (owner). No-op for a brand-new alarm.
    @MainActor
    private func refreshShare() async {
        guard let r = targetReminder else { return }
        if r.isReceivedShare {
            sharedBy = ShareOwnerStore.get(r.id)
            return
        }
        let share = await sharedService.existingShare(for: r)
        existingShare = share
        participants = share.map { sharedService.participantInfos(of: $0).filter { !$0.isOwner } } ?? []
    }

    /// Prepares the share for an existing alarm and hands off to Messages.
    @MainActor
    private func inviteExisting() async {
        // Make sure whatever the user just typed is on the record before the
        // share payload is written from it.
        await flushPendingEdits()
        guard let r = targetReminder else { return }
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            let share = try await sharedService.prepareShare(for: r)
            guard let url = share.url else {
                shareError = SharedRemindersError.shareURLUnavailable.errorDescription
                return
            }
            existingShare = share
            // Wrap the CloudKit share in a Calarm link so the invitation
            // previews with the alarm's name and time, and so whoever doesn't
            // have the app yet lands on a page that offers it. Falling back to
            // the raw share URL keeps invites working if encoding ever fails.
            let inviteURL = InviteLink.make(
                title: r.title,
                date: r.date,
                tintHex: r.category.tint.toHex(),
                emoji: r.iconKind == .emoji ? r.symbolName : nil,
                shareURL: url
            ) ?? url
            pendingInvite = InviteDelivery(title: r.title, url: inviteURL)
        } catch {
            shareError = error.localizedDescription
        }
    }

    private func removeLeadTime(_ value: AlarmLeadTime) {
        guard leadTimes.count > 1 else { return }
        withAnimation(DS.Motion.snappy) {
            leadTimes.removeAll { $0 == value }
        }
        Haptics.light()
    }

    // MARK: - Done

    /// Something is configured that no saved alarm holds yet.
    private var hasPendingWork: Bool { snapshot != autosave.lastCommitted }

    /// "Listo": with no title `commit` saves nothing, so rather than closing the
    /// editor and losing what was set up, flag the field and ask for the name.
    private func handleDone() {
        guard isTitleEmpty, hasPendingWork else {
            dismiss()
            return
        }
        withAnimation(DS.Motion.snappy) { showTitleError = true }
        titleFocused = true
        Haptics.warning()
    }

    // MARK: - Autosave

    private var snapshot: EditSnapshot {
        EditSnapshot(
            title: title,
            notes: notes,
            date: date,
            category: categorySelection,
            iconKind: iconKind,
            symbolName: symbolName,
            photoData: photoData,
            recurrence: recurrence,
            additionalSchedules: additionalSchedules,
            leadTimes: leadTimes,
            tone: tone,
            isEnabled: isEnabled
        )
    }

    /// Debounces a save so we aren't writing (and rescheduling alarms) on every
    /// keystroke. Remote pushes wait for the flush on dismiss.
    private func scheduleAutosave(_ pending: EditSnapshot) {
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            if Task.isCancelled { return }
            await commit(pending, pushRemote: false)
        }
    }

    /// Commits any debounced edit right now — used before actions that read the
    /// stored reminder (sharing, deleting).
    @MainActor
    private func flushPendingEdits() async {
        autosaveTask?.cancel()
        autosaveTask = nil
        await commit(snapshot, pushRemote: false)
    }

    /// Writes the snapshot to the reminder (creating it the first time), keeps the
    /// alarms in sync, and — on the flush when the editor closes — mirrors the
    /// change to CloudKit. Opening an alarm and closing it untouched does nothing.
    @MainActor
    private func commit(_ snap: EditSnapshot, pushRemote: Bool) async {
        guard !autosave.isDeleted else { return }
        // Nothing to save until the alarm has a name.
        guard !snap.trimmedTitle.isEmpty else { return }

        let hasEdits = snap != autosave.lastCommitted
        guard hasEdits || (pushRemote && autosave.needsRemotePush) else { return }

        let reminder: Reminder
        if let existing = targetReminder {
            reminder = existing
        } else {
            let new = Reminder(title: snap.trimmedTitle, date: snap.date)
            modelContext.insert(new)
            autosave.reminder = new
            reminder = new
            Haptics.success()
        }

        if hasEdits {
            apply(snap, to: reminder)
            try? modelContext.save()
            autosave.lastCommitted = snap
            autosave.needsRemotePush = true
            await reminderScheduler.syncAlarms(for: reminder)
        }

        guard pushRemote, autosave.needsRemotePush else { return }
        autosave.needsRemotePush = false
        // Push the change to participants of an already-shared reminder…
        await sharedService.pushUpdateIfShared(reminder)
        // …and mirror create/edit to trusted helpers if delegation is on.
        if settings.delegationEnabled {
            await delegation.pushReminder(reminder)
        }
    }

    private func apply(_ snap: EditSnapshot, to reminder: Reminder) {
        reminder.title = snap.trimmedTitle
        reminder.notes = snap.notes.isEmpty ? nil : snap.notes
        reminder.date = snap.date
        categoryStore.apply(snap.category, to: reminder)
        reminder.iconKind = snap.iconKind
        reminder.symbolName = snap.symbolName
        reminder.photoData = snap.iconKind == .photo ? snap.photoData : nil
        reminder.recurrence = snap.recurrence
        reminder.additionalSchedules = snap.additionalSchedules
        reminder.tone = snap.tone
        reminder.leadTimes = snap.leadTimes
        // On a received share the avisos are the recipient's own — remember them
        // so the next shared-DB scan doesn't overwrite them with the owner's list.
        if reminder.isReceivedShare {
            ShareLeadTimesStore.setPersonal(snap.leadTimes, for: reminder.id)
        }
        reminder.isEnabled = snap.isEnabled
        reminder.updatedAt = Date()
    }

    // MARK: - AI suggestions

    /// Cancels any pending suggestion fetch and starts a new debounced one
    /// for `title`. Bails out early when the title is too short or the user
    /// already explicitly dismissed a previous suggestion.
    private func scheduleSuggestionFetch(for title: String) {
        suggestionTask?.cancel()
        pendingSuggestion = nil

        // Don't fight the user after they explicitly dismissed a suggestion.
        guard !dismissedSuggestion else { return }
        // Skip when editing an existing reminder — they already chose values.
        guard editingReminder == nil else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return }

        suggestionTask = Task {
            // Debounce 700ms so the model doesn't run on every keystroke.
            try? await Task.sleep(for: .milliseconds(700))
            if Task.isCancelled { return }

            let suggestion = await AlarmSuggestionsService.shared.suggest(
                for: trimmed,
                locale: LocalizationManager.shared.currentLocale
            )

            await MainActor.run {
                guard !Task.isCancelled,
                      let suggestion,
                      title.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
                else { return }
                pendingSuggestion = suggestion
            }
        }
    }

    /// Visual banner showing what Calarm AI would set. One tap applies all.
    @ViewBuilder
    private func suggestionSection(_ suggestion: AlarmSuggestion) -> some View {
        Section {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.tint)
                        .symbolEffect(.bounce, options: .nonRepeating)
                    Text("Sugerencias de Calarm")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button {
                        withAnimation(DS.Motion.snappy) {
                            dismissedSuggestion = true
                            pendingSuggestion = nil
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Descartar sugerencia")
                }

                // Mini chips showing what would change
                WrapLayout(spacing: 6, lineSpacing: 6) {
                    if let suggestedSelection = categoryStore.resolve(slug: suggestion.category),
                       suggestedSelection != categorySelection {
                        let s = categoryStore.style(for: suggestedSelection)
                        suggestionChip(
                            icon: "tag.fill",
                            label: s.title,
                            tint: s.color
                        )
                    }
                    let suggestedRecurrence = AlarmSuggestionsService.recurrence(fromSlug: suggestion.recurrence)
                    if suggestedRecurrence.localizedSummary != recurrence.localizedSummary {
                        suggestionChip(
                            icon: "repeat",
                            label: suggestedRecurrence.localizedSummary,
                            tint: .appAccent
                        )
                    }
                    let suggestedLeadTimes = AlarmSuggestionsService.leadTimes(fromMinutes: suggestion.leadTimesMinutes)
                    if Set(suggestedLeadTimes) != Set(leadTimes) {
                        suggestionChip(
                            icon: "bell.fill",
                            label: suggestedLeadTimes.map(\.shortTitle).joined(separator: " · "),
                            tint: .orange
                        )
                    }
                }

                Button {
                    applySuggestion(suggestion)
                } label: {
                    HStack {
                        Image(systemName: "wand.and.stars")
                        Text("Aplicar sugerencias")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Spacing.sm)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(.vertical, DS.Spacing.xs)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func suggestionChip(icon: String, label: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(label)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, 4)
        .foregroundStyle(tint)
        .background(tint.opacity(0.15), in: Capsule())
    }

    private func applySuggestion(_ suggestion: AlarmSuggestion) {
        withAnimation(DS.Motion.snappy) {
            if let suggestedSelection = categoryStore.resolve(slug: suggestion.category) {
                // The categorySelection onChange handler updates the icon to match.
                categorySelection = suggestedSelection
            }
            recurrence = AlarmSuggestionsService.recurrence(fromSlug: suggestion.recurrence)
            leadTimes = AlarmSuggestionsService.leadTimes(fromMinutes: suggestion.leadTimesMinutes)
            pendingSuggestion = nil
        }
        Haptics.success()
    }

    private func deleteReminder() async {
        guard let r = targetReminder else { return }
        // Don't let a queued autosave (or the flush on dismiss) resurrect the
        // reminder we're deleting.
        autosaveTask?.cancel()
        autosaveTask = nil
        autosave.reminder = nil
        autosave.isDeleted = true
        let id = r.id
        let wasOwned = !r.isReceivedShare
        // Tombstone a deleted invitation so the shared-DB scan doesn't re-import it.
        if r.isReceivedShare {
            DeletedSharesStore.add(id)
            ShareLeadTimesStore.forget(id)
        }
        await reminderScheduler.cancelAlarms(for: r)
        modelContext.delete(r)
        try? modelContext.save()
        Haptics.warning()
        if wasOwned, settings.delegationEnabled {
            await delegation.deleteZoneRecord(forReminderID: id)
        }
        dismiss()
    }
}
