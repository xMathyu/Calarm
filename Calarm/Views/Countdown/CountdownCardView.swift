//
//  CountdownCardView.swift
//  Calarm
//
//  La tarjeta de una cuenta regresiva: la foto de fondo (o el color con el
//  emoji/símbolo), el nombre, la fecha y, grande, los días que faltan. La misma
//  tarjeta sirve de vista previa en el editor.
//

import SwiftUI

/// Lo que pinta la tarjeta, sacado del modelo para que el editor pueda
/// enseñar un borrador que todavía no está guardado.
struct CountdownCardContent {
    var id: UUID
    var title: String
    var date: Date
    var includesTime: Bool
    var repeatsYearly: Bool
    var color: Color
    var iconKind: ReminderIconKind
    var iconValue: String
    var photoData: Data?
    /// Llegó por una invitación: la fecha lleva el icono de compartida.
    var isReceivedShare: Bool = false

    func target(now: Date) -> Date {
        CountdownMath.target(date: date, includesTime: includesTime, repeatsYearly: repeatsYearly, now: now)
    }

    func status(now: Date) -> CountdownStatus {
        CountdownMath.status(to: target(now: now), now: now)
    }

    /// La foto solo cuando el icono elegido es la foto.
    var backgroundPhoto: Data? { iconKind == .photo ? photoData : nil }
}

extension CountdownEvent {
    var cardContent: CountdownCardContent {
        CountdownCardContent(
            id: id,
            title: title,
            date: date,
            includesTime: includesTime,
            repeatsYearly: repeatsYearly,
            color: color,
            iconKind: iconKind,
            iconValue: iconValue,
            photoData: photoData,
            isReceivedShare: isReceivedShare
        )
    }
}

struct CountdownCardView: View {
    let content: CountdownCardContent
    let now: Date

    private var photo: UIImage? {
        content.backgroundPhoto.flatMap { CountdownPhoto.image(for: $0, key: content.id) }
    }

    var body: some View {
        let photo = photo
        let status = content.status(now: now)
        HStack(alignment: photo == nil ? .center : .bottom, spacing: DS.Spacing.md) {
            if photo == nil {
                CountdownIconTile(content: content, size: 52)
            }
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(content.title.isEmpty ? appLocalized("Nuevo evento") : content.title)
                    .font(.headline)
                    .lineLimit(2)
                CountdownDateLabel(content: content, now: now)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer(minLength: DS.Spacing.sm)
            CountdownCounter(status: status, numberSize: 42)
        }
        .foregroundStyle(.white)
        .padding(DS.Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: photo == nil ? 96 : 156, alignment: photo == nil ? .leading : .bottomLeading)
        .background {
            CountdownBackground(content: content, photo: photo)
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous))
        // Los pasados se ven apagados, para que lo próximo resalte.
        .saturation(status.isPast ? 0.35 : 1)
        .opacity(status.isPast ? 0.85 : 1)
        .accessibilityElement(children: .combine)
    }
}

/// El fondo compartido por la tarjeta y el detalle.
struct CountdownBackground: View {
    let content: CountdownCardContent
    let photo: UIImage?

    var body: some View {
        if let photo {
            Color.clear
                .overlay {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
                // Oscurece la parte de abajo, donde va el texto blanco.
                .overlay {
                    LinearGradient(
                        colors: [.black.opacity(0.05), .black.opacity(0.2), .black.opacity(0.65)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
        } else {
            LinearGradient(
                colors: [content.color.mix(with: .white, by: 0.12), content.color.mix(with: .black, by: 0.3)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

/// El emoji o símbolo sobre un cuadro translúcido.
struct CountdownIconTile: View {
    let content: CountdownCardContent
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(.white.opacity(0.22))
            switch content.iconKind {
            case .emoji:
                Text(isEmojiIcon(content.iconValue) ? content.iconValue : CountdownEvent.defaultEmoji)
                    .font(.system(size: size * 0.56))
            case .symbol, .photo:
                // Sin foto todavía: el símbolo de calendario ocupa su lugar.
                Image(systemName: content.iconKind == .symbol && !isEmojiIcon(content.iconValue)
                      ? content.iconValue : "calendar")
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// «sáb, 15 nov 2026 · 21:00», y el símbolo de repetir si vuelve cada año.
struct CountdownDateLabel: View {
    let content: CountdownCardContent
    let now: Date

    var body: some View {
        let target = content.target(now: now)
        HStack(spacing: DS.Spacing.xs) {
            if content.isReceivedShare {
                Image(systemName: "person.2.fill")
                    .font(.caption.weight(.bold))
                    .accessibilityLabel(Text("Compartida contigo"))
            }
            if content.repeatsYearly {
                Image(systemName: "repeat")
                    .font(.caption.weight(.bold))
                    .accessibilityLabel(Text("Cada año"))
            }
            if content.includesTime {
                Text(target, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).year().hour().minute())
            } else {
                Text(target, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

/// El número grande de días y su unidad, o «¡Hoy!».
struct CountdownCounter: View {
    let status: CountdownStatus
    var numberSize: CGFloat

    var body: some View {
        switch status {
        case .today:
            Text("¡Hoy!")
                .font(.system(size: numberSize * 0.6, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        case .upcoming(let days):
            stack(days: days, unit: days == 1 ? appLocalized("día") : appLocalized("días"))
        case .past(let days):
            stack(days: days, unit: days == 1 ? appLocalized("día atrás") : appLocalized("días atrás"))
        }
    }

    private func stack(days: Int, unit: String) -> some View {
        VStack(spacing: -2) {
            Text(days, format: .number)
                .font(.system(size: numberSize, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText(value: Double(days)))
            Text(unit)
                .font(.system(size: max(11, numberSize * 0.3), weight: .bold, design: .rounded))
                .textCase(.uppercase)
                .opacity(0.9)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
