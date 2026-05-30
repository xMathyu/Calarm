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
/// SwiftUI apps are scene-based, and iOS delivers share acceptance to the *scene*
/// delegate (`windowScene(_:userDidAcceptCloudKitShareWith:)`); the app-delegate
/// callback frequently never fires. We therefore install `ShareSceneDelegate` and
/// route everything through `receiveAcceptedShare`, which both stores the metadata
/// (for a cold launch before the UI is ready) and posts `.calarmDidAcceptShare`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static let log = Logger(subsystem: "MathyuSolutions.Calarm", category: "sharing")

    /// Most recent accepted-share metadata, kept until the UI ingests it. Read on
    /// launch in case acceptance arrived before any view subscribed to the
    /// notification (e.g. a cold launch straight from the invite link).
    private(set) var pendingShareMetadata: CKShare.Metadata?

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = ShareSceneDelegate.self
        return config
    }

    /// Fallback for the rare case iOS routes acceptance to the app delegate.
    func application(
        _ application: UIApplication,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        receiveAcceptedShare(cloudKitShareMetadata, source: "appDelegate")
    }

    func receiveAcceptedShare(_ metadata: CKShare.Metadata, source: String) {
        Self.log.info("Accepted CloudKit share via \(source, privacy: .public)")
        pendingShareMetadata = metadata
        NotificationCenter.default.post(name: .calarmDidAcceptShare, object: metadata)
    }

    func clearPendingShareMetadata() {
        pendingShareMetadata = nil
    }
}

/// Scene delegate whose sole job is to capture CloudKit share acceptance. It
/// deliberately does NOT create or assign a `UIWindow` — SwiftUI's `WindowGroup`
/// keeps full ownership of rendering, so adding this delegate is non-destructive.
final class ShareSceneDelegate: NSObject, UIWindowSceneDelegate {
    private var appDelegate: AppDelegate? { UIApplication.shared.delegate as? AppDelegate }

    /// Cold launch: the app was opened directly from the invitation link.
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            appDelegate?.receiveAcceptedShare(metadata, source: "scene-cold")
        }
    }

    /// App already running or backgrounded when the user taps "Open".
    func windowScene(
        _ windowScene: UIWindowScene,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        appDelegate?.receiveAcceptedShare(cloudKitShareMetadata, source: "scene")
    }
}
