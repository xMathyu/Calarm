//
//  OnboardingView.swift
//  Calarm
//
//  Bienvenida de la primera vez: cuatro slides que cuentan para qué sirve la
//  app antes de pedir nada, y un último paso con el permiso de alarmas. La
//  versión anterior era una sola pantalla con una lista de features y el botón
//  de permiso encima: se leía como un trámite, no como una presentación.
//

import SwiftUI

struct OnboardingView: View {
    @Environment(AppSettings.self) private var settings

    private enum Step: Equatable {
        case slides
        case requestingAlarms
        case finished
        case error(String)
    }

    @State private var step: Step = .slides
    @State private var page = 0
    @State private var isWorking = false
    @State private var animateContent = false

    let alarmScheduler: AlarmScheduler

    private struct Slide: Identifiable {
        let id: Int
        let symbol: String
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
    }

    private let slides: [Slide] = [
        Slide(
            id: 0,
            symbol: "alarm.waves.left.and.right.fill",
            title: "Alarmas que no te puedes perder",
            detail: "Suenan fuerte aunque el iPhone esté en silencio, bloqueado o en modo Enfoque."
        ),
        Slide(
            id: 1,
            symbol: "birthday.cake.fill",
            title: "Cumpleaños que se repiten solos",
            detail: "Ponle la foto de la persona y se repite cada año. Cada 2 semanas, los lunes y miércoles, cada 21 días: la recurrencia que necesites."
        ),
        Slide(
            id: 2,
            symbol: "calendar.badge.clock",
            title: "Tus eventos también suenan",
            detail: "Calarm lee tu Calendario y le pone hasta 3 avisos a cada evento. Si es una reunión de Teams, Zoom o Meet, aparece el botón para unirte."
        ),
        Slide(
            id: 3,
            symbol: "sparkles",
            title: "Díselo y listo",
            detail: "«Recuérdame la pastilla todos los días a las 9». El asistente la programa por ti, sin que nada salga de tu iPhone."
        ),
        Slide(
            id: 4,
            symbol: "bell.badge.fill",
            title: "Un permiso y ya está",
            detail: "iOS necesita tu permiso para que Calarm programe alarmas que suenen en silencio y sobre la pantalla bloqueada."
        ),
    ]

    private var isLastPage: Bool { page == slides.count - 1 }

    var body: some View {
        ZStack {
            backgroundGradient

            VStack(spacing: 0) {
                skipButton

                TabView(selection: $page) {
                    ForEach(slides) { slide in
                        slideView(slide)
                            .tag(slide.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                // Sin el fondo del indicador, los puntos —blancos— desaparecen sobre el
                // degradado claro.
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                primaryAction
                    .padding(.horizontal, DS.Spacing.xxxl)
                    .padding(.top, DS.Spacing.lg)
                    .padding(.bottom, DS.Spacing.xxl)
            }
        }
        .interactiveDismissDisabled(true)
        .onAppear {
            #if DEBUG
            if let requested = DemoData.requestedPage, slides.indices.contains(requested) {
                page = requested
            }
            #endif
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

    /// Salta a la última pantalla, no al final del onboarding: sin el permiso
    /// la app no puede programar nada, así que ese paso no se puede saltar.
    @ViewBuilder
    private var skipButton: some View {
        HStack {
            Spacer()
            if !isLastPage, step == .slides {
                Button("Omitir") {
                    withAnimation(DS.Motion.smooth) { page = slides.count - 1 }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .frame(height: 28)
        .padding(.horizontal, DS.Spacing.xxl)
        .padding(.top, DS.Spacing.lg)
    }

    private func slideView(_ slide: Slide) -> some View {
        VStack(spacing: DS.Spacing.xxl) {
            Spacer()

            HeroIcon(systemName: slide.symbol)
                .scaleEffect(animateContent ? 1 : 0.7)
                .opacity(animateContent ? 1 : 0)

            VStack(spacing: DS.Spacing.md) {
                Text(slide.title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text(slide.detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, DS.Spacing.xxxl)

            Spacer()
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch step {
        case .slides:
            Button(action: advance) {
                Text(isLastPage ? "Activar alarmas" : "Continuar")
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

    private func advance() {
        guard isLastPage else {
            Haptics.light()
            withAnimation(DS.Motion.smooth) { page += 1 }
            return
        }
        startFlow()
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
