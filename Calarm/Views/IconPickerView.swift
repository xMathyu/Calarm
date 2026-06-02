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
    @FocusState private var emojiFieldFocused: Bool

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
                syncEmojiTextWithSelection()
                emojiFieldFocused = true
            case .symbol:
                if isEmojiIcon(symbolName) { symbolName = defaultSymbol }
                emojiText = ""
            case .photo:
                break
            }
        }
        .onChange(of: symbolName) { _, _ in
            if iconKind == .emoji {
                syncEmojiTextWithSelection()
            }
        }
        .onChange(of: emojiFieldFocused) { _, isFocused in
            guard iconKind == .emoji else { return }
            if isFocused {
                emojiText = ""
            } else {
                syncEmojiTextWithSelection()
            }
        }
    }

    private var emojiSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(selectedEmoji)
                    .font(.system(size: 40))
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(tint.opacity(0.15)))

                TextField("Emoji", text: $emojiText)
                    .font(.system(size: 32))
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                    .frame(width: 72, height: 56)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($emojiFieldFocused)
                    .onChange(of: emojiText) { _, newValue in
                        applyEmojiInput(newValue)
                    }

                Button {
                    emojiFieldFocused = true
                } label: {
                    Image(systemName: "keyboard")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(tint)
                .accessibilityLabel("Elegir emoji")

                Spacer()
            }
            .padding(10)
            .background(Color.dsFill, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
        }
        .onAppear {
            syncEmojiTextWithSelection()
        }
    }

    private var selectedEmoji: String {
        isEmojiIcon(symbolName) ? symbolName : "🎉"
    }

    private func syncEmojiTextWithSelection() {
        let emoji = selectedEmoji
        if emojiText != emoji {
            emojiText = emoji
        }
    }

    private func applyEmojiInput(_ value: String) {
        guard let emoji = value.lastEmojiCluster else {
            if value.isEmpty {
                return
            }
            syncEmojiTextWithSelection()
            return
        }

        if emoji != symbolName {
            withAnimation(DS.Motion.snappy) {
                symbolName = emoji
            }
            Haptics.selection()
        }
        if emojiText != emoji {
            emojiText = emoji
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

private extension String {
    var lastEmojiCluster: String? {
        var result: String?
        for character in self {
            let candidate = String(character)
            if isEmojiIcon(candidate) {
                result = candidate
            }
        }
        return result
    }
}
