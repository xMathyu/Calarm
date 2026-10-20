//
//  PairsChallengeGame.swift
//  Calarm
//

import SwiftUI

/// El clásico juego de memoria con cartas: parejas de emojis boca abajo que se
/// levantan de dos en dos. Las que coinciden se quedan a la vista; las que no,
/// vuelven a taparse. Se acaba cuando no queda ninguna carta boca abajo.
struct PairsChallengeGame: View {
    let difficulty: WakeChallenge.Difficulty
    let onSolved: () -> Void

    private struct Card: Identifiable, Equatable {
        let id: Int
        let emoji: String
    }

    @State private var cards: [Card] = []
    /// Cartas levantadas, incluidas las ya emparejadas.
    @State private var faceUp: Set<Int> = []
    @State private var matched: Set<Int> = []
    /// La primera carta del intento en curso, si ya hay una levantada.
    @State private var firstPick: Int?
    /// Las dos cartas que no coincidieron: mientras esperan para taparse se
    /// ignoran los toques.
    @State private var mismatch: [Int] = []
    @State private var solved = false

    private static let pool = [
        "🌞", "🍳", "☕️", "🐣", "🚀", "🎧", "🧠", "🏃‍♀️",
        "🍋", "🪐", "🎸", "🧃", "🌈", "🦄", "🍩", "🛼",
    ]

    private var pairCount: Int {
        switch difficulty {
        case .easy: 3
        case .medium: 4
        case .hard: 6
        }
    }

    private var columns: Int {
        difficulty == .easy ? 3 : 4
    }

    private var emojiSize: CGFloat {
        difficulty == .easy ? 44 : 36
    }

    var body: some View {
        VStack(spacing: DS.Spacing.lg) {
            Text(appLocalized("Parejas \(matched.count / 2) de \(pairCount)"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())

            grid
        }
        .onAppear(perform: start)
        .task(id: mismatch) { await resolveMismatch() }
    }

    // MARK: - Partes

    private var grid: some View {
        let layout = Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.sm), count: columns)
        return LazyVGrid(columns: layout, spacing: DS.Spacing.sm) {
            ForEach(cards) { card in
                cardView(card)
            }
        }
        .frame(maxWidth: 360)
    }

    private func cardView(_ card: Card) -> some View {
        let isFaceUp = faceUp.contains(card.id)
        let isMatched = matched.contains(card.id)
        return Button {
            tap(card)
        } label: {
            back
                .modifier(FlipEffect(angle: isFaceUp ? 180 : 0) {
                    front(card, matched: isMatched)
                })
                .aspectRatio(0.78, contentMode: .fit)
        }
        .buttonStyle(.plain)
        .disabled(isFaceUp)
        // Un botecito cuando la carta encuentra a su pareja.
        .phaseAnimator([1.0, 1.1], trigger: isMatched) { view, scale in
            view.scaleEffect(scale)
        } animation: { _ in
            DS.Motion.bouncy
        }
        .animation(DS.Motion.smooth, value: isFaceUp)
        .accessibilityLabel(isFaceUp ? Text(verbatim: card.emoji) : Text("Carta boca abajo"))
    }

    /// Dorso: tinte de acento con un destello discreto.
    private var back: some View {
        RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            )
    }

    private func front(_ card: Card, matched: Bool) -> some View {
        RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
            .fill(Color(.secondarySystemBackground))
            .overlay(
                Text(verbatim: card.emoji)
                    .font(.system(size: emojiSize))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .strokeBorder(
                        matched ? Color.accentColor : Color.accentColor.opacity(0.15),
                        lineWidth: matched ? 2 : 1
                    )
            )
    }

    // MARK: - Lógica

    private func start() {
        guard cards.isEmpty else { return }
        let chosen = Array(Self.pool.shuffled().prefix(pairCount))
        cards = (chosen + chosen).shuffled().enumerated().map { Card(id: $0.offset, emoji: $0.element) }
    }

    private func tap(_ card: Card) {
        guard !solved, mismatch.isEmpty, !faceUp.contains(card.id) else { return }
        Haptics.selection()
        faceUp.insert(card.id)

        guard let first = firstPick else {
            firstPick = card.id
            return
        }
        firstPick = nil
        if emoji(of: first) == card.emoji {
            Haptics.light()
            withAnimation(DS.Motion.snappy) {
                matched.formUnion([first, card.id])
            }
            if matched.count == cards.count {
                solved = true
                onSolved()
            }
        } else {
            mismatch = [first, card.id]
        }
    }

    private func emoji(of id: Int) -> String? {
        cards.first { $0.id == id }?.emoji
    }

    /// Deja ver las dos cartas un momento y las vuelve a tapar.
    @MainActor
    private func resolveMismatch() async {
        guard !mismatch.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(700))
        if Task.isCancelled { return }
        Haptics.error()
        faceUp.subtract(mismatch)
        mismatch = []
    }
}

/// Gira una carta sobre su eje vertical. Hasta 90° se ve el dorso (el contenido
/// modificado); a partir de ahí, el frente, girado otros 180° para que no salga
/// en espejo. Es `Animatable` para que el cambio de cara ocurra justo a mitad
/// de giro y no en un fundido.
private struct FlipEffect<Front: View>: ViewModifier, Animatable {
    var angle: Double
    private let front: () -> Front

    init(angle: Double, @ViewBuilder front: @escaping () -> Front) {
        self.angle = angle
        self.front = front
    }

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        ZStack {
            content
                .opacity(angle < 90 ? 1 : 0)
                .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            front()
                .opacity(angle < 90 ? 0 : 1)
                .rotation3DEffect(.degrees(angle - 180), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        }
    }
}
