//
//  OrderChallengeGame.swift
//  Calarm
//

import SwiftUI

/// Una tabla de Schulte: los números del 1 al N revueltos en una cuadrícula y
/// hay que tocarlos en orden ascendente. Cada acierto apaga su casilla; en
/// difícil, cada fallo vuelve a revolver los números que faltan, así que no
/// vale ir de memoria. El cronómetro es solo para picarse.
struct OrderChallengeGame: View {
    let difficulty: WakeChallenge.Difficulty
    let onSolved: () -> Void

    /// Los números en el orden en que se pintan en la cuadrícula.
    @State private var numbers: [Int] = []
    /// El siguiente número que hay que tocar.
    @State private var next = 1
    /// El número que se acaba de tocar por error; mientras parpadea en rojo se
    /// ignoran los toques, para que no sirva aporrear la pantalla.
    @State private var wrongNumber: Int?
    @State private var startDate = Date.now
    @State private var elapsed = 0
    @State private var solved = false

    private var count: Int {
        switch difficulty {
        case .easy: 9
        case .medium: 16
        case .hard: 20
        }
    }

    private var columns: Int {
        difficulty == .easy ? 3 : 4
    }

    /// Alto fijo por casilla para que las cinco filas de difícil quepan junto
    /// a la cabecera de la pantalla del reto.
    private var tileHeight: CGFloat {
        switch difficulty {
        case .easy: 96
        case .medium: 72
        case .hard: 58
        }
    }

    var body: some View {
        VStack(spacing: DS.Spacing.lg) {
            header
            grid
        }
        .onAppear(perform: start)
        .task { await runClock() }
        .task(id: wrongNumber) { await clearWrong() }
    }

    // MARK: - Partes

    private var header: some View {
        HStack {
            Text(appLocalized("Siguiente: \(min(next, count))"))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Spacer()
            Label {
                Text(clockText)
                    .monospacedDigit()
            } icon: {
                Image(systemName: "stopwatch")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Tiempo"))
            .accessibilityValue(Text(clockText))
        }
        .frame(maxWidth: 360)
    }

    private var clockText: String {
        Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond))
    }

    private var grid: some View {
        let layout = Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.sm), count: columns)
        return LazyVGrid(columns: layout, spacing: DS.Spacing.sm) {
            ForEach(numbers, id: \.self) { number in
                tile(number)
            }
        }
        .frame(maxWidth: 360)
    }

    private func tile(_ number: Int) -> some View {
        let done = number < next
        let wrong = wrongNumber == number
        return Button {
            tap(number)
        } label: {
            Text(String(number))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(done || wrong ? Color.white : .primary)
                .frame(maxWidth: .infinity)
                .frame(height: tileHeight)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .fill(wrong ? Color.red : done ? Color.accentColor : Color(.secondarySystemBackground))
                )
                .opacity(done ? 0.35 : 1)
                .scaleEffect(done ? 0.9 : 1)
        }
        .buttonStyle(.plain)
        .disabled(done)
        .animation(DS.Motion.snappy, value: done)
        .animation(DS.Motion.quick, value: wrong)
        .accessibilityLabel(Text(String(number)))
    }

    // MARK: - Lógica

    private func start() {
        guard numbers.isEmpty else { return }
        numbers = Array(1...count).shuffled()
        startDate = .now
    }

    private func tap(_ number: Int) {
        guard !solved, wrongNumber == nil, number >= next else { return }
        if number == next {
            Haptics.selection()
            withAnimation(DS.Motion.snappy) { next += 1 }
            if next > count {
                solved = true
                onSolved()
            }
        } else {
            Haptics.error()
            wrongNumber = number
        }
    }

    /// Apaga el rojo del fallo y, en difícil, revuelve lo que queda.
    @MainActor
    private func clearWrong() async {
        guard wrongNumber != nil else { return }
        try? await Task.sleep(for: .milliseconds(320))
        if Task.isCancelled { return }
        wrongNumber = nil
        if difficulty == .hard {
            withAnimation(DS.Motion.smooth) { reshuffleRemaining() }
        }
    }

    /// Revuelve solo los números que faltan; los ya tocados se quedan en su sitio.
    private func reshuffleRemaining() {
        let positions = numbers.indices.filter { numbers[$0] >= next }
        let values = positions.map { numbers[$0] }.shuffled()
        for (position, value) in zip(positions, values) {
            numbers[position] = value
        }
    }

    /// Cronómetro cosmético: se detiene al resolver y muere con la vista.
    @MainActor
    private func runClock() async {
        while !Task.isCancelled, !solved {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled || solved { return }
            elapsed = Int(Date.now.timeIntervalSince(startDate))
        }
    }
}
