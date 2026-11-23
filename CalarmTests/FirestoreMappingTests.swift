//
//  FirestoreMappingTests.swift
//  CalarmTests
//
//  El contrato con Android y la web (calarmi-firebase/DESIGN.md): cómo viajan
//  una alarma, una cuenta regresiva y una vista previa a Firestore y de vuelta,
//  el token de las invitaciones, sus enlaces, los pushes y las decisiones de la
//  migración desde CloudKit. Sin red ni SDK: el mapeo no importa Firebase.
//

import Foundation
import Testing
@testable import Calarm

struct FirestoreMappingTests {

    // MARK: - Ayudantes

    private static let date = Date(timeIntervalSince1970: 1_800_000_000)

    private static func encoded(_ rule: RecurrenceRule) -> Data {
        (try? JSONEncoder().encode(rule)) ?? Data()
    }

    private static func payload(
        title: String = "Despertar",
        notes: String? = "Con café",
        recurrence: RecurrenceRule = .weekly(interval: 1, weekdays: [.monday, .friday]),
        leadTimes: [Int] = [0, 900],
        extra: [SharePayload.ScheduleInfo]? = nil,
        challenge: WakeChallenge? = nil,
        tone: String? = nil,
        custom: SharePayload.CustomCategoryInfo? = nil
    ) -> SharePayload {
        SharePayload(
            version: SharePayload.currentVersion,
            id: "6F1E4D8A-1111-2222-3333-444455556666",
            title: title,
            notes: notes,
            date: date,
            categoryRaw: ReminderCategory.event.rawValue,
            iconKindRaw: ReminderIconKind.emoji.rawValue,
            symbolName: "⏰",
            leadTimeSeconds: leadTimes,
            isEnabled: true,
            recurrenceData: encoded(recurrence),
            customCategory: custom,
            additionalSchedules: extra,
            challengeData: challenge?.encoded(),
            tone: tone
        )
    }

    private static func rule(_ data: Data) -> RecurrenceRule? {
        try? JSONDecoder().decode(RecurrenceRule.self, from: data)
    }

    // MARK: - Recurrence

    @Test func recurrenceMapsEveryCase() {
        let once = FirestoreMapping.recurrenceMap(.once)
        #expect(once["type"] as? String == "once")
        #expect(once["interval"] as? Int == 1)
        #expect((once["weekdays"] as? [Int])?.isEmpty == true)

        #expect(FirestoreMapping.recurrenceMap(.daily(interval: 3))["type"] as? String == "daily")
        #expect(FirestoreMapping.recurrenceMap(.monthly(interval: 2))["interval"] as? Int == 2)
        #expect(FirestoreMapping.recurrenceMap(.yearly(interval: 1))["type"] as? String == "yearly")
    }

    /// 1 = domingo … 7 = sábado (igual que `Weekday` y que Android), ordenados.
    @Test func weeklyWeekdaysAreSortedRawValues() {
        let map = FirestoreMapping.recurrenceMap(.weekly(interval: 2, weekdays: [.saturday, .sunday, .wednesday]))
        #expect(map["type"] as? String == "weekly")
        #expect(map["interval"] as? Int == 2)
        #expect(map["weekdays"] as? [Int] == [1, 4, 7])
    }

    /// Las reglas aceptan 1…999.
    @Test func intervalIsClampedToRules() {
        #expect(FirestoreMapping.recurrenceMap(.daily(interval: 0))["interval"] as? Int == 1)
        #expect(FirestoreMapping.recurrenceMap(.daily(interval: 5000))["interval"] as? Int == 999)
    }

    @Test func recurrenceRoundTrips() {
        let rules: [RecurrenceRule] = [
            .once, .daily(interval: 2), .weekly(interval: 1, weekdays: [.monday, .thursday]),
            .monthly(interval: 3), .yearly(interval: 1),
        ]
        for rule in rules {
            #expect(FirestoreMapping.recurrence(from: FirestoreMapping.recurrenceMap(rule)) == rule)
        }
    }

