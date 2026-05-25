//
//  ReminderEditorView.swift
//  Calarm
//

import CloudKit
import MessageUI
import SwiftData
import SwiftUI

struct ReminderEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ReminderScheduler.self) private var reminderScheduler
    @Environment(SharedRemindersService.self) private var sharedService

    // nil = creating new; otherwise editing existing
    let editingReminder: Reminder?

    @State private var title: String
    @State private var notes: String
    @State private var date: Date
    @State private var category: ReminderCategory
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
    @State private var selectedContacts: [SelectedContact] = []
    @State private var showingContactPicker = false
    @State private var isPreparingShare = false
    @State private var messageRecipients: [String] = []
    @State private var messageBody: String = ""
    @State private var showingMessageCompose = false
    @State private var shareURL: URL?
    @State private var showingFallbackShare = false
    @State private var shareError: String?

    init(editing reminder: Reminder? = nil) {
        self.editingReminder = reminder
        if let r = reminder {
            _title = State(initialValue: r.title)
            _notes = State(initialValue: r.notes ?? "")
            _date = State(initialValue: r.date)
            _category = State(initialValue: r.category)
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
            _category = State(initialValue: initialCategory)
            _iconKind = State(initialValue: .symbol)
            _symbolName = State(initialValue: initialCategory.defaultSymbol)
            _photoData = State(initialValue: nil)
            _recurrence = State(initialValue: .once)
            _leadTimes = State(initialValue: [.atStart])
            _isEnabled = State(initialValue: true)
        }
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
                    CategoryPickerView(selection: $category)
                        .onChange(of: category) { _, newValue in
                            if iconKind == .symbol, !newValue.suggestedSymbols.contains(symbolName) {
                                symbolName = newValue.defaultSymbol
                            }
                        }
                } header: {
                    Text("Categoría")
                }

                Section {
                    IconPickerView(
                        category: category,
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
                                .foregroundStyle(category.tint)
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
                                .foregroundStyle(category.tint)
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
                                .background(Capsule().fill(Color.accentColor))
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
            .sheet(isPresented: $showingContactPicker) {
                ContactPickerView(preselected: selectedContacts) { contacts in
                    selectedContacts = contacts
                    showingContactPicker = false
                }
            }
            // Messages pre-filled with recipients and share link — user just taps Enviar
            .sheet(isPresented: $showingMessageCompose, onDismiss: { dismiss() }) {
                MessageComposeView(
                    recipients: messageRecipients,
                    body: messageBody
                ) { showingMessageCompose = false }
            }
            // Fallback: generic share sheet when Messages isn't available
            .sheet(isPresented: $showingFallbackShare, onDismiss: { dismiss() }) {
                if let url = shareURL {
                    ShareLink(
                        item: url,
                        message: Text("Te invito a '\(title)' en Calarm")
                    )
                    .padding()
                }
            }
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
            if selectedContacts.isEmpty {
                Button {
                    Haptics.light()
                    showingContactPicker = true
                } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.accentColor.opacity(0.9), Color.accentColor.opacity(0.55)],
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
                            Text("Comparte este evento por Messages")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                invitedContactsCard
            }
        } header: {
            HStack {
                Text("Invitar amigos")
                if !selectedContacts.isEmpty {
                    Text("\(selectedContacts.count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                }
            }
        } footer: {
            if !selectedContacts.isEmpty {
                Text("Al crear, se abrirá Messages con el link para que ellos acepten. Toca un avatar para quitarlo.")
            }
        }
    }

    private var invitedContactsCard: some View {
        WrapLayout(spacing: 10, lineSpacing: 12) {
            ForEach(selectedContacts) { contact in
                InviteeChip(contact: contact) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        selectedContacts.removeAll { $0.id == contact.id }
                    }
                    Haptics.light()
                }
            }
            AddMoreChip {
                Haptics.light()
                showingContactPicker = true
            }
        }
        .padding(.vertical, 6)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selectedContacts)
    }

    private func save() async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        let reminder: Reminder
        if let existing = editingReminder {
            existing.title = trimmedTitle
            existing.notes = notes.isEmpty ? nil : notes
            existing.date = date
            existing.category = category
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
                category: category,
                iconKind: iconKind,
                symbolName: symbolName,
                photoData: iconKind == .photo ? photoData : nil,
                recurrence: recurrence,
                leadTimes: leadTimes,
                isEnabled: isEnabled
            )
            modelContext.insert(new)
            reminder = new
        }

        try? modelContext.save()
        await reminderScheduler.syncAlarms(for: reminder)
        Haptics.success()

        guard editingReminder == nil, !selectedContacts.isEmpty else {
            dismiss()
            return
        }

        // Prepare share and open Messages pre-filled with recipients
        isPreparingShare = true
        do {
            let share = try await sharedService.prepareShare(for: reminder)
            isPreparingShare = false

            guard let url = share.url else {
                dismiss()
                return
            }

            let phones = selectedContacts.flatMap { $0.phoneNumbers }.filter { !$0.isEmpty }
            let inviteText = "Te invito a '\(trimmedTitle)' en Calarm — acepta aquí: \(url.absoluteString)"

            if MFMessageComposeViewController.canSendText(), !phones.isEmpty {
                messageRecipients = phones
                messageBody = inviteText
                showingMessageCompose = true
            } else {
                // Fallback: generic share sheet (AirDrop, Mail, WhatsApp, etc.)
                shareURL = url
                showingFallbackShare = true
            }
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
                    if let suggestedCategory = ReminderCategory.from(slug: suggestion.category),
                       suggestedCategory != category {
                        suggestionChip(
                            icon: suggestedCategory.defaultSymbol,
                            label: suggestedCategory.localizedTitle,
                            tint: suggestedCategory.tint
                        )
                    }
                    let suggestedRecurrence = AlarmSuggestionsService.recurrence(fromSlug: suggestion.recurrence)
                    if suggestedRecurrence.localizedSummary != recurrence.localizedSummary {
                        suggestionChip(
                            icon: "repeat",
                            label: suggestedRecurrence.localizedSummary,
                            tint: .accentColor
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
            if let suggestedCategory = ReminderCategory.from(slug: suggestion.category) {
                category = suggestedCategory
                if iconKind == .symbol {
                    symbolName = suggestedCategory.defaultSymbol
                }
            }
            recurrence = AlarmSuggestionsService.recurrence(fromSlug: suggestion.recurrence)
            leadTimes = AlarmSuggestionsService.leadTimes(fromMinutes: suggestion.leadTimesMinutes)
            pendingSuggestion = nil
        }
        Haptics.success()
    }

    private func deleteReminder() async {
        guard let r = editingReminder else { return }
        await reminderScheduler.cancelAlarms(for: r)
        modelContext.delete(r)
        try? modelContext.save()
        Haptics.warning()
        dismiss()
    }
}

// MARK: - Invitee chips

private struct InviteeChip: View {
    let contact: SelectedContact
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ContactAvatarView(name: contact.name, imageData: contact.imageData, size: 28)
            Text(firstName)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color(.systemGray2))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Quitar \(contact.name)")
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color(.tertiarySystemFill))
        )
        .transition(.scale.combined(with: .opacity))
    }

    private var firstName: String {
        contact.name.split(separator: " ").first.map(String.init) ?? contact.name
    }
}

private struct AddMoreChip: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                Text("Agregar")
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(Color.accentColor)
            .background(
                Capsule()
                    .strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            )
        }
        .buttonStyle(.plain)
    }
}
