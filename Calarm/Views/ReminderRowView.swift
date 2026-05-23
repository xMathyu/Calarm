//
//  ReminderRowView.swift
//  Calarm
//

import SwiftUI

struct ReminderRowView: View {
    let reminder: Reminder
    let nextOccurrence: Date?

    var body: some View {
        HStack(spacing: DS.Spacing.md) {
            avatar
                .opacity(reminder.isEnabled ? 1 : 0.55)

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                HStack(spacing: DS.Spacing.xs) {
                    Text(reminder.title)
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundStyle(reminder.isEnabled ? .primary : .secondary)
                    if !reminder.isEnabled {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .transition(.scale.combined(with: .opacity))
                    }
                }

                if let next = nextOccurrence {
                    Text(next, format: Date.RelativeFormatStyle(presentation: .named, unitsStyle: .wide))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(reminder.category.localizedTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if reminder.recurrence.isRecurring || reminder.isReceivedShare {
                    HStack(spacing: DS.Spacing.xs) {
                        if reminder.recurrence.isRecurring {
                            Label(reminder.recurrence.localizedSummary, systemImage: "repeat")
                                .labelStyle(.titleAndIcon)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, DS.Spacing.sm)
                                .padding(.vertical, 3)
                                .foregroundStyle(reminder.category.tint)
                                .background(reminder.category.tint.opacity(0.13), in: Capsule())
                        }
                        if reminder.isReceivedShare {
                            Label("Compartido", systemImage: "person.2.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, DS.Spacing.sm)
                                .padding(.vertical, 3)
                                .foregroundStyle(.secondary)
                                .background(Color.dsFill, in: Capsule())
                        }
                    }
                }
            }

            Spacer(minLength: DS.Spacing.sm)

            if let next = nextOccurrence {
                timeChip(for: next)
            }
        }
        .padding(.vertical, DS.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .animation(DS.Motion.snappy, value: reminder.isEnabled)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var avatar: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            reminder.category.tint.opacity(0.28),
                            reminder.category.tint.opacity(0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: DS.AvatarSize.md, height: DS.AvatarSize.md)

            switch reminder.iconKind {
            case .photo:
                if let data = reminder.photoData, let img = UIImage(data: data) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: DS.AvatarSize.md, height: DS.AvatarSize.md)
                        .clipShape(Circle())
                } else {
                    Image(systemName: reminder.symbolName ?? reminder.category.defaultSymbol)
                        .font(.title3)
                        .foregroundStyle(reminder.category.tint)
                        .symbolEffect(.bounce, options: .nonRepeating, value: reminder.isEnabled)
                }
            case .symbol:
                Image(systemName: reminder.symbolName ?? reminder.category.defaultSymbol)
                    .font(.title3)
                    .foregroundStyle(reminder.category.tint)
                    .symbolEffect(.bounce, options: .nonRepeating, value: reminder.isEnabled)
            }
        }
    }

    private func timeChip(for date: Date) -> some View {
        let calendar = Calendar.current
        let isWithinNextDay = date.timeIntervalSinceNow < 60 * 60 * 24 && date > Date()

        return VStack(alignment: .trailing, spacing: 2) {
            Text(date, format: .dateTime.hour().minute())
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isWithinNextDay ? reminder.category.tint : .primary)
            if !calendar.isDateInToday(date) && !calendar.isDateInTomorrow(date) {
                Text(date, format: .dateTime.day().month(.abbreviated))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xs)
        .background(
            isWithinNextDay
                ? reminder.category.tint.opacity(0.10)
                : Color.dsFill,
            in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
        )
    }
}
