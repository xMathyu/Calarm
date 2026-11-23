//
//  SharedRemindersService+Firestore.swift
//  Calarm
//
//  Alarmas y cuentas regresivas compartidas en Firestore (1.1+), para que un
//  iPhone comparta con un Android. Contrato: calarmi-firebase/DESIGN.md; las
//  escrituras tienen que pasar sus reglas (firestore.rules) tal cual:
//
//  - El dueño crea `shares/{id}` siendo el único miembro, y cada cambio sube
//    `revision`, pone `updatedBy` y deja `members` con las mismas claves que
//    `memberUids` (puede quitar a alguien, nunca añadir).
//  - Se entra SOLO con una invitación: una escritura que se añade a `members` y
//    `memberUids` y pone `joinToken` (el token de `invites/{token}`).
//  - Salir = quitarse de `members` y `memberUids`, nada más.
//
//  La copia local de lo recibido es la misma de siempre (`Reminder` o
//  `CountdownEvent` con `isReceivedShare`), así que avisos personales, el aviso
//  de cambio de hora y la lista no cambian. Lo de CloudKit sigue en los otros
//  archivos para las invitaciones de antes (ver «Migración» al final).
//

import CloudKit
import FirebaseFirestore
import Foundation
import SwiftData
import UIKit

extension SharedRemindersService {
    enum ShareKind: String {
        case alarm
        case countdown
    }

    private var db: Firestore { FirebaseSession.shared.db }

    private func shareRef(_ docID: String) -> DocumentReference {
        db.collection("shares").document(docID)
    }

    private func inviteRef(_ token: String) -> DocumentReference {
        db.collection("invites").document(token)
    }

    private func photoRef(_ docID: String) -> DocumentReference {
        shareRef(docID).collection("photo").document("current")
    }

    // MARK: - Identidad

    /// La sesión y el nombre que exigen las reglas para compartir o unirse. Sin
    /// nombre abre la hoja «¿Cómo te llamas?».
    func sharingIdentity() async throws -> (uid: String, name: String) {
        guard let name = FirestoreMapping.validName(ShareNames.myName) else {
            asksForName = true
            throw SharedRemindersError.nameRequired
        }
        let uid = try await FirebaseSession.shared.signIn()
        return (uid, name)
    }

    // MARK: - Dueño: contenido

    /// Lo que se sube de una alarma o cuenta: el contenido, la vista previa de la
    /// invitación y la foto.
    struct FirestoreShareContent {
        var kind: ShareKind
        var id: UUID
        var content: [String: Any]
        var preview: [String: Any]
        /// JPEG para `shares/{id}/photo/current` (≤ 600 KB), o nil.
        var photo: Data?
        /// Miniatura para la tarjeta del enlace (`invites/{token}.photo`, ≤ 60 KB).
        var invitePhoto: Data?
        var updatedAt: Date
    }

    func firestoreContent(for reminder: Reminder) -> FirestoreShareContent {
        let payload = makePayload(from: reminder)
        let style = CategoryStore.shared?.style(for: reminder) ?? CategoryStyle(builtin: reminder.category)
        let yearly = if case .yearly = reminder.recurrence { true } else { false }
        let photo = reminder.iconKind == .photo ? reminder.photoData.flatMap(Self.sharedJPEG(from:)) : nil
        return FirestoreShareContent(
            kind: .alarm,
            id: reminder.id,
            content: FirestoreMapping.alarmMap(from: payload),
            preview: FirestoreMapping.previewMap(
                title: reminder.title,
                date: reminder.date,
                hasTime: true,
                repeatsYearly: yearly,
                preview: InvitePreview(reminder: reminder, style: style)
            ),
            photo: photo,
            invitePhoto: photo.flatMap(Self.invitePhoto(from:)),
            updatedAt: reminder.updatedAt
        )
    }

    func firestoreContent(for event: CountdownEvent) -> FirestoreShareContent {
        let payload = makeCountdownPayload(event)
        return FirestoreShareContent(
            kind: .countdown,
            id: event.id,
            content: FirestoreMapping.countdownMap(from: payload),
            preview: FirestoreMapping.previewMap(
                title: event.title,
                date: event.target(),
                hasTime: event.includesTime,
                repeatsYearly: event.repeatsYearly,
                preview: InvitePreview(countdown: event)
            ),
            photo: payload.photo,
            invitePhoto: payload.photo.flatMap(Self.invitePhoto(from:)),
            updatedAt: event.updatedAt
        )
    }

    /// La miniatura de la tarjeta del enlace: lo más grande que quepa en 60 KB.
    static func invitePhoto(from jpeg: Data) -> Data? {
        for side in [256, 160] {
            if let small = CountdownPhoto.prepared(from: jpeg, maxPixelSize: side), small.count <= 60_000 {
                return small
            }
        }
        return InvitePhoto.thumbnail(from: jpeg)
    }

    // MARK: - Dueño: invitar y actualizar

    /// Crea (o pone al día) el share de Firestore de una alarma y devuelve su
    /// enlace de invitación, `…/s/<token>/`. Una sola invitación por share: la
    /// misma para todos los invitados.
    func prepareFirestoreInvite(for reminder: Reminder) async throws -> URL {
        try await prepareFirestoreInvite(firestoreContent(for: reminder), title: reminder.title)
    }

    func prepareFirestoreInvite(forCountdown event: CountdownEvent) async throws -> URL {
        try await prepareFirestoreInvite(firestoreContent(for: event), title: event.title)
    }

