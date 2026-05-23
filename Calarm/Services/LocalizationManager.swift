//
//  LocalizationManager.swift
//  Calarm
//
//  Runtime language override. Swizzles `Bundle.main`'s class to a subclass that
//  loads strings from a specific `.lproj` folder, so the app can switch
//  languages without restarting.
//

import Foundation
import Observation
import ObjectiveC
import os

/// Custom Bundle subclass used to route `localizedString(forKey:value:table:)`
/// to a per-language bundle when the user has overridden the system language.
final class LocalizedBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let perLanguageBundle = LocalizationManager.shared.snapshotBundle() {
            return perLanguageBundle.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

/// Owns the active per-language bundle. Thread-safe — `localizedString` may be
/// invoked from arbitrary threads, so reads are guarded by an `OSAllocatedUnfairLock`.
@Observable
final class LocalizationManager: @unchecked Sendable {
    static let shared = LocalizationManager()

    /// Monotonically incremented every time `apply` changes the language. UI
    /// can observe this and force already-rendered views to re-evaluate their
    /// localized text by using it as a SwiftUI `.id(...)`.
    private(set) var revision: Int = 0

    /// The explicit language code the user picked (e.g. "en", "es"), or `nil`
    /// when in `.system` mode. Used for locale derivation — derive from this
    /// instead of `bundle.preferredLocalizations`, which can return unexpected
    /// values depending on the system's preferred-languages list.
    private(set) var activeLanguageCode: String?

    @ObservationIgnored
    private let storage = OSAllocatedUnfairLock<Bundle?>(initialState: nil)

    @ObservationIgnored
    private var didInstallSwizzle = false

    private init() {}

    /// Snapshot for the swizzled Bundle to consult on every `localizedString` call.
    func snapshotBundle() -> Bundle? {
        storage.withLock { $0 }
    }

    /// The active locale — reflects the user's manual language override if set,
    /// otherwise falls back to the system locale. Use this for `DateFormatter`,
    /// `NumberFormatter`, etc. so date/number formatting matches the rest of
    /// the localized UI.
    ///
    /// For overridden languages we pick a sensible regional default so dates
    /// look right (American English by default produces "June 10, 2026", not
    /// "10 June 2026" which is the en_001 international form).
    var currentLocale: Locale {
        guard let code = activeLanguageCode else {
            // `.system` mode — defer entirely to the iPhone's locale.
            return Locale.current
        }
        switch code {
        case "en":
            return Locale(identifier: "en_US")
        case "es":
            // Keep using the system's Spanish region (es_PE, es_MX, es_ES, …)
            // if it's already Spanish-speaking — Spanish formatting is
            // essentially identical across regions anyway.
            if let region = Locale.current.region?.identifier,
               Locale.current.language.languageCode?.identifier == "es" {
                return Locale(identifier: "es_\(region)")
            }
            return Locale(identifier: "es_ES")
        default:
            return Locale(identifier: code)
        }
    }

    /// Installs the Bundle.main swizzle exactly once. Safe to call multiple
    /// times — subsequent calls are no-ops.
    func installSwizzleIfNeeded() {
        guard !didInstallSwizzle else { return }
        object_setClass(Bundle.main, LocalizedBundle.self)
        didInstallSwizzle = true
    }

    /// Applies the requested language. Pass `.system` to fall back to the
    /// iPhone's preferred language. The change takes effect immediately for
    /// all future `Text(...)` resolutions; combine with a `.id(...)` based on
    /// `revision` to force already-rendered views to re-evaluate their text.
    func apply(_ language: AppLanguage) {
        installSwizzleIfNeeded()

        let resolved: Bundle?
        if let code = language.bundleLanguageCode,
           let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            resolved = bundle
            activeLanguageCode = code
        } else {
            resolved = nil
            activeLanguageCode = nil
        }

        storage.withLock { $0 = resolved }
        revision &+= 1
    }
}
