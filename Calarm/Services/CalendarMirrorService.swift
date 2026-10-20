//
//  CalendarMirrorService.swift
//  Calarm
//
//  Espejo de las alarmas propias en el Calendario del sistema: un calendario
//  llamado «Calarm» con una entrada por cada horario de cada alarma activa.
//  Opcional, detrás de «Guardar mis alarmas en el Calendario» en Ajustes.
//
//  Dos reglas evitan los problemas clásicos de escribir en el calendario:
//  - Bucle: Calarm también LEE el calendario para ponerle alarma a cada evento.
//    Si leyera sus propias entradas, cada alarma sonaría dos veces. Por eso van
//    en un calendario aparte que `EventKitCalendarSource` nunca lee.
//  - Duplicados entre dispositivos: la alarma llega por iCloud a todos los
//    dispositivos y cada uno podría escribir su propia entrada. Cada entrada
//    lleva en su URL la identidad del horario (`calarm://alarm/<alarma>/<horario>`)
//    y una huella de su contenido, y se busca por esa URL —nunca por un
//    identificador de EventKit, que cambia de un dispositivo a otro—. Si dos
//    dispositivos crean la misma, los dos se quedan con la misma (la de menor
//    identificador externo) y borran la otra.
//
//  Una entrada cuyo contenido cambió no se edita: se borra y se crea de nuevo.
//  Editar series recurrentes en EventKit tiene demasiados casos raros.
//

import CryptoKit
import EventKit
import Foundation
import os
import SwiftUI

@MainActor
final class CalendarMirrorService {
    static let calendarTitle = "Calarm"
    /// Una alarma es un instante; en el calendario ocupa media hora para que se
    /// vea sin tapar la mañana entera.
    static let eventDuration: TimeInterval = 30 * 60
    private static let urlPrefix = "calarm://alarm/"

    private let store = EKEventStore()
    private static let log = Logger(subsystem: "MathyuSolutions.Calarm", category: "CalendarMirror")

