//
//  CategoryPickerView.swift
//  Calarm
//

import SwiftUI

struct CategoryPickerView: View {
    @Binding var selection: ReminderCategory

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(ReminderCategory.allCases) { category in
                    let isSelected = category == selection
                    Button {
                        withAnimation(.snappy) { selection = category }
                        Haptics.selection()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: category.defaultSymbol)
                            Text(category.localizedTitle)
                                .fontWeight(.medium)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .foregroundStyle(isSelected ? Color.white : category.tint)
                        .background(
                            Capsule()
                                .fill(isSelected ? category.tint : category.tint.opacity(0.12))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
