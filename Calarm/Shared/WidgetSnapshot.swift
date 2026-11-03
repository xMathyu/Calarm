//
//  WidgetSnapshot.swift
//  Calarm
//
//  Lo que los widgets saben de la app: las próximas alarmas y las cuentas
//  regresivas, en un JSON dentro del App Group. La app lo reescribe cada vez
//  que algo cambia (`WidgetSnapshotWriter`); el widget solo lo lee. Así la base
//  de SwiftData (y su sincronización con iCloud) se queda donde estaba.
//
//  COMPARTIDO con la extensión CalarmWidgets (referencia explícita en el
//  proyecto): solo Foundation y SwiftUI, todo `nonisolated`.
//

import Foundation
import SwiftUI
import UIKit

nonisolated enum CalarmAppGroup {
    static let identifier = "group.MathyuSolutions.Calarm"

    /// Nil cuando el build no tiene el entitlement del App Group.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}

nonisolated struct WidgetSnapshot: Codable, Equatable, Sendable {
    /// El interruptor general de Ajustes: apagado, ninguna alarma suena.
    var alarmsEnabled: Bool
    /// Próximas ocurrencias de las alarmas activas, de la más cercana a la más
    /// lejana. Calculadas por la app; el widget avanza por ellas sin abrirla.
    var alarms: [Alarm]
    var countdowns: [Countdown]

    struct Alarm: Codable, Equatable, Hashable, Sendable {
        var reminderID: UUID
        var title: String
        /// La hora de la alarma, como la enseña la lista (sin restar avisos).
        var date: Date
        var colorHex: String
        /// SF Symbol o emoji (las alarmas con foto llevan el símbolo de su categoría).
        var icon: String
    }

    struct Countdown: Codable, Equatable, Hashable, Identifiable, Sendable {
        var id: UUID
        var title: String
        var date: Date
        var includesTime: Bool
        var repeatsYearly: Bool
        var colorHex: String
        /// `ReminderIconKind` en crudo.
        var iconKindRaw: Int
        var iconValue: String
        /// Nombre del JPEG reducido en `WidgetSnapshotStore.photosDirectory`.
        var photoFile: String?

        var iconKind: ReminderIconKind { ReminderIconKind(rawValue: iconKindRaw) ?? .emoji }

        func target(now: Date) -> Date {
            CountdownMath.target(date: date, includesTime: includesTime, repeatsYearly: repeatsYearly, now: now)
        }

        func status(now: Date) -> CountdownStatus {
            CountdownMath.status(to: target(now: now), now: now)
        }
    }

    static let empty = WidgetSnapshot(alarmsEnabled: true, alarms: [], countdowns: [])

    /// La cuenta que enseña un widget sin evento elegido (o si el elegido ya no
    /// existe): la próxima; si todas pasaron, la más reciente.
    func defaultCountdown(now: Date) -> Countdown? {
        let withTargets = countdowns.map { ($0, $0.target(now: now)) }
        let upcoming = withTargets.filter { !$0.0.status(now: now).isPast }
        if let next = upcoming.min(by: { $0.1 < $1.1 }) { return next.0 }
        return withTargets.max(by: { $0.1 < $1.1 })?.0
    }

    /// Para elegir evento al configurar el widget: próximos primero.
    func countdownsForPicker(now: Date) -> [Countdown] {
        countdowns.sorted { lhs, rhs in
            let lp = lhs.status(now: now).isPast, rp = rhs.status(now: now).isPast
            if lp != rp { return !lp }
            return lp ? lhs.target(now: now) > rhs.target(now: now) : lhs.target(now: now) < rhs.target(now: now)
        }
    }
}

nonisolated enum WidgetSnapshotStore {
    static let fileName = "widget-snapshot.json"

    static var fileURL: URL? {
        CalarmAppGroup.containerURL?.appending(path: fileName)
    }

    static var photosDirectory: URL? {
        CalarmAppGroup.containerURL?.appending(path: "WidgetPhotos", directoryHint: .isDirectory)
    }

    static func load() -> WidgetSnapshot {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return .empty }
        return snapshot
    }

    static func photo(named name: String?) -> UIImage? {
        guard let name, let url = photosDirectory?.appending(path: name) else { return nil }
        return UIImage(contentsOfFile: url.path(percentEncoded: false))
    }
}

/// Los enlaces `calarm://` con que los widgets abren la app en el sitio justo.
nonisolated enum CalarmLinks {
    /// Abre la alarma en el editor (lo entiende `CalendarMirrorService.reminderID`).
    static func alarm(_ id: UUID) -> URL {
        URL(string: "calarm://alarm/\(id.uuidString)")!
    }

    /// Abre la pestaña Cuenta regresiva y, con id, esa cuenta.
    static func countdown(_ id: UUID?) -> URL {
        URL(string: "calarm://countdown" + (id.map { "/\($0.uuidString)" } ?? ""))!
    }

    /// `.some(nil)` = la pestaña sin cuenta concreta; `nil` = no es un enlace de cuentas.
    static func countdownID(from url: URL) -> UUID?? {
        guard url.scheme == "calarm", url.host == "countdown" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        return .some(parts.first.flatMap(UUID.init(uuidString:)))
    }
}

extension Color {
    /// `#RRGGBB` → Color, para el widget (que no tiene el `init(hex:)` de la app).
    nonisolated init(widgetHex hex: String, fallback: Color = .pink) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt64(s, radix: 16) else {
            self = fallback
            return
        }
        self = Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
