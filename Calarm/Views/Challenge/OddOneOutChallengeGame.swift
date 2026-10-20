//
//  OddOneOutChallengeGame.swift
//  Calarm
//

import SwiftUI

/// Una cuadrícula llena del mismo emoji salvo una casilla, que lleva otro muy
/// parecido. Hay que tocarla ronda tras ronda; cuanto más difícil, más casillas
/// y más rondas. Un fallo deja la misma ronda y bloquea un instante los toques,
/// para que no valga ir probando a toda prisa.
struct OddOneOutChallengeGame: View {
    let difficulty: WakeChallenge.Difficulty
    let onSolved: () -> Void

    @State private var round = 1
    /// El emoji que se repite y el que se cuela.
    @State private var common = ""
    @State private var odd = ""
    @State private var oddIndex = 0
    /// La casilla tocada por error; mientras parpadea en rojo se ignoran los toques.
    @State private var wrongIndex: Int?
    @State private var solved = false

    /// Parejas que se confunden a simple vista. Se usan en cualquier orientación.
    private static let pairs: [(String, String)] = [
        ("😀", "😃"), ("🐶", "🐺"), ("🍎", "🍅"), ("🌝", "🌚"), ("⚽️", "🏐"),
        ("🟢", "🟩"), ("🐱", "🐯"), ("🍪", "🥯"), ("🌷", "🌹"), ("🦋", "🐛"),
        ("🚗", "🚕"), ("🧁", "🍰"), ("🐭", "🐹"), ("🌙", "🌛"), ("🍊", "🍑"),
    ]

    private var totalRounds: Int {
        switch difficulty {
        case .easy: 4
        case .medium: 6
        case .hard: 8
        }
    }

    private var columns: Int {
        switch difficulty {
        case .easy: 3
        case .medium: 4
        case .hard: 5
        }
    }

    private var cellCount: Int { columns * columns }

    /// Más pequeño cuantas más columnas, para que el 5×5 quepa en 360 pt.
    private var emojiSize: CGFloat {
        switch difficulty {
        case .easy: 44
        case .medium: 38
        case .hard: 30
        }
    }

    var body: some View {
        VStack(spacing: DS.Spacing.lg) {
            Text(appLocalized("Ronda \(round) de \(totalRounds)"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            // El ZStack deja que la cuadrícula saliente y la entrante se solapen
            // durante la transición sin empujar el resto de la pantalla.
            ZStack {
                grid
                    .id(round)
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
            }
        }
        .onAppear(perform: start)
        .task(id: wrongIndex) { await clearWrong() }
    }

    // MARK: - Partes

    private var grid: some View {
        let layout = Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.sm), count: columns)
        return LazyVGrid(columns: layout, spacing: DS.Spacing.sm) {
            ForEach(0..<cellCount, id: \.self) { index in
                cell(index)
            }
        }
        .frame(maxWidth: 360)
    }

    private func cell(_ index: Int) -> some View {
        let wrong = wrongIndex == index
        let emoji = index == oddIndex ? odd : common
        return Button {
            tap(index)
        } label: {
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .fill(wrong ? Color.red.opacity(0.25) : Color(.secondarySystemBackground))
                .aspectRatio(1, contentMode: .fit)
                .overlay(
                    Text(verbatim: emoji)
                        .font(.system(size: emojiSize))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .strokeBorder(wrong ? Color.red : .clear, lineWidth: 2)
                )
                .animation(DS.Motion.quick, value: wrong)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: emoji))
    }

    // MARK: - Lógica

    private func start() {
        guard common.isEmpty else { return }
        newRound()
    }

    /// Elige una pareja distinta de la anterior, una orientación al azar y la
    /// posición del distinto.
    private func newRound() {
        let candidates = Self.pairs.filter { $0.0 != common && $0.1 != common }
        guard let pair = (candidates.isEmpty ? Self.pairs : candidates).randomElement() else { return }
        let flipped = Bool.random()
        common = flipped ? pair.1 : pair.0
        odd = flipped ? pair.0 : pair.1
        oddIndex = Int.random(in: 0..<cellCount)
        wrongIndex = nil
    }

    private func tap(_ index: Int) {
        guard !solved, wrongIndex == nil else { return }
        if index == oddIndex {
            if round >= totalRounds {
                solved = true
                onSolved()
            } else {
                Haptics.light()
                withAnimation(DS.Motion.snappy) {
                    round += 1
                    newRound()
                }
            }
        } else {
            Haptics.error()
            wrongIndex = index
        }
    }

    @MainActor
    private func clearWrong() async {
        guard wrongIndex != nil else { return }
        try? await Task.sleep(for: .milliseconds(350))
        if Task.isCancelled { return }
        // Cuadrícula nueva con la misma ronda: fallar no puede servir para ir
        // barriendo casillas hasta dar con la distinta.
        withAnimation(DS.Motion.snappy) { newRound() }
    }
}
