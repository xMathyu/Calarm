//
//  FirestoreMapping.swift
//  Calarm
//
//  Traducción entre lo que la app ya sabe aplicar (`SharePayload`,
//  `SharedCountdownPayload`, `RecurrenceRule`, `WakeChallenge`) y los mapas de
//  Firestore del contrato compartido con Android y la web
//  (`calarmi-firebase/DESIGN.md`). Cambiar un nombre de campo aquí exige
//  cambiarlo en los tres lados.
//
//  No importa Firebase a propósito: las fechas salen como `Date` (el SDK las
//  guarda como timestamp) y lo que se lee pasa antes por
//  `FirestoreValues.normalized`, que cambia cada `Timestamp` por un `Date`. Así
//  las pruebas cubren la traducción sin red ni SDK.
//
//  Se traduce a `SharePayload` (el sobre de CloudKit) y no directo a `Reminder`
//  porque todo lo de después ya trabaja con él: `apply`, los avisos personales
//  (`ShareLeadTimesStore`), el aviso de cambio de hora (`ShareChangeNotifier`) y
//  el editor de las personas de confianza.
//

import CryptoKit
import Foundation

enum FirestoreMapping {
    typealias Map = [String: Any]

    // MARK: - Límites de las reglas (firestore.rules)

    /// Lo que las reglas aceptan. Recortar aquí evita que una alarma con un
    /// título larguísimo haga fallar todo el share.
    static let maxTitle = 200
    static let maxNotes = 2000
    static let maxSchedules = 20
    static let maxLeadTimes = 10
    static let maxInterval = 999
    static let maxName = 60

    // MARK: - Recurrence

    /// `{ type, interval, weekdays }`. `weekdays` (1 = domingo … 7 = sábado,
    /// igual que `Weekday`) solo lleva días en `weekly`.
    static func recurrenceMap(_ rule: RecurrenceRule) -> Map {
        func clamp(_ n: Int) -> Int { min(max(n, 1), maxInterval) }
        switch rule {
        case .once:
            return ["type": "once", "interval": 1, "weekdays": [Int]()]
        case .daily(let n):
            return ["type": "daily", "interval": clamp(n), "weekdays": [Int]()]
        case .weekly(let n, let days):
            return ["type": "weekly", "interval": clamp(n), "weekdays": days.map(\.rawValue).sorted()]
        case .monthly(let n):
            return ["type": "monthly", "interval": clamp(n), "weekdays": [Int]()]
        case .yearly(let n):
            return ["type": "yearly", "interval": clamp(n), "weekdays": [Int]()]
        }
    }

    /// Lo contrario, tolerante: lo que no se entiende (un tipo nuevo de otra
    /// plataforma, un intervalo raro) suena una vez en vez de romper la alarma.
    static func recurrence(from value: Any?) -> RecurrenceRule {
        guard let map = value as? Map, let type = map["type"] as? String else { return .once }
        let interval = min(max(int(map["interval"]) ?? 1, 1), maxInterval)
        switch type {
        case "daily": return .daily(interval: interval)
        case "weekly":
            let raw = (map["weekdays"] as? [Any] ?? []).compactMap(int)
            return .weekly(interval: interval, weekdays: Set(raw.compactMap(Weekday.init(rawValue:))))
        case "monthly": return .monthly(interval: interval)
        case "yearly": return .yearly(interval: interval)
        default: return .once
        }
    }

    // MARK: - Alarm

    /// El mapa `Alarm` de un sobre. El tono (`AlarmTone.rawValue`) solo viaja si
    /// es de los que trae la app: uno importado no existe en otro teléfono.
    static func alarmMap(from payload: SharePayload) -> Map {
        var map: Map = [
            "title": clipped(payload.title, maxTitle, fallback: "Alarma"),
            "date": payload.date,
            "recurrence": recurrenceMap(rule(from: payload.recurrenceData)),
            "additionalSchedules": (payload.additionalSchedules ?? []).prefix(maxSchedules).map {
                ["date": $0.date, "recurrence": recurrenceMap(rule(from: $0.recurrenceData))] as Map
            },
            "leadTimes": leadTimes(payload.leadTimeSeconds),
            "categoryRaw": payload.categoryRaw,
            "iconKindRaw": payload.iconKindRaw,
            "isEnabled": payload.isEnabled,
        ]
        if let notes = payload.notes, !notes.isEmpty {
            map["notes"] = String(notes.prefix(maxNotes))
        }
        if let symbol = payload.symbolName, !symbol.isEmpty {
            map["symbolName"] = symbol
        }
        if let custom = payload.customCategory {
            map["customCategory"] = [
                "id": custom.id,
                "name": custom.name,
                "colorHex": custom.colorHex,
                "iconKindRaw": custom.iconKindRaw,
                "iconValue": custom.iconValue,
            ] as Map
        }
        if let data = payload.challengeData, let challenge = WakeChallenge.decode(data) {
            map["challenge"] = challengeMap(challenge)
        }
        if let tone = payload.tone, AlarmTone(rawValue: tone).map(AlarmTone.builtins.contains) == true {
            map["tone"] = tone
        }
        return map
    }

