//
//  ShareDiagnostics.swift
//  Calarm
//
//  Lightweight, persisted trace of the CloudKit share accept → ingest flow, shown
//  in Settings → Diagnóstico. Lets us see exactly where an invitation fails on a
//  real device without attaching Console.app.
//

import Foundation

enum ShareDiagnostics {
    private static let key = "calarm.shareDiagnostics.log"
    private static let maxEntries = 120

    /// Appends a timestamped line. Safe to call from any thread (UserDefaults is
    /// thread-safe); cross-thread ordering is best-effort, which is fine here.
    static func log(_ message: String) {
        let now = Date()
        let cal = Calendar.current
        let stamp = String(
            format: "%02d:%02d:%02d",
            cal.component(.hour, from: now),
            cal.component(.minute, from: now),
            cal.component(.second, from: now)
        )
        var entries = UserDefaults.standard.stringArray(forKey: key) ?? []
        entries.append("\(stamp)  \(message)")
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        UserDefaults.standard.set(entries, forKey: key)
    }

    static func entries() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
