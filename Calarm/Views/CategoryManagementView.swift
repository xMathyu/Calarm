//
//  CategoryManagementView.swift
//  Calarm
//
//  Lists the user's custom categories with create / edit / delete. Reached from
//  Settings.
//

import SwiftUI

struct CategoryManagementView: View {
    @Environment(CategoryStore.self) private var categoryStore

    @State private var editingCategory: CustomCategory?
    @State private var creatingNew = false

    var body: some View {
        List {
            Section {
                ForEach(categoryStore.customCategories) { category in
                    Button {
                        editingCategory = category
                    } label: {
                        row(category)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    let toDelete = offsets.map { categoryStore.customCategories[$0] }
                    for category in toDelete { categoryStore.delete(category) }
                    Haptics.warning()
                }

                Button {
                    creatingNew = true
                } label: {
                    Label("Nueva categoría", systemImage: "plus.circle.fill")
                        .foregroundStyle(.tint)
                }
            } footer: {
                Text("Crea categorías propias con su color y emoji o ícono. Aparecen junto a las predefinidas al crear una alarma.")
            }
        }
        .navigationTitle("Categorías")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if categoryStore.customCategories.isEmpty {
                ContentUnavailableView {
                    Label("Sin categorías propias", systemImage: "square.grid.2x2")
                } description: {
                    Text("Toca \"Nueva categoría\" para crear la primera.")
                }
            }
        }
        .sheet(item: $editingCategory) { category in
            CategoryEditorView(category: category)
        }
        .sheet(isPresented: $creatingNew) {
            CategoryEditorView(category: nil)
        }
    }

    private func row(_ category: CustomCategory) -> some View {
        HStack(spacing: DS.Spacing.md) {
            ReminderIconView(
                iconKind: category.iconKind,
                iconValue: category.iconValue,
                fallbackSymbol: "star.fill",
                tint: category.color,
                size: DS.AvatarSize.sm,
                shape: .circle
            )
            Text(category.name)
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