    // MARK: - Acceso

    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Pide el permiso si nunca se pidió. Devuelve si al final hay acceso total.
    func requestAccessIfNeeded() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return true
        case .notDetermined: return (try? await store.requestFullAccessToEvents()) ?? false
        default: return false
        }
    }

    /// El calendario que Calarm escribe y que nunca debe leer.
    nonisolated static func isMirrorCalendar(_ calendar: EKCalendar) -> Bool {
        calendar.title == calendarTitle
    }

    // MARK: - Enlace desde el evento

    /// La alarma a la que apunta la URL de una entrada del calendario, para
    /// abrirla en Calarm al tocar el enlace desde la app Calendario.
    nonisolated static func reminderID(from url: URL) -> UUID? {
        guard url.scheme == "calarm", url.host == "alarm" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let first = parts.first else { return nil }
        return UUID(uuidString: first)
    }

    // MARK: - Sincronización

    /// Deja el calendario «Calarm» exactamente con las entradas de `reminders`.
    func reconcile(_ reminders: [Reminder]) {
        Self.log.info("reconcile \(reminders.count) reminders, access=\(self.hasAccess)")
        guard hasAccess, let calendar = mirrorCalendar(createIfNeeded: true) else { return }
        sync(specs: reminders.flatMap(Self.specs(for:)), ownerIDs: nil, in: calendar)
    }

    /// Actualiza solo las entradas de una alarma (al guardarla o apagarla).
    func apply(_ reminder: Reminder) {
        guard hasAccess, let calendar = mirrorCalendar(createIfNeeded: true) else { return }
        sync(specs: Self.specs(for: reminder), ownerIDs: [reminder.id], in: calendar)
    }

    /// Quita las entradas de una alarma borrada.
    func remove(reminderID: UUID) {
        guard hasAccess, let calendar = mirrorCalendar(createIfNeeded: false) else { return }
        sync(specs: [], ownerIDs: [reminderID], in: calendar)
    }

    /// Borra el calendario «Calarm» entero, con todas sus entradas.
    func removeCalendar() {
        guard hasAccess else { return }
        for calendar in store.calendars(for: .event) where Self.isMirrorCalendar(calendar) {
            try? store.removeCalendar(calendar, commit: false)
        }
        try? store.commit()
    }

    /// `ownerIDs` acota qué entradas existentes se tocan: solo las de esas
    /// alarmas (`nil` = todas). Las que no estén en `specs`, o tengan contenido
    /// viejo, se borran; las que falten se crean. Una entrada con la misma
    /// huella se deja como está, así que repetir esto no cambia nada.
    private func sync(specs: [EventSpec], ownerIDs: Set<UUID>?, in calendar: EKCalendar) {
        let existing = existingEvents(in: calendar, covering: specs, ownerIDs: ownerIDs)
        let wanted = Dictionary(specs.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false

        for (key, events) in existing {
            let keep = wanted[key].flatMap { spec in events.first { Self.version(of: $0) == spec.hash } }
            for event in events where event !== keep {
                changed = remove(event) || changed
            }
        }
        for spec in wanted.values {
            let alreadyThere = (existing[spec.key] ?? []).contains { Self.version(of: $0) == spec.hash }
            guard !alreadyThere else { continue }
            changed = create(spec, in: calendar) || changed
        }
        if changed {
            do { try store.commit() } catch { Self.log.error("commit: \(error.localizedDescription)") }
        }
        Self.log.info("sync: \(wanted.count) wanted, \(existing.count) existing, changed=\(changed)")
    }

    /// Las entradas de Calarm que ya existen, por horario, ordenadas de forma
    /// estable entre dispositivos. Devuelve la primera ocurrencia de cada serie,
    /// que es la que hay que borrar para borrar la serie entera.
    private func existingEvents(
        in calendar: EKCalendar,
        covering specs: [EventSpec],
        ownerIDs: Set<UUID>?
    ) -> [String: [EKEvent]] {
        let now = Date()
        var start = now.addingTimeInterval(-365 * 86_400)
        var end = now.addingTimeInterval(2 * 365 * 86_400)
        // Una serie recurrente cae en cualquier ventana de un año; solo las
        // entradas de una sola vez obligan a mirar su propia fecha.
        for spec in specs where spec.rule == .once {
            start = min(start, spec.start.addingTimeInterval(-86_400))
            end = max(end, spec.start.addingTimeInterval(86_400))
        }

        var masters: [String: EKEvent] = [:]
        // EventKit no acepta predicados de más de cuatro años: se trocea.
        let chunk: TimeInterval = 4 * 365 * 86_400 - 86_400
        var chunkStart = start
        var chunks = 0
        while chunkStart < end, chunks < 12 {
            let chunkEnd = min(end, chunkStart.addingTimeInterval(chunk))
            let predicate = store.predicateForEvents(withStart: chunkStart, end: chunkEnd, calendars: [calendar])
            for occurrence in store.events(matching: predicate) {
                guard let id = occurrence.eventIdentifier, masters[id] == nil,
                      let key = Self.key(of: occurrence) else { continue }
                if let ownerIDs, let owner = Self.ownerID(ofKey: key), !ownerIDs.contains(owner) { continue }
                masters[id] = store.event(withIdentifier: id) ?? occurrence
            }
            chunkStart = chunkEnd
            chunks += 1
        }

        var result: [String: [EKEvent]] = [:]
        for event in masters.values {
            guard let key = Self.key(of: event) else { continue }
            result[key, default: []].append(event)
        }
        for key in result.keys {
            result[key]?.sort { ($0.calendarItemExternalIdentifier ?? "") < ($1.calendarItemExternalIdentifier ?? "") }
        }
        return result
    }

    private func create(_ spec: EventSpec, in calendar: EKCalendar) -> Bool {
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = spec.title
        event.startDate = spec.start
        event.endDate = spec.start.addingTimeInterval(Self.eventDuration)
        event.notes = spec.notes
        event.url = URL(string: Self.urlPrefix + spec.key + "?v=" + spec.hash)
        // Sin avisos propios: la que suena es la alarma de Calarm.
        event.alarms = nil
        if let rule = Self.recurrenceRule(for: spec.rule) {
            event.recurrenceRules = [rule]
        }
        do {
            try store.save(event, span: .thisEvent, commit: false)
            return true
        } catch {
            Self.log.error("save \(spec.key): \(error.localizedDescription)")
            return false
        }
    }

    private func remove(_ event: EKEvent) -> Bool {
        do {
            try store.remove(event, span: event.hasRecurrenceRules ? .futureEvents : .thisEvent, commit: false)
            return true
        } catch {
            Self.log.error("remove: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Calendario «Calarm»

    private func mirrorCalendar(createIfNeeded: Bool) -> EKCalendar? {
        let candidates = store.calendars(for: .event)
            .filter { Self.isMirrorCalendar($0) && $0.allowsContentModifications }
        // Si hay más de uno (dos cuentas, por ejemplo) gana el de iCloud, y
        // entre iguales el mismo en todos los dispositivos.
        if let found = candidates.min(by: { (Self.rank($0), $0.calendarIdentifier) < (Self.rank($1), $1.calendarIdentifier) }) {
            return found
        }
        guard createIfNeeded else { return nil }
        guard let source = preferredSource() else {
            Self.log.error("no source for the Calarm calendar; sources: \(self.store.sources.map { "\($0.title)/\($0.sourceType.rawValue)" })")
            return nil
        }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = Self.calendarTitle
        calendar.source = source
        calendar.cgColor = UIColor(Theme.shared.accent).cgColor
        do {
            try store.saveCalendar(calendar, commit: true)
            Self.log.info("created the Calarm calendar in \(source.title)")
            return calendar
        } catch {
            Self.log.error("saveCalendar in \(source.title): \(error.localizedDescription)")
            return nil
        }
    }

    private static func rank(_ calendar: EKCalendar) -> Int {
        calendar.source?.sourceType == .calDAV ? 0 : 1
    }

    /// Dónde crear el calendario: en iCloud si la cuenta está, para que llegue a
    /// los demás dispositivos; si no, donde van los eventos nuevos; y si no,
    /// en el propio iPhone.
    private func preferredSource() -> EKSource? {
        let sources = store.sources
        if let icloud = sources.first(where: {
            $0.sourceType == .calDAV && $0.title.localizedCaseInsensitiveContains("icloud")
        }) {
            return icloud
        }
        if let defaultSource = store.defaultCalendarForNewEvents?.source,
           [.calDAV, .local, .exchange].contains(defaultSource.sourceType) {
            return defaultSource
        }
        return sources.first { $0.sourceType == .local }
    }

    // MARK: - Qué entradas tiene que haber

    private struct EventSpec {
        let ownerID: UUID
        /// `<alarma>/<horario>`, la identidad de la entrada en su URL.
        let key: String
        let title: String
        let start: Date
        let notes: String?
        let rule: RecurrenceRule
        /// Huella del contenido. Igual en todos los dispositivos para la misma
        /// alarma, que es lo que permite reconocer una entrada ya escrita.
        let hash: String
    }

    /// Las alarmas recibidas de otra persona no se escriben: son suyas, y ya
    /// están en su calendario si ella lo activó. Las apagadas tampoco: el
    /// calendario enseña lo que va a sonar.
    private static func specs(for reminder: Reminder) -> [EventSpec] {
        guard !reminder.isReceivedShare, reminder.isEnabled else { return [] }
        let trimmedTitle = reminder.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmedTitle.isEmpty ? appLocalized("Alarma") : trimmedTitle
        let trimmedNotes = reminder.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let notes: String? = trimmedNotes.isEmpty ? nil : trimmedNotes

        return reminder.allSchedules.map { schedule in
            let start = firstOccurrence(of: schedule)
            let hash = digest([
                title,
                String(format: "%.0f", start.timeIntervalSinceReferenceDate),
                canonical(schedule.recurrence),
                notes ?? "",
                String(Int(eventDuration)),
            ])
            return EventSpec(
                ownerID: reminder.id,
                key: "\(reminder.id.uuidString)/\(schedule.id.uuidString)",
                title: title,
                start: start,
                notes: notes,
                rule: schedule.recurrence,
                hash: hash
            )
        }
    }

    /// Para una regla semanal el día elegido puede no ser uno de los marcados;
    /// el calendario necesita que la primera entrada sí lo sea, o pintaría ese
    /// día de más.
    private static func firstOccurrence(of schedule: AlarmSchedule) -> Date {
        guard case .weekly(_, let weekdays) = schedule.recurrence, !weekdays.isEmpty else { return schedule.date }
        let horizon = schedule.date.addingTimeInterval(400 * 86_400)
        return RecurrenceEngine.occurrences(
            rule: schedule.recurrence,
            baseDate: schedule.date,
            from: schedule.date,
            to: horizon
        ).first ?? schedule.date
    }

    /// Texto estable de una regla (el JSON de un `Set` cambia de orden de una
    /// ejecución a otra, y la huella tiene que ser la misma en todas partes).
    private static func canonical(_ rule: RecurrenceRule) -> String {
        switch rule {
        case .once: "once"
        case .daily(let n): "daily:\(n)"
        case .weekly(let n, let days): "weekly:\(n):" + days.map(\.rawValue).sorted().map(String.init).joined(separator: ",")
        case .monthly(let n): "monthly:\(n)"
        case .yearly(let n): "yearly:\(n)"
        }
    }

    private static func digest(_ parts: [String]) -> String {
        let data = Data(parts.joined(separator: "|").utf8)
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func recurrenceRule(for rule: RecurrenceRule) -> EKRecurrenceRule? {
        switch rule {
        case .once:
            return nil
        case .daily(let n):
            return EKRecurrenceRule(recurrenceWith: .daily, interval: max(1, n), end: nil)
        case .weekly(let n, let days):
            guard !days.isEmpty else {
                return EKRecurrenceRule(recurrenceWith: .weekly, interval: max(1, n), end: nil)
            }
            let weekdays = days
                .sorted { $0.rawValue < $1.rawValue }
                .compactMap { EKWeekday(rawValue: $0.rawValue) }
                .map { EKRecurrenceDayOfWeek($0) }
            return EKRecurrenceRule(
                recurrenceWith: .weekly,
                interval: max(1, n),
                daysOfTheWeek: weekdays,
                daysOfTheMonth: nil,
                monthsOfTheYear: nil,
                weeksOfTheYear: nil,
                daysOfTheYear: nil,
                setPositions: nil,
                end: nil
            )
        case .monthly(let n):
            return EKRecurrenceRule(recurrenceWith: .monthly, interval: max(1, n), end: nil)
        case .yearly(let n):
            return EKRecurrenceRule(recurrenceWith: .yearly, interval: max(1, n), end: nil)
        }
    }

    // MARK: - URL de cada entrada

    private static func key(of event: EKEvent) -> String? {
        guard let url = event.url, url.absoluteString.hasPrefix(urlPrefix) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2 else { return nil }
        return parts[0] + "/" + parts[1]
    }

    private static func version(of event: EKEvent) -> String? {
        guard let url = event.url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        return items.first { $0.name == "v" }?.value
    }

    private static func ownerID(ofKey key: String) -> UUID? {
        key.split(separator: "/").first.flatMap { UUID(uuidString: String($0)) }
    }
}
