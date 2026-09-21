//
//  InviteLink.swift
//  Calarm
//
//  Calarm's own invitation links, e.g.
//  `https://calarm-puce.vercel.app/i/<payload>/`.
//
//  Before these, invites travelled as the raw `icloud.com/share/…` URL. That
//  link only previews nicely inside iMessage, never shows *when* the alarm
//  rings, and is a dead end for anyone who doesn't have Calarm yet — which is
//  most people receiving an invitation.
//
//  The whole invitation is encoded into the URL itself: there is no server
//  storing anything. The website decodes the same payload to render the preview
//  card, and the app decodes it to recover the CloudKit share URL it must
//  accept. `src/lib/invite.ts` in the calarm-web repo is the other half of this
//  contract — the two must be changed together.
//

import Foundation

enum InviteLink {
    /// Host that serves the invitation pages. Must match the `applinks:` entry
    /// in Calarm.entitlements, or iOS opens the link in Safari instead.
    static let host = "calarm-puce.vercel.app"

    /// Wire format version, mirrored by `INVITE_VERSION` on the web side.
    private static let version = 1

    /// Only CloudKit share URLs are ever carried or accepted.
    private static let shareURLPrefix = "https://www.icloud.com/share/"

    /// The invitation, as it travels inside the link. Field names are
    /// single-letter on purpose: they end up in a URL people see.
    private struct Payload: Codable {
        /// Wire format version.
        let v: Int
        /// Alarm title — the preview card's headline.
        let t: String
        /// When it rings.
        let d: Date
        /// IANA zone, so the card shows the time the sender meant.
        let tz: String?
        /// Sender's app language, picks the card's wording.
        let l: String?
        /// Category tint as `#RRGGBB`, colors the card.
        let c: String?
        /// The CloudKit share URL, which is what the app actually needs.
        let s: String
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        // The web side parses this with `Date.parse`, which wants ISO-8601.
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Building

    /// Wraps a prepared CloudKit share in a Calarm link. Returns `nil` only if
    /// the payload can't be encoded, in which case callers should fall back to
    /// sending `shareURL` directly — a plain link still works, it just previews
    /// poorly.
    static func make(
        title: String,
        date: Date,
        tintHex: String?,
        shareURL: URL,
        languageCode: String = LocalizationManager.shared.currentLocale.language.languageCode?.identifier ?? "es"
    ) -> URL? {
        guard shareURL.absoluteString.hasPrefix(shareURLPrefix) else { return nil }

        let payload = Payload(
            v: version,
            t: title,
            d: date,
            tz: TimeZone.current.identifier,
            l: languageCode == "en" ? "en" : "es",
            c: tintHex,
            s: shareURL.absoluteString
        )

        guard let data = try? encoder.encode(payload) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        // The trailing slash is the site's canonical form; without it Vercel
        // answers with a redirect.
        components.path = "/i/\(base64URLEncoded(data))/"
        return components.url
    }

    // MARK: - Reading

    /// True when `url` is one of our invitation links, so the app can claim it
    /// without trying to decode every URL it's handed.
    static func isInvite(_ url: URL) -> Bool {
        url.host() == host && url.path().hasPrefix("/i/")
    }

    /// Recovers the CloudKit share URL from an incoming invitation link.
    ///
    /// Returns `nil` for anything malformed or for a payload pointing somewhere
    /// other than iCloud — the link arrives from outside the app, so it is not
    /// to be trusted.
    static func shareURL(from url: URL) -> URL? {
        guard isInvite(url) else { return nil }

        let segment = url.path()
            .dropFirst("/i/".count)
            .split(separator: "/")
            .first
        guard let segment,
              let data = base64URLDecoded(String(segment)),
              let payload = try? decoder.decode(Payload.self, from: data),
              payload.v == version,
              payload.s.hasPrefix(shareURLPrefix)
        else { return nil }

        return URL(string: payload.s)
    }

    // MARK: - base64url

    /// base64url without padding — safe to drop straight into a path segment.
    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecoded(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Re-add the padding `base64URLEncoded` stripped.
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }
}
