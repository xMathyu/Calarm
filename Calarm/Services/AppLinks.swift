//
//  AppLinks.swift
//  Calarm
//
//  The app's own public links. Kept in one place because they end up inside
//  messages the user sends to other people (invites, "compartir Calarm"), where
//  a wrong or missing link is a dead end for whoever receives it.
//

import Foundation

enum AppLinks {
    /// Calarm on the App Store. Apple resolves the id to the visitor's own
    /// storefront and language, so this single link works for every recipient.
    static let appStore = URL(string: "https://apps.apple.com/app/id6772419323")!
}
