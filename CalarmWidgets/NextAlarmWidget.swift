//
//  NextAlarmWidget.swift
//  CalarmWidgets
//
//  Widget de próxima alarma: la siguiente (o las tres siguientes en el tamaño
//  mediano). Avanza solo cuando cada una pasa, con las ocurrencias que la app
//  dejó calculadas en el `WidgetSnapshot`.
//

import SwiftUI
import WidgetKit

nonisolated struct NextAlarmEntry: TimelineEntry {
    let date: Date
    let alarmsEnabled: Bool
    /// Las que aún no pasaron a la hora de esta entrada.
    let alarms: [WidgetSnapshot.Alarm]
}

nonisolated struct NextAlarmProvider: TimelineProvider {
    /// Una alarma sigue a la vista el minuto en que suena.
    private static let grace: TimeInterval = 60
    private static let maxEntries = 40

    func placeholder(in context: Context) -> NextAlarmEntry {
        NextAlarmEntry(date: Date(), alarmsEnabled: true, alarms: [Self.sample])
    }

    func getSnapshot(in context: Context, completion: @escaping (NextAlarmEntry) -> Void) {
        let snapshot = WidgetSnapshotStore.load()
        let entry = entry(from: snapshot, at: Date())
        if entry.alarms.isEmpty, context.isPreview {
            completion(placeholder(in: context))
        } else {
            completion(entry)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextAlarmEntry>) -> Void) {
        let snapshot = WidgetSnapshotStore.load()
        let calendar = Calendar.current
        let now = Date()
        // Cambia cuando pasa cada alarma y a medianoche («Mañana» pasa a «Hoy»).
        var dates = Set([now])
        for alarm in snapshot.alarms where alarm.date + Self.grace > now {
            dates.insert(alarm.date + Self.grace)
        }
        var midnight = calendar.startOfDay(for: now)
        for _ in 0..<2 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: midnight) else { break }
            midnight = next
            dates.insert(next)
        }
        let entries = dates.sorted().prefix(Self.maxEntries).map { entry(from: snapshot, at: $0) }
        completion(Timeline(entries: Array(entries), policy: .atEnd))
    }

    private func entry(from snapshot: WidgetSnapshot, at date: Date) -> NextAlarmEntry {
        NextAlarmEntry(
            date: date,
            alarmsEnabled: snapshot.alarmsEnabled,
            alarms: snapshot.alarms.filter { $0.date + Self.grace > date }
        )
    }

    static let sample = WidgetSnapshot.Alarm(
        reminderID: UUID(),
        title: String(localized: "Despertar"),
        date: Calendar.current.date(bySettingHour: 7, minute: 30, second: 0, of: Date().addingTimeInterval(86_400)) ?? Date(),
        colorHex: "#FF9500",
        icon: "alarm.fill"
    )
}

struct NextAlarmWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NextAlarmEntry

    var body: some View {
        NextAlarmWidgetContent(alarms: entry.alarms, alarmsEnabled: entry.alarmsEnabled, now: entry.date, family: family)
            .widgetURL(entry.alarms.first.map { CalarmLinks.alarm($0.reminderID) })
            .containerBackground(for: .widget) {
                NextAlarmWidgetBackground(alarm: entry.alarms.first)
            }
    }
}

struct NextAlarmWidget: Widget {
    static let kind = "CalarmNextAlarmWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: NextAlarmProvider()) { entry in
            NextAlarmWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Próxima alarma")
        .description("La siguiente alarma que va a sonar, o las tres siguientes.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
