//
//  ReminderIconView.swift
//  Calarm
//
//  Renders a reminder's (or category's) icon — an SF Symbol, an emoji, or a
//  photo — inside a tinted container. Centralizes the symbol/emoji/photo logic
//  so every surface (list, detail, editor, share thumbnail) stays consistent.
//

import SwiftUI
import UIKit

struct ReminderIconView: View {
    enum ContainerShape: Equatable {
        case circle
        case roundedRect(CGFloat)
    }

    let iconKind: ReminderIconKind
    /// SF Symbol name or emoji string, depending on `iconKind`.
    let iconValue: String?
    var photoData: Data? = nil
    /// SF Symbol shown when `iconValue` is missing/invalid for a symbol icon.
    var fallbackSymbol: String = "bell.fill"
    let tint: Color
    var size: CGFloat = DS.AvatarSize.md
    var shape: ContainerShape = .circle
    /// Flip to play a one-shot bounce (e.g. bound to a reminder's enabled state).
    var bounceValue: Bool = false

    var body: some View {
        ZStack {
            background
            content
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var background: some View {
        let gradient = LinearGradient(
            colors: [tint.opacity(0.28), tint.opacity(0.12)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        switch shape {
        case .circle:
            Circle().fill(gradient)
        case .roundedRect(let radius):
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(gradient)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch iconKind {
        case .photo:
            if let data = photoData, let img = UIImage(data: data) {
                photo(img)
            } else {
                symbol
            }
        case .emoji:
            Text(displayEmoji)
                .font(.system(size: size * 0.5))
                .minimumScaleFactor(0.5)
        case .symbol:
            symbol
        }
    }

    private var symbol: some View {
        Image(systemName: resolvedSymbol)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(tint)
            .symbolEffect(.bounce, options: .nonRepeating, value: bounceValue)
    }

    @ViewBuilder
    private func photo(_ img: UIImage) -> some View {
        let image = Image(uiImage: img)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
        switch shape {
        case .circle:
            image.clipShape(Circle())
        case .roundedRect(let radius):
            image.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }

    private var resolvedSymbol: String {
        if iconKind == .symbol, let value = iconValue, !value.isEmpty { return value }
        return fallbackSymbol
    }

    private var displayEmoji: String {
        if let value = iconValue, !value.isEmpty { return value }
        return "⭐️"
    }
}
