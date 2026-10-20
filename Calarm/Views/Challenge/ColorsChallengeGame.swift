//
//  ColorsChallengeGame.swift
//  Calarm
//

import SwiftUI

/// Prueba de Stroop: el nombre de un color escrito con una tinta distinta
/// («Rojo» pintado de azul) y, debajo, muestras redondas sin texto. Hay que
/// tocar la del color de la TINTA, no la del color que dice la palabra. Leer es
/// automático y mirar el color no, así que cuesta lo justo para despejarse.
/// Fallar sacude la muestra, la marca en rojo y repite la misma ronda.
struct ColorsChallengeGame: View {
    let difficulty: WakeChallenge.Difficulty
    let onSolved: () -> Void

    @State private var round = 1
    @State private var current: StroopRound?
    /// Hubo un fallo en esta ronda: el aviso se pone en rojo hasta acertar.
    @State private var wrong = false
    /// La muestra que se tocó mal, para el borde rojo mientras dura el bloqueo.
    @State private var wrongSwatch: StroopColor?
    /// Cuántas veces se ha sacudido cada muestra: sube de uno en uno y la
    /// animación recorre justo esa unidad (tres vaivenes).
    @State private var shakes: [StroopColor: Int] = [:]
    /// Cambia con cada fallo y reinicia la tarea que bloquea los toques un
    /// instante: así no sirve de nada aporrear las muestras al azar.
    @State private var lockToken = 0
    @State private var locked = false
    @State private var solved = false

    private var totalRounds: Int {
        switch difficulty {
        case .easy: 5
        case .medium: 8
        case .hard: 12
        }
    }

    private var optionCount: Int {
        difficulty == .hard ? 6 : 4
    }

    var body: some View {
        VStack(spacing: DS.Spacing.lg) {
            Text(appLocalized("Ronda \(round) de \(totalRounds)"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            wordCard

            Text(wrong
                 ? appLocalized("Ese no es el color de la tinta.")
                 : appLocalized("Toca el color de la tinta, no la palabra."))
                .font(.footnote)
                .foregroundStyle(wrong ? Color.red : Color.secondary)
                .multilineTextAlignment(.center)
                .frame(minHeight: 18)

            swatches
        }
        .onAppear(perform: start)
        .task(id: lockToken) { await holdLock() }
    }

    // MARK: - Partes

    private var wordCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                .fill(Color(.secondarySystemBackground))
            if let current {
                Text(current.word.localizedName)
                    .font(.system(size: 48, weight: .heavy, design: .rounded))
                    .foregroundStyle(current.ink.color)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(.horizontal, DS.Spacing.lg)
                    .id(round)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                    .accessibilityLabel(
                        Text(appLocalized("Palabra \(current.word.localizedName), tinta \(current.ink.localizedName)"))
                    )
            }
        }
        .frame(height: 96)
        .frame(maxWidth: 360)
    }

