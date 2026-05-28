//
//  OnboardingView.swift
//  Calarm
//

import SwiftUI

struct OnboardingView: View {
    @Environment(AppSettings.self) private var settings

    private enum Step {
        case intro
        case requestingAlarms
        case finished
        case error(String)
    }

    @State private var step: Step = .intro
    @State private var isWorking = false
    @State private var animateContent = false

    let alarmScheduler: AlarmScheduler

    private let features: [(symbol: String, title: LocalizedStringKey, description: LocalizedStringKey)] = [
        ("birthday.cake.fill", "Cumpleaños y aniversarios", "Alarmas anuales que se repiten automáticamente."),
        ("repeat", "Recurrencias avanzadas", "Cada N días, semanas, meses o días específicos."),
        ("photo.fill", "Foto o icono", "Pon la foto del cumpleañero o un símbolo a cada alarma."),
        ("bell.fill", "Suena fuerte", "Aunque el iPhone esté en silencio, bloqueado o en Focus.")
    ]

    var body: some View {
        ZStack {
            backgroundGradient

            VStack(spacing: DS.Spacing.xxl) {
                Spacer()

                HeroIcon(systemName: "alarm.waves.left.and.right.fill")
                    .scaleEffect(animateContent ? 1 : 0.7)
                    .opacity(animateContent ? 1 : 0)

                VStack(spacing: DS.Spacing.md) {
                    Text("Bienvenido a Calarm")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("Crea alarmas para cumpleaños, aniversarios y eventos personales. Suenan aunque tu iPhone esté en silencio.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DS.Spacing.xxxl)
                }
                .opacity(animateContent ? 1 : 0)
                .offset(y: animateContent ? 0 : 10)

                featureList

                Spacer()

                primaryAction
                    .padding(.horizontal, DS.Spacing.xxxl)
                    .padding(.bottom, DS.Spacing.xxl)
                    .opacity(animateContent ? 1 : 0)
            }
            .padding(.top)
        }
        .interactiveDismissDisabled(true)
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.75).delay(0.1)) {
                animateContent = true
            }
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color.appAccent.opacity(0.12),
                Color.appAccent.opacity(0.02),
                Color(.systemBackground)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            ForEach(Array(features.enumerated()), id: \.offset) { index, feature in
                featureRow(symbol: feature.symbol, title: feature.title, description: feature.description)
                    .opacity(animateContent ? 1 : 0)
                    .offset(x: animateContent ? 0 : -20)
                    .animation(
                        .spring(response: 0.6, dampingFraction: 0.8)
                            .delay(0.25 + Double(index) * 0.08),
                        value: animateContent
                    )
            }
        }
        .padding(.horizontal, DS.Spacing.xxxl)
    }

    private func featureRow(symbol: String, title: LocalizedStringKey, description: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.md) {
            ZStack {
                Circle()
                    .fill(Color.appAccent.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch step {
        case .intro:
            Button(action: startFlow) {
                Text("Comenzar")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .requestingAlarms:
            ProgressView("Solicitando permiso de alarmas…")
                .controlSize(.regular)
        case .finished:
            EmptyView()
        case .error(let message):
            VStack(spacing: DS.Spacing.md) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                Button("Continuar de todas formas") { complete() }
                    .buttonStyle(.bordered)
                Button("Reintentar", action: startFlow)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }

    private func startFlow() {
        guard !isWorking else { return }
        isWorking = true
        Haptics.light()
        Task {
            defer { isWorking = false }
            step = .requestingAlarms
            _ = try? await alarmScheduler.requestAuthorization()
            complete()
        }
    }

    private func complete() {
        settings.onboardingCompleted = true
        step = .finished
        Haptics.success()
    }
}
