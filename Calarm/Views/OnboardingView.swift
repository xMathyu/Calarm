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

    let alarmScheduler: AlarmScheduler

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            iconHeader
            VStack(spacing: 12) {
                Text("Bienvenido a Calarm")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text("Crea alarmas para cumpleaños, aniversarios y eventos personales. Suenan aunque tu iPhone esté en silencio.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            featureList
            Spacer()
            primaryAction
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
        }
        .padding(.top)
        .interactiveDismissDisabled(true)
    }

    private var iconHeader: some View {
        ZStack {
            Circle()
                .fill(.tint.opacity(0.18))
                .frame(width: 120, height: 120)
            Image(systemName: "alarm.waves.left.and.right.fill")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(.tint)
        }
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 16) {
            featureRow(systemImage: "birthday.cake.fill", title: "Cumpleaños y aniversarios", description: "Alarmas anuales que se repiten automáticamente.")
            featureRow(systemImage: "repeat", title: "Recurrencias avanzadas", description: "Cada N días, semanas, meses, años. O días específicos de la semana.")
            featureRow(systemImage: "photo.fill", title: "Foto o icono", description: "Pon la foto del cumpleañero o un símbolo a cada alarma.")
            featureRow(systemImage: "bell.fill", title: "Suena fuerte", description: "Aunque el iPhone esté en silencio, bloqueado o en Focus.")
        }
        .padding(.horizontal, 32)
    }

    private func featureRow(systemImage: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(description).font(.subheadline).foregroundStyle(.secondary)
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
        case .finished:
            EmptyView()
        case .error(let message):
            VStack(spacing: 12) {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("Continuar de todas formas") { complete() }
                    .buttonStyle(.bordered)
                Button("Reintentar", action: startFlow)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func startFlow() {
        guard !isWorking else { return }
        isWorking = true
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
    }
}