    private var swatches: some View {
        let options = current?.options ?? []
        let perRow = optionCount == 6 ? 3 : 4
        let rows = stride(from: 0, to: options.count, by: perRow).map {
            Array(options[$0..<min($0 + perRow, options.count)])
        }
        return VStack(spacing: DS.Spacing.md) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: DS.Spacing.md) {
                    ForEach(rows[row]) { color in
                        swatch(color)
                    }
                }
            }
        }
        .frame(maxWidth: 360)
    }

    private func swatch(_ color: StroopColor) -> some View {
        Button {
            tap(color)
        } label: {
            Circle()
                .fill(color.color.gradient)
                .frame(width: 72, height: 72)
                .overlay(
                    Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
                .overlay(
                    Circle()
                        .strokeBorder(Color.red, lineWidth: 4)
                        .opacity(wrongSwatch == color ? 1 : 0)
                )
                .shadow(color: color.color.opacity(0.35), radius: 6, y: 3)
                .scaleEffect(wrongSwatch == color ? 0.92 : 1)
                .modifier(StroopShake(animatableData: CGFloat(shakes[color, default: 0])))
                .animation(DS.Motion.quick, value: wrongSwatch)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(color.localizedName))
    }

    // MARK: - Lógica

    private func start() {
        guard current == nil else { return }
        current = StroopRound.random(optionCount: optionCount, avoiding: nil)
    }

    private func tap(_ color: StroopColor) {
        guard let current, !locked, !solved else { return }
        if color == current.ink {
            withAnimation(DS.Motion.quick) { wrong = false }
            wrongSwatch = nil
            if round >= totalRounds {
                solved = true
                onSolved()
            } else {
                Haptics.light()
                withAnimation(DS.Motion.snappy) {
                    round += 1
                    self.current = StroopRound.random(optionCount: optionCount, avoiding: current)
                }
            }
        } else {
            Haptics.error()
            withAnimation(DS.Motion.quick) { wrong = true }
            wrongSwatch = color
            withAnimation(.linear(duration: 0.4)) { shakes[color, default: 0] += 1 }
            // Se bloquea AQUÍ, de forma síncrona: la tarea de `holdLock` arranca
            // un pase de render después y, mientras tanto, otros toques (o varios
            // dedos a la vez) seguirían entrando.
            locked = true
            lockToken += 1
        }
    }

    /// Tras un fallo, ignora los toques mientras dura la sacudida y luego
    /// apaga el borde rojo. Al arrancar la vista (`lockToken == 0`) no hay
    /// nada que bloquear.
    @MainActor
    private func holdLock() async {
        guard lockToken > 0 else { return }
        locked = true
        try? await Task.sleep(for: .milliseconds(450))
        if Task.isCancelled { return }
        wrongSwatch = nil
        // Ronda nueva con la misma cuenta: fallar no puede servir para ir
        // descartando colores hasta dar con el de la tinta.
        if let current {
            withAnimation(DS.Motion.snappy) {
                self.current = StroopRound.random(optionCount: optionCount, avoiding: current)
            }
        }
        locked = false
    }
}

// MARK: - Modelo

/// Los seis colores del juego, con su tinta y su nombre.
enum StroopColor: CaseIterable, Identifiable, Hashable {
    case rojo
    case verde
    case azul
    case amarillo
    case morado
    case naranja

    var id: Self { self }

    var color: Color {
        switch self {
        case .rojo: .red
        case .verde: .green
        case .azul: .blue
        case .amarillo: .yellow
        case .morado: .purple
        case .naranja: .orange
        }
    }

    var localizedName: String {
        switch self {
        case .rojo: appLocalized("Rojo")
        case .verde: appLocalized("Verde")
        case .azul: appLocalized("Azul")
        case .amarillo: appLocalized("Amarillo")
        case .morado: appLocalized("Morado")
        case .naranja: appLocalized("Naranja")
        }
    }
}

/// Una ronda: la palabra, la tinta con la que se pinta y las muestras a elegir.
struct StroopRound: Equatable {
    let word: StroopColor
    let ink: StroopColor
    let options: [StroopColor]

    /// Palabra y tinta siempre distintas. La tinta cambia respecto a la ronda
    /// anterior para que no valga repetir la misma muestra. Entre las opciones
    /// están siempre la tinta y el color de la palabra (el señuelo), y el resto
    /// se rellena al azar; todo barajado para que la posición no delate nada.
    static func random(optionCount: Int, avoiding previous: StroopRound?) -> StroopRound {
        let all = StroopColor.allCases
        let inkPool = all.filter { $0 != previous?.ink }
        let ink = inkPool.randomElement() ?? .rojo
        let word = all.filter { $0 != ink }.randomElement() ?? .azul
        let others = all.filter { $0 != ink && $0 != word }.shuffled()
        let options = [ink, word] + others.prefix(max(0, optionCount - 2))
        return StroopRound(word: word, ink: ink, options: options.shuffled())
    }
}

/// Sacudida horizontal: cada unidad de `animatableData` son tres vaivenes.
private struct StroopShake: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let offset = 7 * sin(animatableData * .pi * 6)
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}
