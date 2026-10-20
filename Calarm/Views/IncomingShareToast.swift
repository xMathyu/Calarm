//
//  IncomingShareToast.swift
//  Calarm
//
//  The small banner at the top of the screen while an invitation someone sent
//  becomes an alarm on this list, and the confirmation right after. Driven by
//  `SharedRemindersService.incomingShare`; `ContentView` shows and dismisses it.
//

import SwiftUI

struct IncomingShareToast: View {
    let status: SharedRemindersService.IncomingShareStatus
    /// Tapping the confirmation opens the alarm it names.
    let onOpen: (UUID) -> Void

    var body: some View {
        Group {
            switch status {
            case .accepting:
                content
            case .accepted(let reminderID, _, _):
                Button {
                    onOpen(reminderID)
                } label: {
                    content
                }
                .buttonStyle(.pressable)
                .accessibilityHint(Text("Toca para abrirla"))
            }
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.top, DS.Spacing.sm)
    }

    private var content: some View {
        HStack(spacing: DS.Spacing.md) {
            icon
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.md)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                .strokeBorder(Color.dsDivider.opacity(0.5), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch status {
        case .accepting:
            ProgressView()
                .controlSize(.small)
        case .accepted:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .symbolEffect(.bounce, options: .nonRepeating)
        }
    }

    private var title: String {
        switch status {
        case .accepting:
            return appLocalized("Agregando la alarma compartida…")
        case .accepted(_, let title, _):
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? appLocalized("Alarma") : trimmed
            return appLocalized("«\(name)» ya está en tus alarmas")
        }
    }

    private var subtitle: String? {
        guard case .accepted(_, _, let ownerName) = status, let ownerName else { return nil }
        return appLocalized("Compartida por \(ownerName)")
    }
}

#Preview("Agregando") {
    IncomingShareToast(status: .accepting) { _ in }
}

#Preview("Agregada") {
    IncomingShareToast(status: .accepted(reminderID: UUID(), title: "Cumpleaños de mamá", ownerName: "Ana")) { _ in }
}
