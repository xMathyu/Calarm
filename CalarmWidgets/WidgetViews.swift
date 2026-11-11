//
//  WidgetViews.swift
//  CalarmWidgets
//
//  Lo que pintan los widgets de cuenta regresiva y de próxima alarma, en cada
//  tamaño. Reciben la familia como parámetro (y no del entorno) para que la app
//  pueda enseñarlas en DEBUG (`-demoScreen widgets`): este archivo también
//  compila en la app, por eso no usa nada propio de la extensión.
//

import SwiftUI
import UIKit
import WidgetKit

// MARK: - Textos

nonisolated enum WidgetText {
    static func dayUnit(_ days: Int) -> String {
        days == 1 ? String(localized: "día") : String(localized: "días")
    }

    static func pastUnit(_ days: Int) -> String {
        days == 1 ? String(localized: "día atrás") : String(localized: "días atrás")
    }

    /// «23 días», «1 día atrás» o «¡Hoy!», en una línea.
    static func countdownLine(_ status: CountdownStatus) -> String {
        switch status {
        case .today: String(localized: "¡Hoy!")
        case .upcoming(let days): "\(days) \(dayUnit(days))"
        case .past(let days): "\(days) \(pastUnit(days))"
        }
    }

    /// «Hoy», «Mañana» o «jue, 12 nov».
    static func dayLabel(for date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Hoy") }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return String(localized: "Mañana")
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

// MARK: - Cuenta regresiva

struct CountdownWidgetContent: View {
    let countdown: WidgetSnapshot.Countdown?
    let now: Date
    let family: WidgetFamily

    var body: some View {
        if let countdown {
            switch family {
            case .accessoryCircular: circular(countdown)
            case .accessoryRectangular: rectangular(countdown)
            case .accessoryInline: inline(countdown)
            case .systemMedium: medium(countdown)
            default: small(countdown)
            }
        } else {
            empty
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "hourglass")
                .font(.title2)
            if !family.isAccessory {
                Text("Crea una cuenta regresiva en Calarmi")
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(family.isAccessory ? Color.primary : Color.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func small(_ c: WidgetSnapshot.Countdown) -> some View {
        let hasPhoto = WidgetSnapshotStore.photo(named: c.photoFile) != nil
        return VStack(alignment: .leading, spacing: 2) {
            if !hasPhoto {
                CountdownWidgetIcon(countdown: c, size: 34)
            }
            Spacer(minLength: 0)
            CountdownWidgetCounter(status: c.status(now: now), numberSize: 40, alignment: .leading)
            Text(c.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(hasPhoto ? 0.4 : 0), radius: 4, y: 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func medium(_ c: WidgetSnapshot.Countdown) -> some View {
        let hasPhoto = WidgetSnapshotStore.photo(named: c.photoFile) != nil
        return HStack(alignment: hasPhoto ? .bottom : .center, spacing: 12) {
            if !hasPhoto {
                CountdownWidgetIcon(countdown: c, size: 54)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(c.title)
                    .font(.headline)
                    .lineLimit(2)
                CountdownWidgetDate(countdown: c, now: now)
                    .font(.subheadline)
                    .opacity(0.85)
            }
            Spacer(minLength: 4)
            CountdownWidgetCounter(status: c.status(now: now), numberSize: 50, alignment: .center)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(hasPhoto ? 0.4 : 0), radius: 4, y: 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: hasPhoto ? .bottomLeading : .leading)
    }

    private func circular(_ c: WidgetSnapshot.Countdown) -> some View {
        ZStack {
            AccessoryWidgetBackground()
            switch c.status(now: now) {
            case .today:
                Text(c.iconKind == .emoji && isEmojiIcon(c.iconValue) ? c.iconValue : "🎉")
                    .font(.title2)
            case .upcoming(let days), .past(let days):
                VStack(spacing: -2) {
                    Text(days, format: .number)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text(c.status(now: now).isPast ? String(localized: "atrás") : WidgetText.dayUnit(days))
                        .font(.system(size: 9, weight: .semibold))
                        .textCase(.uppercase)
                }
                .padding(.horizontal, 4)
            }
        }
        .widgetAccentable()
    }

    private func rectangular(_ c: WidgetSnapshot.Countdown) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                if c.iconKind == .emoji, isEmojiIcon(c.iconValue) {
                    Text(c.iconValue)
                } else {
                    Image(systemName: "hourglass")
                }
                Text(c.title)
                    .lineLimit(1)
            }
            .font(.headline)
            .widgetAccentable()
            Text(WidgetText.countdownLine(c.status(now: now)))
                .font(.system(.title3, design: .rounded).weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            CountdownWidgetDate(countdown: c, now: now)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ c: WidgetSnapshot.Countdown) -> some View {
        Label {
            Text(verbatim: "\(WidgetText.countdownLine(c.status(now: now))) · \(c.title)")
        } icon: {
            Image(systemName: "hourglass")
        }
    }
}

/// El fondo del widget de cuenta regresiva: la foto (oscurecida abajo) o el
/// degradado del color, como las tarjetas de la app.
struct CountdownWidgetBackground: View {
    let countdown: WidgetSnapshot.Countdown?

    var body: some View {
        if let image = WidgetSnapshotStore.photo(named: countdown?.photoFile) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .overlay {
                    LinearGradient(
                        colors: [.black.opacity(0.05), .black.opacity(0.25), .black.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
        } else {
            let color = Color(widgetHex: countdown?.colorHex ?? "#FF2D55")
            LinearGradient(
                colors: [color.mix(with: .white, by: 0.12), color.mix(with: .black, by: 0.3)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

struct CountdownWidgetIcon: View {
    let countdown: WidgetSnapshot.Countdown
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(.white.opacity(0.22))
            if countdown.iconKind == .emoji, isEmojiIcon(countdown.iconValue) {
                Text(countdown.iconValue)
                    .font(.system(size: size * 0.56))
            } else {
                Image(systemName: countdown.iconKind == .symbol && !isEmojiIcon(countdown.iconValue)
                      ? countdown.iconValue : "calendar")
                    .font(.system(size: size * 0.44, weight: .semibold))
            }
        }
        .frame(width: size, height: size)
    }
}

struct CountdownWidgetDate: View {
    let countdown: WidgetSnapshot.Countdown
    let now: Date

    var body: some View {
        let target = countdown.target(now: now)
        HStack(spacing: 3) {
            if countdown.repeatsYearly {
                Image(systemName: "repeat")
                    .font(.caption2.weight(.bold))
            }
            if countdown.includesTime {
                Text(target, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
            } else {
                Text(target, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

struct CountdownWidgetCounter: View {
    let status: CountdownStatus
    var numberSize: CGFloat
    var alignment: HorizontalAlignment

    var body: some View {
        switch status {
        case .today:
            Text("¡Hoy!")
                .font(.system(size: numberSize * 0.62, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        case .upcoming(let days):
            stack(days, unit: WidgetText.dayUnit(days))
        case .past(let days):
            stack(days, unit: WidgetText.pastUnit(days))
        }
    }

    private func stack(_ days: Int, unit: String) -> some View {
        VStack(alignment: alignment, spacing: -3) {
            Text(days, format: .number)
                .font(.system(size: numberSize, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(unit)
                .font(.system(size: max(10, numberSize * 0.26), weight: .bold, design: .rounded))
                .textCase(.uppercase)
                .opacity(0.9)
        }
        .fixedSize(horizontal: alignment == .center, vertical: false)
    }
}

// MARK: - Próxima alarma

struct NextAlarmWidgetContent: View {
    let alarms: [WidgetSnapshot.Alarm]
    let alarmsEnabled: Bool
    let now: Date
    let family: WidgetFamily

    var body: some View {
        if !alarmsEnabled {
            placeholder(symbol: "bell.slash.fill", text: String(localized: "Alarmas desactivadas"))
        } else if let next = alarms.first {
            switch family {
            case .accessoryCircular: circular(next)
            case .accessoryRectangular: rectangular(next)
            case .accessoryInline: inline(next)
            case .systemMedium: medium
            default: small(next)
            }
        } else {
            placeholder(symbol: "alarm", text: String(localized: "Sin alarmas próximas"))
        }
    }

    private func placeholder(symbol: String, text: String) -> some View {
        Group {
            switch family {
            case .accessoryInline:
                Label(text, systemImage: symbol)
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: symbol).font(.title3)
                }
            default:
                VStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(family.isAccessory ? .body : .title2)
                        .foregroundStyle(family.isAccessory ? Color.primary : Color.secondary)
                    Text(text)
                        .font(.caption.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func header(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "alarm.fill")
            Text(title)
                .lineLimit(1)
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(.tint)
    }

    private func small(_ alarm: WidgetSnapshot.Alarm) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            header("Próxima alarma")
            Spacer(minLength: 0)
            HStack(alignment: .center, spacing: 6) {
                AlarmWidgetIcon(alarm: alarm, size: 26)
                Text(WidgetText.dayLabel(for: alarm.date, now: now))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(alarm.date, format: .dateTime.hour().minute())
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(alarm.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            header("Próximas alarmas")
            ForEach(Array(distinctAlarms.prefix(3).enumerated()), id: \.offset) { _, alarm in
                Link(destination: CalarmLinks.alarm(alarm.reminderID)) {
                    HStack(spacing: 10) {
                        AlarmWidgetIcon(alarm: alarm, size: 30)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(alarm.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(WidgetText.dayLabel(for: alarm.date, now: now))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(alarm.date, format: .dateTime.hour().minute())
                            .font(.system(.title3, design: .rounded).weight(.bold))
                            .lineLimit(1)
                    }
                }
                // Un Link no debe teñir la fila con el color de acento.
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Una fila por alarma: una diaria no ocupa las tres con sus próximos días.
    private var distinctAlarms: [WidgetSnapshot.Alarm] {
        var seen = Set<UUID>()
        return alarms.filter { seen.insert($0.reminderID).inserted }
    }

    private func circular(_ alarm: WidgetSnapshot.Alarm) -> some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "alarm.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text(alarm.date, format: .dateTime.hour().minute())
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .padding(.horizontal, 5)
        }
        .widgetAccentable()
    }

    private func rectangular(_ alarm: WidgetSnapshot.Alarm) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "alarm.fill")
                Text(alarm.date, format: .dateTime.hour().minute())
            }
            .font(.system(.title3, design: .rounded).weight(.bold))
            .widgetAccentable()
            Text(alarm.title)
                .font(.headline)
                .lineLimit(1)
            Text(WidgetText.dayLabel(for: alarm.date, now: now))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ alarm: WidgetSnapshot.Alarm) -> some View {
        Label {
            Text(verbatim: "\(alarm.date.formatted(.dateTime.hour().minute())) \(alarm.title)")
        } icon: {
            Image(systemName: "alarm.fill")
        }
    }
}

/// Un velo del color de la próxima alarma sobre el fondo del sistema.
struct NextAlarmWidgetBackground: View {
    let alarm: WidgetSnapshot.Alarm?

    var body: some View {
        let color = Color(widgetHex: alarm?.colorHex ?? "#FF9500", fallback: .orange)
        ZStack {
            Color(.systemBackground)
            LinearGradient(
                colors: [color.opacity(0.22), color.opacity(0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

struct AlarmWidgetIcon: View {
    let alarm: WidgetSnapshot.Alarm
    var size: CGFloat

    var body: some View {
        let color = Color(widgetHex: alarm.colorHex, fallback: .orange)
        ZStack {
            Circle().fill(color.opacity(0.2))
            if isEmojiIcon(alarm.icon) {
                Text(alarm.icon).font(.system(size: size * 0.55))
            } else {
                Image(systemName: alarm.icon)
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
    }
}

extension WidgetFamily {
    var isAccessory: Bool {
        switch self {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline: true
        default: false
        }
    }
}
