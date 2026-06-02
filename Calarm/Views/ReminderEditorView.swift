//
//  ReminderEditorView.swift
//  Calarm
//

import CloudKit
import SwiftData
import SwiftUI

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
    @State private var leadTimes: [AlarmLeadTime]
    @State private var showingLeadTimePicker = false
    @State private var isEnabled: Bool

    // AI suggestion state
    @State private var pendingSuggestion: AlarmSuggestion?
    @State private var suggestionTask: Task<Void, Never>?
    @State private var dismissedSuggestion: Bool = false

    private static let maxLeadTimes = 5

    // Sharing on create
    @State private var isPreparingShare = false
    @State private var pendingInvite: InviteDelivery?
    @State private var shareError: String?

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
            _leadTimes = State(initialValue: r.leadTimes)
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
            _leadTimes = State(initialValue: [.atStart])
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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Título", text: $title)
                    TextField("Notas (opcional)", text: $notes, axis: .vertical)
                        .lineLimit(1...4)
                } header: {
                    Text("Información")
                }

                if let suggestion = pendingSuggestion {
                    suggestionSection(suggestion)
                }

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

                Section {
                    IconPickerView(
                        tint: style.color,
                        suggestedSymbols: suggestedSymbols,
                        defaultSymbol: style.iconKind == .symbol ? style.iconValue : "star.fill",
                        iconKind: $iconKind,
                        symbolName: $symbolName,
                        photoData: $photoData
                    )
                } header: {
                    Text("Icono")
                }

                Section {
                    DatePicker(selection: $date, displayedComponents: [.date]) {
                        EmptyView()
                    }
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                } header: {
                    HStack(spacing: DS.Spacing.xs) {
                        Image(systemName: "calendar")
                            .font(.caption2)
                        Text("Fecha")
                    }
                }

                Section {
                    DatePicker(selection: $date, displayedComponents: [.hourAndMinute]) {
                        HStack(spacing: DS.Spacing.sm) {
                            Image(systemName: "clock.fill")
                                .foregroundStyle(style.color)
                                .font(.title3)
                            Text("Hora")
                                .font(.body.weight(.medium))
                        }
                    }
                    .padding(.vertical, DS.Spacing.xs)
                } header: {
                    HStack(spacing: DS.Spacing.xs) {
                        Image(systemName: "clock")
                            .font(.caption2)
                        Text("Hora")
                    }
                }

                Section {
                    ForEach(leadTimes) { value in
                        HStack {
                            Image(systemName: "bell.fill")
                                .foregroundStyle(style.color)
                            Text(value.localizedTitle)
                            Spacer()
                            if leadTimes.count > 1 {
                                Button {
                                    withAnimation(DS.Motion.snappy) {
                                        leadTimes.removeAll { $0 == value }
                                    }
                                    Haptics.light()
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text("Quitar \(value.localizedTitle)"))
                            }
                        }
                        .transition(.opacity)
                    }
                    .onDelete { offsets in
                        // Only allow delete if it would leave at least one entry.
                        var copy = leadTimes
                        copy.remove(atOffsets: offsets)
                        guard !copy.isEmpty else { return }
                        withAnimation(DS.Motion.snappy) {
                            leadTimes = copy
                        }
                    }

                    if leadTimes.count < Self.maxLeadTimes {
                        Button {
                            Haptics.light()
                            showingLeadTimePicker = true
                        } label: {
                            Label("Agregar aviso", systemImage: "plus.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                } header: {
                    HStack(spacing: DS.Spacing.xs) {
                        Text("Aviso")
                        if leadTimes.count > 1 {
                            Text("\(leadTimes.count)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.appAccent))
                        }
                    }
                } footer: {
                    if leadTimes.count > 1 {
                        Text("La alarma sonará una vez por cada aviso configurado.")
                    }
                }

                Section {
                    NavigationLink {
                        RecurrencePickerView(rule: $recurrence, baseDate: date)
                    } label: {
                        LabeledContent {
                            Text(recurrence.localizedSummary)
                        } label: {
                            Text("Repetir")
                        }
                    }
                } header: {
                    Text("Repetir")
                }

                Section {
                    Toggle("Alarma activa", isOn: $isEnabled)
                }

                // Contact picker — only when creating new reminders
                if editingReminder == nil {
                    inviteSection
                }

                if editingReminder != nil {
                    Section {
                        Button(role: .destructive) {
                            Task { await deleteReminder() }
                        } label: {
                            Label("Borrar recordatorio", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(editingReminder == nil ? "Nuevo recordatorio" : "Editar")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .animation(DS.Motion.smooth, value: pendingSuggestion)
            .onChange(of: title) { _, newValue in
                scheduleSuggestionFetch(for: newValue)
            }
            .onDisappear {
                suggestionTask?.cancel()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Group {
                        if isPreparingShare {
                            ProgressView()
                        } else {
                            Button(editingReminder == nil ? "Crear" : "Guardar") {
                                Task { await save() }
                            }
                            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
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
            // Shared invite delivery (Messages, with generic share fallback).
            // Closing it dismisses the editor — the reminder is already saved.
            .inviteDelivery($pendingInvite) { dismiss() }
            .alert("Error al compartir", isPresented: Binding(
                get: { shareError != nil },
                set: { if !$0 { shareError = nil } }
            )) {
                Button("OK") { shareError = nil; dismiss() }
            } message: {
                Text(shareError ?? "")
            }
        }
    }

    @ViewBuilder
    private var inviteSection: some View {
        Section {
            Button {
                Haptics.light()
                Task { await save(thenInvite: true) }
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.appAccent.opacity(0.9), Color.appAccent.opacity(0.55)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 40, height: 40)
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Invitar amigos")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        Text("Comparte el link por Messages")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isPreparingShare {
                        ProgressView()
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isPreparingShare)
        } header: {
            Text("Invitar amigos")
        } footer: {
            Text("Se guardará la alarma y se abrirá Messages con el link para que tus invitados la acepten.")
        }
    }

    private func save(thenInvite: Bool = false) async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        let reminder: Reminder
        if let existing = editingReminder {
            existing.title = trimmedTitle
            existing.notes = notes.isEmpty ? nil : notes
            existing.date = date
            categoryStore.apply(categorySelection, to: existing)
            existing.iconKind = iconKind
            existing.symbolName = symbolName
            existing.photoData = iconKind == .photo ? photoData : nil
            existing.recurrence = recurrence
            existing.leadTimes = leadTimes
            existing.isEnabled = isEnabled
            existing.updatedAt = Date()
            reminder = existing
        } else {
            let new = Reminder(
                title: trimmedTitle,
                notes: notes.isEmpty ? nil : notes,
                date: date,
                iconKind: iconKind,
                symbolName: symbolName,
                photoData: iconKind == .photo ? photoData : nil,
                recurrence: recurrence,
                leadTimes: leadTimes,
                isEnabled: isEnabled
            )
            categoryStore.apply(categorySelection, to: new)
            modelContext.insert(new)
            reminder = new
        }

        try? modelContext.save()
        await reminderScheduler.syncAlarms(for: reminder)
        Haptics.success()

        // If editing an already-shared reminder, push the change to participants.
        if editingReminder != nil {
            await sharedService.pushUpdateIfShared(reminder)
        }
        // Mirror create/edit to trusted helpers if delegation is on.
        if settings.delegationEnabled {
            await delegation.pushReminder(reminder)
        }

        guard thenInvite else {
            dismiss()
            return
        }

        // Prepare the share and hand off to the shared invite delivery (Messages).
        isPreparingShare = true
        do {
            let share = try await sharedService.prepareShare(for: reminder)
            isPreparingShare = false

            guard let url = share.url else {
                shareError = SharedRemindersError.shareURLUnavailable.errorDescription
                return
            }

            pendingInvite = InviteDelivery(title: trimmedTitle, url: url)
        } catch {
            isPreparingShare = false
            shareError = error.localizedDescription
        }
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
        guard let r = editingReminder else { return }
        let id = r.id
        let wasOwned = !r.isReceivedShare
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
