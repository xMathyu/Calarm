//
//  IconPickerView.swift
//  Calarm
//

import PhotosUI
import SwiftUI

struct IconPickerView: View {
    let category: ReminderCategory
    @Binding var iconKind: ReminderIconKind
    @Binding var symbolName: String
    @Binding var photoData: Data?

    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Tipo", selection: $iconKind) {
                Text("Símbolo").tag(ReminderIconKind.symbol)
                Text("Foto").tag(ReminderIconKind.photo)
            }
            .pickerStyle(.segmented)

            switch iconKind {
            case .symbol:
                symbolGrid
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
    }

    private var symbolGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            ForEach(category.suggestedSymbols, id: \.self) { symbol in
                let isSelected = symbol == symbolName
                Button {
                    withAnimation(DS.Motion.snappy) { symbolName = symbol }
                    Haptics.selection()
                } label: {
                    Image(systemName: symbol)
                        .font(.title2)
                        .foregroundStyle(isSelected ? .white : category.tint)
                        .frame(width: 52, height: 52)
                        .background(
                            Circle().fill(isSelected ? category.tint : category.tint.opacity(0.15))
                        )
                        .scaleEffect(isSelected ? 1.08 : 1.0)
                        .shadow(color: isSelected ? category.tint.opacity(0.35) : .clear, radius: 8, y: 3)
                        .symbolEffect(.bounce, options: .nonRepeating, value: isSelected)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var photoSection: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(category.tint.opacity(0.15))
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
                        .foregroundStyle(category.tint)
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
