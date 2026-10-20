//
//  ShakeChallengeGame.swift
//  Calarm
//

import CoreMotion
import SwiftUI

/// Sacudir el teléfono con ganas. El acelerómetro cuenta cada sacudida (un pico
/// en el que la aceleración se aleja más de 0,8 g de la gravedad) y hay que
/// llegar a la cuota de la dificultad. Sin acelerómetro (el simulador) no hay
/// nada que contar: se avisa y un botón da el reto por resuelto.
struct ShakeChallengeGame: View {
    let difficulty: WakeChallenge.Difficulty
    let onSolved: () -> Void

    @State private var sensor = ShakeMotionSensor()
    @State private var done = false

    private var required: Int {
        switch difficulty {
        case .easy: 20
        case .medium: 35
        case .hard: 50
        }
    }

    private var progress: Double {
        min(1, Double(sensor.shakes) / Double(required))
    }

    /// 0 al empezar, 1 a mitad, 2 cerca del final: cambia la frase de ánimo.
    private var stage: Int {
        progress >= 0.8 ? 2 : (progress >= 0.5 ? 1 : 0)
    }

    var body: some View {
        if sensor.isAvailable {
            game
        } else {
            unavailable
        }
    }

    // MARK: - Partes

    private var game: some View {
        VStack(spacing: DS.Spacing.lg) {
            Text("Sacude el teléfono con fuerza")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            ZStack {
                ShakeRing(progress: progress)
                VStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.wiggle.clockwise, value: sensor.shakes)
                    Text(appLocalized("\(sensor.shakes) / \(required)"))
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(DS.Motion.snappy, value: sensor.shakes)
                    Text("sacudidas")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 180, height: 180)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(appLocalized("\(sensor.shakes) / \(required)")))

            Text(encouragement)
                .font(.headline)
                .foregroundStyle(stage == 2 ? Color.green : .primary)
                .contentTransition(.opacity)
                .animation(DS.Motion.quick, value: stage)
                .frame(minHeight: 24)
        }
        .onAppear(perform: sensor.start)
        .onDisappear(perform: sensor.stop)
        .onChange(of: sensor.shakes) { _, count in handle(count) }
    }

    private var encouragement: String {
        switch stage {
        case 2: appLocalized("¡Ya casi!")
        case 1: appLocalized("¡Sigue!")
        default: appLocalized("¡Dale, sacude!")
        }
    }

    private var unavailable: some View {
        VStack(spacing: DS.Spacing.lg) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Este dispositivo no tiene sensores de movimiento.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: finish) {
                Text("Continuar")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.vertical, DS.Spacing.xxl)
    }

    // MARK: - Lógica

    private func handle(_ count: Int) {
        guard !done else { return }
        if count >= required {
            finish()
        } else {
            Haptics.soft()
        }
    }

    private func finish() {
        guard !done else { return }
        done = true
        sensor.stop()
        onSolved()
    }
}

/// Anillo de progreso alrededor del contador.
private struct ShakeRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.accentColor.opacity(0.15), lineWidth: 12)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(DS.Motion.smooth, value: progress)
        }
    }
}

/// Cuenta sacudidas con el acelerómetro a 50 Hz. Una sacudida es un pico en el
/// que el módulo de la aceleración se aleja más de 0,8 g de 1 g (la gravedad en
/// reposo). Tras contar una, hay que volver a la calma (menos de 0,4 g) y dejar
/// pasar 150 ms antes de la siguiente: así un solo meneo no cuenta varias veces.
@MainActor @Observable
private final class ShakeMotionSensor {
    private(set) var shakes = 0

    @ObservationIgnored private let manager = CMMotionManager()
    @ObservationIgnored private var lastShake: TimeInterval = 0
    @ObservationIgnored private var armed = true

    private static let threshold = 0.8
    private static let rearm = 0.4
    private static let debounce: TimeInterval = 0.15

    var isAvailable: Bool { manager.isAccelerometerAvailable }

    func start() {
        guard manager.isAccelerometerAvailable, !manager.isAccelerometerActive else { return }
        manager.accelerometerUpdateInterval = 1.0 / 50.0
        manager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            let a = data.acceleration
            let magnitude = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            let time = data.timestamp
            // La cola es la principal, así que ya estamos en el hilo principal.
            MainActor.assumeIsolated {
                self?.process(magnitude: magnitude, at: time)
            }
        }
    }

    func stop() {
        manager.stopAccelerometerUpdates()
    }

    private func process(magnitude: Double, at time: TimeInterval) {
        let deviation = abs(magnitude - 1)
        if deviation < Self.rearm {
            armed = true
            return
        }
        guard armed, deviation > Self.threshold, time - lastShake >= Self.debounce else { return }
        armed = false
        lastShake = time
        shakes += 1
    }
}
