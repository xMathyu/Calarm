//
//  InviteLink.swift
//  Calarm
//
//  Calarm's own invitation links, e.g.
//  `https://calarmi.mathyusolutions.com/c/07628shg9cGxsh2Moi-46rp9A/`.
//
//  Before these, invites travelled as the raw `icloud.com/share/…` URL. That
//  link only previews nicely inside iMessage, never shows *when* the alarm
//  rings, and is a dead end for anyone who doesn't have Calarm yet — which is
//  most people receiving an invitation.
//
//  Two shapes of the data segment exist:
//  - The share token (1.0.18+): the id of the CloudKit share, the part after
//    `icloud.com/share/`. That is all the link carries (~64 characters). The
//    app rebuilds the share URL from it. The website reads the alarm itself
//    from CloudKit (`src/lib/cloudkit.ts` in calarm-web), using the share's
//    root record and the `InvitePreview` stored in its payload.
//  - JSON (before 1.0.18): the whole invitation, base64url JSON with the full
//    share URL (~330 characters). Links already sent use it, so it is still
//    read. It is also still built as a fallback, when a share URL doesn't have
//    the usual shape. `src/lib/invite.ts` in calarm-web decodes it.
//
//  There is no server storing anything of ours either way. Both shapes are a
//  contract with the website — change them together.
//
//  Since 1.1 new invitations are Firestore ones: `/s/<token>/` (and
//  `calarm://s/<token>`), where the token is the id of `invites/{token}`
//  (calarmi-firebase/DESIGN.md › Enlaces). The document says whether it's an
//  alarm, a countdown or a trusted-people list, so one path serves all three.
//  `/i/` and `/c/` stay readable: they are the CloudKit invitations already sent.
//

import Foundation

enum InviteLink {
    /// What an invitation is for. Each kind has its own path (`/i/` alarms,
    /// `/c/` countdowns): builds that predate countdowns only claim `/i/`, so
    /// they ignore a countdown link instead of importing it as a broken alarm.
    enum Kind: String {
        case alarm = "i"
        case countdown = "c"
    }

    /// Host that serves the invitation pages. Must match the `applinks:` entry
    /// in Calarm.entitlements, or iOS opens the link in Safari instead.
    static let host = "calarmi.mathyusolutions.com"

    /// Hosts of links already sent. They stay in `applinks:` and are still
    /// accepted, so an old invitation keeps opening the app. The web also uses
    /// the first one in the Smart App Banner, since every app version knows it.
    static let legacyHosts: Set<String> = ["calarm-puce.vercel.app", "calarmi.vercel.app"]

    /// Second door: `calarm://i/<payload>/`, declared in Info.plist.
    ///
    /// The invitation page can't send someone into the app with a universal
    /// link, because iOS deliberately ignores those when the page already lives
    /// on the claimed domain. Its "Ya tengo Calarm" button uses this instead,
    /// which also rescues anyone whose link opens in Safari because they once
    /// chose to leave the app association off.
    static let scheme = "calarm"

    /// The query parameter that carries the alarm's photo (`InvitePhoto`):
    /// base64url JPEG bytes. Kept out of the payload so a photo can never break
    /// the invitation itself, and spared a second round of base64.
    static let photoQueryName = "f"

    /// Wire format version, mirrored by `INVITE_VERSION` on the web side.
    private static let version = 1

    /// Only CloudKit share URLs are ever carried or accepted.
    private static let shareURLPrefix = "https://www.icloud.com/share/"

    /// Characters a share token may have, same rule as `SHARE_TOKEN` on the web.
    /// A share URL with anything else (a query, a new shape) gets a JSON link.
    private static let tokenAlphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".unicodeScalars)