    private func prepareFirestoreInvite(_ content: FirestoreShareContent, title: String) async throws -> URL {
        ShareDiagnostics.log("↗️ preparando invitación (Firestore) '\(title)'")
        do {
            guard let token = try await upsertFirestoreShare(content, create: true) else {
                throw SharedRemindersError.shareUnavailable
            }
            // Si además tenía un share de CloudKit, el token va en su registro: los
            // invitados de antes con la app nueva se pasan solos a Firestore.
            await writeTokenToCloudKitRecord(id: content.id, kind: content.kind)
            ShareDiagnostics.log("✅ invitación lista '\(title)'")
            return InviteLink.make(token: token)
        } catch let error as SharedRemindersError {
            ShareDiagnostics.log("❌ invitación: \(error.localizedDescription)")
            throw error
        } catch {
            ShareDiagnostics.log("❌ invitación: \(error.localizedDescription)")
            throw SharedRemindersError.shareCreationFailed(error)
        }
    }

    /// Una edición del dueño: reescribe el share si esta sesión lo tiene.
    func pushFirestoreUpdate(_ reminder: Reminder) async {
        guard FirebaseSession.shared.uid != nil, FirestoreShareStore.owned(reminder.id) != nil else { return }
        do {
            try await upsertFirestoreShare(firestoreContent(for: reminder), create: false)
            ShareDiagnostics.log("↻ Firestore: '\(reminder.title)' actualizada")
        } catch {
            ShareDiagnostics.log("❌ Firestore: actualizar '\(reminder.title)': \(error.localizedDescription)")
        }
    }

    func pushFirestoreUpdate(countdown event: CountdownEvent) async {
        guard FirebaseSession.shared.uid != nil, FirestoreShareStore.owned(event.id) != nil else { return }
        do {
            try await upsertFirestoreShare(firestoreContent(for: event), create: false)
            ShareDiagnostics.log("↻ Firestore: cuenta '\(event.title)' actualizada")
        } catch {
            ShareDiagnostics.log("❌ Firestore: actualizar cuenta '\(event.title)': \(error.localizedDescription)")
        }
    }

    /// Crea o actualiza `shares/{id}` con `content` y deja una invitación
    /// vigente; devuelve su token. Con `create: false` solo pone al día un share
    /// que ya existe (una edición) y devuelve nil si ya no está.
    @discardableResult
    func upsertFirestoreShare(_ content: FirestoreShareContent, create: Bool) async throws -> String? {
        let (uid, name) = try await sharingIdentity()
        var entry = FirestoreShareStore.owned(content.id)
        let docID = entry?.docID ?? content.id.uuidString
        let ref = shareRef(docID)

        // ¿Existe y es de esta sesión? Las reglas niegan leer un share que no
        // existe igual que uno ajeno: el dueño siempre es miembro, así que si no
        // se puede leer, o no existe o no es suyo (y entonces crear lo rechaza).
        var existing: [String: Any]?
        do {
            let snapshot = try await ref.getDocument(source: .server)
            existing = snapshot.exists ? FirestoreValues.document(snapshot.data()) : nil
        } catch where FirestoreValues.isPermissionDenied(error) {
            existing = nil
        }
        if let existing, existing["ownerUid"] as? String != uid {
            throw SharedRemindersError.notShareOwner
        }
        guard existing != nil || create else {
            // Ya no existe (se dejó de compartir): se olvida.
            FirestoreShareStore.setOwned(nil, for: content.id)
            return nil
        }

        let photoHash = content.photo.map(FirestoreMapping.sha256)
        let fingerprint = FirestoreMapping.fingerprint([content.content, content.preview, photoHash ?? ""] as [Any])
        let now = FieldValue.serverTimestamp()
        let batch = db.batch()
        let token: String
        var photoRevision: Int

        if let existing {
            let changed = fingerprint != entry?.contentHash
            photoRevision = FirestoreMapping.int(existing["photoRevision"]) ?? 0
            var update: [AnyHashable: Any] = [
                "ownerName": name,
                FieldPath(["members", uid, "name"]): name,
                "updatedBy": uid,
                "updatedAt": now,
            ]
            if changed {
                // `revision` + 1: las funciones avisan a los miembros solo cuando cambia.
                update[content.kind.rawValue] = content.content
                update["preview"] = content.preview
                update["revision"] = FieldValue.increment(Int64(1))
                let hadPhoto = existing["hasPhoto"] as? Bool ?? false
                if let photo = content.photo {
                    if photoHash != entry?.photoHash || !hadPhoto {
                        photoRevision += 1
                        batch.setData(["jpeg": photo, "revision": photoRevision], forDocument: photoRef(docID))
                    }
                } else if hadPhoto {
                    photoRevision += 1
                    batch.deleteDocument(photoRef(docID))
                }
                update["hasPhoto"] = content.photo != nil
                update["photoRevision"] = photoRevision
            }
            // La invitación vigente; si la revocaron o no está, otra nueva.
            if let current = existing["inviteToken"] as? String,
               await inviteIsUsable(current, uid: uid, targetID: docID) {
                token = current
                if changed {
                    batch.updateData([
                        "preview": content.preview,
                        "ownerName": name,
                        "photo": content.invitePhoto.map { $0 as Any } ?? FieldValue.delete(),
                    ], forDocument: inviteRef(token))
                }
            } else {
                token = InviteToken.make()
                update["inviteToken"] = token
                batch.setData(inviteData(content, token: token, docID: docID, uid: uid, name: name), forDocument: inviteRef(token))
            }
            batch.updateData(update, forDocument: ref)
        } else {
            token = InviteToken.make()
            photoRevision = content.photo == nil ? 0 : 1
            let share: [String: Any] = [
                "kind": content.kind.rawValue,
                "ownerUid": uid,
                "ownerName": name,
                "members": [uid: ["name": name, "role": "owner", "joinedAt": now]],
                "memberUids": [uid],
                "revision": 1,
                "updatedAt": now,
                "updatedBy": uid,
                "inviteToken": token,
                "preview": content.preview,
                content.kind.rawValue: content.content,
                "hasPhoto": content.photo != nil,
                "photoRevision": photoRevision,
            ]
            batch.setData(share, forDocument: ref)
            if let photo = content.photo {
                batch.setData(["jpeg": photo, "revision": photoRevision], forDocument: photoRef(docID))
            }
            batch.setData(inviteData(content, token: token, docID: docID, uid: uid, name: name), forDocument: inviteRef(token))
        }

        do {
            try await batch.commit()
        } catch where FirestoreValues.isPermissionDenied(error) && existing == nil {
            // El share existe y es de otra sesión (otro dispositivo de la cuenta).
            throw SharedRemindersError.notShareOwner
        }
        entry = FirestoreShareStore.Owned(
            docID: docID,
            kind: content.kind.rawValue,
            inviteToken: token,
            lastPushed: content.updatedAt,
            contentHash: fingerprint,
            photoHash: photoHash,
            photoRevision: photoRevision
        )
        FirestoreShareStore.setOwned(entry, for: content.id)
        return token
    }