    /// Un sobre a partir del mapa `Alarm` de Firestore. Nil si falta lo mínimo
    /// (título y fecha). `id` es el del documento; `updatedAt`, el del documento
    /// que lo contiene (el `Alarm` no lleva fecha de cambio propia).
    static func payload(fromAlarm value: Any?, id: String, updatedAt: Date?) -> SharePayload? {
        guard let map = value as? Map,
              let title = map["title"] as? String,
              let date = map["date"] as? Date
        else { return nil }
        let schedules = (map["additionalSchedules"] as? [Any] ?? []).compactMap { item -> SharePayload.ScheduleInfo? in
            guard let schedule = item as? Map, let date = schedule["date"] as? Date else { return nil }
            return SharePayload.ScheduleInfo(date: date, recurrenceData: encode(recurrence(from: schedule["recurrence"])))
        }
        var custom: SharePayload.CustomCategoryInfo?
        if let c = map["customCategory"] as? Map, let cid = c["id"] as? String {
            custom = SharePayload.CustomCategoryInfo(
                id: cid,
                name: c["name"] as? String ?? "",
                colorHex: c["colorHex"] as? String ?? "",
                iconKindRaw: int(c["iconKindRaw"]) ?? ReminderIconKind.symbol.rawValue,
                iconValue: c["iconValue"] as? String ?? ""
            )
        }
        let seconds = (map["leadTimes"] as? [Any] ?? []).compactMap(int)
        return SharePayload(
            version: SharePayload.currentVersion,
            id: id,
            title: title,
            notes: map["notes"] as? String,
            date: date,
            categoryRaw: int(map["categoryRaw"]) ?? ReminderCategory.event.rawValue,
            iconKindRaw: int(map["iconKindRaw"]) ?? ReminderIconKind.symbol.rawValue,
            symbolName: map["symbolName"] as? String,
            leadTimeSeconds: seconds.isEmpty ? [AlarmLeadTime.atStart.rawValue] : seconds,
            isEnabled: map["isEnabled"] as? Bool ?? true,
            recurrenceData: encode(recurrence(from: map["recurrence"])),
            customCategory: custom,
            updatedAt: updatedAt,
            isDeleted: nil,
            photoThumbnail: nil,
            additionalSchedules: schedules.isEmpty ? nil : schedules,
            challengeData: challenge(from: map["challenge"])?.encoded(),
            invitePreview: nil,
            tone: map["tone"] as? String
        )
    }

    static func challengeMap(_ challenge: WakeChallenge) -> Map {
        var map: Map = [
            "kind": challenge.kind.rawValue,
            "difficulty": challenge.difficulty.rawValue,
            "allowsSnooze": challenge.allowsSnooze,
        ]
        if let code = challenge.code, !code.isEmpty { map["code"] = code }
        return map
    }

    /// Un reto de un tipo que esta versión no conoce se descarta: mejor una
    /// alarma que se apaga con un toque que una que no se puede apagar.
    static func challenge(from value: Any?) -> WakeChallenge? {
        guard let map = value as? Map,
              let kind = (map["kind"] as? String).flatMap(WakeChallenge.Kind.init(rawValue:))
        else { return nil }
        return WakeChallenge(
            kind: kind,
            difficulty: int(map["difficulty"]).flatMap(WakeChallenge.Difficulty.init(rawValue:)) ?? .medium,
            allowsSnooze: map["allowsSnooze"] as? Bool ?? true,
            code: map["code"] as? String
        )
    }

    // MARK: - Countdown

    static func countdownMap(from payload: SharedCountdownPayload) -> Map {
        var map: Map = [
            "title": clipped(payload.title, maxTitle, fallback: "Cuenta regresiva"),
            "date": payload.date,
            "includesTime": payload.includesTime,
            "repeatsYearly": payload.repeatsYearly,
            "colorHex": String(payload.colorHex.prefix(9)),
            "iconKindRaw": payload.iconKindRaw,
            "iconValue": String(payload.iconValue.prefix(100)),
        ]
        if let notes = payload.notes, !notes.isEmpty {
            map["notes"] = String(notes.prefix(maxNotes))
        }
        return map
    }