    /// The language the website writes the invitation page in: "es", "en" or
    /// "pt". Older versions of the website read anything but "en" as Spanish.
    static func pageLanguage(
        _ code: String = LocalizationManager.shared.currentLocale.language.languageCode?.identifier ?? "es"
    ) -> String {
        ["en", "pt"].contains(code) ? code : "es"
    }

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
        /// The emoji chosen as the alarm's icon, when there is one.
        let e: String?
        /// Otherwise the SF Symbol name of its icon. The site can't draw SF
        /// Symbols, so it maps the name to a look-alike glyph of its own.
        let y: String?
        /// The CloudKit share URL, which is what the app actually needs.
        let s: String
        /// `"c"` for a countdown; absent for an alarm (every older link).
        var k: String? = nil
        /// Countdowns only: whether `d` carries a meaningful time of day. All-day
        /// events show just the date.
        var h: Bool? = nil
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
    ///
    /// Usually the link carries only the share's token, and every other
    /// argument goes unused: the website reads them from CloudKit. They fill
    /// the JSON link built when the share URL has an unexpected shape.
    static func make(
        kind: Kind = .alarm,
        title: String,
        date: Date,
        hasTime: Bool = true,
        tintHex: String?,
        emoji: String? = nil,
        symbol: String? = nil,
        photo: Data? = nil,
        shareURL: URL,
        languageCode: String = LocalizationManager.shared.currentLocale.language.languageCode?.identifier ?? "es"
    ) -> URL? {
        guard shareURL.absoluteString.hasPrefix(shareURLPrefix) else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = host

        // The token is enough: the website reads the rest from CloudKit.
        if let token = shareToken(of: shareURL) {
            // The trailing slash is the site's canonical form; without it Vercel
            // answers with a redirect.
            components.path = "/\(kind.rawValue)/\(token)/"
            return components.url
        }

        let payload = Payload(
            v: version,
            t: title,
            d: date,
            tz: TimeZone.current.identifier,
            l: pageLanguage(languageCode),
            c: tintHex,
            e: emoji,
            y: symbol,
            s: shareURL.absoluteString,
            k: kind == .countdown ? "c" : nil,
            h: kind == .countdown ? hasTime : nil
        )

        guard let data = try? encoder.encode(payload) else { return nil }
        components.path = "/\(kind.rawValue)/\(base64URLEncoded(data))/"
        if let photo, !photo.isEmpty {
            // base64url's alphabet is already query-safe.
            components.percentEncodedQuery = "\(photoQueryName)=\(base64URLEncoded(photo))"
        }
        return components.url
    }

    /// The token of `https://www.icloud.com/share/<token>#<title>`. The
    /// `#<title>` fragment is dropped: CloudKit finds a share by its token, and
    /// the fragment is only a display hint.
    private static func shareToken(of url: URL) -> String? {
        let string = url.absoluteString
        guard string.hasPrefix(shareURLPrefix) else { return nil }
        let token = string.dropFirst(shareURLPrefix.count).prefix { $0 != "#" }
        return isShareToken(token) ? String(token) : nil
    }

    /// A JSON segment is never this short (its smallest payload is ~150
    /// characters), so the length alone tells the two shapes apart.
    private static func isShareToken(_ token: Substring) -> Bool {
        (10...64).contains(token.count) && token.unicodeScalars.allSatisfy(tokenAlphabet.contains)
    }

    // MARK: - Firestore invitations (1.1+)

    /// Path of a Firestore invitation (`/s/<token>/`), shared with Android and
    /// the website.
    static let firestorePath = "s"

    /// `https://calarmi.mathyusolutions.com/s/<token>/`. The trailing slash is
    /// the site's canonical form, as in `/i/`.
    static func make(token: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/\(firestorePath)/\(token)/"
        return components.url!
    }

    /// The token of a Firestore invitation link: `https://<host>/s/<token>/` or
    /// `calarm://s/<token>`. Nil for anything else, including a token with the
    /// wrong shape (the link arrives from outside the app).
    static func firestoreToken(from url: URL) -> String? {
        let segment: String?
        if url.scheme?.lowercased() == scheme {
            // In `calarm://s/<token>` the "s" parses as the host.
            guard url.host()?.lowercased() == firestorePath else { return nil }
            segment = url.pathComponents.first { $0 != "/" }
        } else {
            guard let urlHost = url.host(), urlHost == host || legacyHosts.contains(urlHost) else { return nil }
            let parts = url.path().split(separator: "/")
            guard parts.count >= 2, parts[0] == firestorePath else { return nil }
            segment = String(parts[1])
        }
        guard let segment, InviteToken.isValid(segment) else { return nil }
        return segment
    }

    // MARK: - Reading

