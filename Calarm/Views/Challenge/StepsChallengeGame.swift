//
//  StepsChallengeGame.swift
//  Calarm
//

import CoreMotion
import SwiftUI
import UIKit

/// Dar unos pasos de verdad: el podómetro cuenta los pasos desde que se abre el
/// reto y hay que llegar a la cuota de la dificultad. Si el dispositivo no cuenta
/// pasos, el reto pasa a ser «Sacudir»; si el permiso de movimiento está
/// denegado, se ofrece abrir Ajustes o sacudir el teléfono en su lugar.
struct StepsChallengeGame: View {
    let difficulty: WakeChallenge.Difficulty
    let onSolved: () -> Void

    private enum Mode {
        /// Contando pasos con el podómetro.
        case counting
        /// Permiso de movimiento denegado o restringido.
        case denied
        /// El dispositivo no cuenta pasos: sacudidas, con una línea que lo explica.
        case unavailable
        /// La persona eligió sacudir en vez de dar permiso.
        case shake
    }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var counter = PedometerCounter()
    @State private var mode: Mode
    @State private var done = false

    init(difficulty: WakeChallenge.Difficulty, onSolved: @escaping () -> Void) {
        self.difficulty = difficulty
        self.onSolved = onSolved
        _mode = State(initialValue: Self.initialMode())
    }

    private var required: Int {
        switch difficulty {
        case .easy: 15
        case .medium: 30
        case .hard: 50
        }
    }

    private var progress: Double {
        min(1, Double(counter.steps) / Double(required))
    }

    var body: some View {
        switch mode {
        case .counting:
            counting
        case .denied:
            denied
        case .unavailable:
            VStack(spacing: DS.Spacing.md) {
                Text("Este dispositivo no cuenta pasos: sacude el teléfono en su lugar.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ShakeChallengeGame(difficulty: difficulty, onSolved: finish)
            }
        case .shake:
            ShakeChallengeGame(difficulty: difficulty, onSolved: finish)
        }
    }

    // MARK: - Partes

    private var counting: some View {
        VStack(spacing: DS.Spacing.lg) {
            Text("Camina con el teléfono en la mano.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            ZStack {
                StepsRing(progress: progress)
                VStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "figure.walk")
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.bounce, value: counter.steps)
                        // Un balanceo suave y continuo, como quien camina.
                        .phaseAnimator([false, true]) { view, phase in
                            view.offset(y: phase ? -2.5 : 2.5)
                        } animation: { _ in
                            .easeInOut(duration: 0.7)
                        }
                    Text(appLocalized("\(counter.steps) / \(required)"))
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(DS.Motion.snappy, value: counter.steps)
                    Text("pasos")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 180, height: 180)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(appLocalized("\(counter.steps) / \(required)")))

            Text("El contador se actualiza cada pocos segundos.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .onAppear(perform: counter.start)
        .onDisappear(perform: counter.stop)
        .onChange(of: counter.steps) { _, steps in handle(steps) }
        .onChange(of: counter.unauthorized) { _, unauthorized in
            // La persona denegó el permiso en el aviso del sistema.
            if unauthorized { switchToDenied() }
        }
        .onChange(of: counter.failed) { _, failed in
            // Falló por otra causa: mejor sacudir que un contador clavado en 0.
            if failed { switchToUnavailable() }
        }
    }

    private var denied: some View {
        VStack(spacing: DS.Spacing.lg) {
            Image(systemName: "figure.walk.circle")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Calarm no tiene permiso para contar tus pasos. Actívalo en Ajustes › Privacidad y seguridad › Movimiento y forma física.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            } label: {
                Label("Abrir Ajustes", systemImage: "gear")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button {
                withAnimation(DS.Motion.snappy) { mode = .shake }
            } label: {
                Label("Usar sacudidas", systemImage: "iphone.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(.vertical, DS.Spacing.md)
        .onChange(of: scenePhase) { _, phase in
            // Al volver de Ajustes con el permiso concedido, se cuenta de verdad.
            guard phase == .active, CMPedometer.authorizationStatus() == .authorized else { return }
            withAnimation(DS.Motion.snappy) { mode = .counting }
        }
    }

    // MARK: - Lógica

    private static func initialMode() -> Mode {
        guard CMPedometer.isStepCountingAvailable() else { return .unavailable }
        switch CMPedometer.authorizationStatus() {
        case .denied, .restricted: return .denied
        case .notDetermined, .authorized: return .counting
        @unknown default: return .counting
        }
    }

    /// El podómetro falló por algo que no es el permiso: se pasa a sacudir.
    private func switchToUnavailable() {
        guard !done else { return }
        counter.stop()
        withAnimation(DS.Motion.snappy) { mode = .unavailable }
    }

    private func handle(_ steps: Int) {
        guard !done, mode == .counting else { return }
        if steps >= required {
            finish()
        } else if steps > 0 {
            // Cada actualización del podómetro se nota: los pasos están contando.
            Haptics.soft()
        }
    }

    private func switchToDenied() {
        guard !done, mode == .counting else { return }
        counter.stop()
        withAnimation(DS.Motion.snappy) { mode = .denied }
    }

    private func finish() {
        guard !done else { return }
        done = true
        counter.stop()
        onSolved()
    }
}

/// Anillo de progreso alrededor del contador.
private struct StepsRing: View {
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

/// Pasos acumulados desde `start()`. El podómetro entrega el total desde la
/// fecha de inicio cada pocos segundos, en una cola cualquiera: se salta al
/// hilo principal antes de tocar el estado.
@MainActor @Observable
private final class PedometerCounter {
    private(set) var steps = 0
    /// Se activa si el podómetro falla por falta de permiso, por ejemplo porque
    /// la persona lo denegó en el aviso del sistema que salió al empezar.
    private(set) var unauthorized = false
    /// Se activa si falla por cualquier otra causa (el seguimiento de actividad
    /// apagado a nivel de sistema, un error del sensor…): sin esto el contador
    /// se quedaría en 0 sin salida.
    private(set) var failed = false

    @ObservationIgnored private let pedometer = CMPedometer()
    @ObservationIgnored private var running = false

    func start() {
        guard !running else { return }
        running = true
        steps = 0
        unauthorized = false
        failed = false
        pedometer.startUpdates(from: Date()) { [weak self] data, error in
            let count = data?.numberOfSteps.intValue
            let failed = error != nil
            Task { @MainActor in
                guard let self, self.running else { return }
                if let count {
                    self.steps = max(self.steps, count)
                }
                if failed {
                    switch CMPedometer.authorizationStatus() {
                    case .denied, .restricted: self.unauthorized = true
                    default: self.failed = true
                    }
                }
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        pedometer.stopUpdates()
    }
}
