//
//  SharedRemindersService+Countdowns.swift
//  Calarm
//
//  Compartir una cuenta regresiva con amigos, con la misma maquinaria que las
//  alarmas. Desde la 1.1 las invitaciones nuevas son shares de Firestore
//  (`kind: "countdown"`, ver `SharedRemindersService+Firestore`); lo de CloudKit
//  que queda aquí sirve a las cuentas que ya se habían compartido: un registro
//  por cuenta en la zona `SharedRemindersZone` del dueño, con su `CKShare` de
//  enlace público, y una copia de solo lectura en cada invitado que se rehace
//  en cada escaneo de la base compartida.
//
//  Va en su propio tipo de registro, `CalarmSharedCountdown`, y no en
//  `CalarmSharedReminder`: las versiones anteriores de la app importan TODO
//  registro de ese tipo como alarma, y con este lo ignoran. Por lo mismo su
//  enlace usa `/c/` en vez de `/i/` (`InviteLink`).
//
//  Todo lo que se añada va dentro de `SharedCountdownPayload`, nunca como
//  columna (sería otro despliegue del esquema a Production).
//

import CloudKit
import os
import SwiftData
import SwiftUI
import UIKit

extension SharedRemindersService {
    static let countdownRecordType = "CalarmSharedCountdown"
    static let countdownShareType = "com.mathyusolutions.calarm.countdown"

    /// Lado mayor de la foto que viaja con la cuenta: un registro de CloudKit no
    /// puede pasar de 1 MB, y en Firestore las reglas aceptan hasta 600 KB.
    private static let sharedPhotoMaxPixelSize = 1080
    static let sharedPhotoMaxBytes = 600_000

    // MARK: - Dueño

    /// El share de CloudKit de una cuenta compartida antes de la 1.1, sin
    /// crearlo; nil si nunca se compartió así.
    func existingShare(forCountdown event: CountdownEvent) async -> CKShare? {
        let zoneID = CKRecordZone.ID(zoneName: Self.sharingZoneName, ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: event.id.uuidString, zoneID: zoneID)
        return try? await fetchExistingShare(for: recordID)
    }

    /// El dueño la editó: reescribe el share de Firestore y, mientras exista, el
    /// registro de CloudKit, para que los invitados lo vean (por push o en su
    /// próximo escaneo). No hace nada si nunca se compartió o si es una recibida.
    func pushUpdateIfShared(countdown event: CountdownEvent) async {
        guard !event.isReceivedShare else { return }
        await pushFirestoreUpdate(countdown: event)
        let zoneID = CKRecordZone.ID(zoneName: Self.sharingZoneName, ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: event.id.uuidString, zoneID: zoneID)
        let database = cloudKitContainer.privateCloudDatabase
        guard let record = try? await database.record(for: recordID) else { return }
        let token = FirestoreShareStore.owned(event.id)?.inviteToken ?? countdownPayload(from: record)?.firebaseToken
        writeCountdown(event, to: record, firebaseToken: token)
        _ = try? await database.modifyRecords(saving: [record], deleting: [])
        ShareDiagnostics.log("↻ push cuenta '\(event.title)'")
    }

    /// Después de borrar una cuenta: el dueño quita el share (los invitados la
    /// pierden en su próxima lectura); el invitado deja una marca para que no
    /// vuelva y se sale del share.
    func countdownDeleted(id: UUID, wasReceived: Bool) async {
        if wasReceived {
            DeletedSharesStore.add(id)
            await leaveShare(forReminderID: id)
        } else {
            await deleteSharedRecord(forReminderID: id)
        }
    }

    // MARK: - Invitado (CloudKit)

    /// Una invitación de CloudKit a una cuenta regresiva (y no a una alarma o a
    /// la delegación).
    static func isCountdownShare(_ metadata: CKShare.Metadata) -> Bool {
        if metadata.rootRecord?.recordType == countdownRecordType { return true }
        return metadata.share[CKShare.SystemFieldKey.shareType] as? String == countdownShareType
    }

