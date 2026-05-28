//
//  IconPickerView.swift
//  Calarm
//

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
    @State private var emojiText: String = ""

    private static let commonEmojis = [
        "🎉", "🎂", "🎁", "❤️", "⭐️", "🔥", "💪", "📚", "💼", "🏃", "🧘", "🐶",
        "🐱", "🌱", "☕️", "🍔", "✈️", "🏠", "💊", "💰", "📅", "⏰", "🎵", "🎮",
        "⚽️", "🎨", "📸", "💡", "🛒", "🩺", "🦷", "🚗", "🌙", "☀️", "✅", "🎓"
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

            switch iconKind {
            case .symbol:
                symbolGrid
            case .emoji:
                emojiSection
            case .photo:
                photoSection
            }
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
        // tab, an SF Symbol for the symbol tab.
        .onChange(of: iconKind) { _, newKind in
            switch newKind {
            case .emoji:
                if !isEmojiIcon(symbolName) { symbolName = "🎉" }
            case .symbol:
                if isEmojiIcon(symbolName) { symbolName = defaultSymbol }
            case .photo:
                break
            }
        }
    }

    private var emojiSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(isEmojiIcon(symbolName) ? symbolName : "🎉")
                    .font(.system(size: 40))
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(tint.opacity(0.15)))
                Text("Toca un emoji o escribe el tuyo abajo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 10) {
                ForEach(Self.commonEmojis, id: \.self) { emoji in
                    let isSelected = emoji == symbolName
                    Button {
                        withAnimation(DS.Motion.snappy) { symbolName = emoji }
                        Haptics.selection()
                    } label: {
                        Text(emoji)
                            .font(.system(size: 26))
                            .frame(width: 46, height: 46)
                            .background(
                                Circle().fill(isSelected ? tint.opacity(0.30) : tint.opacity(0.10))
                            )
                            .overlay(Circle().strokeBorder(isSelected ? tint : .clear, lineWidth: 2))
                            .scaleEffect(isSelected ? 1.08 : 1.0)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .foregroundStyle(.secondary)
                TextField("Cualquier emoji", text: $emojiText)
                    .autocorrectionDisabled()
                    .onChange(of: emojiText) { _, newValue in
                        if let last = newValue.last, isEmojiIcon(String(last)) {
                            symbolName = String(last)
                            Haptics.selection()
                        }
                        if !newValue.isEmpty { emojiText = "" }
                    }
            }
            .padding(10)
            .background(Color.dsFill, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
        }
    }

    private var symbolGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            ForEach(suggestedSymbols, id: \.self) { symbol in
                let isSelected = symbol == symbolName
                Button {
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
