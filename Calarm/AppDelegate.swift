//
//  AppDelegate.swift
//  Calarm
//

import CloudKit
import UIKit
import os

extension Notification.Name {
    /// Posted when a CloudKit share invitation's metadata is captured. The
    /// notification's `object` is the `CKShare.Metadata`.
    static let calarmDidAcceptShare = Notification.Name("CalarmDidAcceptShare")
}

/// Single, delegate-independent capture point for an incoming CloudKit share.
///
/// iOS delivers share metadata to SwiftUI apps inconsistently — sometimes via the
/// scene's `connectionOptions` (cold launch), sometimes `windowScene(_:userDidAccept…)`,
/// sometimes the app delegate. Every channel funnels here. We deliberately do NOT
/// route through `UIApplication.shared.delegate as? AppDelegate` (that returned nil
/// during cold-launch scene connection, silently dropping the metadata).
enum PendingShare {
    static let log = Logger(subsystem: "MathyuSolutions.Calarm", category: "sharing")

    /// Metadata awaiting accept/ingest. Read on launch by `CalarmApp`. Touched only
    /// on the main thread (delegate callbacks + the launch `.task`).
    nonisolated(unsafe) private(set) static var metadata: CKShare.Metadata?

    static func store(_ metadata: CKShare.Metadata, source: String) {
        log.info("Captured share metadata via \(source, privacy: .public)")
        ShareDiagnostics.log("📥 Invitación recibida (\(source))")
        self.metadata = metadata
        NotificationCenter.default.post(name: .calarmDidAcceptShare, object: metadata)
    }

    static func clear() { metadata = nil }
}

/// Installs the scene delegate (the only channel that reliably sees share metadata
/// on cold launch) and catches the app-delegate acceptance callback as a fallback.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = ShareSceneDelegate.self
        return config
    }

    func application(
        _ application: UIApplication,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        PendingShare.store(cloudKitShareMetadata, source: "appDelegate")
    }
}

/// Captures CloudKit share acceptance. Does NOT create a window — SwiftUI's
/// `WindowGroup` keeps full ownership of rendering.
final class ShareSceneDelegate: NSObject, UIWindowSceneDelegate {
    /// Cold launch: the app was opened directly from the invitation link.
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        ShareDiagnostics.log("🔌 scene conectada (share=\(connectionOptions.cloudKitShareMetadata != nil))")
        if let metadata = connectionOptions.cloudKitShareMetadata {
            PendingShare.store(metadata, source: "scene-cold")
        }
    }

    /// App already running or backgrounded when the user taps "Open".
    func windowScene(
        _ windowScene: UIWindowScene,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        PendingShare.store(cloudKitShareMetadata, source: "scene")
    }
}
