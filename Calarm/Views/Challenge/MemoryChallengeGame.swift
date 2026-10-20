//
//  MemoryChallengeGame.swift
//  Calarm
//

import SwiftUI

/// Un «Simón» en una cuadrícula de 3×3: se ilumina una secuencia de casillas y
/// hay que repetirla. Tres rondas, cada una con una casilla más.
struct MemoryChallengeGame: View {
    let difficulty: WakeChallenge.Difficulty
    let onSolved: () -> Void

    private enum Phase {
        case showing
        case input
    }

    @State private var sequence: [Int] = []
    @State private var round = 1
    /// Cambia en cada ronda y en cada repetición tras un fallo: reinicia la
    /// tarea que reproduce la secuencia.
    @State private var attempt = 0
    @State private var phase: Phase = .showing
    @State private var litTile: Int?
    @State private var inputCount = 0
    @State private var wrong = false

    private static let totalRounds = 3
    private static let tiles = 9

    private var startLength: Int {
        switch difficulty {
        case .easy: 3
        case .medium: 4
        case .hard: 5
        }
    }

    var body: some View {
        VStack(spacing: DS.Spacing.lg) {
            Text(appLocalized("Ronda \(round) de \(Self.totalRounds)"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            Text(statusText)
                .font(.headline)
                .foregroundStyle(wrong ? .red : .primary)
                .frame(minHeight: 24)

            grid
        }
        .task(id: attempt) { await playSequence() }
    }

    private var statusText: String {
        if wrong { return appLocalized("Secuencia incorrecta, mírala otra vez.") }
        switch phase {
        case .showing: return appLocalized("Observa la secuencia…")
        case .input: return appLocalized("Ahora repítela")
        }
    }

    private var grid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.sm), count: 3)
        return LazyVGrid(columns: columns, spacing: DS.Spacing.sm) {
            ForEach(0..<Self.tiles, id: \.self) { tile in
                Button {
                    tap(tile)
                } label: {
                    RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                        .fill(litTile == tile ? Color.accentColor : Color(.secondarySystemBackground))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(phase == .input ? 0.35 : 0.1), lineWidth: 1.5)
                        )
                        .animation(DS.Motion.quick, value: litTile)
                }
                .buttonStyle(.plain)
                .disabled(phase != .input)
                .accessibilityLabel(Text(String(tile + 1)))
            }
        }
        .frame(maxWidth: 360)
    }

    // MARK: - Lógica

    @MainActor
    private func playSequence() async {
        phase = .showing
        inputCount = 0
        litTile = nil
        if sequence.isEmpty {
            sequence = Self.makeSequence(length: startLength + round - 1)
        }
        try? await Task.sleep(for: .milliseconds(700))
        if Task.isCancelled { return }
        for tile in sequence {
            litTile = tile
            Haptics.soft()
            try? await Task.sleep(for: .milliseconds(520))
            if Task.isCancelled { return }
            litTile = nil
            try? await Task.sleep(for: .milliseconds(260))
            if Task.isCancelled { return }
        }
        withAnimation(DS.Motion.quick) { wrong = false }
        phase = .input
    }

    private func tap(_ tile: Int) {
        guard phase == .input, inputCount < sequence.count else { return }
        if sequence[inputCount] == tile {
            flash(tile)
            inputCount += 1
            if inputCount == sequence.count {
                phase = .showing
                if round >= Self.totalRounds {
                    onSolved()
                } else {
                    Haptics.light()
                    sequence = []
                    round += 1
                    attempt += 1
                }
            }
        } else {
            phase = .showing
            withAnimation(DS.Motion.quick) { wrong = true }
            Haptics.error()
            // Misma secuencia otra vez.
            attempt += 1
        }
    }

    private func flash(_ tile: Int) {
        litTile = tile
        Haptics.selection()
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            if litTile == tile { litTile = nil }
        }
    }

    /// Casillas al azar sin dos iguales seguidas, que serían ambiguas al verlas.
    private static func makeSequence(length: Int) -> [Int] {
        var result: [Int] = []
        while result.count < length {
            let next = Int.random(in: 0..<tiles)
            if next != result.last { result.append(next) }
        }
        return result
    }
}
