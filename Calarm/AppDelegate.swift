//
//  AppDelegate.swift
//  Calarm
//

import CloudKit
import UIKit
import os

extension Notification.Name {
    /// Posted when the user accepts a CloudKit share invitation. The notification's
    /// `object` is the `CKShare.Metadata` to ingest.
    static let calarmDidAcceptShare = Notification.Name("CalarmDidAcceptShare")
}

/// Handles system callbacks that SwiftUI scenes cannot intercept directly —
/// notably CloudKit share acceptance when the user taps an invitation link.
///
/// Acceptance is handed off via `NotificationCenter` rather than an `@Observable`
/// counter: `@UIApplicationDelegateAdaptor` does not reliably drive SwiftUI's
/// `.onChange` for `@Observable` delegates, which would silently drop the share.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static let log = Logger(subsystem: "MathyuSolutions.Calarm", category: "sharing")

    /// The most recent accepted-share metadata, kept until the UI ingests it.
    /// Read on launch in case acceptance arrived before any view subscribed to
    /// the notification (e.g. a cold launch straight from the invite link).
    private(set) var pendingShareMetadata: CKShare.Metadata?

    func application(
        _ application: UIApplication,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        Self.log.info("userDidAcceptCloudKitShareWith fired (app delegate)")
        pendingShareMetadata = cloudKitShareMetadata
        NotificationCenter.default.post(name: .calarmDidAcceptShare, object: cloudKitShareMetadata)
    }

    func clearPendingShareMetadata() {
        pendingShareMetadata = nil
    }
}
