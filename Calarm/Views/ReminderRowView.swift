//
//  ReminderRowView.swift
//  Calarm
//

import SwiftUI

struct ReminderRowView: View {
    @Environment(CategoryStore.self) private var categoryStore
    let reminder: Reminder
    let nextOccurrence: Date?

    private var style: CategoryStyle { categoryStore.style(for: reminder) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
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
                        Text(style.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: DS.Spacing.sm)

                if let next = nextOccurrence {
                    timeChip(for: next)
                }
            }

            // Pills live on their own full-width row so a long recurrence summary
            // (e.g. "Weekly (Mon, Tue, Wed, Thu, Fri)") and the "Shared" badge
            // aren't squeezed next to the time chip. Indented to align under the title.
            if reminder.recurrence.isRecurring || reminder.isReceivedShare || !reminder.additionalSchedules.isEmpty {
                WrapLayout(spacing: DS.Spacing.xs, lineSpacing: 6) {
                    if reminder.recurrence.isRecurring {
                        Label(reminder.recurrence.localizedSummary, systemImage: "repeat")
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, DS.Spacing.sm)
                            .padding(.vertical, 3)
                            .foregroundStyle(style.color)
                            .background(style.color.opacity(0.13), in: Capsule())
                    }
                    if !reminder.additionalSchedules.isEmpty {
                        // Alarm fires on more than one day/time — surface the count.
                        Label("+\(reminder.additionalSchedules.count)", systemImage: "calendar.badge.clock")
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, DS.Spacing.sm)
                            .padding(.vertical, 3)
                            .foregroundStyle(style.color)
                            .background(style.color.opacity(0.13), in: Capsule())
                    }
                    if reminder.isReceivedShare {
                        Label("Compartido", systemImage: "person.2.fill")
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, DS.Spacing.sm)
                            .padding(.vertical, 3)
                            .foregroundStyle(.secondary)
                            .background(Color.dsFill, in: Capsule())
                    }
                }
                .padding(.leading, DS.AvatarSize.md + DS.Spacing.md)
            }
        }
        .padding(.vertical, DS.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .animation(DS.Motion.snappy, value: reminder.isEnabled)
        .accessibilityElement(children: .combine)
    }

    private var avatar: some View {
        ReminderIconView(
            iconKind: reminder.iconKind,
            iconValue: reminder.symbolName,
            photoData: reminder.photoData,
            fallbackSymbol: style.iconKind == .symbol ? style.iconValue : "bell.fill",
            tint: style.color,
            size: DS.AvatarSize.md,
            shape: .circle,
            bounceValue: reminder.isEnabled
        )
    }

    private func timeChip(for date: Date) -> some View {
        let calendar = Calendar.current
        let isWithinNextDay = date.timeIntervalSinceNow < 60 * 60 * 24 && date > Date()

        return VStack(alignment: .trailing, spacing: 2) {
            Text(date, format: .dateTime.hour().minute())
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isWithinNextDay ? style.color : .primary)
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
                ? style.color.opacity(0.10)
                : Color.dsFill,
            in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
        )
    }
}
