//
//  DesignSystem.swift
//  Calarm
//
//  Central design tokens — spacing, radii, animation presets, and reusable
//  modifiers. Use these instead of magic numbers throughout the UI so the look
//  stays consistent and is easy to tune globally.
//

import SwiftUI

enum DS {

    // MARK: - Spacing
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    // MARK: - Corner radii
    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let pill: CGFloat = 999
    }

    // MARK: - Avatar sizes
    enum AvatarSize {
        static let xs: CGFloat = 28
        static let sm: CGFloat = 32
        static let md: CGFloat = 44
        static let lg: CGFloat = 56
        static let xl: CGFloat = 72
        static let hero: CGFloat = 120
    }

    // MARK: - Motion
    enum Motion {
        static let snappy: Animation = .spring(response: 0.3, dampingFraction: 0.8)
        static let smooth: Animation = .spring(response: 0.4, dampingFraction: 0.85)
        static let bouncy: Animation = .spring(response: 0.35, dampingFraction: 0.65)
        static let quick: Animation = .easeOut(duration: 0.18)
    }
}

// MARK: - Color tokens

extension Color {
    /// Adaptive card surface — slightly elevated from background.
    static var dsCard: Color { Color(.secondarySystemGroupedBackground) }

    /// Subtle separator/divider line.
    static var dsDivider: Color { Color(.separator) }

    /// Soft surface tint, e.g. for chip backgrounds.
    static var dsFill: Color { Color(.tertiarySystemFill) }
}

// MARK: - Press-feedback button style

/// Plain-looking button that scales slightly on press and plays a light haptic.
/// Use for any button-as-row-or-card where the default plain style feels dead.
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    var haptic: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(DS.Motion.quick, value: configuration.isPressed)
            .sensoryFeedback(.selection, trigger: configuration.isPressed) { _, isPressed in
                haptic && isPressed
            }
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

// MARK: - Common modifiers

private struct CardSurfaceModifier: ViewModifier {
    var padding: CGFloat = DS.Spacing.lg

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color.dsCard, in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
    }
}

extension View {
    /// Wraps the content in a rounded card surface — useful outside of `Form` rows.
    func cardSurface(padding: CGFloat = DS.Spacing.lg) -> some View {
        modifier(CardSurfaceModifier(padding: padding))
    }
}

// MARK: - Hero icon used in onboarding / permission screens

struct HeroIcon: View {
    let systemName: String
    var tint: Color = .accentColor
    var size: CGFloat = DS.AvatarSize.hero

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.28), tint.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.bounce, options: .nonRepeating)
        }
    }
}
