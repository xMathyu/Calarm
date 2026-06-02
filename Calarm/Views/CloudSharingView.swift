//
//  CloudSharingView.swift
//  Calarm
//

import CloudKit
import SwiftUI
import UIKit

/// SwiftUI wrapper for `UICloudSharingController`.
/// Present as a sheet after obtaining a prepared `CKShare` from `SharedRemindersService.prepareShare(for:)`.
struct CloudSharingView: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    /// Permissions offered in the share UI. Reminder shares are read-only; the
    /// delegation share needs read/write so trusted helpers can edit the list.
    var availablePermissions: UICloudSharingController.PermissionOptions = [.allowPrivate, .allowReadOnly]
    var onDismiss: () -> Void = {}

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.delegate = context.coordinator
        controller.availablePermissions = availablePermissions
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        var onDismiss: () -> Void
        init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            onDismiss()
        }

        func itemTitle(for csc: UICloudSharingController) -> String? { nil }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            onDismiss()
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            onDismiss()
        }
    }
}
