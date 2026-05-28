//
//  CategoryPickerView.swift
//  Calarm
//

import SwiftUI

struct CategoryPickerView: View {
    @Binding var selection: CategorySelection
    @Environment(CategoryStore.self) private var categoryStore

    @State private var showingNewCategory = false

    var body: some View {
        let styles = categoryStore.allStyles()
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(styles) { style in
                        chip(for: style)
                            .id(style.selection)
                    }
                    newChip
                }
                .padding(.vertical, 4)
            }
            .onChange(of: selection) { _, newValue in
                withAnimation(DS.Motion.smooth) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
        .sheet(isPresented: $showingNewCategory) {
            CategoryEditorView(category: nil) { newID in
                withAnimation(DS.Motion.snappy) { selection = .custom(newID) }
            }
        }
    }

    private func chip(for style: CategoryStyle) -> some View {
        let isSelected = style.selection == selection
        return Button {
            withAnimation(DS.Motion.snappy) { selection = style.selection }
            Haptics.selection()
        } label: {
            HStack(spacing: 6) {
                CategoryGlyph(iconKind: style.iconKind, iconValue: style.iconValue, isSelected: isSelected)
                Text(style.title)
                    .fontWeight(.medium)
            }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .foregroundStyle(isSelected ? .white : style.color)
            .background(
                Capsule().fill(isSelected ? style.color : style.color.opacity(0.12))
            )
            .scaleEffect(isSelected ? 1.04 : 1.0)
            .shadow(color: isSelected ? style.color.opacity(0.35) : .clear, radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }

    private var newChip: some View {
        Button {
            Haptics.light()
            showingNewCategory = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                Text("Nueva")
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .foregroundStyle(Color.appAccent)
            .background(
                Capsule().strokeBorder(Color.appAccent.opacity(0.5), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            )
        }
        .buttonStyle(.plain)
    }
}

/// Small symbol-or-emoji glyph used in category chips.
struct CategoryGlyph: View {
    let iconKind: ReminderIconKind
    let iconValue: String
    var isSelected: Bool = false

    var body: some View {
        switch iconKind {
        case .emoji:
            Text(iconValue)
        case .symbol, .photo:
            Image(systemName: iconKind == .symbol ? iconValue : "tag.fill")
                .symbolEffect(.bounce, options: .nonRepeating, value: isSelected)
        }
    }
}
