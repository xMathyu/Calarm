//
//  ContactInviteFlow.swift
//  Calarm
//
//  Shared "send the invite link" delivery used by the alarm editor
//  (ReminderEditorView) and by trusted-helper invites (DelegationSettingsView),
//  so the invite experience and wording are identical. Prepare a `CKShare`,
//  then drive this to open the system share sheet with the link: the user picks
//  where to send it (WhatsApp, Instagram, Messages, Mail, AirDrop…) and who to
//  send it to inside that app.
//

import SwiftUI
import UIKit

/// One invitation ready to be delivered: the prepared share link plus the
/// reminder title for the message.
struct InviteDelivery: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let url: URL
    /// Already-localized intro; when nil the standard
    /// "Te invito a '<title>' en Calarm" wording is used.
    var customMessage: String? = nil
}

extension View {
    /// Drives the shared "send the share link" experience through the system
    /// share sheet.
    ///
    /// Set `delivery` to a non-nil value to start; `onFinish` runs once the user
    /// sends the link or closes the share sheet (e.g. to dismiss the editor or
    /// to refresh who has access).
    func inviteDelivery(_ delivery: Binding<InviteDelivery?>, onFinish: @escaping () -> Void = {}) -> some View {
        modifier(InviteDeliveryModifier(delivery: delivery, onFinish: onFinish))
    }
}

private struct InviteDeliveryModifier: ViewModifier {
    @Binding var delivery: InviteDelivery?
    let onFinish: () -> Void

    /// Finds the window this view lives in, so the sheet opens in the right
    /// window on iPad.
    @State private var anchor = ShareSheetAnchor()

    func body(content: Content) -> some View {
        content
            .background(ShareSheetAnchorView(anchor: anchor))
            .onChange(of: delivery?.id) { _, newID in
                guard newID != nil, let invite = delivery else { return }
                present(invite)
            }
    }

    /// Opens the share sheet directly from UIKit. SwiftUI's `ShareLink` needs
    /// the user to tap it, but here the link only exists after the share has
    /// been prepared in CloudKit.
    private func present(_ invite: InviteDelivery) {
        guard let presenter = anchor.topViewController() else {
            finish()
            return
        }
        // Text first and the link as its own item: Messages and WhatsApp put
        // the text above the link and build the preview from the link.
        let controller = UIActivityViewController(
            activityItems: [InviteTextItem(invite: invite), invite.url],
            applicationActivities: nil
        )
        controller.excludedActivityTypes = [
            .addToReadingList, .assignToContact, .openInIBooks,
            .print, .saveToCameraRoll, .markupAsPDF,
        ]
        controller.completionWithItemsHandler = { _, _, _, _ in finish() }
        // iPad shows the sheet as a popover; center it without an arrow.
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        presenter.present(controller, animated: true)
    }

    private func finish() {
        delivery = nil
        onFinish()
    }
}

// MARK: - Message text

/// The text that goes with the link. Also gives Mail a subject.
private final class InviteTextItem: NSObject, UIActivityItemSource {
    let invite: InviteDelivery

    init(invite: InviteDelivery) { self.invite = invite }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        ""
    }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        Self.message(for: invite)
    }

    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        Self.intro(for: invite)
    }

    private static func intro(for invite: InviteDelivery) -> String {
        invite.customMessage ?? appLocalized("Te invito a '\(invite.title)' en Calarmi")
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
        return appLocalized("¿No tienes Calarmi? Descárgala aquí:") + "\n" + AppLinks.appStore.absoluteString
    }

    /// The link travels as its own share item, so only the wording goes here.
    static func message(for invite: InviteDelivery) -> String {
        var body = intro(for: invite)
        if let hint = installHint(for: invite) { body += "\n\n" + hint }
        return body
    }
}

// MARK: - Presenting from UIKit

/// Holds a view that sits behind the SwiftUI content, used to reach its window.
private final class ShareSheetAnchor {
    weak var view: UIView?

    /// The controller on top of this view's window (e.g. the editor sheet),
    /// which is the one that can present the share sheet.
    func topViewController() -> UIViewController? {
        let window = view?.window ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

private struct ShareSheetAnchorView: UIViewRepresentable {
    let anchor: ShareSheetAnchor

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        anchor.view = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        anchor.view = uiView
    }
}
