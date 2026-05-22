//
//  KeyboardDismissOnTap.swift
//  Calarm
//

import SwiftUI
import UIKit

/// Adds a window-level tap recognizer that resigns the first responder on any
/// tap outside an active text field. Configured so it does NOT cancel touches
/// — buttons, scrolling, and other gestures continue to work as expected.
extension UIApplication {
    @MainActor
    func installGlobalKeyboardDismissGesture() {
        for scene in connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                let alreadyInstalled = window.gestureRecognizers?.contains {
                    $0.name == Self.dismissGestureName
                } ?? false
                guard !alreadyInstalled else { continue }

                let tap = UITapGestureRecognizer(target: window, action: #selector(UIView.endEditing))
                tap.name = Self.dismissGestureName
                tap.cancelsTouchesInView = false
                tap.requiresExclusiveTouchType = false
                tap.delegate = KeyboardDismissGestureDelegate.shared
                window.addGestureRecognizer(tap)
            }
        }
    }

    private static let dismissGestureName = "calarm.globalKeyboardDismiss"
}

private final class KeyboardDismissGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardDismissGestureDelegate()

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        // Don't intercept taps on interactive controls — let them handle their own taps.
        if touch.view is UIControl { return false }
        return true
    }
}
