//
//  CountdownWidget.swift
//  CalarmWidgets
//
//  Widget de cuenta regresiva: los días que faltan para un evento, con su foto
//  o su emoji. Cada widget puede mostrar un evento elegido (mantener pulsado →
//  Editar widget); sin elegir, enseña el próximo.
//

import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Elegir evento

nonisolated struct CountdownEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Cuenta regresiva"
    static let defaultQuery = CountdownEntityQuery()

    var id: UUID
    var title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

nonisolated struct CountdownEntityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [CountdownEntity] {
        WidgetSnapshotStore.load().countdowns
            .filter { identifiers.contains($0.id) }
            .map { CountdownEntity(id: $0.id, title: $0.title) }
    }

    func suggestedEntities() async throws -> [CountdownEntity] {
        WidgetSnapshotStore.load().countdownsForPicker(now: Date())
            .map { CountdownEntity(id: $0.id, title: $0.title) }
    }
}

struct SelectCountdownIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Elegir evento"
    static let description = IntentDescription("Elige qué cuenta regresiva muestra el widget. Sin elegir, muestra la próxima.")

    @Parameter(title: "Evento")
    var event: CountdownEntity?

    init() {}
}

// MARK: - Línea de tiempo

nonisolated struct CountdownEntry: TimelineEntry {
    let date: Date
    let countdown: WidgetSnapshot.Countdown?
}

nonisolated struct CountdownProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CountdownEntry {
        CountdownEntry(date: Date(), countdown: Self.sample)
    }

    func snapshot(for configuration: SelectCountdownIntent, in context: Context) async -> CountdownEntry {
        let entry = entry(for: configuration, at: Date())
        // En la galería, sin cuentas todavía: un ejemplo en vez de un widget vacío.
        if entry.countdown == nil, context.isPreview {
            return CountdownEntry(date: entry.date, countdown: Self.sample)
        }
        return entry
    }

    func timeline(for configuration: SelectCountdownIntent, in context: Context) async -> Timeline<CountdownEntry> {
        // Una entrada por medianoche: el número de días cambia sin abrir la app.
        let calendar = Calendar.current
        let now = Date()
        var dates = [now]
        var midnight = calendar.startOfDay(for: now)
        for _ in 0..<7 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: midnight) else { break }
            midnight = next
            dates.append(next)
        }
        return Timeline(entries: dates.map { entry(for: configuration, at: $0) }, policy: .atEnd)
    }

    private func entry(for configuration: SelectCountdownIntent, at date: Date) -> CountdownEntry {
        let snapshot = WidgetSnapshotStore.load()
        let chosen = configuration.event.flatMap { event in snapshot.countdowns.first { $0.id == event.id } }
        return CountdownEntry(date: date, countdown: chosen ?? snapshot.defaultCountdown(now: date))
    }

    static let sample = WidgetSnapshot.Countdown(
        id: UUID(),
        title: String(localized: "Concierto"),
        date: Calendar.current.date(byAdding: .day, value: 23, to: Calendar.current.startOfDay(for: Date())) ?? Date(),
        includesTime: false,
        repeatsYearly: false,
        colorHex: "#5856D6",
        iconKindRaw: ReminderIconKind.emoji.rawValue,
        iconValue: "🎤",
        photoFile: nil
    )
}

// MARK: - Widget

struct CountdownWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CountdownEntry

    var body: some View {
        CountdownWidgetContent(countdown: entry.countdown, now: entry.date, family: family)
            .widgetURL(CalarmLinks.countdown(entry.countdown?.id))
            .containerBackground(for: .widget) {
                CountdownWidgetBackground(countdown: entry.countdown)
            }
    }
}

struct CountdownWidget: Widget {
    static let kind = "CalarmCountdownWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: SelectCountdownIntent.self, provider: CountdownProvider()) { entry in
            CountdownWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Cuenta regresiva")
        .description("Los días que faltan para un evento, con su foto o su emoji.")
        // La foto va en el fondo del contenedor, que llega hasta el borde aunque
        // el contenido respete los márgenes del sistema.
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
