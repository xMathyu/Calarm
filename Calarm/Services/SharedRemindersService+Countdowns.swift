//
//  SharedRemindersService+Countdowns.swift
//  Calarm
//
//  Compartir una cuenta regresiva con amigos, con la misma maquinaria que las
//  alarmas: un registro por cuenta en la zona `SharedRemindersZone` del dueño,
//  con su `CKShare` de enlace público, y una copia de solo lectura en cada
//  invitado que se rehace en cada escaneo de la base compartida.
//
//  Va en su propio tipo de registro, `CalarmSharedCountdown`, y no en
//  `CalarmSharedReminder`: las versiones anteriores de la app importan TODO
//  registro de ese tipo como alarma, y con este lo ignoran. Por lo mismo su
//  enlace usa `/c/` en vez de `/i/` (`InviteLink`).
//
//  OJO: tipo de registro nuevo (con un solo campo, `payload` BYTES), así que
//  hay que desplegar el esquema a Production antes de publicar. Todo lo que se
//  añada después va dentro de `SharedCountdownPayload`, nunca como columna.
//

import CloudKit
import os
import SwiftData
import SwiftUI
import UIKit

extension SharedRemindersService {
    static let countdownRecordType = "CalarmSharedCountdown"
    static let countdownShareType = "com.mathyusolutions.calarm.countdown"

    /// Lado mayor de la foto que viaja dentro del registro: un registro de
    /// CloudKit no puede pasar de 1 MB, y la tarjeta no necesita más.
    private static let sharedPhotoMaxPixelSize = 1080
    private static let sharedPhotoMaxBytes = 600_000

    // MARK: - Dueño

    /// Crea (o reutiliza) el share de una cuenta regresiva y lo deja listo para
    /// mandar por enlace.
    func prepareShare(forCountdown event: CountdownEvent) async throws -> CKShare {
        do {
            try await ensureCloudKitAccountAvailable()
            ShareDiagnostics.log("↗️ preparando share de cuenta '\(event.title)'")
            let zone = try await ensureSharingZone()
            let recordID = CKRecord.ID(recordName: event.id.uuidString, zoneID: zone.zoneID)
            let database = cloudKitContainer.privateCloudDatabase

            let record: CKRecord
            if let existing = try await fetchRootRecord(for: recordID) {
                if let share = try await fetchShare(attachedTo: existing, database: database) {
                    // Lo último que cambió viaja con la invitación nueva.
                    writeCountdown(event, to: existing)
                    _ = try? await database.modifyRecords(saving: [existing], deleting: [])
                    return try await prepareExistingShareForInvite(share, database: database)
                }
                record = existing
            } else {
                record = CKRecord(recordType: Self.countdownRecordType, recordID: recordID)
            }
            writeCountdown(event, to: record)

            let share = CKShare(rootRecord: record, shareID: CKRecord.ID(
                recordName: "share-\(event.id.uuidString)",
                zoneID: zone.zoneID
            ))
            share[CKShare.SystemFieldKey.title] = event.title as CKRecordValue
            share[CKShare.SystemFieldKey.shareType] = Self.countdownShareType as CKRecordValue
            if let thumbnail = countdownThumbnail(for: event) {
                share[CKShare.SystemFieldKey.thumbnailImageData] = thumbnail as CKRecordValue
            }
            // Como en las alarmas: quien recibe el enlace entra como «público».
            share.publicPermission = .readOnly

            let results = try await database.modifyRecords(saving: [record, share], deleting: [])
            let saved = try savedShare(from: results.saveResults, id: share.recordID)
            let ready = try await shareWithInviteURL(saved, database: database)
            ShareDiagnostics.log("✅ share de cuenta creado (url=\(ready.url != nil))")
            return ready
        } catch let error as SharedRemindersError {
            ShareDiagnostics.log("❌ preparar share de cuenta: \(error.localizedDescription)")
            throw error
        } catch {
            ShareDiagnostics.log("❌ preparar share de cuenta: \(Self.diagnosticDescription(for: error))")
            throw SharedRemindersError.shareCreationFailed(error)
        }
    }

    /// El share de una cuenta, sin crearlo; nil si nunca se compartió.
    func existingShare(forCountdown event: CountdownEvent) async -> CKShare? {
        let zoneID = CKRecordZone.ID(zoneName: Self.sharingZoneName, ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: event.id.uuidString, zoneID: zoneID)
        return try? await fetchExistingShare(for: recordID)
    }

    /// El dueño la editó: reescribe el registro compartido para que los
    /// invitados lo vean (por push o en su próximo escaneo). No hace nada si
    /// nunca se compartió o si es una recibida.
    func pushUpdateIfShared(countdown event: CountdownEvent) async {
        guard !event.isReceivedShare else { return }
        let zoneID = CKRecordZone.ID(zoneName: Self.sharingZoneName, ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: event.id.uuidString, zoneID: zoneID)
        let database = cloudKitContainer.privateCloudDatabase
        guard let record = try? await database.record(for: recordID) else { return }
        writeCountdown(event, to: record)
        _ = try? await database.modifyRecords(saving: [record], deleting: [])
        ShareDiagnostics.log("↻ push cuenta '\(event.title)'")
    }

