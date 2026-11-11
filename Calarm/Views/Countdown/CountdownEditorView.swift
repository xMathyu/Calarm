//
//  CountdownEditorView.swift
//  Calarm
//
//  Crear o editar una cuenta regresiva: nombre, fecha (con hora opcional),
//  si vuelve cada año, y su imagen —emoji, símbolo o una foto de fondo— y
//  color. Arriba, la tarjeta tal como va a quedar en la lista.
//

import SwiftData
import SwiftUI

struct CountdownEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SharedRemindersService.self) private var sharedService

    /// nil = nueva.
    let event: CountdownEvent?
    /// Quien la presenta se encarga de cerrar y borrar (el detalle tiene que
    /// irse antes de que el modelo desaparezca). Sin él, el editor la borra solo.
    var onDelete: (() -> Void)? = nil

    @State private var draftID: UUID
    @State private var title: String
    @State private var notes: String
    @State private var date: Date
    @State private var includesTime: Bool
    @State private var repeatsYearly: Bool
    @State private var colorHex: String
    @State private var iconKind: ReminderIconKind
    @State private var iconValue: String
    @State private var photoData: Data?
    /// La última foto ya reducida, para no volver a procesar la que acabamos de
    /// escribir (`onChange` salta también con ella).
    @State private var preparedPhoto: Data?
    @State private var isPreparingPhoto = false
    @State private var confirmingDelete = false
    @FocusState private var titleFocused: Bool

    private static let suggestedSymbols = [
        "music.mic", "ticket.fill", "airplane", "suitcase.rolling.fill",
        "birthday.cake.fill", "gift.fill", "heart.fill", "party.popper.fill",
        "graduationcap.fill", "sportscourt.fill", "film.fill", "star.fill"
    ]

    init(editing event: CountdownEvent?, onDelete: (() -> Void)? = nil) {
        self.event = event
        self.onDelete = onDelete
        _draftID = State(initialValue: event?.id ?? UUID())
        _title = State(initialValue: event?.title ?? "")
        _notes = State(initialValue: event?.notes ?? "")
        _date = State(initialValue: event?.date ?? Self.defaultDate())
        _includesTime = State(initialValue: event?.includesTime ?? false)
        _repeatsYearly = State(initialValue: event?.repeatsYearly ?? false)
        _colorHex = State(initialValue: event?.colorHex ?? CountdownEvent.defaultColorHex)
        _iconKind = State(initialValue: event?.iconKind ?? .emoji)
        _iconValue = State(initialValue: event?.iconValue ?? CountdownEvent.defaultEmoji)
        _photoData = State(initialValue: event?.photoData)
        _preparedPhoto = State(initialValue: event?.photoData)
    }

    /// Dentro de un mes a las 20:00: la hora típica de un concierto, por si
    /// la persona enciende «Hora».
    private static func defaultDate() -> Date {
        let calendar = Calendar.current
        let inAMonth = calendar.date(byAdding: .month, value: 1, to: Date()) ?? Date()
        return calendar.date(bySettingHour: 20, minute: 0, second: 0, of: inAMonth) ?? inAMonth
    }

    private var color: Color { Color(hex: colorHex) ?? .pink }
    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var draft: CountdownCardContent {
        CountdownCardContent(
            id: draftID,
            title: trimmedTitle,
            date: date,
            includesTime: includesTime,
            repeatsYearly: repeatsYearly,
            color: color,
            iconKind: iconKind,
            iconValue: iconValue,
            photoData: photoData
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CountdownCardView(content: draft, now: Date())
                        .animation(DS.Motion.smooth, value: iconKind)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section {
                    TextField("Nombre del evento", text: $title)
                        .font(.headline)
                        .focused($titleFocused)
                        .submitLabel(.done)
                    TextField("Notas (opcional)", text: $notes, axis: .vertical)
                        .lineLimit(1...4)
                } footer: {
                    if event == nil {
                        Text("Por ejemplo «Concierto de Coldplay» o «Viaje a Japón».")
                    }
                }

                Section {
                    DatePicker(selection: $date, displayedComponents: [.date]) {
                        Label("Fecha", systemImage: "calendar")
                    }
                    Toggle(isOn: $includesTime.animation(DS.Motion.snappy)) {
                        Label("Hora", systemImage: "clock.fill")
                    }
                    if includesTime {
                        DatePicker(selection: $date, displayedComponents: [.hourAndMinute]) {
                            Text("A las")
                        }
                    }
                    Toggle(isOn: $repeatsYearly) {
                        Label("Repetir cada año", systemImage: "repeat")
                    }
                } footer: {
                    if repeatsYearly {
                        Text("Para cumpleaños y aniversarios: al llegar el día, la cuenta empieza de nuevo para el año siguiente.")
                    } else if includesTime {
                        Text("Con hora, la pantalla del evento cuenta también horas, minutos y segundos.")
                    }
                }

                Section {
                    IconPickerView(
                        tint: color,
                        suggestedSymbols: Self.suggestedSymbols,
                        defaultSymbol: "star.fill",
                        allowsPhoto: true,
                        iconKind: $iconKind,
                        symbolName: $iconValue,
                        photoData: $photoData
                    )
                } header: {
                    Text("Imagen")
                } footer: {
                    if iconKind == .photo {
                        Text("La foto ocupa toda la tarjeta, como fondo.")
                    }
                }

                if iconKind != .photo {
                    Section {
                        colorPalette
                        ColorPicker(selection: colorBinding, supportsOpacity: false) {
                            Label("Personalizado", systemImage: "eyedropper.halffull")
                        }
                    } header: {
                        Text("Color")
                    }
                }

                if event != nil {
                    Section {
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Label("Borrar evento", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(appLocalized(event == nil ? "Nuevo evento" : "Editar evento"))
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(appLocalized(event == nil ? "Crear" : "Guardar")) { save() }
                        .bold()
                        .disabled(trimmedTitle.isEmpty || isPreparingPhoto)
                }
            }
            .onAppear {
                if event == nil { titleFocused = true }
            }
            .onChange(of: photoData) { _, newValue in
                preparePhoto(newValue)
            }
            .confirmationDialog(
                appLocalized("¿Borrar esta cuenta regresiva?"),
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Borrar", role: .destructive) { delete() }
            }
        }
    }

    // MARK: - Color

    /// Filas fijas en vez de LazyVGrid: dentro de un Form la rejilla perezosa
    /// calcula mal su alto.
    private var colorPalette: some View {
        let presets = AppSettings.accentPresets
        let columns = 5
        let rows = stride(from: 0, to: presets.count, by: columns).map {
            Array(presets[$0..<min($0 + columns, presets.count)])
        }
        return VStack(spacing: DS.Spacing.md) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: DS.Spacing.md) {
                    ForEach(0..<columns, id: \.self) { index in
                        if index < row.count {
                            colorSwatch(row[index])
                        } else {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 34)
                        }
                    }
                }
            }
        }
        .padding(.vertical, DS.Spacing.xs)
    }

    private func colorSwatch(_ hex: String) -> some View {
        let isSelected = hex.uppercased() == colorHex.uppercased()
        return Button {
            withAnimation(DS.Motion.snappy) { colorHex = hex }
            Haptics.selection()
        } label: {
            Circle()
                .fill(Color(hex: hex) ?? .accentColor)
                .frame(width: 34, height: 34)
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .scaleEffect(isSelected ? 1.12 : 1.0)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { color },
            set: { if let hex = $0.toHex() { colorHex = hex } }
        )
    }

    // MARK: - Photo

    /// Reduce la foto recién elegida fuera del hilo principal y la cambia por la
    /// versión reducida.
    private func preparePhoto(_ data: Data?) {
        guard let data else {
            // Foto quitada (aunque se estuviera procesando otra).
            isPreparingPhoto = false
            return
        }
        guard data != preparedPhoto else { return }
        isPreparingPhoto = true
        Task {
            let prepared = await Task.detached(priority: .userInitiated) {
                CountdownPhoto.prepared(from: data)
            }.value
            // Otra foto elegida mientras tanto: esa manda.
            guard photoData == data else { return }
            let result = prepared ?? data
            preparedPhoto = result
            photoData = result
            isPreparingPhoto = false
        }
    }

    // MARK: - Save / delete

    private func save() {
        guard !trimmedTitle.isEmpty else { return }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let target: CountdownEvent
        if let event {
            target = event
        } else {
            target = CountdownEvent(id: draftID)
            modelContext.insert(target)
        }
        target.title = trimmedTitle
        target.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        target.date = includesTime ? date : Calendar.current.startOfDay(for: date)
        target.includesTime = includesTime
        target.repeatsYearly = repeatsYearly
        target.colorHex = colorHex
        target.iconKind = iconKind
        target.iconValue = iconValue
        // La foto solo se guarda si es el icono elegido: si no, ocuparía iCloud
        // sin verse nunca.
        target.photoData = iconKind == .photo ? photoData : nil
        target.updatedAt = Date()
        try? modelContext.save()
        // Si está compartida, los invitados ven el cambio (no-op si no lo está).
        let sharing = sharedService
        Task { await sharing.pushUpdateIfShared(countdown: target) }
        Haptics.success()
        dismiss()
    }

    private func delete() {
        if let onDelete {
            onDelete()
            return
        }
        guard let event else { return }
        let context = modelContext
        let sharing = sharedService
        let id = event.id
        let wasReceived = event.isReceivedShare
        Haptics.warning()
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            context.delete(event)
            try? context.save()
            await sharing.countdownDeleted(id: id, wasReceived: wasReceived)
        }
    }
}
