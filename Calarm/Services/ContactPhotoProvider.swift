//
//  ContactPhotoProvider.swift
//  Calarm
//
//  Looks up a person's photo in the device Contacts by email or phone, so share
//  participants can show their real picture. Falls back to nil (→ initials) when
//  access isn't granted or no match exists. Results are cached.
//

import Contacts
import Foundation

actor ContactPhotoProvider {
    static let shared = ContactPhotoProvider()

    private let store = CNContactStore()
    private var cache: [String: Data?] = [:]

    /// Prompts for Contacts access once, if the user hasn't decided yet.
    func requestAccessIfNeeded() async {
        guard CNContactStore.authorizationStatus(for: .contacts) == .notDetermined else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.requestAccess(for: .contacts) { _, _ in continuation.resume() }
        }
    }

    /// Returns the contact's thumbnail image data (Sendable) for an email/phone, or
    /// nil. The caller builds the image on its own actor.
    func thumbnailData(email: String?, phone: String?) -> Data? {
        let key = "\(email ?? "")|\(phone ?? "")"
        if let cached = cache[key] { return cached }
        let data = lookup(email: email, phone: phone)
        cache[key] = data
        return data
    }

    private var canReadContacts: Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized { return true }
        if #available(iOS 18.0, *) { return status == .limited }
        return false
    }

    private func lookup(email: String?, phone: String?) -> Data? {
        guard canReadContacts else { return nil }
        let keys = [CNContactThumbnailImageDataKey as CNKeyDescriptor]
        var predicates: [NSPredicate] = []
        if let email, !email.isEmpty {
            predicates.append(CNContact.predicateForContacts(matchingEmailAddress: email))
        }
        if let phone, !phone.isEmpty {
            predicates.append(CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: phone)))
        }
        for predicate in predicates {
            guard let contacts = try? store.unifiedContacts(matching: predicate, keysToFetch: keys) else { continue }
            if let data = contacts.first(where: { $0.thumbnailImageData != nil })?.thumbnailImageData {
                return data
            }
        }
        return nil
    }
}
