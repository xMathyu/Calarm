//
//  MonthGridView.swift
//  Calarm
//
//  La rejilla de un mes: iniciales de los días de la semana, un botón por día
//  con hasta tres puntos debajo. Solo pinta; quién decide qué puntos van en
//  cada día es `MonthCalendarView`.
//

import SwiftUI

/// One dot under a day: the category color of an alarm (hollow when the alarm
/// is off and won't ring) or the calendar color of a system event.
struct DayMark: Hashable {
    let color: Color
    let isHollow: Bool
}

struct MonthGridView: View {
    let grid: MonthGrid
    let marks: [Date: [DayMark]]
    @Binding var selectedDay: Date
    let calendar: Calendar

    private static let maxMarks = 3

    var body: some View {
        VStack(spacing: DS.Spacing.xs) {
            weekdayHeader
            // Filas explícitas en vez de LazyVGrid: dentro de una List la rejilla
            // perezosa calcula mal su alto cuando cambia el número de semanas.
            ForEach(Array(grid.weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        if let day {
                            DayCell(
                                day: day,
                                dayNumber: calendar.component(.day, from: day),
                                isSelected: calendar.isDate(day, inSameDayAs: selectedDay),
                                isToday: calendar.isDateInToday(day),
                                marks: Array((marks[day] ?? []).prefix(Self.maxMarks)),
                                accessibilityLabel: accessibilityLabel(for: day)
                            ) {
                                guard !calendar.isDate(day, inSameDayAs: selectedDay) else { return }
                                Haptics.selection()
                                withAnimation(DS.Motion.snappy) { selectedDay = day }
                            }
                        } else {
                            Color.clear
                                .frame(maxWidth: .infinity, minHeight: DayCell.height)
                        }
                    }
                }
            }
        }
        .padding(.vertical, DS.Spacing.sm)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(Array(MonthGrid.weekdaySymbols(calendar: calendar).enumerated()), id: \.offset) { _, symbol in
                Text(symbol.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private func accessibilityLabel(for day: Date) -> String {
        var style = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar)
        style = style.weekday(.wide).day().month(.wide)
        let dateText = day.formatted(style)
        guard !(marks[day] ?? []).isEmpty else { return dateText }
        return dateText + ", " + appLocalized("Con alarmas o eventos")
    }
}

private struct DayCell: View {
    static let height: CGFloat = 50

    let day: Date
    let dayNumber: Int
    let isSelected: Bool
    let isToday: Bool
    let marks: [DayMark]
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Text("\(dayNumber)")
                    .font(.callout.weight(isToday || isSelected ? .semibold : .regular))
                    .monospacedDigit()
                    .frame(width: 34, height: 34)
                    .background {
                        if isSelected {
                            Circle().fill(Color.appAccent)
                        }
                    }
                    .foregroundStyle(numberColor)

                // Alto fijo aunque no haya puntos, para que todas las filas midan igual.
                HStack(spacing: 3) {
                    ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                        if mark.isHollow {
                            Circle()
                                .strokeBorder(mark.color, lineWidth: 1.2)
                                .frame(width: 6, height: 6)
                        } else {
                            Circle()
                                .fill(mark.color)
                                .frame(width: 6, height: 6)
                        }
                    }
                }
                .frame(height: 6)
            }
            .frame(maxWidth: .infinity, minHeight: Self.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var numberColor: Color {
        if isSelected { return .white }
        if isToday { return .appAccent }
        return .primary
    }
}
