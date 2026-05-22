//
//  ReminderRowView.swift
//  Calarm
//

import SwiftUI

struct ReminderRowView: View {
    let reminder: Reminder
    let nextOccurrence: Date?

    var body: some View {
        HStack(spacing: 14) {
            avatar
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(reminder.title)
                        .font(.headline)
                        .lineLimit(1)
                    if !reminder.isEnabled {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let next = nextOccurrence {
                    Text(next, format: relativeFormat(for: next))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(reminder.category.localizedTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if reminder.recurrence.isRecurring {
                    Label(reminder.recurrence.localizedSummary, systemImage: "repeat")
                        .font(.caption2)
                        .foregroundStyle(reminder.category.tint)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var avatar: some View {
        ZStack {
            Circle().fill(reminder.category.tint.opacity(0.18))
                .frame(width: 48, height: 48)
            switch reminder.iconKind {
            case .photo:
                if let data = reminder.photoData, let img = UIImage(data: data) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 48, height: 48)
                        .clipShape(Circle())
                } else {
                    Image(systemName: reminder.symbolName ?? reminder.category.defaultSymbol)
                        .font(.title3)
                        .foregroundStyle(reminder.category.tint)
                }
            case .symbol:
                Image(systemName: reminder.symbolName ?? reminder.category.defaultSymbol)
                    .font(.title3)
                    .foregroundStyle(reminder.category.tint)
            }
        }
    }

    private func relativeFormat(for date: Date) -> Date.RelativeFormatStyle {
        Date.RelativeFormatStyle(presentation: .named, unitsStyle: .wide)
    }
}
