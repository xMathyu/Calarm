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

    /// The alarm rings within the next 24h — worth tinting so it stands out.
    private var isSoon: Bool {
        guard let next = nextOccurrence else { return false }
        return next > Date() && next.timeIntervalSinceNow < 60 * 60 * 24
    }

    var body: some View {
        HStack(spacing: DS.Spacing.md) {
            avatar

            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.title)
                    .font(.headline)
                    .lineLimit(1)

                // The time is the line that matters most, so it gets the weight
                // (and the category tint when the alarm is about to ring); the
                // day sits next to it as quieter context.
                if let next = nextOccurrence {
                    HStack(spacing: DS.Spacing.xs) {
                        Text(next, format: .dateTime.hour().minute())
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(isSoon ? style.color : .primary)
                        Text(dayLabel(for: next))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text(style.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if hasBadges {
                    badges
                        .padding(.top, 1)
                }
            }

            Spacer(minLength: DS.Spacing.sm)
        }
        // Off alarms stay legible but visibly muted — the switch says on/off,
        // so the row doesn't need a second "disabled" icon.
        .opacity(reminder.isEnabled ? 1 : 0.45)
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

    private var hasBadges: Bool {
        reminder.recurrence.isRecurring
            || reminder.isReceivedShare
            || !reminder.additionalSchedules.isEmpty
    }

    /// Recurrence / extra schedules / shared, as one quiet line under the time —
    /// aligned with the title instead of spanning the whole row.
    private var badges: some View {
        WrapLayout(spacing: DS.Spacing.xs, lineSpacing: 4) {
            if reminder.recurrence.isRecurring {
                badge(reminder.recurrence.localizedSummary, systemImage: "repeat", tint: style.color)
            }
            if !reminder.additionalSchedules.isEmpty {
                // Alarm fires on more than one day/time — surface the count.
                badge("+\(reminder.additionalSchedules.count)", systemImage: "calendar.badge.clock", tint: style.color)
            }
            if reminder.isReceivedShare {
                badge(appLocalized("Compartido"), systemImage: "person.2.fill", tint: .secondary)
            }
        }
    }

    private func badge(_ text: String, systemImage: String, tint: some ShapeStyle) -> some View {
        // Hand-rolled instead of `Label` so the icon hugs its text — Label keeps a
        // wide icon column, which leaves an odd gap at this size.
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .imageScale(.small)
            Text(text)
                .lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(tint)
    }

    /// "hoy" / "mañana" / weekday for this week / short date beyond that — the
    /// list is already grouped by day, so this just confirms which one.
    private func dayLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return appLocalized("hoy") }
        if calendar.isDateInTomorrow(date) { return appLocalized("mañana") }
        if date.timeIntervalSinceNow < 60 * 60 * 24 * 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