    /// Lo que llega de otra plataforma se lee con tolerancia: un tipo
    /// desconocido suena una vez, un número de JavaScript sirve de entero y un
    /// día fuera de rango se ignora.
    @Test func recurrenceFromOtherPlatformsIsLenient() {
        #expect(FirestoreMapping.recurrence(from: ["type": "hourly", "interval": 1, "weekdays": []]) == .once)
        #expect(FirestoreMapping.recurrence(from: nil) == .once)
        #expect(FirestoreMapping.recurrence(from: ["type": "daily", "interval": 3.0, "weekdays": []]) == .daily(interval: 3))
        #expect(FirestoreMapping.recurrence(from: ["type": "daily", "interval": 0]) == .daily(interval: 1))
        let weekly = FirestoreMapping.recurrence(from: ["type": "weekly", "interval": NSNumber(value: 1), "weekdays": [2, 9, 6]])
        #expect(weekly == .weekly(interval: 1, weekdays: [.monday, .friday]))
    }

    // MARK: - Alarm

    @Test func alarmMapCarriesTheContract() {
        let extra = [SharePayload.ScheduleInfo(date: Self.date.addingTimeInterval(3600), recurrenceData: Self.encoded(.daily(interval: 1)))]
        let challenge = WakeChallenge(kind: .math, difficulty: .hard, allowsSnooze: false)
        let custom = SharePayload.CustomCategoryInfo(id: "C1", name: "Gym", colorHex: "#FF0000", iconKindRaw: 0, iconValue: "dumbbell")
        let map = FirestoreMapping.alarmMap(from: Self.payload(extra: extra, challenge: challenge, tone: "chime", custom: custom))

        #expect(map["title"] as? String == "Despertar")
        #expect(map["notes"] as? String == "Con café")
        #expect(map["date"] as? Date == Self.date)
        #expect(map["leadTimes"] as? [Int] == [0, 900])
        #expect(map["categoryRaw"] as? Int == ReminderCategory.event.rawValue)
        #expect(map["iconKindRaw"] as? Int == ReminderIconKind.emoji.rawValue)
        #expect(map["symbolName"] as? String == "⏰")
        #expect(map["isEnabled"] as? Bool == true)
        #expect(map["tone"] as? String == "chime")
        let recurrence = map["recurrence"] as? [String: Any]
        #expect(recurrence?["weekdays"] as? [Int] == [2, 6])
        let schedules = map["additionalSchedules"] as? [[String: Any]]
        #expect(schedules?.count == 1)
        #expect((schedules?.first?["recurrence"] as? [String: Any])?["type"] as? String == "daily")
        let challengeMap = map["challenge"] as? [String: Any]
        #expect(challengeMap?["kind"] as? String == "math")
        #expect(challengeMap?["difficulty"] as? Int == 3)
        #expect(challengeMap?["allowsSnooze"] as? Bool == false)
        #expect((map["customCategory"] as? [String: Any])?["name"] as? String == "Gym")
    }

    /// Lo opcional vacío no viaja, y los avisos cumplen las reglas (≥ 1, sin repetidos).
    @Test func alarmMapOmitsEmptyOptionalsAndNormalizesLeadTimes() {
        let map = FirestoreMapping.alarmMap(from: Self.payload(notes: "", leadTimes: []))
        #expect(map["notes"] == nil)
        #expect(map["challenge"] == nil)
        #expect(map["customCategory"] == nil)
        #expect(map["tone"] == nil)
        #expect(map["leadTimes"] as? [Int] == [0])
        #expect(FirestoreMapping.leadTimes([900, 0, 900, 60]) == [0, 60, 900])
        #expect(FirestoreMapping.leadTimes(Array(0..<20)).count == FirestoreMapping.maxLeadTimes)
    }

