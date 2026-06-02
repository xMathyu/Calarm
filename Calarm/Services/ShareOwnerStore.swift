//
//  ShareOwnerStore.swift
//  Calarm
//
//  Remembers who shared a received reminder, so the recipient can see
//  "Compartido por <nombre>". Stored locally (UserDefaults) keyed by the local
//  reminder id — it's display-only metadata, so it doesn't need to live in the
//  SwiftData/CloudKit schema.
//

import Foundation

/// A person involved in a share, with enough info to look up their Contacts photo.
struct SharedByPerson: Codable, Equatable {
    var name: String
    var email: String?
    var phone: String?
}

enum ShareOwnerStore {
    private static let key = "calarm.shareOwners"

    static func set(_ owner: SharedByPerson, for id: UUID) {
        var map = load()
        map[id.uuidString] = owner
        save(map)
    }

    static func get(_ id: UUID) -> SharedByPerson? {
        load()[id.uuidString]
    }

    private static func load() -> [String: SharedByPerson] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: SharedByPerson].self, from: data)) ?? [:]
    }

    private static func save(_ map: [String: SharedByPerson]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(map), forKey: key)
    }
}
