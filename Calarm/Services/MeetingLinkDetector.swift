//
//  MeetingLinkDetector.swift
//  Calarm
//

import Foundation

/// Identifies whether a calendar event contains a video-meeting join link
/// (Microsoft Teams, Zoom or Google Meet) by inspecting its URL, location,
/// and notes fields.
enum MeetingLinkDetector {

    /// Extracts the best meeting join link found across the provided fields, or nil if none.
    ///
    /// Invites often contain several URLs from the same provider (e.g. Teams' mobile-browser
    /// router `visit.teams.microsoft.com`, the organizer's `meetingOptions` page, …), so
    /// instead of returning the first match this collects every candidate and prefers a
    /// real join link.
    /// - Parameters:
    ///   - url: The event's `URL?` field (often the structured meeting URL).
    ///   - location: The event's location string.
    ///   - notes: The event's notes/body string.
    static func extractMeetingLink(url: URL?, location: String?, notes: String?) -> MeetingLink? {
        var candidates: [MeetingLink] = []
        if let url, let link = meetingLink(for: url) {
            candidates.append(link)
        }
        for text in [location, notes] {
            guard let text, !text.isEmpty else { continue }
            candidates.append(contentsOf: meetingLinks(in: text))
        }

        var best: (link: MeetingLink, score: Int)?
        for candidate in candidates {
            let score = joinPriority(candidate)
            if best == nil || score > best!.score {
                best = (candidate, score)
            }
        }
        return best?.link
    }

    /// Returns the meeting provider the URL belongs to, or nil for non-meeting URLs.
    static func provider(for url: URL) -> MeetingProvider? {
        guard let host = url.host?.lowercased() else { return nil }
        if matches(host, domain: "teams.microsoft.com") || matches(host, domain: "teams.live.com") {
            return .teams
        }
        if matches(host, domain: "zoom.us") || matches(host, domain: "zoom.com") {
            return .zoom
        }
        if host == "meet.google.com" {
            return .googleMeet
        }
        return nil
    }

    // MARK: - Private

    private static func meetingLink(for url: URL) -> MeetingLink? {
        guard let provider = provider(for: url) else { return nil }
        return MeetingLink(provider: provider, url: url)
    }

    private static func matches(_ host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    /// Ranks a meeting URL by how likely it is to be the actual join link. Higher wins;
    /// among equal scores the earliest occurrence wins.
    private static func joinPriority(_ link: MeetingLink) -> Int {
        let host = link.url.host?.lowercased() ?? ""
        let path = link.url.path.lowercased()
        switch link.provider {
        case .teams:
            // Real join links: https://teams.microsoft.com/meet/<id> and the classic
            // https://teams.microsoft.com/l/meetup-join/<thread> deep link.
            if path.hasPrefix("/meet/") || path.hasPrefix("/l/meetup-join") {
                return 2
            }
            // Not join links: the mobile-browser WebRTC router and the organizer's
            // meeting-options page. Only used if nothing better exists.
            if host.hasPrefix("visit.") || path.hasPrefix("/meetingoptions") {
                return 0
            }
            return 1
        case .zoom:
            // /j/<id> (also on corporate subdomains like empresa.zoom.us), /w/ webinars,
            // /s/ SSO joins, /my/<vanity> personal rooms.
            if path.hasPrefix("/j/") || path.hasPrefix("/w/") || path.hasPrefix("/s/") || path.hasPrefix("/my/") {
                return 2
            }
            return 1
        case .googleMeet:
            // Any non-root path is a meeting code (meet.google.com/abc-defg-hij or /lookup/…).
            return path.count > 1 ? 2 : 1
        }
    }

    private static func meetingLinks(in text: String) -> [MeetingLink] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        var results: [MeetingLink] = []
        detector.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            if let url = match?.url, let link = meetingLink(for: url) {
                results.append(link)
            }
        }
        return results
    }
}
