//
//  IconPickerView.swift
//  Calarm
//

import ElegantEmojiPicker
import PhotosUI
import SwiftUI

struct IconPickerView: View {
    /// Accent used to tint the picker. SF Symbol suggestions + the default
    /// symbol come from the active category (built-in or custom).
    var tint: Color
    var suggestedSymbols: [String]
    var defaultSymbol: String
    /// Whether to offer the Photo tab (reminders: yes; categories: no).
    var allowsPhoto: Bool = true
    @Binding var iconKind: ReminderIconKind
    @Binding var symbolName: String
    @Binding var photoData: Data?

    @State private var photoItem: PhotosPickerItem?
    @State private var showingEmojiPicker = false
    @State private var pickedEmoji: Emoji?

    // Last selection per tab, so switching Symbol ↔ Emoji round-trips without
    // losing what the user picked (symbolName can only hold one at a time).
    @State private var lastEmoji: String?
    @State private var lastSymbol: String?

    /// Quick one-tap picks; the full searchable picker covers everything else.
    private static let commonEmojis = [
        "🎉", "⭐️", "❤️", "🔥", "✅", "⏰",
        "📅", "💼", "💊", "🎂", "🎁", "✈️"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(selection: $iconKind) {
                Text("Símbolo").tag(ReminderIconKind.symbol)
                Text("Emoji").tag(ReminderIconKind.emoji)
                if allowsPhoto {
                    Text("Foto").tag(ReminderIconKind.photo)
                }
            } label: {
                Text("Tipo")
            }
            .pickerStyle(.segmented)

            Group {
                switch iconKind {
                case .symbol:
                    symbolGrid
                case .emoji:
                    emojiSection
                case .photo:
                    photoSection
                }
            }
            // Swap tabs without animating the structural change: animating it
            // inside a Form row leaves the row with a stale height and the
            // content pushed down under a large empty gap.
            .id(iconKind)
            .transaction { $0.animation = nil }
        }
        .onChange(of: photoItem) { _, newItem in
            Task {
                guard let newItem else { return }
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    await MainActor.run { photoData = data }
                }
            }
        }
        // Keep `symbolName` valid for the active kind: an emoji for the emoji
        // tab, an SF Symbol for the symbol tab. Stash the outgoing value and
        // restore it when the user comes back to that tab.
        .onChange(of: iconKind) { oldKind, newKind in
            switch oldKind {
            case .emoji:
                if isEmojiIcon(symbolName) { lastEmoji = symbolName }
            case .symbol:
                if !isEmojiIcon(symbolName) { lastSymbol = symbolName }
            case .photo:
                break
            }
            switch newKind {
            case .emoji:
                if !isEmojiIcon(symbolName) { symbolName = lastEmoji ?? "🎉" }
            case .symbol:
                if isEmojiIcon(symbolName) { symbolName = lastSymbol ?? defaultSymbol }
            case .photo:
                break
            }
        }
    }

    private var emojiSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack(spacing: DS.Spacing.md) {
                Text(selectedEmoji)
                    .font(.system(size: 40))
                    .frame(width: 64, height: 64)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                            .fill(tint.opacity(0.15))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                            .strokeBorder(tint.opacity(0.35), lineWidth: 1)
                    )
                Spacer()
            }

            // Eager rows instead of LazyVGrid: lazy grids inside a Form row
            // misreport their height when the tab content changes, leaving a
            // large empty gap above the picker.
            eagerGrid(cellCount: Self.commonEmojis.count, columns: 6, hSpacing: 8, vSpacing: 10) { index in
                emojiButton(Self.commonEmojis[index])
            }

            allEmojisButton
        }
        .emojiPicker(
            isPresented: $showingEmojiPicker,
            selectedEmoji: $pickedEmoji,
            configuration: ElegantConfiguration(showRandom: false, showReset: false),
            localization: Self.emojiPickerLocalization
        )
        .onChange(of: pickedEmoji) { _, newValue in
            guard let newValue else { return }
            withAnimation(DS.Motion.snappy) { symbolName = newValue.emoji }
            Haptics.selection()
            // Clear so picking the same emoji again still triggers this.
            pickedEmoji = nil
        }
    }

    private var allEmojisButton: some View {
        Button {
            Haptics.light()
            showingEmojiPicker = true
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                Text("Todos los emojis")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(Color.dsFill)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The library's texts, routed through the app's language override.
    private static var emojiPickerLocalization: ElegantLocalization {
        ElegantLocalization(
            searchFieldPlaceholder: appLocalized("Buscar"),
            searchResultsTitle: appLocalized("Resultados"),
            searchResultsEmptyTitle: appLocalized("No se encontraron emojis"),
            emojiCategoryTitles: [
                .SmileysAndEmotion: appLocalized("Emoticonos y emociones"),
                .PeopleAndBody: appLocalized("Personas y cuerpo"),
                .AnimalsAndNature: appLocalized("Animales y naturaleza"),
                .FoodAndDrink: appLocalized("Comida y bebida"),
                .TravelAndPlaces: appLocalized("Viajes y lugares"),
                .Activities: appLocalized("Actividades"),
                .Objects: appLocalized("Objetos"),
                .Symbols: appLocalized("Símbolos"),
                .Flags: appLocalized("Banderas")
            ]
        )
    }

    private var selectedEmoji: String {
        isEmojiIcon(symbolName) ? symbolName : "🎉"
    }

    private func emojiButton(_ emoji: String) -> some View {
        let isSelected = emoji == selectedEmoji
        return Button {
            withAnimation(DS.Motion.snappy) { symbolName = emoji }
            Haptics.selection()
        } label: {
            Text(emoji)
                .font(.system(size: 26))
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                        .fill(isSelected ? tint.opacity(0.22) : Color.dsFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                        .strokeBorder(isSelected ? tint : .clear, lineWidth: 2)
                )
                .scaleEffect(isSelected ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(emoji))
    }

    private var symbolGrid: some View {
        eagerGrid(cellCount: suggestedSymbols.count, columns: 4, hSpacing: 12, vSpacing: 12) { index in
            symbolButton(suggestedSymbols[index])
        }
    }

    private func symbolButton(_ symbol: String) -> some View {
        let isSelected = symbol == symbolName
        return Button {
            withAnimation(DS.Motion.snappy) { symbolName = symbol }
            Haptics.selection()
        } label: {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(isSelected ? .white : tint)
                .frame(width: 52, height: 52)
                .background(
                    Circle().fill(isSelected ? tint : tint.opacity(0.15))
                )
                .scaleEffect(isSelected ? 1.08 : 1.0)
                .shadow(color: isSelected ? tint.opacity(0.35) : .clear, radius: 8, y: 3)
                .symbolEffect(.bounce, options: .nonRepeating, value: isSelected)
        }
        .buttonStyle(.plain)
    }

    /// Fixed row/column layout with an eager layout pass, so the row height is
    /// always exact. Cells are distributed evenly across the full width.
    private func eagerGrid<Cell: View>(
        cellCount: Int,
        columns: Int,
        hSpacing: CGFloat,
        vSpacing: CGFloat,
        @ViewBuilder cell: @escaping (Int) -> Cell
    ) -> some View {
        let rowCount = (cellCount + columns - 1) / columns
        return VStack(spacing: vSpacing) {
            ForEach(0..<rowCount, id: \.self) { row in
                HStack(spacing: hSpacing) {
                    ForEach(0..<columns, id: \.self) { column in
                        Group {
                            let index = row * columns + column
                            if index < cellCount {
                                cell(index)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var photoSection: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(tint.opacity(0.15))
                    .frame(width: 64, height: 64)
                if let data = photoData, let img = UIImage(data: data) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.title)
                        .foregroundStyle(tint)
                }
            }
            PhotosPicker(
                selection: $photoItem,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Text(photoData == nil ? "Elegir foto" : "Cambiar foto")
            }
            if photoData != nil {
                Button(role: .destructive) {
                    photoData = nil
                    photoItem = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }
}

