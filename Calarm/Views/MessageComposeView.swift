//
//  MessageComposeView.swift
//  Calarm
//

import MessageUI
import SwiftUI

/// Wraps MFMessageComposeViewController so SwiftUI can present it as a sheet.
/// Recipients and body are pre-filled; the user only needs to tap Send.
struct MessageComposeView: UIViewControllerRepresentable {
    let recipients: [String]
    let body: String
    var onDismiss: () -> Void = {}

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.recipients = recipients
        vc.body = body
        vc.messageComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        var onDismiss: () -> Void
        init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }

        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            onDismiss()
        }
    }
}
