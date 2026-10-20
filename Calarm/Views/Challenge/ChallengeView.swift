//
//  ChallengeView.swift
//  Calarm
//

import AlarmKit
import SwiftUI

/// La pantalla que apaga una alarma con reto. Mientras está abierta la alarma
/// sigue sonando: solo resolver el juego (o posponer, si la alarma lo permite)
/// la calla. En modo de prueba, desde el editor, no hay alarma detrás.
struct ChallengeView: View {
    enum Mode {
        case alarm(ChallengeCoordinator.Session)
        case practice(WakeChallenge, title: String)
    }

    let mode: Mode

    @Environment(ChallengeCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var solved = false

    private var challenge: WakeChallenge {
        switch mode {
        case .alarm(let session): session.challenge
        case .practice(let challenge, _): challenge
        }
    }

    private var title: String {
        switch mode {
        case .alarm(let session): session.title
        case .practice(_, let title): title
        }
    }

    private var isPractice: Bool {
        if case .practice = mode { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: DS.Spacing.xl) {
                header
                if solved {
                    solvedBanner
                } else {
                    game
                }
                Spacer(minLength: 0)
                footer
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.bottom, DS.Spacing.lg)
            .navigationTitle(challenge.kind.localizedTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isPractice {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cerrar") { dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled()
        .task { await watchAlarm() }
    }

    // MARK: - Partes

    private var header: some View {
        VStack(spacing: DS.Spacing.sm) {
            Image(systemName: "bell.and.waves.left.and.right.fill")
                .font(.system(size: 36))
                .foregroundStyle(settings.accentColor)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !isPractice && !solved)
            Text(title.isEmpty ? appLocalized("Alarma") : title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(isPractice ? "Modo de prueba: la alarma no está sonando." : "Resuelve el reto para apagar la alarma")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, DS.Spacing.md)
    }

    @ViewBuilder
    private var game: some View {
        switch challenge.kind {
        case .math:
            MathChallengeGame(difficulty: challenge.difficulty, onSolved: handleSolved)
        case .memory:
            MemoryChallengeGame(difficulty: challenge.difficulty, onSolved: handleSolved)
        case .qr:
            QRChallengeGame(expectedCode: challenge.code ?? "", onSolved: handleSolved)
        }
    }

    private var solvedBanner: some View {
        VStack(spacing: DS.Spacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Reto resuelto")
                .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.xxxl)
        .transition(.scale.combined(with: .opacity))
    }

    @ViewBuilder
    private var footer: some View {
        if case .alarm(let session) = mode, session.challenge.allowsSnooze, !solved {
            Button {
                Task { await coordinator.snooze() }
            } label: {
                Label(appLocalized("Posponer \(session.snooze.localizedTitle)"), systemImage: "zzz")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    // MARK: - Acciones

    private func handleSolved() {
        guard !solved else { return }
        withAnimation(DS.Motion.bouncy) { solved = true }
        Haptics.success()
        Task {
            // Un instante de «resuelto» antes de que la pantalla desaparezca.
            try? await Task.sleep(for: .milliseconds(700))
            switch mode {
            case .alarm:
                await coordinator.solve()
            case .practice:
                dismiss()
            }
        }
    }

    /// Si la alarma desaparece del sistema (la detuvieron desde el reloj, o
    /// terminó de sonar), la pantalla se cierra sola: ya no hay nada que apagar.
    private func watchAlarm() async {
        guard case .alarm(let session) = mode else { return }
        for await alarms in AlarmManager.shared.alarmUpdates {
            let stillLive = alarms.contains { $0.id == session.id && $0.state != .scheduled }
            if !stillLive {
                coordinator.sessionAlarmEnded()
                return
            }
        }
    }
}
