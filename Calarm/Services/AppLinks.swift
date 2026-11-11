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

    /// Términos de uso de las compras: el contrato estándar de Apple (EULA). La
    /// App Store exige enlazarlo desde la pantalla de compra de una suscripción.
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    /// La web de Calarmi.
    static let website = URL(string: "https://calarmi.mathyusolutions.com/")!

    /// La política de privacidad de la web, en el idioma de la app.
    static var privacy: URL {
        let path = switch LocalizationManager.shared.currentLocale.language.languageCode?.identifier {
        case "es": "privacidad/"
        case "pt": "pt/privacidade/"
        default: "en/privacy/"
        }
        return website.appending(path: path)
    }
}
