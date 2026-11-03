//
//  WidgetSnapshotWriter.swift
//  Calarm
//
//  Escribe el `WidgetSnapshot` que leen los widgets y les pide redibujarse,
//  solo cuando el contenido cambió (iOS limita cuántas veces al día puede
//  recargarse un widget). Lo llaman: cada guardado de SwiftData (con un pequeño
//  retraso para juntar varios), la sincronización de alarmas y el paso a segundo
//  plano.
//

import CryptoKit
import Foundation
import os
import SwiftData
import SwiftUI
import WidgetKit

@MainActor
enum WidgetSnapshotWriter {
    private static let log = Logger(subsystem: "MathyuSolutions.Calarm", category: "WidgetSnapshot")

    /// Ocurrencias por horario y en total: con varias alarmas diarias, 64 cubren
    /// más de una semana sin abrir la app.
    private static let occurrencesPerSchedule = 8
    private static let maxAlarms = 64
    /// Lado mayor de las fotos del widget: con más, WidgetKit se niega a
    /// pintarlas («image being too large») en el tamaño mediano.
    private static let photoMaxPixelSize = 800

    private static var lastWritten: WidgetSnapshot?
    private static var pendingUpdate: Task<Void, Never>?

    /// Junta los guardados seguidos (el editor guarda varias veces) en una escritura.
    static func scheduleUpdate(container: ModelContainer) {
        pendingUpdate?.cancel()
        pendingUpdate = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            update(container: container)
        }
    }

    static func update(container: ModelContainer) {
        guard let fileURL = WidgetSnapshotStore.fileURL,
              let photosDirectory = WidgetSnapshotStore.photosDirectory else {
            log.error("App Group not available; widgets stay empty")
            return
        }
        let context = container.mainContext
        let reminders = (try? context.fetch(FetchDescriptor<Reminder>())) ?? []
        let categories = (try? context.fetch(FetchDescriptor<CustomCategory>())) ?? []
        let events = (try? context.fetch(FetchDescriptor<CountdownEvent>())) ?? []

        let snapshot = WidgetSnapshot(
            alarmsEnabled: UserDefaults.standard.object(forKey: "settings.alarmsEnabled") as? Bool ?? true,
            alarms: alarms(from: reminders, categories: categories),
            countdowns: countdowns(from: events, photosDirectory: photosDirectory)
        )
        guard snapshot != lastWritten || !FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
            lastWritten = snapshot
            WidgetCenter.shared.reloadAllTimelines()
            log.info("snapshot written: \(snapshot.alarms.count) alarms, \(snapshot.countdowns.count) countdowns")
        } catch {
            log.error("snapshot write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Alarmas

    private static func alarms(from reminders: [Reminder], categories: [CustomCategory]) -> [WidgetSnapshot.Alarm] {
        let categoryByID = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [WidgetSnapshot.Alarm] = []
        for reminder in reminders where reminder.isEnabled {
            let custom = reminder.customCategoryID.flatMap { categoryByID[$0] }
            let colorHex = custom?.colorHex ?? reminder.category.tint.toHex() ?? "#FF9500"
            let icon = icon(for: reminder, custom: custom)
            for schedule in reminder.allSchedules {
                let dates = RecurrenceEngine.nextOccurrences(
                    rule: schedule.recurrence,
                    baseDate: schedule.date,
                    count: occurrencesPerSchedule
                )
                result += dates.map {
                    WidgetSnapshot.Alarm(reminderID: reminder.id, title: reminder.title, date: $0, colorHex: colorHex, icon: icon)
                }
            }
        }
        // Dos horarios que coinciden suenan una vez: una sola fila.
        var seen = Set<String>()
        return result
            .sorted { $0.date < $1.date }
            .filter { seen.insert("\($0.reminderID)-\($0.date.timeIntervalSinceReferenceDate)").inserted }
            .prefix(maxAlarms)
            .map { $0 }
    }

    /// Emoji o SF Symbol; una foto (que el widget no carga) cae al icono de la categoría.
    private static func icon(for reminder: Reminder, custom: CustomCategory?) -> String {
        switch reminder.iconKind {
        case .emoji:
            if let value = reminder.symbolName, isEmojiIcon(value) { return value }
        case .symbol:
            if let value = reminder.symbolName, !value.isEmpty, !isEmojiIcon(value) { return value }
        case .photo:
            break
        }
        if let custom, !custom.iconValue.isEmpty { return custom.iconValue }
        return reminder.category.defaultSymbol
    }

    // MARK: - Cuentas regresivas

    private static func countdowns(from events: [CountdownEvent], photosDirectory: URL) -> [WidgetSnapshot.Countdown] {
        try? FileManager.default.createDirectory(at: photosDirectory, withIntermediateDirectories: true)
        var keptPhotos = Set<String>()
        let result = events.map { event -> WidgetSnapshot.Countdown in
            var photoFile: String?
            if event.iconKind == .photo, let data = event.photoData {
                photoFile = writePhoto(data, for: event.id, in: photosDirectory)
                if let photoFile { keptPhotos.insert(photoFile) }
            }
            return WidgetSnapshot.Countdown(
                id: event.id,
                title: event.title,
                date: event.date,
                includesTime: event.includesTime,
                repeatsYearly: event.repeatsYearly,
                colorHex: event.colorHex,
                iconKindRaw: event.iconKindRaw,
                iconValue: event.iconValue,
                photoFile: photoFile
            )
        }
        // Fotos de cuentas borradas o cambiadas: fuera.
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: photosDirectory.path(percentEncoded: false))) ?? []
        for name in existing where !keptPhotos.contains(name) {
            try? FileManager.default.removeItem(at: photosDirectory.appending(path: name))
        }
        return result
    }

    /// El nombre lleva un resumen de la foto: si no cambió, el archivo ya está.
    private static func writePhoto(_ data: Data, for id: UUID, in directory: URL) -> String? {
        let digest = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        let name = "\(id.uuidString)-\(digest).jpg"
        let url = directory.appending(path: name)
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { return name }
        guard let small = CountdownPhoto.prepared(from: data, maxPixelSize: photoMaxPixelSize),
              (try? small.write(to: url, options: .atomic)) != nil else { return nil }
        return name
    }
}
