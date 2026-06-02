//
//  DelegationHelperEditorView.swift
//  Calarm
//
//  Editor a trusted helper uses to create/edit an alarm FOR a principal. It writes
//  a `SharePayload` straight into the principal's shared zone (never a local
//  `Reminder`), so the alarm rings on the principal's phone, not the helper's.
//

import CloudKit
import SwiftUI

struct DelegationHelperEditorView: View {
    @Environment(DelegationService.self) private var delegation
    @Environment(\.dismiss) private var dismiss

    let principal: DelegationPrincipal
    let existing: DelegatedReminder?

    @State private var title: String = ""
    @State private var notes: String = ""
    @State private var date: Date = Date()
    @State private var category: ReminderCategory = .event
    @State private var recurrence: RecurrenceRule = .once
    @State private var leadTime: AlarmLeadTime = .atStart
    @State private var isEnabled = true
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Título", text: $title)
                    DatePicker("Fecha y hora", selection: $date)
                    Toggle("Activa", isOn: $isEnabled)
                }
                Section("Categoría") {
                    Picker("Categoría", selection: $category) {
                        ForEach(ReminderCategory.displayOrder) { cat in
                            Label(cat.localizedTitle, systemImage: cat.defaultSymbol).tag(cat)
                        }
                    }
                }
                Section("Aviso") {
                    Picker("Avisar", selection: $leadTime) {
                        ForEach(AlarmLeadTime.allCases, id: \.self) { lead in
                            Text(lead.shortTitle).tag(lead)
                        }
                    }
                }
                Section("Repetición") {
                    RecurrencePickerView(rule: $recurrence, baseDate: date)
                }
                Section("Notas") {
                    TextField("Notas", text: $notes, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .navigationTitle(existing == nil ? "Nueva alarma" : "Editar alarma")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Guardar") { Task { await save() } }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
            .onAppear(perform: prefill)
        }
    }

    private func prefill() {
        guard let existing else { return }
        let p = existing.payload
        title = p.title
        notes = p.notes ?? ""
        date = p.date
        category = ReminderCategory(rawValue: p.categoryRaw) ?? .event
        recurrence = (try? JSONDecoder().decode(RecurrenceRule.self, from: p.recurrenceData)) ?? .once
        leadTime = AlarmLeadTime(rawValue: p.leadTimeSeconds.first ?? AlarmLeadTime.atStart.rawValue) ?? .atStart
        isEnabled = p.isEnabled
    }

    private func save() async {
        isSaving = true
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Preserve a photo icon when editing (the helper editor doesn't add/change
        // photos); otherwise the glyph follows the chosen category.
        let isPhoto = existing?.payload.iconKindRaw == ReminderIconKind.photo.rawValue
        let payload = SharePayload(
            version: SharePayload.currentVersion,
            id: existing?.payload.id ?? UUID().uuidString,
            title: trimmed,
            notes: notes.isEmpty ? nil : notes,
            date: date,
            categoryRaw: category.rawValue,
            iconKindRaw: isPhoto ? ReminderIconKind.photo.rawValue : ReminderIconKind.symbol.rawValue,
            symbolName: isPhoto ? existing?.payload.symbolName : category.defaultSymbol,
            leadTimeSeconds: [leadTime.rawValue],
            isEnabled: isEnabled,
            recurrenceData: (try? JSONEncoder().encode(recurrence)) ?? Data(),
            customCategory: nil,
            photoThumbnail: isPhoto ? existing?.payload.photoThumbnail : nil
        )
        await delegation.helperUpsert(payload, in: principal.zoneID, existingRecordID: existing?.recordID)
        Haptics.success()
        isSaving = false
        dismiss()
    }
}