    static func countdownPayload(from value: Any?, id: String, photo: Data?, updatedAt: Date?) -> SharedCountdownPayload? {
        guard let map = value as? Map,
              let title = map["title"] as? String,
              let date = map["date"] as? Date
        else { return nil }
        return SharedCountdownPayload(
            version: SharedCountdownPayload.currentVersion,
            id: id,
            title: title,
            notes: map["notes"] as? String,
            date: date,
            includesTime: map["includesTime"] as? Bool ?? false,
            repeatsYearly: map["repeatsYearly"] as? Bool ?? false,
            colorHex: map["colorHex"] as? String ?? CountdownEvent.defaultColorHex,
            iconKindRaw: int(map["iconKindRaw"]) ?? ReminderIconKind.emoji.rawValue,
            iconValue: map["iconValue"] as? String ?? CountdownEvent.defaultEmoji,
            photo: photo,
            updatedAt: updatedAt ?? Date()
        )
    }

    // MARK: - Preview

    /// Lo que dibuja la página de invitación (y la tarjeta del enlace).
    /// `repeatsYearly`: una cuenta anual (cumpleaños) o una alarma cuyo horario
    /// principal se repite cada año; la web muestra la próxima vez.
    static func previewMap(title: String, date: Date, hasTime: Bool, repeatsYearly: Bool = false, preview: InvitePreview) -> Map {
        var map: Map = [
            "title": clipped(title, maxTitle, fallback: "Calarmi"),
            "date": date,
            "hasTime": hasTime,
            "timeZone": String(preview.timeZone.prefix(64)),
            "language": ["es", "en", "pt"].contains(preview.language) ? preview.language : "es",
            "repeatsYearly": repeatsYearly,
        ]
        if let tint = preview.tintHex { map["tintHex"] = tint }
        if let emoji = preview.emoji { map["emoji"] = emoji }
        if let symbol = preview.symbol { map["symbol"] = symbol }
        return map
    }

    // MARK: - Personas

    /// El nombre tal como lo aceptan las reglas (1…60 caracteres), o nil.
    static func validName(_ raw: String?) -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxName))
    }

    /// Los miembros de un share (o las personas de confianza de una lista),
    /// ordenados por cuándo entraron, sin quien pregunta.
    struct Person: Equatable {
        var uid: String
        var name: String
        var role: String
        var joinedAt: Date?
    }

    static func people(in value: Any?, excluding uid: String? = nil, dateKey: String = "joinedAt") -> [Person] {
        guard let map = value as? Map else { return [] }
        return map.compactMap { key, entry -> Person? in
            guard key != uid, let entry = entry as? Map else { return nil }
            return Person(
                uid: key,
                name: validName(entry["name"] as? String) ?? "",
                role: entry["role"] as? String ?? "member",
                joinedAt: entry[dateKey] as? Date
            )
        }
        .sorted { ($0.joinedAt ?? .distantFuture, $0.uid) < ($1.joinedAt ?? .distantFuture, $1.uid) }
    }

    // MARK: - Huellas

    /// Huella estable de un mapa (claves ordenadas, fechas en milisegundos):
    /// el dueño no vuelve a subir (ni a avisar a todos) lo que no cambió.
    static func fingerprint(_ value: Any) -> String {
        var out = ""
        func walk(_ value: Any) {
            switch value {
            case let map as Map:
                out += "{"
                for key in map.keys.sorted() {
                    out += key.debugDescription + ":"
                    walk(map[key]!)
                    out += ","
                }
                out += "}"
            case let date as Date:
                out += "d\(Int64((date.timeIntervalSince1970 * 1000).rounded()))"
            case let data as Data:
                out += "b" + sha256(data)
            case let bool as Bool:
                out += bool ? "T" : "F"
            case let string as String:
                out += string.debugDescription
            case let number as Int:
                out += "i\(number)"
            case let number as Double:
                out += "f\(number)"
            case let list as [Any]:
                out += "["
                list.forEach { walk($0); out += "," }
                out += "]"
            default:
                out += "?\(value)"
            }
        }
        walk(value)
        return sha256(Data(out.utf8))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Ayudantes

    /// Un entero de Firestore (NSNumber), de Swift o un `Double` exacto (la web
    /// escribe números de JavaScript).
    nonisolated static func int(_ value: Any?) -> Int? {
        switch value {
        case let v as Int: return v
        case let v as Int64: return Int(v)
        case let v as Double where v.rounded() == v && abs(v) < 1e15: return Int(v)
        case let v as NSNumber: return v.intValue
        default: return nil
        }
    }

    /// Avisos en segundos: al menos uno (las reglas lo exigen) y sin repetidos.
    static func leadTimes(_ seconds: [Int]) -> [Int] {
        let unique = Array(Set(seconds.filter { $0 >= 0 })).sorted()
        return unique.isEmpty ? [AlarmLeadTime.atStart.rawValue] : Array(unique.prefix(maxLeadTimes))
    }

    private static func clipped(_ text: String, _ max: Int, fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : String(trimmed.prefix(max))
    }

    /// Mismo respaldo que `Reminder.recurrence`: lo ilegible suena una vez.
    private static func rule(from data: Data) -> RecurrenceRule {
        (try? JSONDecoder().decode(RecurrenceRule.self, from: data)) ?? .once
    }

    private static func encode(_ rule: RecurrenceRule) -> Data {
        (try? JSONEncoder().encode(rule)) ?? Data()
    }
}

