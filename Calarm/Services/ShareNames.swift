//
//  ShareNames.swift
//  Calarm
//
//  El nombre con el que cada persona aparece ante quien comparte con ella.
//

import CloudKit
import Foundation

/// El nombre con el que cada persona aparece en «Personas» y en «Compartido por».
///
/// iCloud no le da a la app el nombre de quien entra por el enlace de una
/// invitación: desde iOS 26 un participante que se une con la URL del share es
/// anónimo, y ni la hoja de Apple de «Gestionar» lo muestra (comprobado con dos
/// cuentas el 2026-11-21, aun con el entitlement `icloud-extended-share-access`).
/// Por eso la app de cada persona publica su nombre en la base PÚBLICA del
/// contenedor, en un registro por cada sitio que ocupa en un
/// share (`p-<participantID>`, el mismo id que ve la otra persona) y otro con su
/// usuario de iCloud (`u-<userRecordName>`). La app del otro lado lo busca por
/// esos ids. Solo quien creó el registro puede cambiarlo (rol `_creator`).
///
/// Es un tipo de registro nuevo (`CalarmPersonName`, campo `name` STRING): hay
/// que desplegar el esquema a Production antes de publicar la versión, o las
/// escrituras fallan (sin romper nada más: los nombres simplemente no salen).
///
/// Desde la cuenta obligatoria (calarmi-firebase/DESIGN.md › «Identidad») el
/// nombre sale de la cuenta y ya no se pregunta: `myName` es su copia (la pone
/// `AccountService` al iniciar sesión y al cambiarlo en Ajustes › Cuenta), que
/// lee todo lo compartido. El que hubiera de una versión anterior es el tercer
/// candidato al elegir el nombre de la cuenta.
@MainActor
enum ShareNames {
    static let recordType = "CalarmPersonName"
    private static let nameField = "name"

    // MARK: - Mi nombre

    /// En iCloud key-value, para que valga en todos los dispositivos de la
    /// cuenta, y en local como respaldo (sin iCloud o antes de sincronizar).
    private static let cloudKey = "profile.displayName"
    private static let localKey = "calarm.profile.displayName"
    /// recordName → nombre publicado, para no reescribir en cada escaneo.
    private static let publishedKey = "calarm.profile.publishedNames"

    /// El nombre de la cuenta (o el que la persona escribió en una versión
    /// anterior), o nil si no hay ninguno.
    static var myName: String? {
        let raw = NSUbiquitousKeyValueStore.default.string(forKey: cloudKey)
            ?? UserDefaults.standard.string(forKey: localKey)
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Guarda el nombre (vacío lo quita) y lo vuelve a publicar donde ya estaba.
    static func setMyName(_ name: String, container: CKContainer) async {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        if trimmed.isEmpty {
            NSUbiquitousKeyValueStore.default.removeObject(forKey: cloudKey)
            UserDefaults.standard.removeObject(forKey: localKey)
        } else {
            NSUbiquitousKeyValueStore.default.set(trimmed, forKey: cloudKey)
            UserDefaults.standard.set(trimmed, forKey: localKey)
        }
        NSUbiquitousKeyValueStore.default.synchronize()
        await republishAll(container: container)
    }

    #if DEBUG
    /// Los datos de demostración traen nombre: el de la cuenta de mentira de las
    /// capturas de la tienda (`AccountService.demoUser`).
    static func setForDemo(_ name: String) {
        UserDefaults.standard.set(name, forKey: localKey)
    }
    #endif

    // MARK: - Publicar

    private static var published: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: publishedKey) as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: publishedKey) }
    }

    private static var myUserRecordName: String?

    /// Publica mi nombre para cada share de `shares` en el que estoy (como dueño
    /// o como invitado) y con mi usuario, salvo lo que ya estaba publicado igual.
    static func publishMine(in shares: [CKShare], container: CKContainer) async {
        guard let name = myName else { return }
        var keys = shares.compactMap { $0.currentUserParticipant?.participantID }.map { "p-\($0)" }
        if myUserRecordName == nil {
            myUserRecordName = try? await container.userRecordID().recordName
        }
        if let user = myUserRecordName { keys.append("u-\(user)") }
        let current = published
        let pending = Array(Set(keys.filter { current[$0] != name }))
        guard !pending.isEmpty else { return }
        await write(name, to: pending, container: container)
    }

    /// Tras cambiar el nombre: lo reescribe en todo lo ya publicado (o lo borra).
    private static func republishAll(container: CKContainer) async {
        let keys = Array(published.keys)
        guard !keys.isEmpty else { return }
        guard let name = myName else {
            let ids = keys.map { CKRecord.ID(recordName: $0) }
            _ = try? await container.publicCloudDatabase.modifyRecords(saving: [], deleting: ids)
            published = [:]
            return
        }
        await write(name, to: keys, container: container)
    }

    private static func write(_ name: String, to keys: [String], container: CKContainer) async {
        let records = keys.map { key -> CKRecord in
            let record = CKRecord(recordType: recordType, recordID: CKRecord.ID(recordName: key))
            record[nameField] = name as CKRecordValue
            return record
        }
        do {
            // `.allKeys`: pisa el registro propio que ya existía sin pedir su etag.
            let result = try await container.publicCloudDatabase.modifyRecords(
                saving: records, deleting: [], savePolicy: .allKeys
            )
            var map = published
            var failed = 0
            for (id, outcome) in result.saveResults {
                if case .success = outcome { map[id.recordName] = name } else { failed += 1 }
            }
            published = map
            ShareDiagnostics.log("🪪 nombre publicado en \(records.count - failed) sitio(s)\(failed > 0 ? ", \(failed) fallaron" : "")")
        } catch {
            ShareDiagnostics.log("❌ publicar nombre: \(SharedRemindersService.diagnosticDescription(for: error))")
        }
    }

    // MARK: - Leer

    /// Los nombres que publicaron estas personas, por `participantID` (y, si se
    /// sabe, su usuario de iCloud). Clave del resultado: el `participantID`.
    static func names(
        for people: [(participantID: String, userRecordName: String?)],
        container: CKContainer
    ) async -> [String: String] {
        guard !people.isEmpty else { return [:] }
        var ids: [CKRecord.ID] = []
        for person in people {
            ids.append(CKRecord.ID(recordName: "p-\(person.participantID)"))
            if let user = person.userRecordName { ids.append(CKRecord.ID(recordName: "u-\(user)")) }
        }
        guard let results = try? await container.publicCloudDatabase.records(for: ids) else { return [:] }
        func name(_ key: String) -> String? {
            guard case .success(let record)? = results[CKRecord.ID(recordName: key)],
                  let value = record[nameField] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return value
        }
        var found: [String: String] = [:]
        for person in people {
            // El del share primero: es el que la persona puso para este sitio.
            if let value = name("p-\(person.participantID)") ?? person.userRecordName.flatMap({ name("u-\($0)") }) {
                found[person.participantID] = value
            }
        }
        return found
    }
}
