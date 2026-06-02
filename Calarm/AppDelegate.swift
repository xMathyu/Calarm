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
    /// Posted when a silent CloudKit push says the shared database changed (owner
    /// edited/deleted a shared reminder), so the recipient should re-sync.
    static let calarmSharedDataChanged = Notification.Name("CalarmSharedDataChanged")
    /// Posted by code paths that create/edit reminders outside the main editor
    /// (e.g. the AI assistant tools) so delegation can mirror the change up.
    static let calarmLocalRemindersChanged = Notification.Name("CalarmLocalRemindersChanged")
    /// Posted when a reminder is deleted outside the main editor; `object` is the
    /// deleted reminder's UUID, so delegation can remove its zone record.
    static let calarmReminderDeleted = Notification.Name("CalarmReminderDeleted")
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
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Needed to receive CloudKit's silent push when a shared reminder changes.
        application.registerForRemoteNotifications()
        return true
    }

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

    /// Silent CloudKit push: the shared database changed. Ask the app to re-sync.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        PendingShare.log.info("Remote notification (CloudKit) received")
        ShareDiagnostics.log("🔔 push CloudKit recibido")
        NotificationCenter.default.post(name: .calarmSharedDataChanged, object: nil)
        completionHandler(.newData)
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
