//
//  MathChallengeGame.swift
//  Calarm
//

import SwiftUI

/// Tres operaciones seguidas, con teclado numérico propio: nada de autocorrector
/// ni de teclado del sistema que tape el problema.
struct MathChallengeGame: View {
    let difficulty: WakeChallenge.Difficulty
    let onSolved: () -> Void

    @State private var problems: [MathProblem] = []
    @State private var index = 0
    @State private var input = ""
    @State private var wrong = false

    private static let total = 3

    var body: some View {
        VStack(spacing: DS.Spacing.lg) {
            Text(appLocalized("Problema \(index + 1) de \(Self.total)"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            VStack(spacing: DS.Spacing.sm) {
                Text(problems.indices.contains(index) ? problems[index].text : "")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(input.isEmpty ? "?" : input)
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(input.isEmpty ? .secondary : .primary)
                    .frame(minHeight: 48)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                            .strokeBorder(wrong ? Color.red : .clear, lineWidth: 2)
                    )
            }

            Text("Incorrecto, inténtalo otra vez.")
                .font(.footnote)
                .foregroundStyle(.red)
                .opacity(wrong ? 1 : 0)
                .accessibilityHidden(!wrong)

            keypad
        }
        .onAppear(perform: start)
    }

    private var keypad: some View {
        let keys: [[Key]] = [
            [.digit(1), .digit(2), .digit(3)],
            [.digit(4), .digit(5), .digit(6)],
            [.digit(7), .digit(8), .digit(9)],
            [.delete, .digit(0), .check],
        ]
        return VStack(spacing: DS.Spacing.sm) {
            ForEach(keys.indices, id: \.self) { row in
                HStack(spacing: DS.Spacing.sm) {
                    ForEach(keys[row], id: \.self) { key in
                        keyButton(key)
                    }
                }
            }
        }
    }

    private enum Key: Hashable {
        case digit(Int)
        case delete
        case check
    }

    @ViewBuilder
    private func keyButton(_ key: Key) -> some View {
        Button {
            tap(key)
        } label: {
            Group {
                switch key {
                case .digit(let d): Text(String(d))
                case .delete: Image(systemName: "delete.left")
                case .check: Image(systemName: "checkmark")
                }
            }
            .font(.title2.weight(.semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 56)
        }
        .buttonStyle(.bordered)
        .tint(key == .check ? .green : .secondary)
        .disabled(key == .check && input.isEmpty)
        .accessibilityLabel(accessibilityLabel(for: key))
    }

    private func accessibilityLabel(for key: Key) -> Text {
        switch key {
        case .digit(let d): Text(String(d))
        case .delete: Text("Borrar")
        case .check: Text("Comprobar")
        }
    }

    // MARK: - Lógica

    private func start() {
        guard problems.isEmpty else { return }
        problems = (0..<Self.total).map { _ in MathProblem.random(difficulty) }
    }

    private func tap(_ key: Key) {
        switch key {
        case .digit(let d):
            guard input.count < 6 else { return }
            withAnimation(DS.Motion.quick) { wrong = false }
            input += String(d)
            Haptics.selection()
        case .delete:
            guard !input.isEmpty else { return }
            input.removeLast()
            Haptics.selection()
        case .check:
            check()
        }
    }

    private func check() {
        guard problems.indices.contains(index), let answer = Int(input) else { return }
        if answer == problems[index].answer {
            input = ""
            wrong = false
            if index + 1 >= Self.total {
                onSolved()
            } else {
                Haptics.light()
                withAnimation(DS.Motion.snappy) { index += 1 }
            }
        } else {
            input = ""
            withAnimation(DS.Motion.quick) { wrong = true }
            Haptics.error()
        }
    }
}

/// Una operación con su resultado. Los operandos se eligen para que el resultado
/// sea siempre un entero no negativo, así el teclado no necesita signo menos.
struct MathProblem: Equatable {
    let text: String
    let answer: Int

    static func random(_ difficulty: WakeChallenge.Difficulty) -> MathProblem {
        switch difficulty {
        case .easy:
            // Suma o resta de dos cifras: 47 + 38, 83 − 29.
            let a = Int.random(in: 10...99)
            let b = Int.random(in: 10...99)
            if Bool.random() {
                return MathProblem(text: "\(a) + \(b)", answer: a + b)
            }
            let (hi, lo) = a >= b ? (a, b) : (b, a)
            return MathProblem(text: "\(hi) − \(lo)", answer: hi - lo)
        case .medium:
            // Multiplicación de una cifra por dos, o suma y resta encadenadas.
            if Bool.random() {
                let a = Int.random(in: 3...9)
                let b = Int.random(in: 12...29)
                return MathProblem(text: "\(a) × \(b)", answer: a * b)
            }
            let a = Int.random(in: 20...99)
            let b = Int.random(in: 10...99)
            let c = Int.random(in: 1...min(a + b, 60))
            return MathProblem(text: "\(a) + \(b) − \(c)", answer: a + b - c)
        case .hard:
            // Multiplicación de dos cifras más un sumando: 23 × 7 + 45.
            let a = Int.random(in: 12...29)
            let b = Int.random(in: 3...9)
            let c = Int.random(in: 10...99)
            return MathProblem(text: "\(a) × \(b) + \(c)", answer: a * b + c)
        }
    }
}
