//
//  CategoryEditorView.swift
//  Calarm
//
//  Create or edit a user-defined category: name, color, and icon (SF Symbol or
//  emoji). Photos aren't offered for categories.
//

import SwiftUI

struct CategoryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CategoryStore.self) private var categoryStore

    /// nil = creating a new category.
    let category: CustomCategory?
    /// Called with the saved category's id (for auto-selecting a new one).
    var onSave: (UUID) -> Void = { _ in }

    @State private var name: String
    @State private var colorHex: String
    @State private var iconKind: ReminderIconKind
    @State private var iconValue: String

    private static let suggestedSymbols = [
        "star.fill", "heart.fill", "flag.fill", "bell.fill", "bookmark.fill", "tag.fill",
        "house.fill", "briefcase.fill", "cart.fill", "creditcard.fill", "gift.fill", "gamecontroller.fill",
        "figure.run", "dumbbell.fill", "book.fill", "graduationcap.fill", "pawprint.fill", "leaf.fill",
        "fork.knife", "cup.and.saucer.fill", "airplane", "car.fill", "cross.case.fill", "pills.fill",
        "music.note", "paintbrush.fill", "camera.fill", "film.fill", "calendar", "alarm.fill"
    ]

    init(category: CustomCategory?, onSave: @escaping (UUID) -> Void = { _ in }) {
        self.category = category
        self.onSave = onSave
        _name = State(initialValue: category?.name ?? "")
        _colorHex = State(initialValue: category?.colorHex ?? "#5856D6")
        _iconKind = State(initialValue: category?.iconKind ?? .symbol)
        _iconValue = State(initialValue: category?.iconValue ?? "star.fill")
    }

    private var color: Color { Color(hex: colorHex) ?? .accentColor }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: DS.Spacing.lg) {
                        ReminderIconView(
                            iconKind: iconKind,
                            iconValue: iconValue,
                            fallbackSymbol: "star.fill",
                            tint: color,
                            size: 56,
                            shape: .roundedRect(DS.Radius.md)
                        )
                        Text(trimmedName.isEmpty ? appLocalized("Nueva categoría") : trimmedName)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(trimmedName.isEmpty ? .secondary : .primary)
                        Spacer()
                    }
                    .padding(.vertical, DS.Spacing.xs)
                }

                Section {
                    TextField("Nombre", text: $name)
                } header: {
                    Text("Nombre")
                }

                Section {
                    colorPalette
                    ColorPicker(selection: colorBinding, supportsOpacity: false) {
                        Label("Personalizado", systemImage: "eyedropper.halffull")
                    }
                } header: {
                    Text("Color")
                }

                Section {
                    IconPickerView(
                        tint: color,
                        suggestedSymbols: Self.suggestedSymbols,
                        defaultSymbol: "star.fill",
                        allowsPhoto: false,
                        iconKind: $iconKind,
                        symbolName: $iconValue,
                        photoData: .constant(nil)
                    )
                } header: {
                    Text("Icono")
                }

                if let category {
                    Section {
                        Button(role: .destructive) {
                            categoryStore.delete(category)
                            Haptics.warning()
                            dismiss()
                        } label: {
                            Label("Borrar categoría", systemImage: "trash")
                        }
                    } footer: {
                        Text("Las alarmas con esta categoría volverán a una categoría predefinida.")
                    }
                }
            }
            .navigationTitle(category == nil ? "Nueva categoría" : "Editar categoría")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(category == nil ? "Crear" : "Guardar") { save() }
                        .disabled(trimmedName.isEmpty)
                        .bold()
                }
            }
        }
    }

    private var colorPalette: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.md), count: 5)
        return LazyVGrid(columns: columns, spacing: DS.Spacing.md) {
            ForEach(AppSettings.accentPresets, id: \.self) { hex in
                let isSelected = hex.uppercased() == colorHex.uppercased()
                Button {
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
        }
        .padding(.vertical, DS.Spacing.xs)
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { color },
            set: { if let hex = $0.toHex() { colorHex = hex } }
        )
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        if let category {
            categoryStore.update(category, name: trimmedName, colorHex: colorHex, iconKind: iconKind, iconValue: iconValue)
            onSave(category.id)
        } else {
            let created = categoryStore.add(name: trimmedName, colorHex: colorHex, iconKind: iconKind, iconValue: iconValue)
            onSave(created.id)
        }
        Haptics.success()
        dismiss()
    }
}
