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
                        body: Self.messageBody(title: invite.title, url: invite.url)
                    ) { showingMessages = false }
                }
            }
            // Fallback: generic share sheet (AirDrop, Mail, WhatsApp, etc.).
            .sheet(isPresented: $showingFallback, onDismiss: finish) {
                if let invite = delivery {
                    ShareLink(
                        item: invite.url,
                        message: Text("Te invito a '\(invite.title)' en Calarm")
                    )
                    .padding()
                }
            }
    }

    private func finish() {
        delivery = nil
        onFinish()
    }

    /// Localized invite text for the Messages body. The link goes on its own
    /// line so iMessage/Mail render the rich preview.
    static func messageBody(title: String, url: URL) -> String {
        appLocalized("Te invito a '\(title)' en Calarm") + "\n" + url.absoluteString
    }
}
