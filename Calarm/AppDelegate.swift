//
//  AppDelegate.swift
//  Calarm
//

import CloudKit
import Observation
import UIKit

/// Handles system callbacks that SwiftUI scenes cannot intercept directly —
/// notably CloudKit share acceptance when the user taps an invitation link.
@Observable
final class AppDelegate: NSObject, UIApplicationDelegate {
    var acceptedShareVersion: Int = 0
    var pendingShareMetadata: CKShare.Metadata?

    func application(
        _ application: UIApplication,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        pendingShareMetadata = cloudKitShareMetadata
        acceptedShareVersion += 1
    }
}
