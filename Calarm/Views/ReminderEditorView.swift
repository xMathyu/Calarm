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
    @State private var leadTime: AlarmLeadTime
    @State private var isEnabled: Bool

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
            _leadTime = State(initialValue: r.leadTime)
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
            _leadTime = State(initialValue: .atStart)
            _isEnabled = State(initialValue: true)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Información") {
                    TextField("Título", text: $title)
                    TextField("Notas (opcional)", text: $notes, axis: .vertical)
                        .lineLimit(1...4)
                }

                Section("Categoría") {
                    CategoryPickerView(selection: $category)
                        .onChange(of: category) { _, newValue in
                            if iconKind == .symbol, !newValue.suggestedSymbols.contains(symbolName) {
                                symbolName = newValue.defaultSymbol
                            }
                        }
                }

                Section("Icono") {
                    IconPickerView(
                        category: category,
                        iconKind: $iconKind,
                        symbolName: $symbolName,
                        photoData: $photoData
                    )
                }

                Section("Fecha y hora") {
                    DatePicker("Fecha", selection: $date, displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical)
                }

                Section("Aviso") {
                    Picker("Cuándo sonar", selection: $leadTime) {
                        ForEach(AlarmLeadTime.allCases) { value in
                            Text(value.localizedTitle).tag(value)
                        }
                    }
                }

                Section("Repetir") {
                    NavigationLink {
                        RecurrencePickerView(rule: $recurrence, baseDate: date)
                    } label: {
                        LabeledContent("Repetir", value: recurrence.localizedSummary)
                    }
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
            // Contact picker sheet
            .sheet(isPresented: $showingContactPicker) {
                ContactPickerView { contacts in
                    for contact in contacts where !selectedContacts.contains(where: { $0.id == contact.id }) {
                        selectedContacts.append(contact)
                    }
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
                    showingContactPicker = true
                } label: {
                    Label("Invitar amigos", systemImage: "person.badge.plus")
                }
            } else {
                ForEach(selectedContacts) { contact in
                    HStack {
                        Label(contact.name, systemImage: "person.circle")
                        Spacer()
                        Button {
                            selectedContacts.removeAll { $0.id == contact.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button {
                    showingContactPicker = true
                } label: {
                    Label("Agregar más", systemImage: "person.badge.plus")
                }
            }
        } header: {
            Text("Invitar amigos")
        } footer: {
            if !selectedContacts.isEmpty {
                Text("Al crear, se abrirá Messages con el link para que ellos acepten.")
            }
        }
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
            existing.leadTime = leadTime
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
                leadTime: leadTime,
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

    private func deleteReminder() async {
        guard let r = editingReminder else { return }
        await reminderScheduler.cancelAlarms(for: r)
        modelContext.delete(r)
        try? modelContext.save()
        Haptics.warning()
        dismiss()
    }
}
