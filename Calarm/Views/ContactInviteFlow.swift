//
//  ContactInviteFlow.swift
//  Calarm
//
//  Shared "invite people via Messages" delivery used by the alarm editor
//  (ReminderEditorView), for both creating and sharing an existing alarm, so the
//  invite experience and wording are identical. Prepare a `CKShare`, then drive
//  this to open Messages with the link pre-filled — the user picks recipients
//  right in the Messages "To:" field, so there's a single sheet (no separate
//  contact picker step).
//

import MessageUI
import SwiftUI

/// One invitation ready to be delivered: the prepared share link plus the
/// reminder title for the message preview.
struct InviteDelivery: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let url: URL
    /// Already-localized Messages body; when nil the standard
    /// "Te invito a '<title>' en Calarm" wording is used.
    var customMessage: String? = nil
}

extension View {
    /// Drives the shared "send the share link via Messages, with a generic
    /// share-sheet fallback when Messages is unavailable" experience.
    ///
    /// Set `delivery` to a non-nil value to start; `onFinish` runs once the user
    /// closes Messages / the fallback sheet (e.g. to dismiss the editor or to
    /// refresh the detail view's share state).
    func inviteDelivery(_ delivery: Binding<InviteDelivery?>, onFinish: @escaping () -> Void = {}) -> some View {
        modifier(InviteDeliveryModifier(delivery: delivery, onFinish: onFinish))
    }
}

private struct InviteDeliveryModifier: ViewModifier {
    @Binding var delivery: InviteDelivery?
    let onFinish: () -> Void

    @State private var showingMessages = false
    @State private var showingFallback = false

    func body(content: Content) -> some View {
        content
            .onChange(of: delivery?.id) { _, newID in
                guard newID != nil else { return }
                // Open Messages when the device can send texts (recipients are
                // chosen right in Messages); otherwise the generic share sheet.
                if MFMessageComposeViewController.canSendText() {
                    showingMessages = true
                } else {
                    showingFallback = true
                }
            }
            // Messages pre-filled with the invite link — the user picks who to
            // send to in the "To:" field, then taps Enviar.
            .sheet(isPresented: $showingMessages, onDismiss: finish) {
                if let invite = delivery {
                    MessageComposeView(
                        recipients: [],
                        body: Self.messageBody(for: invite)
                    ) { showingMessages = false }
                }
            }
            // Fallback: generic share sheet (AirDrop, Mail, WhatsApp, etc.).
            .sheet(isPresented: $showingFallback, onDismiss: finish) {
                if let invite = delivery {
                    // The share sheet already carries the link as the item, so
                    // the message only needs the intro and the install hint.
                    ShareLink(
                        item: invite.url,
                        message: Text(verbatim: Self.fallbackMessage(for: invite))
                    )
                    .padding()
                }
            }
    }

    private func finish() {
        delivery = nil
        onFinish()
    }

    private static func intro(for invite: InviteDelivery) -> String {
        invite.customMessage ?? appLocalized("Te invito a '\(invite.title)' en Calarm")
    }

    /// Closes the invite for whoever doesn't have Calarm yet — a bare iCloud
    /// share link is a dead end without the app, and most invitations go to
    /// someone who has never installed it.
    ///
    /// A Calarm invitation link needs none of this: its own page already shows
    /// the alarm and offers the download. Appending it there would only put a
    /// second link in the message and spoil the preview, so it is added solely
    /// for the links that are still raw iCloud URLs (delegation invites, and
    /// the fallback when building our own link fails).
    private static func installHint(for invite: InviteDelivery) -> String? {
        guard !InviteLink.isInvite(invite.url) else { return nil }
        return appLocalized("¿No tienes Calarm? Descárgala aquí:") + "\n" + AppLinks.appStore.absoluteString
    }

    /// Localized invite text for the Messages body. Each link goes on its own
    /// line so iMessage/Mail render the rich preview.
    static func messageBody(for invite: InviteDelivery) -> String {
        var body = intro(for: invite) + "\n" + invite.url.absoluteString
        if let hint = installHint(for: invite) { body += "\n\n" + hint }
        return body
    }

    /// Body for the generic share sheet, which carries the link as its own item
    /// — so only the wording belongs here.
    private static func fallbackMessage(for invite: InviteDelivery) -> String {
        var body = intro(for: invite)
        if let hint = installHint(for: invite) { body += "\n\n" + hint }
        return body
    }
}