// MARK: - Token de invitación

/// El token de `invites/{token}`: 22 caracteres `[A-Za-z0-9]` al azar (~131
/// bits). Es la llave de la invitación (cualquiera que lo tenga puede leerla),
/// así que sale del generador criptográfico del sistema.
enum InviteToken {
    static let length = 22
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    static func make() -> String {
        // `SystemRandomNumberGenerator` es criptográfico en las plataformas de
        // Apple, y `randomElement` elige sin sesgo de módulo.
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }

    /// Lo mismo que exigen las reglas (`^[A-Za-z0-9]{22}$`).
    static func isValid(_ token: String) -> Bool {
        token.count == length && token.unicodeScalars.allSatisfy {
            ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0)
        }
    }
}

// MARK: - Migración desde CloudKit

/// Las decisiones de la migración (DESIGN.md › «Migración desde CloudKit»),
/// separadas de las llamadas a red para poder probarlas.
enum ShareMigration {
    /// Qué hace un invitado con una alarma o cuenta que todavía le llega por
    /// CloudKit.
    enum ParticipantStep: Equatable {
        /// Sigue como está: el dueño aún no migró (sin token), Firebase no está,
        /// o falta el nombre que pide unirse.
        case stayOnCloudKit
        /// El dueño ya creó el share de Firestore: unirse con su token y luego
        /// salir del `CKShare`.
        case joinFirestore(token: String)
        /// Ya se unió en Firestore pero la salida del `CKShare` no se completó.
        case leaveCloudKit
        /// La persona la había quitado de su lista: el escaneo ya la saca del share.
        case ignore
    }

    static func participantStep(
        firebaseToken: String?,
        deletedByMe: Bool,
        alreadyOnFirestore: Bool,
        hasName: Bool,
        firebaseAvailable: Bool
    ) -> ParticipantStep {
        if deletedByMe { return .ignore }
        guard firebaseAvailable, let token = firebaseToken, InviteToken.isValid(token) else { return .stayOnCloudKit }
        if alreadyOnFirestore { return .leaveCloudKit }
        return hasName ? .joinFirestore(token: token) : .stayOnCloudKit
    }

    /// Si el dueño debe crear el share de Firestore (y su invitación) para un
    /// share de CloudKit. Lo hace una sola vez: si el payload ya lleva token, lo
    /// hizo este u otro de sus dispositivos.
    static func ownerShouldMigrate(
        payloadToken: String?,
        ownsLocalItem: Bool,
        hasName: Bool,
        firebaseAvailable: Bool
    ) -> Bool {
        firebaseAvailable && hasName && ownsLocalItem && (payloadToken ?? "").isEmpty
    }

    /// Las copias recibidas que hay que quitar tras sincronizar, y por qué.
    ///
    /// Conviven dos orígenes: lo que llega por CloudKit (invitaciones viejas) y
    /// lo que llega por Firestore. Cada origen solo puede dar por borrado lo
    /// suyo, y solo si su lectura salió bien (`nil` = falló o no se leyó): una
    /// red caída no puede borrar alarmas válidas.
    struct Stale: Equatable {
        /// El dueño la borró, dejó de compartirla o quitó a esta persona: se avisa.
        var byOwner: Set<UUID> = []
        /// La persona la había quitado de su lista: se borra sin avisar.
        var byMe: Set<UUID> = []
    }

    static func staleReceived(
        local: Set<UUID>,
        cloudKitPresent: Set<UUID>?,
        firestorePresent: Set<UUID>?,
        firestoreTracked: Set<UUID>,
        accepting: Set<UUID>,
        tombstoned: Set<UUID>
    ) -> Stale {
        var stale = Stale()
        for id in local {
            if tombstoned.contains(id) {
                stale.byMe.insert(id)
                continue
            }
            if accepting.contains(id) { continue }
            let inCloudKit = cloudKitPresent?.contains(id)
            let inFirestore = firestorePresent?.contains(id)
            if inCloudKit == true || inFirestore == true { continue }
            // De Firestore: decide Firestore. Del resto: CloudKit.
            let gone = firestoreTracked.contains(id) ? inFirestore == false : inCloudKit == false
            if gone { stale.byOwner.insert(id) }
        }
        return stale
    }
}