    private func inviteData(_ content: FirestoreShareContent, token: String, docID: String, uid: String, name: String) -> [String: Any] {
        var data: [String: Any] = [
            "kind": content.kind.rawValue,
            "targetId": docID,
            "ownerUid": uid,
            "ownerName": name,
            "preview": content.preview,
            "revoked": false,
            "createdAt": FieldValue.serverTimestamp(),
        ]
        if let photo = content.invitePhoto { data["photo"] = photo }
        return data
    }

    /// Si la invitación sigue sirviendo para este share.
    private func inviteIsUsable(_ token: String, uid: String, targetID: String) async -> Bool {
        guard InviteToken.isValid(token),
              let snapshot = try? await inviteRef(token).getDocument(source: .server),
              snapshot.exists,
              let data = snapshot.data()
        else { return false }
        return data["revoked"] as? Bool == false
            && data["ownerUid"] as? String == uid
            && data["targetId"] as? String == targetID
    }

    /// El token de Firestore en el registro de CloudKit de una alarma o cuenta
    /// compartida antes de la 1.1, si lo tiene.
    private func writeTokenToCloudKitRecord(id: UUID, kind: ShareKind) async {
        let context = modelContainer.mainContext
        switch kind {
        case .alarm:
            let descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.id == id && !$0.isReceivedShare })
            if let reminder = try? context.fetch(descriptor).first {
                await writeCloudKitRecordIfShared(reminder)
            }
        case .countdown:
            let descriptor = FetchDescriptor<CountdownEvent>(predicate: #Predicate { $0.id == id && !$0.isReceivedShare })
            if let event = try? context.fetch(descriptor).first {
                let zoneID = CKRecordZone.ID(zoneName: Self.sharingZoneName, ownerName: CKCurrentUserDefaultName)
                let database = cloudKitContainer.privateCloudDatabase
                guard let record = try? await database.record(for: CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)),
                      record.share != nil
                else { return }
                writeCountdown(event, to: record, firebaseToken: FirestoreShareStore.owned(id)?.inviteToken)
                _ = try? await database.modifyRecords(saving: [record], deleting: [])
            }
        }
    }

    // MARK: - Dueño: personas y dejar de compartir

    /// Lo que el dueño ve de lo compartido de una alarma o cuenta: si está en
    /// Firestore, el `CKShare` de antes (si lo hay) y todas las personas.
    struct ShareOverview {
        var isOnFirestore = false
        var legacyShare: CKShare?
        var people: [ShareParticipantInfo] = []

        var isShared: Bool { isOnFirestore || legacyShare != nil }
    }

    func shareOverview(forReminder reminder: Reminder) async -> ShareOverview {
        await shareOverview(id: reminder.id, legacy: await existingShare(for: reminder))
    }

    func shareOverview(forCountdown event: CountdownEvent) async -> ShareOverview {
        await shareOverview(id: event.id, legacy: await existingShare(forCountdown: event))
    }

    private func shareOverview(id: UUID, legacy: CKShare?) async -> ShareOverview {
        var overview = ShareOverview(legacyShare: legacy)
        if let entry = FirestoreShareStore.owned(id), let uid = FirebaseSession.shared.uid {
            do {
                // Sin red, la caché: la lista se ve igual.
                let snapshot = try await shareRef(entry.docID).getDocument()
                if snapshot.exists {
                    overview.isOnFirestore = true
                    let data = FirestoreValues.document(snapshot.data())
                    overview.people = FirestoreMapping.people(in: data["members"], excluding: uid).map(Self.participant)
                } else {
                    FirestoreShareStore.setOwned(nil, for: id)
                }
            } catch where FirestoreValues.isPermissionDenied(error) {
                // Ya no existe.
                FirestoreShareStore.setOwned(nil, for: id)
            } catch {
                overview.isOnFirestore = true
            }
        }
        if let legacy {
            overview.people += await namedParticipantInfos(of: legacy).filter { !$0.isOwner }
        }
        return overview
    }

    static func participant(_ person: FirestoreMapping.Person) -> ShareParticipantInfo {
        ShareParticipantInfo(
            name: person.name.isEmpty ? appLocalized("Alguien") : person.name,
            email: nil,
            phone: nil,
            status: .accepted,
            isOwner: false,
            hasName: !person.name.isEmpty,
            firebaseUID: person.uid
        )
    }

    /// Quita a una persona de lo compartido (de Firestore o del `CKShare` de antes).
    func removeParticipant(_ person: ShareParticipantInfo, from overview: ShareOverview, id: UUID) async throws {
        if let memberUID = person.firebaseUID {
            guard let entry = FirestoreShareStore.owned(id) else { return }
            let uid = try await FirebaseSession.shared.signIn()
            try await shareRef(entry.docID).updateData([
                FieldPath(["members", memberUID]): FieldValue.delete(),
                "memberUids": FieldValue.arrayRemove([memberUID]),
                "updatedBy": uid,
                "updatedAt": FieldValue.serverTimestamp(),
            ])
            ShareDiagnostics.log("🚫 Firestore: persona quitada del share")
        } else if let share = overview.legacyShare,
                  let target = share.participants.first(where: {
                      $0.role != .owner && $0.participantID == person.participantID
                  }) {
            share.removeParticipant(target)
            _ = try await cloudKitContainer.privateCloudDatabase.modifyRecords(saving: [share], deleting: [])
            ShareDiagnostics.log("🚫 CloudKit: persona quitada del share")
        }
    }

    /// Deja de compartir: borra el share de Firestore (los invitados pierden su
    /// copia y se les avisa) y el de CloudKit, si lo había. La alarma o cuenta
    /// del dueño se queda.
    func stopSharing(id: UUID, overview: ShareOverview) async throws {
        await deleteFirestoreShare(id: id)
        if let legacy = overview.legacyShare {
            try await stopSharing(legacy)
        }
    }

    /// Borra `shares/{id}` y su foto, y revoca la invitación. No hace nada si
    /// esta sesión no es la dueña.
    func deleteFirestoreShare(id: UUID) async {
        guard let entry = FirestoreShareStore.owned(id), FirebaseSession.shared.uid != nil else { return }
        let batch = db.batch()
        batch.deleteDocument(photoRef(entry.docID))
        batch.deleteDocument(shareRef(entry.docID))
        do {
            try await batch.commit()
            FirestoreShareStore.setOwned(nil, for: id)
            ShareDiagnostics.log("🗑️ Firestore: share borrado \(id.uuidString)")
        } catch where FirestoreValues.isPermissionDenied(error) {
            // Ya no existía.
            FirestoreShareStore.setOwned(nil, for: id)
        } catch {
            ShareDiagnostics.log("❌ Firestore: borrar share: \(error.localizedDescription)")
            return
        }
        // Aparte: si la invitación ya no estaba, el lote entero fallaría.
        if let token = entry.inviteToken {
            try? await inviteRef(token).updateData(["revoked": true])
        }
    }

    // MARK: - Invitado: aceptar

    /// Una invitación de Firestore, leída por su token.
    struct FirestoreInvite {
        enum Kind: String {
            case alarm, countdown, delegation
        }

        var token: String
        var kind: Kind
        /// El id del share, o el uid del principal en `delegation`.
        var targetID: String
        var ownerUID: String
        var ownerName: String?
    }

    /// Lee `invites/{token}` (cualquiera puede leerla con el token; nadie puede
    /// listarlas).
    func fetchInvite(_ token: String) async throws -> FirestoreInvite {
        guard FirebaseSession.shared.isConfigured else { throw SharedRemindersError.firebaseUnavailable }
        guard InviteToken.isValid(token) else { throw SharedRemindersError.inviteInvalid }
        let snapshot: DocumentSnapshot
        do {
            snapshot = try await inviteRef(token).getDocument(source: .server)
        } catch {
            throw SharedRemindersError.acceptFailed(error)
        }
        let data = FirestoreValues.document(snapshot.data())
        guard snapshot.exists,
              data["revoked"] as? Bool == false,
              let kind = (data["kind"] as? String).flatMap(FirestoreInvite.Kind.init(rawValue:)),
              let target = data["targetId"] as? String,
              let owner = data["ownerUid"] as? String
        else { throw SharedRemindersError.inviteInvalid }
        return FirestoreInvite(
            token: token,
            kind: kind,
            targetID: target,
            ownerUID: owner,
            ownerName: FirestoreMapping.validName(data["ownerName"] as? String)
        )
    }

    /// Se une al share de una invitación y deja la alarma (o la cuenta) en la
    /// lista. `silent`: sin el aviso de arriba (una migración desde CloudKit).
    func acceptFirestoreShare(_ invite: FirestoreInvite, silent: Bool = false) async throws {
        let isCountdown = invite.kind == .countdown
        guard invite.kind != .delegation, let localID = UUID(uuidString: invite.targetID) else {
            throw SharedRemindersError.inviteInvalid
        }
        if !silent { incomingShare = isCountdown ? .acceptingCountdown : .accepting }
        let identity: (uid: String, name: String)
        do {
            identity = try await sharingIdentity()
        } catch SharedRemindersError.nameRequired {
            // Se une en cuanto escriba su nombre (la hoja ya está abierta).
            if !invitesAwaitingName.contains(invite.token) { invitesAwaitingName.append(invite.token) }
            if !silent { incomingShare = nil }
            ShareDiagnostics.log("⏸️ invitación en espera del nombre")
            return
        } catch {
            if !silent { reportAcceptFailure(error) }
            throw error
        }
        guard invite.ownerUID != identity.uid else {
            // Su propia invitación: ya la tiene.
            if !silent { incomingShare = nil }
            return
        }
        acceptingIDs.insert(localID)
        defer {
            Task {
                await releaseAcceptGuard(localID)
                // Lo que pasó mientras duraba la guarda (el dueño la borró o
                // sacó a esta persona justo después) se resuelve ahora.
                await importAllSharedReminders(cloudKit: false)
            }
        }
        ShareDiagnostics.log("▶️ Firestore: uniéndose a \(invite.kind.rawValue)")
        do {
            let ref = shareRef(invite.targetID)
            // Ya es miembro (otra vez el mismo enlace): no hay que unirse.
            var snapshot = try? await ref.getDocument(source: .server)
            if snapshot?.exists != true {
                do {
                    try await ref.updateData([
                        FieldPath(["members", identity.uid]): [
                            "name": identity.name,
                            "role": "member",
                            "joinedAt": FieldValue.serverTimestamp(),
                        ],
                        "memberUids": FieldValue.arrayUnion([identity.uid]),
                        "joinToken": invite.token,
                    ])
                } catch where FirestoreValues.isPermissionDenied(error) || FirestoreValues.isNotFound(error) {
                    // El share ya no existe (lo borraron) o la invitación se revocó.
                    throw SharedRemindersError.inviteInvalid
                }
                snapshot = try await ref.getDocument(source: .server)
            }
            guard let snapshot, snapshot.exists else { throw SharedRemindersError.shareUnavailable }
            // Volver a aceptar una que se había quitado la trae de vuelta.
            DeletedSharesStore.remove(localID)
            let context = modelContainer.mainContext
            let data = FirestoreValues.document(snapshot.data())
            guard let applied = await applyFirestoreShare(docID: snapshot.documentID, data: data, in: context) else {
                throw SharedRemindersError.shareUnavailable
            }
            try context.save()
            CategoryStore.shared?.reload()
            clearAcceptError()
            if !silent {
                incomingShare = isCountdown
                    ? .acceptedCountdown(id: applied.id, title: applied.title, ownerName: applied.ownerName)
                    : .accepted(reminderID: applied.id, title: applied.title, ownerName: applied.ownerName)
            }
            ShareDiagnostics.log("✅ Firestore: '\(applied.title)' agregada")
        } catch {
            ShareDiagnostics.log("❌ Firestore: aceptar: \(error.localizedDescription)")
            if !silent { reportAcceptFailure(error) }
            throw error
        }
    }

    // MARK: - Invitado: copia local

    struct AppliedShare {
        var id: UUID
        var title: String
        var ownerName: String?
        /// La alarma cuyo horario cambió el dueño (para avisar).
        var rescheduled: Reminder?
    }

    /// Inserta o actualiza la copia local de un share recibido. Quien llama guarda.
    func applyFirestoreShare(docID: String, data: [String: Any], in context: ModelContext) async -> AppliedShare? {
        guard let id = UUID(uuidString: docID),
              let kind = (data["kind"] as? String).flatMap(ShareKind.init(rawValue:))
        else { return nil }
        let ownerName = FirestoreMapping.validName(data["ownerName"] as? String)
        let updatedAt = data["updatedAt"] as? Date
        let known = FirestoreShareStore.received(id)

        // La foto va aparte (`photo/current`): solo se baja cuando cambia su revisión.
        let hasPhoto = data["hasPhoto"] as? Bool ?? false
        let photoRevision = FirestoreMapping.int(data["photoRevision"]) ?? 0
        var photo: Data?
        var photoKnown = false
        if hasPhoto {
            if known?.photoRevision == photoRevision, let current = currentPhoto(of: id, kind: kind, in: context) {
                photo = current
                photoKnown = true
            } else if let fetched = await fetchPhoto(docID: docID) {
                photo = fetched
                photoKnown = true
            } else {
                // Sin red para la foto: se queda la que había hasta la próxima.
                photo = currentPhoto(of: id, kind: kind, in: context)
            }
        }

        var result: AppliedShare
        switch kind {
        case .alarm:
            guard var payload = FirestoreMapping.payload(fromAlarm: data["alarm"], id: docID, updatedAt: updatedAt) else { return nil }
            payload.photoThumbnail = photo
            guard let applied = applyReceivedPayload(payload, localID: id, in: context) else { return nil }
            result = AppliedShare(
                id: id,
                title: applied.reminder.title,
                ownerName: ownerName,
                rescheduled: applied.scheduleChanged ? applied.reminder : nil
            )
        case .countdown:
            guard let payload = FirestoreMapping.countdownPayload(from: data["countdown"], id: docID, photo: photo, updatedAt: updatedAt),
                  let event = applyReceivedCountdownPayload(payload, localID: id, in: context)
            else { return nil }
            result = AppliedShare(id: id, title: event.title, ownerName: ownerName, rescheduled: nil)
        }
        FirestoreShareStore.setReceived(
            .init(
                docID: docID,
                kind: kind.rawValue,
                ownerName: ownerName ?? known?.ownerName,
                photoRevision: hasPhoto ? (photoKnown ? photoRevision : nil) : 0
            ),
            for: id
        )
        if let ownerName {
            ownerNames[id] = SharedByPerson(name: ownerName, email: nil, phone: nil)
        }
        return result
    }

    private func currentPhoto(of id: UUID, kind: ShareKind, in context: ModelContext) -> Data? {
        switch kind {
        case .alarm:
            let descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.id == id })
            return (try? context.fetch(descriptor).first)?.photoData
        case .countdown:
            let descriptor = FetchDescriptor<CountdownEvent>(predicate: #Predicate { $0.id == id })
            return (try? context.fetch(descriptor).first)?.photoData
        }
    }

    private func fetchPhoto(docID: String) async -> Data? {
        guard let snapshot = try? await photoRef(docID).getDocument(source: .server), snapshot.exists else { return nil }
        return snapshot.data()?["jpeg"] as? Data
    }

    // MARK: - Invitado: salir

    /// Sale de un share recibido (la persona la quitó de su lista).
    func leaveFirestoreShare(id: UUID) async {
        guard let uid = FirebaseSession.shared.uid else { return }
        await leaveFirestoreShare(docID: FirestoreShareStore.docID(forReceived: id), uid: uid)
    }

    private func leaveFirestoreShare(docID: String, uid: String) async {
        do {
            try await shareRef(docID).updateData([
                FieldPath(["members", uid]): FieldValue.delete(),
                "memberUids": FieldValue.arrayRemove([uid]),
            ])
            ShareDiagnostics.log("👋 Firestore: fuera del share \(docID)")
        } catch where FirestoreValues.isPermissionDenied(error) {
            // Ya no es miembro (o el share ya no existe).
        } catch {
            // Sin red: el próximo escaneo lo reintenta (queda la marca de borrado).
            ShareDiagnostics.log("❌ Firestore: salir del share: \(error.localizedDescription)")
        }
    }

    // MARK: - Sincronizar

    /// Lee los shares de Firestore de esta persona: aplica los recibidos, sube lo
    /// propio que cambió desde otro dispositivo y devuelve los ids recibidos que
    /// siguen ahí. Nil si no se pudo leer del servidor (o Firebase no está):
    /// entonces nada de Firestore se da por borrado.
    func syncFirestoreShares(source: FirestoreSource) async -> Set<UUID>? {
        guard FirebaseSession.shared.isConfigured else { return nil }
        guard let uid = FirebaseSession.shared.uid else {
            // Sin sesión nunca compartió nada por Firestore. (Si recuerda copias
            // de Firestore, la sesión se perdió: mejor no borrar nada.)
            return FirestoreShareStore.receivedIDs.isEmpty ? [] : nil
        }
        let snapshot: QuerySnapshot
        do {
            snapshot = try await db.collection("shares")
                .whereField("memberUids", arrayContains: uid)
                .getDocuments(source: source)
        } catch {
            ShareDiagnostics.log("❌ Firestore: leer shares: \(error.localizedDescription)")
            return nil
        }
        let context = modelContainer.mainContext
        var present: Set<UUID> = []
        var applied = 0
        var rescheduled: [(reminder: Reminder, ownerName: String?)] = []
        var owned: [(docID: String, data: [String: Any])] = []
        for document in snapshot.documents {
            let data = FirestoreValues.document(document.data())
            if data["ownerUid"] as? String == uid {
                owned.append((document.documentID, data))
                continue
            }
            guard let id = UUID(uuidString: document.documentID) else { continue }
            present.insert(id)
            // La quitó de su lista, pero la salida no llegó (sin red): otra vez.
            if DeletedSharesStore.contains(id) {
                await leaveFirestoreShare(docID: document.documentID, uid: uid)
                continue
            }
            guard let result = await applyFirestoreShare(docID: document.documentID, data: data, in: context) else { continue }
            applied += 1
            if let reminder = result.rescheduled { rescheduled.append((reminder, result.ownerName)) }
        }
        if applied > 0 {
            try? context.save()
            CategoryStore.shared?.reload()
            ShareDiagnostics.log("✅ Firestore: \(applied) compartido(s) al día")
        }
        // El dueño la cambió de día u hora: que la persona se entere.
        for (reminder, ownerName) in rescheduled {
            await ShareChangeNotifier.notifyScheduleChanged(reminder, ownerName: ownerName)
        }
        let authoritative = !snapshot.metadata.isFromCache
        await reconcileOwnedShares(owned, authoritative: authoritative)
        return authoritative ? present : nil
    }

    /// Un push de «cambió»: lee solo ese share y lo aplica. Si ya no se puede leer
    /// (lo borraron o sacaron a esta persona), la pasada completa lo resuelve.
    func syncFirestoreShare(docID: String) async {
        guard let uid = FirebaseSession.shared.uid else { return }
        do {
            let snapshot = try await shareRef(docID).getDocument(source: .server)
            let data = FirestoreValues.document(snapshot.data())
            guard snapshot.exists else {
                await importAllSharedReminders(cloudKit: false)
                return
            }
            guard data["ownerUid"] as? String != uid,
                  let id = UUID(uuidString: docID),
                  !DeletedSharesStore.contains(id)
            else { return }
            let context = modelContainer.mainContext
            guard let result = await applyFirestoreShare(docID: docID, data: data, in: context) else { return }
            try? context.save()
            CategoryStore.shared?.reload()
            ShareDiagnostics.log("↻ Firestore: '\(result.title)' al día (push)")
            if let reminder = result.rescheduled {
                await ShareChangeNotifier.notifyScheduleChanged(reminder, ownerName: result.ownerName)
            }
        } catch {
            await importAllSharedReminders(cloudKit: false)
        }
    }

    /// Los shares de esta sesión: vuelve a subir lo que cambió por iCloud desde
    /// otro dispositivo de la cuenta (que tiene otra sesión y no puede
    /// escribirlos) y borra el de una alarma o cuenta que se borró allí.
    private func reconcileOwnedShares(_ documents: [(docID: String, data: [String: Any])], authoritative: Bool) async {
        let context = modelContainer.mainContext
        let ownCount = (try? context.fetchCount(FetchDescriptor<Reminder>(predicate: #Predicate { !$0.isReceivedShare }))) ?? 0
        var found: Set<String> = []
        for (docID, data) in documents {
            guard let id = UUID(uuidString: docID),
                  let kind = (data["kind"] as? String).flatMap(ShareKind.init(rawValue:))
            else { continue }
            found.insert(id.uuidString)
            let known = FirestoreShareStore.owned(id)
            if known == nil {
                // Tras reinstalar (la sesión vive en el llavero; esto no).
                FirestoreShareStore.setOwned(.init(
                    docID: docID,
                    kind: kind.rawValue,
                    inviteToken: data["inviteToken"] as? String,
                    photoRevision: FirestoreMapping.int(data["photoRevision"]) ?? 0
                ), for: id)
            }
            let lastPushed = known?.lastPushed ?? .distantPast
            switch kind {
            case .alarm:
                let descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.id == id && !$0.isReceivedShare })
                if let reminder = try? context.fetch(descriptor).first {
                    if reminder.updatedAt > lastPushed.addingTimeInterval(1) {
                        await pushFirestoreUpdate(reminder)
                    }
                } else if known != nil, ownCount > 0 {
                    // La borró en otro dispositivo (llegó por iCloud). Solo si este
                    // ya la conocía y su lista no está vacía (una base recién
                    // restaurada no cuenta como borrado).
                    await deleteFirestoreShare(id: id)
                }
            case .countdown:
                let descriptor = FetchDescriptor<CountdownEvent>(predicate: #Predicate { $0.id == id && !$0.isReceivedShare })
                if let event = try? context.fetch(descriptor).first {
                    if event.updatedAt > lastPushed.addingTimeInterval(1) {
                        await pushFirestoreUpdate(countdown: event)
                    }
                } else if known != nil, ownCount > 0 {
                    await deleteFirestoreShare(id: id)
                }
            }
        }
        // Los que ya no existen (se dejaron de compartir) se olvidan.
        if authoritative {
            let map = FirestoreShareStore.owned
            let kept = map.filter { found.contains($0.key) }
            if kept.count != map.count { FirestoreShareStore.owned = kept }
        }
    }

    // MARK: - Escucha en vivo

    /// Mientras la app está en pantalla, los cambios llegan solos: la escucha
    /// trae lo nuevo a la caché y dispara una pasada que lee de ahí (sin pagar
    /// lecturas otra vez). Lo que desaparece se confirma con el servidor.
    func startFirestoreListener() {
        guard firestoreListener == nil, let uid = FirebaseSession.shared.uid else { return }
        firestoreListener = db.collection("shares")
            .whereField("memberUids", arrayContains: uid)
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let self, let snapshot, !snapshot.metadata.hasPendingWrites else { return }
                let removed = snapshot.documentChanges.contains { $0.type == .removed }
                let fromServer = !snapshot.metadata.isFromCache
                Task { @MainActor in
                    await self.importAllSharedReminders(
                        cloudKit: false,
                        firestoreSource: removed && fromServer ? .default : .cache
                    )
                    // Quién entró o salió: «Personas» se vuelve a leer.
                    NotificationCenter.default.post(name: .calarmSharedDataChanged, object: nil)
                }
            }
    }

    func stopFirestoreListener() {
        firestoreListener?.remove()
        firestoreListener = nil
    }

    // MARK: - Nombre

    /// El nombre nuevo, en todo lo de Firestore donde aparece: el perfil, cada
    /// share (como dueño o miembro), sus invitaciones y las listas de confianza.
    func propagateMyNameToFirestore() async {
        guard let uid = FirebaseSession.shared.uid,
              let name = FirestoreMapping.validName(ShareNames.myName)
        else { return }
        await FirebaseSession.shared.updateProfile()
        if let shares = try? await db.collection("shares").whereField("memberUids", arrayContains: uid).getDocuments() {
            for document in shares.documents {
                let data = document.data()
                if data["ownerUid"] as? String == uid {
                    try? await document.reference.updateData([
                        "ownerName": name,
                        FieldPath(["members", uid, "name"]): name,
                        "updatedBy": uid,
                        "updatedAt": FieldValue.serverTimestamp(),
                    ])
                    if let token = data["inviteToken"] as? String {
                        try? await inviteRef(token).updateData(["ownerName": name])
                    }
                } else {
                    try? await document.reference.updateData([FieldPath(["members", uid, "name"]): name])
                }
            }
        }
        let principal = db.collection("delegations").document(uid)
        if let snapshot = try? await principal.getDocument(), snapshot.exists {
            try? await principal.updateData(["principalName": name, "updatedAt": FieldValue.serverTimestamp()])
            if let token = UserDefaults.standard.string(forKey: DelegationService.inviteTokenKey) {
                try? await inviteRef(token).updateData(["ownerName": name, "preview.title": name])
            }
        }
        if let helping = try? await db.collection("delegations").whereField("helperUids", arrayContains: uid).getDocuments() {
            for document in helping.documents {
                try? await document.reference.updateData([FieldPath(["helpers", uid, "name"]): name])
            }
        }
        ShareDiagnostics.log("🪪 Firestore: nombre actualizado")
    }

    // MARK: - Migración desde CloudKit

    /// Invitado: lo recibido por CloudKit cuyo dueño ya creó el share de
    /// Firestore (el token viaja en el payload). Se une allí y sale del
    /// `CKShare`; si algo falla, sigue por CloudKit como siempre.
    func migrateReceivedCloudKitShares(_ migrations: [CloudKitMigration]) async {
        for migration in migrations {
            let step = ShareMigration.participantStep(
                firebaseToken: migration.token,
                deletedByMe: DeletedSharesStore.contains(migration.id),
                alreadyOnFirestore: FirestoreShareStore.received(migration.id) != nil,
                hasName: FirestoreMapping.validName(ShareNames.myName) != nil,
                firebaseAvailable: FirebaseSession.shared.isConfigured
            )
            switch step {
            case .joinFirestore(let token):
                do {
                    let invite = try await fetchInvite(token)
                    guard invite.kind != .delegation,
                          invite.targetID.caseInsensitiveCompare(migration.id.uuidString) == .orderedSame
                    else { continue }
                    try await acceptFirestoreShare(invite, silent: true)
                    guard FirestoreShareStore.received(migration.id) != nil else { continue }
                    await leaveShare(of: migration.record)
                    ShareDiagnostics.log("🔀 migrada a Firestore \(migration.id.uuidString)")
                } catch {
                    ShareDiagnostics.log("⚠️ migración (invitado) pendiente: \(error.localizedDescription)")
                }
            case .leaveCloudKit:
                await leaveShare(of: migration.record)
            case .stayOnCloudKit, .ignore:
                break
            }
        }
    }

    /// Dueño: por cada alarma o cuenta compartida por CloudKit, el share de
    /// Firestore y su invitación, con el token escrito en el payload de CloudKit
    /// para que los invitados con la app nueva se pasen. El `CKShare` se queda:
    /// los invitados con la app vieja (y los enlaces `/i/`, `/c/` aún sin abrir)
    /// siguen por ahí, y `pushUpdateIfShared` le sigue escribiendo cada cambio.
    func migrateOwnedCloudKitShares() async {
        guard FirebaseSession.shared.isConfigured, FirestoreMapping.validName(ShareNames.myName) != nil else { return }
        let zoneID = CKRecordZone.ID(zoneName: Self.sharingZoneName, ownerName: CKCurrentUserDefaultName)
        let database = cloudKitContainer.privateCloudDatabase
        var records: [CKRecord] = []
        do {
            var token: CKServerChangeToken?
            var more = true
            while more {
                let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
                for result in changes.modificationResultsByID.values {
                    if case .success(let modification) = result { records.append(modification.record) }
                }
                token = changes.changeToken
                more = changes.moreComing
            }
        } catch {
            // Sin zona: nunca compartió por CloudKit.
            if !Self.isCKError(error, .zoneNotFound) {
                ShareDiagnostics.log("⚠️ migración (dueño): \(Self.diagnosticDescription(for: error))")
            }
            return
        }
        let context = modelContainer.mainContext
        var migrated = 0
        for record in records where record.share != nil {
            guard let id = UUID(uuidString: record.recordID.recordName) else { continue }
            do {
                if record.recordType == Self.countdownRecordType {
                    let descriptor = FetchDescriptor<CountdownEvent>(predicate: #Predicate { $0.id == id && !$0.isReceivedShare })
                    let event = try? context.fetch(descriptor).first
                    guard ShareMigration.ownerShouldMigrate(
                        payloadToken: countdownPayload(from: record)?.firebaseToken,
                        ownsLocalItem: event != nil, hasName: true, firebaseAvailable: true
                    ), let event,
                    let token = try await upsertFirestoreShare(firestoreContent(for: event), create: true)
                    else { continue }
                    writeCountdown(event, to: record, firebaseToken: token)
                } else if record.recordType == "CalarmSharedReminder" {
                    let descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.id == id && !$0.isReceivedShare })
                    let reminder = try? context.fetch(descriptor).first
                    guard ShareMigration.ownerShouldMigrate(
                        payloadToken: decodePayload(from: record).firebaseToken,
                        ownsLocalItem: reminder != nil, hasName: true, firebaseAvailable: true
                    ), let reminder,
                    let token = try await upsertFirestoreShare(firestoreContent(for: reminder), create: true)
                    else { continue }
                    writeFields(from: reminder, to: record, firebaseToken: token)
                } else {
                    continue
                }
                _ = try await database.modifyRecords(saving: [record], deleting: [])
                migrated += 1
            } catch {
                ShareDiagnostics.log("⚠️ migración (dueño) \(id.uuidString): \(error.localizedDescription)")
            }
        }
        if migrated > 0 {
            ShareDiagnostics.log("🔀 migración (dueño): \(migrated) compartido(s) ya en Firestore")
        }
    }
}

// MARK: - Push

/// Un mensaje de datos de las funciones de Firebase (DESIGN.md › Push). Todos
/// los valores llegan como texto.
struct SharePush: Equatable {
    enum Kind: String {
        case share, delegation, delegationReminder
    }

    var type: Kind
    var event: String
    var id: String
    var principal: String?
    var title: String?
    var actorName: String?
    var oldDate: Date?
    var newDate: Date?

    init?(userInfo: [AnyHashable: Any]) {
        guard let type = (userInfo["type"] as? String).flatMap(Kind.init(rawValue:)),
              let event = userInfo["event"] as? String,
              let id = userInfo["id"] as? String
        else { return nil }
        func date(_ key: String) -> Date? {
            (userInfo[key] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
        }
        self.type = type
        self.event = event
        self.id = id
        self.principal = userInfo["principal"] as? String
        self.title = userInfo["title"] as? String
        self.actorName = userInfo["actorName"] as? String
        self.oldDate = date("oldDate")
        self.newDate = date("newDate")
    }
}
