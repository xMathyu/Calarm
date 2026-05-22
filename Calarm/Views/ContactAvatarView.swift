//
//  ContactAvatarView.swift
//  Calarm
//

import SwiftUI
import UIKit

struct ContactAvatarView: View {
    let name: String
    let imageData: Data?
    var size: CGFloat = 44
    var showsRing: Bool = false

    var body: some View {
        ZStack {
            if let data = imageData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(gradient)
                    .frame(width: size, height: size)
                    .overlay(
                        Text(initials)
                            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    )
            }
        }
        .overlay {
            if showsRing {
                Circle()
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
                    .frame(width: size, height: size)
            }
        }
    }

    private var initials: String {
        let parts = name
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
            .map(String.init)
        let joined = parts.joined().uppercased()
        return joined.isEmpty ? "?" : joined
    }

    private var gradient: LinearGradient {
        let base = Self.color(for: name)
        return LinearGradient(
            colors: [base.opacity(0.95), base.opacity(0.65)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func color(for name: String) -> Color {
        let palette: [Color] = [
            .red, .orange, .yellow, .green, .mint, .teal,
            .cyan, .blue, .indigo, .purple, .pink, .brown
        ]
        var hash: UInt64 = 5381
        for byte in name.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

#Preview {
    HStack(spacing: 16) {
        ContactAvatarView(name: "Ana Martínez", imageData: nil)
        ContactAvatarView(name: "Bob Pérez", imageData: nil, size: 56)
        ContactAvatarView(name: "Caro López", imageData: nil, size: 32)
        ContactAvatarView(name: "Caro López", imageData: nil, size: 56, showsRing: true)
    }
    .padding()
}
