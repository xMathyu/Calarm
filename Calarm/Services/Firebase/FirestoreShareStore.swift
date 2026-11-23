//
//  FirestoreShareStore.swift
//  Calarm
//
//  Lo que este dispositivo recuerda de sus shares de Firestore, por id local de
//  la alarma o cuenta (en mayúsculas, como `UUID.uuidString`).
//
//  Hace falta porque el dueño no puede preguntar a Firestore si un share existe
//  (las reglas niegan leer uno que no existe, igual que uno ajeno), y porque
//  conviven dos orígenes de lo recibido: CloudKit (invitaciones viejas) y
//  Firestore. Cada escaneo solo da por borrado lo de su origen
//  (`ShareMigration.staleReceived`).
//
//  En UserDefaults, como `ShareLeadTimesStore`: es estado de este dispositivo
//  (otro dispositivo de la misma cuenta de iCloud tiene otra sesión anónima).
//

import Foundation

enum FirestoreShareStore {
    /// Un share que esta sesión creó (es su dueña).
    struct Owned: Codable, Equatable {
        /// El id del documento tal cual (Android usa minúsculas; aquí, el UUID de iOS).
        var docID: String
        var kind: String
        /// La invitación vigente del share (`invites/{token}`).
        var inviteToken: String?
        /// El `updatedAt` de la alarma o cuenta la última vez que se subió: si la
        /// local es más nueva (un cambio que llegó por iCloud desde otro
        /// dispositivo), se vuelve a subir.
        var lastPushed: Date?
        /// Huella de lo último subido, para no subir (ni avisar a todos) si no cambió.
        var contentHash: String?
        /// Huella y revisión de la foto subida a `shares/{id}/photo/current`.
        var photoHash: String?
        var photoRevision: Int = 0
    }

    /// Un share de otra persona del que este dispositivo es miembro.
    struct Received: Codable, Equatable {
        var docID: String
        var kind: String
        /// Lo guarda la app (es dato propio, no de iCloud): hace falta para el
        /// aviso «X la borró» cuando el share ya no existe.
        var ownerName: String?
        /// La revisión de la foto que ya se bajó.
        var photoRevision: Int?
    }

    private static let ownedKey = "calarm.firestore.ownedShares"
    private static let receivedKey = "calarm.firestore.receivedShares"

    // MARK: - Propios

    static var owned: [String: Owned] {
        get { load(ownedKey) }
        set { save(newValue, ownedKey) }
    }

    static func owned(_ id: UUID) -> Owned? {
        owned[id.uuidString]
    }

    static func setOwned(_ entry: Owned?, for id: UUID) {
        var map = owned
        map[id.uuidString] = entry
        owned = map
    }

    // MARK: - Recibidos

    static var received: [String: Received] {
        get { load(receivedKey) }
        set { save(newValue, receivedKey) }
    }

    static var receivedIDs: Set<UUID> {
        Set(received.keys.compactMap(UUID.init(uuidString:)))
    }

    static func received(_ id: UUID) -> Received? {
        received[id.uuidString]
    }

    static func setReceived(_ entry: Received?, for id: UUID) {
        var map = received
        map[id.uuidString] = entry
        received = map
    }

    /// Tras una lectura completa sin errores: solo quedan los que siguen.
    static func keepReceived(_ ids: Set<UUID>) {
        let keep = Set(ids.map(\.uuidString))
        let map = received
        let kept = map.filter { keep.contains($0.key) }
        if kept.count != map.count { received = kept }
    }

    /// El id del documento de un share recibido (en Android va en minúsculas).
    static func docID(forReceived id: UUID) -> String {
        received(id)?.docID ?? id.uuidString
    }

    // MARK: - Almacenamiento

    private static func load<T: Codable>(_ key: String) -> [String: T] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: T].self, from: data)) ?? [:]
    }

    private static func save<T: Codable>(_ map: [String: T], _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(map), forKey: key)
    }
}