    /// Un tono importado no existe en otro teléfono: no viaja.
    @Test func importedToneDoesNotTravel() {
        #expect(FirestoreMapping.alarmMap(from: Self.payload(tone: "imported:abc"))["tone"] == nil)
        #expect(FirestoreMapping.alarmMap(from: Self.payload(tone: "system"))["tone"] as? String == "system")
    }

    @Test func titleIsClippedToRules() {
        let long = String(repeating: "a", count: 300)
        #expect((FirestoreMapping.alarmMap(from: Self.payload(title: long))["title"] as? String)?.count == 200)
        #expect(FirestoreMapping.alarmMap(from: Self.payload(title: "   "))["title"] as? String == "Alarma")
    }

    @Test func alarmRoundTripsThroughFirestore() throws {
        let extra = [SharePayload.ScheduleInfo(date: Self.date.addingTimeInterval(7200), recurrenceData: Self.encoded(.monthly(interval: 1)))]
        let challenge = WakeChallenge(kind: .qr, difficulty: .easy, allowsSnooze: true, code: "123")
        let custom = SharePayload.CustomCategoryInfo(id: "C9", name: "Casa", colorHex: "#00FF00", iconKindRaw: 2, iconValue: "🏠")
        let original = Self.payload(extra: extra, challenge: challenge, tone: "harp", custom: custom)
        let updatedAt = Self.date.addingTimeInterval(-60)

        let back = try #require(FirestoreMapping.payload(
            fromAlarm: FirestoreMapping.alarmMap(from: original), id: "doc-id", updatedAt: updatedAt
        ))
        #expect(back.id == "doc-id")
        #expect(back.title == original.title)
        #expect(back.notes == original.notes)
        #expect(back.date == original.date)
        #expect(back.categoryRaw == original.categoryRaw)
        #expect(back.iconKindRaw == original.iconKindRaw)
        #expect(back.symbolName == original.symbolName)
        #expect(back.leadTimeSeconds == [0, 900])
        #expect(back.isEnabled)
        #expect(Self.rule(back.recurrenceData) == .weekly(interval: 1, weekdays: [.monday, .friday]))
        #expect(back.additionalSchedules?.count == 1)
        #expect(back.additionalSchedules.flatMap { Self.rule($0[0].recurrenceData) } == .monthly(interval: 1))
        #expect(back.challengeData.flatMap(WakeChallenge.decode) == challenge)
        #expect(back.customCategory?.id == "C9")
        #expect(back.customCategory?.iconValue == "🏠")
        #expect(back.tone == "harp")
        #expect(back.updatedAt == updatedAt)
    }

    @Test func alarmWithoutTitleOrDateIsRejected() {
        #expect(FirestoreMapping.payload(fromAlarm: ["date": Self.date], id: "x", updatedAt: nil) == nil)
        #expect(FirestoreMapping.payload(fromAlarm: ["title": "Sin fecha"], id: "x", updatedAt: nil) == nil)
        #expect(FirestoreMapping.payload(fromAlarm: nil, id: "x", updatedAt: nil) == nil)
    }

    /// Lo que escribe Android con lo mínimo se lee con valores por defecto.
    @Test func minimalAlarmFromAndroidGetsDefaults() throws {
        let map: [String: Any] = [
            "title": "Pastilla", "date": Self.date,
            "recurrence": ["type": "daily", "interval": NSNumber(value: 1), "weekdays": []],
            "leadTimes": [NSNumber(value: 0)], "categoryRaw": NSNumber(value: 3),
            "iconKindRaw": NSNumber(value: 0), "isEnabled": true,
            "challenge": ["kind": "unknownGame", "difficulty": 2, "allowsSnooze": true],
        ]
        let payload = try #require(FirestoreMapping.payload(fromAlarm: map, id: "abc", updatedAt: nil))
        #expect(payload.categoryRaw == 3)
        #expect(payload.additionalSchedules == nil)
        #expect(Self.rule(payload.recurrenceData) == .daily(interval: 1))
        // Un reto que esta versión no conoce no deja una alarma imposible de apagar.
        #expect(payload.challengeData == nil)
    }

    // MARK: - Countdown y vista previa

    @Test func countdownRoundTrips() throws {
        let original = SharedCountdownPayload(
            version: 1, id: "E1", title: "Viaje", notes: "Lisboa", date: Self.date,
            includesTime: true, repeatsYearly: false, colorHex: "#FF2D55",
            iconKindRaw: ReminderIconKind.emoji.rawValue, iconValue: "✈️", photo: nil, updatedAt: Self.date
        )
        let map = FirestoreMapping.countdownMap(from: original)
        #expect(map["colorHex"] as? String == "#FF2D55")
        let photo = Data([0xFF, 0xD8, 0xFF])
        let back = try #require(FirestoreMapping.countdownPayload(from: map, id: "E1", photo: photo, updatedAt: Self.date))
        #expect(back.title == "Viaje")
        #expect(back.notes == "Lisboa")
        #expect(back.date == Self.date)
        #expect(back.includesTime)
        #expect(!back.repeatsYearly)
        #expect(back.iconValue == "✈️")
        #expect(back.photo == photo)
    }

    @Test func previewFollowsRules() {
        var invite = InvitePreview(tintHex: "#123456", emoji: "🎂", symbol: nil)
        invite.language = "fr"
        let map = FirestoreMapping.previewMap(title: "Cumple", date: Self.date, hasTime: false, repeatsYearly: true, preview: invite)
        #expect(map["title"] as? String == "Cumple")
        #expect(map["hasTime"] as? Bool == false)
        #expect(map["repeatsYearly"] as? Bool == true)
        // Las reglas solo aceptan es/en/pt.
        #expect(map["language"] as? String == "es")
        #expect(map["tintHex"] as? String == "#123456")
        #expect(map["emoji"] as? String == "🎂")
        #expect(map["symbol"] == nil)
        #expect((map["timeZone"] as? String)?.isEmpty == false)
    }

    // MARK: - Personas y huellas

    @Test func namesFollowRules() {
        #expect(FirestoreMapping.validName("  Ana  ") == "Ana")
        #expect(FirestoreMapping.validName("   ") == nil)
        #expect(FirestoreMapping.validName(nil) == nil)
        #expect(FirestoreMapping.validName(String(repeating: "x", count: 80))?.count == 60)
    }

    @Test func peopleAreSortedAndExcludeMe() {
        let members: [String: Any] = [
            "me": ["name": "Yo", "role": "owner", "joinedAt": Self.date],
            "b": ["name": "Bea", "role": "member", "joinedAt": Self.date.addingTimeInterval(20)],
            "a": ["name": "Ana", "role": "member", "joinedAt": Self.date.addingTimeInterval(10)],
        ]
        let people = FirestoreMapping.people(in: members, excluding: "me")
        #expect(people.map(\.name) == ["Ana", "Bea"])
        #expect(people.map(\.uid) == ["a", "b"])
    }

    @Test func fingerprintIgnoresKeyOrderButNotContent() {
        let a: [String: Any] = ["title": "X", "date": Self.date, "list": [1, 2]]
        let b: [String: Any] = ["list": [1, 2], "date": Self.date, "title": "X"]
        let c: [String: Any] = ["title": "X", "date": Self.date.addingTimeInterval(60), "list": [1, 2]]
        #expect(FirestoreMapping.fingerprint(a) == FirestoreMapping.fingerprint(b))
        #expect(FirestoreMapping.fingerprint(a) != FirestoreMapping.fingerprint(c))
    }

    // MARK: - Token y enlaces

    @Test func tokenIs22Base62Characters() {
        let tokens = (0..<200).map { _ in InviteToken.make() }
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        for token in tokens {
            #expect(token.count == 22)
            #expect(token.allSatisfy(alphabet.contains))
            #expect(InviteToken.isValid(token))
        }
        #expect(Set(tokens).count == tokens.count)
    }

    @Test func tokenValidationMatchesRules() {
        #expect(!InviteToken.isValid("short"))
        #expect(!InviteToken.isValid("abcdefghijklmnopqrstu-"))
        #expect(!InviteToken.isValid("abcdefghijklmnopqrstuvw"))
        #expect(!InviteToken.isValid("abcdefghijklmnopqrstñv"))
        #expect(InviteToken.isValid("abcdefghijklmnopqrstuv"))
    }

    @Test func firestoreInviteLinks() {
        let token = "Ab3dEf6hIj9kLm2nOp5qRs"
        let url = InviteLink.make(token: token)
        #expect(url.absoluteString == "https://calarmi.mathyusolutions.com/s/\(token)/")
        #expect(InviteLink.firestoreToken(from: url) == token)
        #expect(InviteLink.isInvite(url))
        // El botón «Abrir en Calarmi» de la web, mientras el AASA no tenga /s/*.
        #expect(InviteLink.firestoreToken(from: URL(string: "calarm://s/\(token)")!) == token)
        #expect(InviteLink.firestoreToken(from: URL(string: "calarm://s/\(token)/")!) == token)
        #expect(InviteLink.isInvite(URL(string: "calarm://s/\(token)")!))
        #expect(InviteLink.firestoreToken(from: URL(string: "https://calarmi.mathyusolutions.com/s/\(token)")!) == token)
    }

    @Test func otherLinksAreNotFirestoreInvites() {
        #expect(InviteLink.firestoreToken(from: URL(string: "https://calarmi.mathyusolutions.com/s/bad-token/")!) == nil)
        #expect(InviteLink.firestoreToken(from: URL(string: "https://example.com/s/Ab3dEf6hIj9kLm2nOp5qRs/")!) == nil)
        #expect(InviteLink.firestoreToken(from: URL(string: "calarm://i/Ab3dEf6hIj9kLm2nOp5qRs")!) == nil)
        // Los enlaces de CloudKit siguen siendo de CloudKit.
        let old = URL(string: "https://calarmi.mathyusolutions.com/i/07628shg9cGxsh2Moi-46rp9A/")!
        #expect(InviteLink.firestoreToken(from: old) == nil)
        #expect(InviteLink.isInvite(old))
        #expect(InviteLink.shareURL(from: old)?.absoluteString == "https://www.icloud.com/share/07628shg9cGxsh2Moi-46rp9A")
    }

    // MARK: - Push

    @Test func pushDataMessageParses() throws {
        let push = try #require(SharePush(userInfo: [
            "type": "share", "event": "updated", "id": "ABC", "kind": "alarm",
            "title": "Despertar", "oldDate": "1800000000000", "newDate": "1800003600000",
            "actorName": "Ana", "gcm.message_id": "1", "aps": ["content-available": 1],
        ]))
        #expect(push.type == .share)
        #expect(push.event == "updated")
        #expect(push.id == "ABC")
        #expect(push.actorName == "Ana")
        #expect(push.oldDate == Self.date)
        #expect(push.newDate == Self.date.addingTimeInterval(3600))

        let reminder = try #require(SharePush(userInfo: ["type": "delegationReminder", "event": "deleted", "id": "R", "principal": "P"]))
        #expect(reminder.principal == "P")
    }

    /// Un push de CloudKit no es un mensaje de Firebase.
    @Test func cloudKitPushIsNotADataMessage() {
        #expect(SharePush(userInfo: ["ck": ["ce": 2], "aps": ["content-available": 1]]) == nil)
        #expect(SharePush(userInfo: ["type": "other", "event": "updated", "id": "x"]) == nil)
    }

    // MARK: - Migración desde CloudKit

    @Test func participantJoinsFirestoreOnlyWithTokenAndName() {
        let token = "Ab3dEf6hIj9kLm2nOp5qRs"
        func step(_ token: String?, deleted: Bool = false, already: Bool = false, name: Bool = true, firebase: Bool = true) -> ShareMigration.ParticipantStep {
            ShareMigration.participantStep(
                firebaseToken: token, deletedByMe: deleted, alreadyOnFirestore: already,
                hasName: name, firebaseAvailable: firebase
            )
        }
        #expect(step(token) == .joinFirestore(token: token))
        // El dueño aún no migró (app vieja): sigue por CloudKit.
        #expect(step(nil) == .stayOnCloudKit)
        #expect(step("") == .stayOnCloudKit)
        #expect(step("not-a-token") == .stayOnCloudKit)
        // Unirse exige nombre; sin Firebase no hay a dónde ir.
        #expect(step(token, name: false) == .stayOnCloudKit)
        #expect(step(token, firebase: false) == .stayOnCloudKit)
        // Ya está en Firestore: solo falta salir del CKShare.
        #expect(step(token, already: true) == .leaveCloudKit)
        // La había quitado de su lista: no vuelve por la migración.
        #expect(step(token, deleted: true) == .ignore)
    }

    @Test func ownerMigratesOnceAndOnlyOwnItems() {
        #expect(ShareMigration.ownerShouldMigrate(payloadToken: nil, ownsLocalItem: true, hasName: true, firebaseAvailable: true))
        // Ya lo hizo este u otro dispositivo de la cuenta.
        #expect(!ShareMigration.ownerShouldMigrate(payloadToken: "Ab3dEf6hIj9kLm2nOp5qRs", ownsLocalItem: true, hasName: true, firebaseAvailable: true))
        #expect(!ShareMigration.ownerShouldMigrate(payloadToken: nil, ownsLocalItem: false, hasName: true, firebaseAvailable: true))
        #expect(!ShareMigration.ownerShouldMigrate(payloadToken: nil, ownsLocalItem: true, hasName: false, firebaseAvailable: true))
        #expect(!ShareMigration.ownerShouldMigrate(payloadToken: nil, ownsLocalItem: true, hasName: true, firebaseAvailable: false))
    }

    /// Cada origen solo borra lo suyo, y solo si su lectura salió bien.
    @Test func staleCopiesRespectTheirSource() {
        let ck = UUID(), fs = UUID(), migrating = UUID(), mine = UUID(), accepting = UUID()
        let local: Set<UUID> = [ck, fs, migrating, mine, accepting]

        // Las dos lecturas bien y ninguna trae nada: se va todo menos lo que se
        // está aceptando; lo borrado por la persona va aparte.
        let all = ShareMigration.staleReceived(
            local: local, cloudKitPresent: [], firestorePresent: [],
            firestoreTracked: [fs], accepting: [accepting], tombstoned: [mine]
        )
        #expect(all.byOwner == [ck, fs, migrating])
        #expect(all.byMe == [mine])

        // Falló Firestore: lo de Firestore se queda; lo de CloudKit, no.
        let firestoreDown = ShareMigration.staleReceived(
            local: [ck, fs], cloudKitPresent: [], firestorePresent: nil,
            firestoreTracked: [fs], accepting: [], tombstoned: []
        )
        #expect(firestoreDown.byOwner == [ck])

        // Falló CloudKit (o solo se leyó Firestore): lo de CloudKit se queda.
        let cloudKitDown = ShareMigration.staleReceived(
            local: [ck, fs], cloudKitPresent: nil, firestorePresent: [],
            firestoreTracked: [fs], accepting: [], tombstoned: []
        )
        #expect(cloudKitDown.byOwner == [fs])

        // Migrando: ya en Firestore y todavía en CloudKit, o al revés: se queda.
        let mid = ShareMigration.staleReceived(
            local: [migrating], cloudKitPresent: [], firestorePresent: [migrating],
            firestoreTracked: [], accepting: [], tombstoned: []
        )
        #expect(mid.byOwner.isEmpty)
        let leaving = ShareMigration.staleReceived(
            local: [migrating], cloudKitPresent: [migrating], firestorePresent: [],
            firestoreTracked: [migrating], accepting: [], tombstoned: []
        )
        #expect(leaving.byOwner.isEmpty)
    }
}