    /// Después de borrar una cuenta: el dueño quita el registro compartido (los
    /// invitados la pierden en su próximo escaneo); el invitado deja una marca
    /// para que no vuelva y se sale del share.
    func countdownDeleted(id: UUID, wasReceived: Bool) async {
        if wasReceived {
            DeletedSharesStore.add(id)
            await leaveShare(forReminderID: id)
        } else {
            await deleteSharedRecord(forReminderID: id)
        }
    }

    // MARK: - Invitado

    /// Una invitación a una cuenta regresiva (y no a una alarma o a la delegación).
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
            _ = try await cloudKitContainer.accept(metadata)
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
            guard let event = applyCountdownRecord(record, in: context) else {
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
            Task { await releaseAcceptGuard(guardedID) }
        } catch {
            ShareDiagnostics.log("❌ aceptar cuenta: \(error.localizedDescription)")
            reportAcceptFailure(error)
            Task { await releaseAcceptGuard(guardedID) }
            throw error
        }
    }

    /// Lo que el escaneo de la base compartida encontró de cuentas regresivas:
    /// actualiza las copias y quita las que el dueño borró o dejó de compartir.
    /// Solo se llama tras un escaneo sin errores.
    func applyReceivedCountdowns(_ records: [CKRecord], presentIDs: Set<UUID>, in context: ModelContext) {
        for record in records {
            _ = applyCountdownRecord(record, in: context)
        }
        let descriptor = FetchDescriptor<CountdownEvent>(predicate: #Predicate { $0.isReceivedShare })
        let received = (try? context.fetch(descriptor)) ?? []
        let gone = received.filter {
            DeletedSharesStore.contains($0.id)
                || (!presentIDs.contains($0.id) && !acceptingIDs.contains($0.id))
        }
        for event in gone {
            context.delete(event)
        }
        if !records.isEmpty || !gone.isEmpty {
            try? context.save()
            ShareDiagnostics.log("scan: \(records.count) cuenta(s) compartida(s), \(gone.count) quitada(s)")
        }
    }

    // MARK: - Registro

    /// Inserta o actualiza la copia local de una cuenta recibida. Como con las
    /// alarmas, varios dispositivos pueden haber insertado su copia: se queda la
    /// más antigua.
    @discardableResult
    private func applyCountdownRecord(_ record: CKRecord, in context: ModelContext) -> CountdownEvent? {
        guard let data = record["payload"] as? Data,
              let payload = try? JSONDecoder().decode(SharedCountdownPayload.self, from: data)
        else { return nil }
        let localID = UUID(uuidString: record.recordID.recordName) ?? UUID(uuidString: payload.id) ?? UUID()
        let descriptor = FetchDescriptor<CountdownEvent>(
            predicate: #Predicate { $0.id == localID },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        let matches = (try? context.fetch(descriptor)) ?? []
        let event: CountdownEvent
        if let oldest = matches.first {
            event = oldest
            for duplicate in matches.dropFirst() {
                context.delete(duplicate)
            }
        } else {
            event = CountdownEvent(id: localID)
            context.insert(event)
        }
        // Nunca pisar una cuenta propia con una ajena del mismo id.
        if matches.first != nil, !event.isReceivedShare { return event }
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

    private func writeCountdown(_ event: CountdownEvent, to record: CKRecord) {
        let payload = SharedCountdownPayload(
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
            updatedAt: event.updatedAt
        )
        if let data = try? JSONEncoder().encode(payload) {
            record["payload"] = data as CKRecordValue
        }
    }

    /// La foto de fondo, reducida hasta que quepa holgada en el registro.
    private func sharedPhoto(for event: CountdownEvent) -> Data? {
        guard event.iconKind == .photo, let data = event.photoData else { return nil }
        for side in [Self.sharedPhotoMaxPixelSize, 800, 600] {
            if let small = CountdownPhoto.prepared(from: data, maxPixelSize: side),
               small.count <= Self.sharedPhotoMaxBytes {
                return small
            }
        }
        return nil
    }

    /// La vista previa del share (la que iCloud enseña al aceptarla): la foto, o
    /// el emoji/símbolo sobre el color de la cuenta.
    private func countdownThumbnail(for event: CountdownEvent) -> Data? {
        if event.iconKind == .photo, let data = event.photoData, let image = UIImage(data: data) {
            return resized(image, to: 256).pngData()
        }
        let tint = event.color
        if event.iconKind == .emoji, isEmojiIcon(event.iconValue) {
            return renderIconThumbnail(tint: tint) {
                Text(event.iconValue).font(.system(size: 150))
            }
        }
        return renderIconThumbnail(tint: tint) {
            Image(systemName: event.iconKind == .symbol ? event.iconValue : "hourglass")
                .font(.system(size: 128, weight: .semibold))
                .foregroundStyle(.white)
        }
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
}
