//
//  CategoryPickerView.swift
//  Calarm
//

import SwiftUI

struct CategoryPickerView: View {
    @Binding var selection: ReminderCategory

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(ReminderCategory.displayOrder) { category in
                        let isSelected = category == selection
                        Button {
                            withAnimation(DS.Motion.snappy) { selection = category }
                            Haptics.selection()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: category.defaultSymbol)
                                    .symbolEffect(.bounce, options: .nonRepeating, value: isSelected)
                                Text(category.localizedTitle)
                                    .fontWeight(.medium)
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .foregroundStyle(isSelected ? .white : category.tint)
                            .background(
                                Capsule()
                                    .fill(isSelected ? category.tint : category.tint.opacity(0.12))
                            )
                            .scaleEffect(isSelected ? 1.04 : 1.0)
                            .shadow(color: isSelected ? category.tint.opacity(0.35) : .clear, radius: 6, y: 2)
                        }
                        .buttonStyle(.plain)
                        .id(category)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: selection) { _, newValue in
                withAnimation(DS.Motion.smooth) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }
}
