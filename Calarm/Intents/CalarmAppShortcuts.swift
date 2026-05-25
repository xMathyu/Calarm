//
//  CalarmAppShortcuts.swift
//  Calarm
//
//  Declares the Siri phrases and Spotlight/Action Button entries that
//  Calarm exposes to the system. Apple auto-discovers this provider — no
//  Info.plist or App Store Connect setup required.
//

import AppIntents

struct CalarmAppShortcuts: AppShortcutsProvider {
    /// Up to 10 shortcuts can be registered. Each `phrases` entry MUST contain
    /// `\(.applicationName)` (Apple enforces this so users know which app
    /// will run). The shortcuts appear in:
    ///   • Spotlight (swipe down → type "alarma")
    ///   • Shortcuts app (browse by app)
    ///   • Siri (when the user includes "Calarm" in the phrase)
    ///   • Action Button on iPhone 15 Pro and newer (configurable)
    ///   • Apple Intelligence suggestions (proactive)
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateAlarmIntent(),
            phrases: [
                "Crear alarma en \(.applicationName)",
                "Nueva alarma en \(.applicationName)",
                "Pon una alarma en \(.applicationName)",
                "Programa una alarma en \(.applicationName)",
                "Agrega una alarma en \(.applicationName)",
                "\(.applicationName) nueva alarma",
                "\(.applicationName) crear alarma",
                "Recuérdame algo en \(.applicationName)",
            ],
            shortTitle: "Nueva alarma",
            systemImageName: "alarm.fill"
        )
    }

    /// Tint color for the shortcut tile in the Shortcuts app — matches the
    /// app's accent (orange).
    static let shortcutTileColor: ShortcutTileColor = .orange
}