    /// Acepta la invitación y deja la cuenta en la lista, marcada como recibida.
    func acceptCountdownShare(metadata: CKShare.Metadata) async throws {
        ShareDiagnostics.log("▶️ aceptando cuenta regresiva…")
        incomingShare = .acceptingCountdown
        let guardedID = Self.rootRecordID(of: metadata).flatMap { UUID(uuidString: $0.recordName) }
        if let guardedID { acceptingIDs.insert(guardedID) }
        do {
            let acceptedShare = try await cloudKitContainer.accept(metadata)
            guard let rootRecordID = Self.rootRecordID(of: metadata) else {
                throw SharedRemindersError.shareUnavailable
            }
            let record: CKRecord
            if let carried = metadata.rootRecord, carried.recordType == Self.countdownRecordType {
                record = carried
            } else {
                record = try await fetchSharedRecordWithRetries(rootRecordID)
            }
            let context = modelContainer.mainContext
            guard let payload = countdownPayload(from: record),
                  let event = applyReceivedCountdownPayload(payload, localID: countdownLocalID(record, payload), in: context)
            else {
                throw SharedRemindersError.shareUnavailable
            }
            if let owner = Self.person(metadata.ownerIdentity) {
                ownerNames[event.id] = owner
            }
            // Volver a aceptar una que se había quitado la trae de vuelta.
            DeletedSharesStore.remove(event.id)
            try context.save()
            incomingShare = .acceptedCountdown(
                id: event.id,
                title: event.title,
                ownerName: Self.knownDisplayName(metadata.ownerIdentity)
            )
            ShareDiagnostics.log("✅ cuenta regresiva '\(event.title)' agregada")
            announceMyself(in: acceptedShare)
            rememberOwner(of: acceptedShare, for: event.id)
            // Un enlace `/c/` viejo de una cuenta que el dueño ya pasó a Firestore.
            if let token = payload.firebaseToken {
                let migration = CloudKitMigration(id: event.id, token: token, record: record)
                Task { await migrateReceivedCloudKitShares([migration]) }
            }
            Task { await releaseAcceptGuard(guardedID) }
        } catch {
            ShareDiagnostics.log("❌ aceptar cuenta: \(error.localizedDescription)")
            reportAcceptFailure(error)
            Task { await releaseAcceptGuard(guardedID) }
            throw error
        }
    }

    /// Las cuentas que encontró el escaneo de CloudKit: actualiza las copias.
    /// Las que ya no están las quita `removeStaleCountdowns`.
    func applyReceivedCountdowns(_ records: [CKRecord], in context: ModelContext) {
        var applied = 0
        for record in records {
            guard let payload = countdownPayload(from: record) else { continue }
            if applyReceivedCountdownPayload(payload, localID: countdownLocalID(record, payload), in: context) != nil {
                applied += 1
            }
        }
        if applied > 0 {
            try? context.save()
            ShareDiagnostics.log("scan: \(applied) cuenta(s) compartida(s)")
        }
    }

