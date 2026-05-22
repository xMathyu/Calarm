//
//  TeamsMeetingDetector.swift
//  Calarm
//

import Foundation

/// Identifies whether a calendar event represents a Microsoft Teams meeting by inspecting
/// its URL, location, and notes fields for known Teams meeting hosts.
enum TeamsMeetingDetector {
    private static let teamsHosts: [String] = [
        "teams.microsoft.com",
        "teams.live.com"
    ]

    /// Extracts the first Teams join URL found across the provided fields, or nil if none.
    /// - Parameters:
    ///   - url: The event's `URL?` field (often the structured meeting URL).
    ///   - location: The event's location string.
    ///   - notes: The event's notes/body string.
    static func extractTeamsURL(url: URL?, location: String?, notes: String?) -> URL? {
        if let url, isTeamsURL(url) {
            return url
        }
        for candidate in [location, notes] {
            guard let text = candidate, !text.isEmpty else { continue }
            if let found = firstTeamsURL(in: text) {
                return found
            }
        }
        return nil
    }

    static func isTeamsURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return teamsHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func firstTeamsURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        var result: URL?
        detector.enumerateMatches(in: text, options: [], range: range) { match, _, stop in
            if let url = match?.url, isTeamsURL(url) {
                result = url
                stop.pointee = true
            }
        }
        return result
    }
}
