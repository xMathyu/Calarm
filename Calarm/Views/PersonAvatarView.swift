//
//  PersonAvatarView.swift
//  Calarm
//
//  A circular avatar for a person in a share: their Contacts photo when available,
//  otherwise a tinted circle with their initials.
//

import SwiftUI
import UIKit

struct PersonAvatarView: View {
    let name: String
    var email: String?
    var phone: String?
    var size: CGFloat = 36

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.appAccent, Color.appAccent.opacity(0.65)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        Text(initials)
                            .font(.system(size: size * 0.4, weight: .semibold))
                            .foregroundStyle(.white)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: "\(email ?? "")|\(phone ?? "")") {
            await ContactPhotoProvider.shared.requestAccessIfNeeded()
            if let data = await ContactPhotoProvider.shared.thumbnailData(email: email, phone: phone) {
                image = UIImage(data: data)
            }
        }
    }

    private var initials: String {
        let letters = name
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
            .map(String.init)
            .joined()
            .uppercased()
        return letters.isEmpty ? "?" : letters
    }
}
