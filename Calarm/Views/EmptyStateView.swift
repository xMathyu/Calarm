//
//  EmptyStateView.swift
//  Calarm
//

import SwiftUI

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    @State private var animate = false

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .symbolEffect(.bounce, options: .nonRepeating, value: animate)
            }
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button {
                    Haptics.light()
                    action()
                } label: {
                    Text(actionTitle)
                        .padding(.horizontal, DS.Spacing.sm)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .onAppear {
            // Trigger the symbol effect once on appear.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { animate.toggle() }
        }
    }
}