    /// True when `url` is one of our invitation links, in any shape, so the
    /// app can claim it without trying to decode every URL it's handed.
    static func isInvite(_ url: URL) -> Bool {
        dataSegment(of: url) != nil || firestoreToken(from: url) != nil
    }

    /// Whether an invitation link is for an alarm or a countdown.
    static func kind(of url: URL) -> Kind? {
        dataSegment(of: url)?.kind
    }

    /// The payload segment of an invitation URL, whichever door it came through:
    /// `https://<host>/i/<payload>/` or `calarm://i/<payload>/` (`c` for a
    /// countdown).
    private static func dataSegment(of url: URL) -> (segment: String, kind: Kind)? {
        if url.scheme?.lowercased() == scheme {
            // In `calarm://i/<payload>/` the "i" parses as the host.
            guard let kind = url.host().flatMap(Kind.init(rawValue:)),
                  let segment = url.pathComponents.first(where: { $0 != "/" }) else { return nil }
            return (segment, kind)
        }
        guard let urlHost = url.host(), urlHost == host || legacyHosts.contains(urlHost) else { return nil }
        let parts = url.path().split(separator: "/")
        guard parts.count >= 2, let kind = Kind(rawValue: String(parts[0])) else { return nil }
        return (String(parts[1]), kind)
    }

    /// Recovers the CloudKit share URL from an incoming invitation link.
    ///
    /// Returns `nil` for anything malformed or for a payload pointing somewhere
    /// other than iCloud — the link arrives from outside the app, so it is not
    /// to be trusted.
    static func shareURL(from url: URL) -> URL? {
        guard let segment = dataSegment(of: url)?.segment else { return nil }

        // A token can't escape iCloud's prefix: its alphabet has no `/`, `?`,
        // `#` or `@`.
        if isShareToken(Substring(segment)) {
            return URL(string: shareURLPrefix + segment)
        }

        guard let data = base64URLDecoded(segment),
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

// MARK: - Preview for the website

/// What the invitation page needs that the rest of a shared payload doesn't
/// say. Stored, optional, in the root record's `payload` JSON
/// (`SharePayload.invitePreview`, `SharedCountdownPayload.invitePreview`), so
/// the website can draw a link that carries only the share token. Adding it
/// changed no CloudKit schema. Older apps ignore the key.
///
/// `src/lib/cloudkit.ts` in calarm-web reads it. Keep the field names in sync.
struct InvitePreview: Codable, Equatable {
    /// IANA zone of the sender, so the page shows the time they meant.
    var timeZone: String
    /// "es", "en" or "pt": the page's language.
    var language: String
    /// The color of the tile, `#RRGGBB`.
    var tintHex: String?
    /// The emoji drawn as the icon, when there is one.
    var emoji: String?
    /// Otherwise the SF Symbol name; the website draws a look-alike.
    var symbol: String?

    init(tintHex: String?, emoji: String?, symbol: String?) {
        self.timeZone = TimeZone.current.identifier
        self.language = InviteLink.pageLanguage()
        self.tintHex = tintHex
        self.emoji = emoji
        self.symbol = symbol
    }

    /// An alarm drawn the way the list draws it (`ReminderRowView`): its
    /// category's color (a custom category's too, not just the built-in tint)
    /// and its own icon. A photo is read from the payload, but the category's
    /// symbol goes along in case the photo can't be drawn.
    @MainActor
    init(reminder: Reminder, style: CategoryStyle) {
        let ownIcon = reminder.symbolName.flatMap { $0.isEmpty ? nil : $0 }
        let categorySymbol = style.iconKind == .symbol ? style.iconValue : "bell.fill"
        let symbol: String? = switch reminder.iconKind {
        case .emoji: nil
        case .symbol: ownIcon ?? categorySymbol
        case .photo: categorySymbol
        }
        self.init(
            tintHex: style.color.toHex(),
            emoji: reminder.iconKind == .emoji ? (ownIcon ?? "⭐️") : nil,
            symbol: symbol
        )
    }

    /// A countdown: its color and its emoji or symbol.
    init(countdown event: CountdownEvent) {
        self.init(
            tintHex: event.colorHex,
            emoji: event.iconKind == .emoji && isEmojiIcon(event.iconValue) ? event.iconValue : nil,
            symbol: event.iconKind == .symbol ? event.iconValue : nil
        )
    }
}