    /// Quita las cuentas recibidas que su origen da por borradas (el dueño la
    /// borró, dejó de compartirla o sacó a esta persona) y las que la persona
    /// quitó de su lista. Un origen cuya lectura falló (`nil`) no quita nada.
    func removeStaleCountdowns(
        cloudKitPresent: Set<UUID>?,
        firestorePresent: Set<UUID>?,
        tracked: Set<UUID>,
        in context: ModelContext
    ) {
        let descriptor = FetchDescriptor<CountdownEvent>(predicate: #Predicate { $0.isReceivedShare })
        guard let received = try? context.fetch(descriptor), !received.isEmpty else { return }
        let local = Set(received.map(\.id))
        let stale = ShareMigration.staleReceived(
            local: local,
            cloudKitPresent: cloudKitPresent,
            firestorePresent: firestorePresent,
            firestoreTracked: tracked,
            accepting: acceptingIDs,
            tombstoned: local.filter(DeletedSharesStore.contains)
        )
        let gone = received.filter { stale.byOwner.contains($0.id) || stale.byMe.contains($0.id) }
        guard !gone.isEmpty else { return }
        for event in gone {
            context.delete(event)
        }
        try? context.save()
        ShareDiagnostics.log("scan: \(gone.count) cuenta(s) compartida(s) quitada(s)")
    }

    // MARK: - Copia local

    /// Inserta o actualiza la copia local de una cuenta recibida (de CloudKit o
    /// de Firestore). Como con las alarmas, varios dispositivos pueden haber
    /// insertado su copia: se queda la más antigua. Nil si el id es de una cuenta
    /// propia: nunca se pisa con una ajena.
    @discardableResult
    func applyReceivedCountdownPayload(_ payload: SharedCountdownPayload, localID: UUID, in context: ModelContext) -> CountdownEvent? {
        let descriptor = FetchDescriptor<CountdownEvent>(
            predicate: #Predicate { $0.id == localID },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        let matches = (try? context.fetch(descriptor)) ?? []
        let event: CountdownEvent
        if let oldest = matches.first {
            guard oldest.isReceivedShare else { return nil }
            event = oldest
            for duplicate in matches.dropFirst() where duplicate.isReceivedShare {
                context.delete(duplicate)
            }
        } else {
            event = CountdownEvent(id: localID)
            context.insert(event)
        }
        event.title = payload.title
        event.notes = payload.notes
        event.date = payload.date
        event.includesTime = payload.includesTime
        event.repeatsYearly = payload.repeatsYearly
        event.colorHex = payload.colorHex
        event.iconKindRaw = payload.iconKindRaw
        event.iconValue = payload.iconValue
        event.photoData = payload.photo
        event.updatedAt = payload.updatedAt
        event.isReceivedShare = true
        return event
    }

    // MARK: - Registro de CloudKit

    func countdownPayload(from record: CKRecord) -> SharedCountdownPayload? {
        guard let data = record["payload"] as? Data else { return nil }
        return try? JSONDecoder().decode(SharedCountdownPayload.self, from: data)
    }

    private func countdownLocalID(_ record: CKRecord, _ payload: SharedCountdownPayload) -> UUID {
        UUID(uuidString: record.recordID.recordName) ?? UUID(uuidString: payload.id) ?? UUID()
    }

    /// Todo lo que lleva una cuenta compartida, con la foto ya reducida.
    func makeCountdownPayload(_ event: CountdownEvent, firebaseToken: String? = nil) -> SharedCountdownPayload {
        SharedCountdownPayload(
            version: SharedCountdownPayload.currentVersion,
            id: event.id.uuidString,
            title: event.title,
            notes: event.notes,
            date: event.date,
            includesTime: event.includesTime,
            repeatsYearly: event.repeatsYearly,
            colorHex: event.colorHex,
            iconKindRaw: event.iconKindRaw,
            iconValue: event.iconValue,
            photo: sharedPhoto(for: event),
            updatedAt: event.updatedAt,
            invitePreview: InvitePreview(countdown: event),
            firebaseToken: firebaseToken
        )
    }

    func writeCountdown(_ event: CountdownEvent, to record: CKRecord, firebaseToken: String? = nil) {
        if let data = try? JSONEncoder().encode(makeCountdownPayload(event, firebaseToken: firebaseToken)) {
            record["payload"] = data as CKRecordValue
        }
    }

    /// La foto de fondo, reducida hasta que quepa holgada en el registro.
    func sharedPhoto(for event: CountdownEvent) -> Data? {
        guard event.iconKind == .photo, let data = event.photoData else { return nil }
        return Self.sharedJPEG(from: data)
    }

    /// Una foto reducida (≤ 1080 px) que cabe en lo que aceptan CloudKit y las
    /// reglas de Firestore (`shares/{id}/photo/current`, ≤ 600 KB).
    static func sharedJPEG(from data: Data) -> Data? {
        for side in [sharedPhotoMaxPixelSize, 800, 600] {
            if let small = CountdownPhoto.prepared(from: data, maxPixelSize: side),
               small.count <= sharedPhotoMaxBytes {
                return small
            }
        }
        return nil
    }
}

/// Todo lo que lleva una cuenta compartida, en un solo campo `payload` del
/// registro. Los campos nuevos van como opcionales, para que un payload de un
/// emisor anterior siga decodificando.
struct SharedCountdownPayload: Codable {
    static let currentVersion = 1

    var version: Int
    var id: String
    var title: String
    var notes: String?
    var date: Date
    var includesTime: Bool
    var repeatsYearly: Bool
    var colorHex: String
    var iconKindRaw: Int
    var iconValue: String
    /// JPEG de hasta 1080 px (`sharedPhoto`), solo si el icono es la foto.
    var photo: Data?
    var updatedAt: Date
    /// Zona horaria, idioma, color e ícono para la página de invitación, que
    /// lee la cuenta de CloudKit (ver `InvitePreview`). Ausente en payloads de
    /// versiones anteriores a la 1.0.18.
    var invitePreview: InvitePreview? = nil
    /// 1.1: el token de la invitación de Firestore del mismo share (ver
    /// `SharePayload.firebaseToken`).
    var firebaseToken: String? = nil
}
