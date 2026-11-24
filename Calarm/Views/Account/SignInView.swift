//
//  SignInView.swift
//  Calarm
//
//  La pantalla de inicio de sesión, obligatoria (calarmi-firebase/DESIGN.md ›
//  «Identidad»): la primera, antes de la bienvenida, y de nuevo después de
//  cerrar sesión o borrar la cuenta. Reemplaza a «¿Cómo te llamas?»: el nombre
//  sale de la cuenta.
//
//  Tapa la app pero no el reto de una alarma que suena (`ContentView` lo
//  presenta por encima), y nada de lo que suena depende de ella.
//
//  Los botones van en el orden del contrato: Apple, Google, correo. El de Apple
//  es el del sistema (Human Interface Guidelines); el de Google sigue su guía de
//  marca (la «G» de colores sin tocar, fondo blanco con borde o casi negro en
//  modo oscuro), los tres del mismo tamaño.
//

import AuthenticationServices
import SwiftUI

struct SignInView: View {
    @Environment(AccountService.self) private var account
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingEmail = false
    @State private var appeared = false

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: DS.Spacing.xxxl) {
                        Spacer(minLength: DS.Spacing.lg)
                        header
                        VStack(spacing: DS.Spacing.lg) {
                            if !account.isAvailable {
                                unavailableNotice
                            }
                            buttons
                                .disabled(!account.isAvailable || account.isBusy)
                                .opacity(account.isAvailable ? 1 : 0.45)
                            if let message = account.errorMessage, !showingEmail {
                                ErrorNotice(message: message)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        Spacer(minLength: DS.Spacing.lg)
                        footer
                    }
                    .padding(.horizontal, DS.Spacing.xxxl)
                    .padding(.vertical, DS.Spacing.xl)
                    .frame(maxWidth: 480)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .background(background)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showingEmail) {
                EmailSignInView()
            }
            .animation(DS.Motion.smooth, value: account.errorMessage)
        }
        .overlay {
            if account.isBusy, !showingEmail {
                BusyOverlay()
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.75).delay(0.1)) {
                appeared = true
            }
        }
        #if DEBUG
        // `-demoScreen signInEmail`: el formulario del correo, como tras tocarlo.
        .task {
            guard DemoData.requestedScreen == "signInEmail" else { return }
            try? await Task.sleep(for: .seconds(1))
            showingEmail = true
        }
        #endif
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color.appAccent.opacity(0.14),
                Color.appAccent.opacity(0.03),
                Color(.systemBackground)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(spacing: DS.Spacing.xl) {
            Image(AppIconOption.current.previewName)
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
                .scaleEffect(appeared ? 1 : 0.8)
                .opacity(appeared ? 1 : 0)
                .accessibilityHidden(true)
            VStack(spacing: DS.Spacing.md) {
                Text("Inicia sesión en Calarmi")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("Con tu cuenta, quienes comparten alarmas contigo ven tu nombre, desde un iPhone o un Android. Tus alarmas se quedan en este iPhone y suenan aunque no haya conexión.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var buttons: some View {
        VStack(spacing: DS.Spacing.md) {
            SignInWithAppleButton(.continue) { request in
                account.prepareAppleRequest(request)
            } onCompletion: { result in
                Task { await account.completeApple(result) }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            // El estilo del botón de Apple no sigue un cambio de apariencia solo.
            .id(colorScheme)
            .frame(height: SignInButtonMetrics.height)
            .clipShape(Capsule())

            GoogleSignInButton {
                Task { await account.signInWithGoogle() }
            }

            Button {
                account.errorMessage = nil
                showingEmail = true
            } label: {
                Label("Continuar con correo", systemImage: "envelope.fill")
                    .font(SignInButtonMetrics.font)
                    .frame(maxWidth: .infinity, minHeight: SignInButtonMetrics.height)
                    .foregroundStyle(.primary)
                    .background(Color.dsFill, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.pressable)
        }
    }

    private var unavailableNotice: some View {
        HStack(alignment: .top, spacing: DS.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Iniciar sesión no está disponible en esta versión de la app.")
                    .font(.subheadline.weight(.semibold))
                Text("A esta compilación le falta la configuración de Firebase (GoogleService-Info.plist). Tus alarmas siguen sonando.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .cardSurface()
    }

    private var footer: some View {
        Link(destination: AppLinks.privacy) {
            Text("Política de privacidad")
                .font(.footnote)
                .underline()
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Piezas

/// Las medidas comunes de los tres botones: misma altura y peso visual que el
/// de Apple, que no puede quedar menos destacado que los demás.
enum SignInButtonMetrics {
    static let height: CGFloat = 50
    static let font: Font = .system(size: 19, weight: .medium)
}

/// «Continuar con Google» según la guía de marca de Google: la «G» de colores
/// original, fondo blanco con borde gris (o casi negro con borde claro en modo
/// oscuro) y su texto.
struct GoogleSignInButton: View {
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        Button(action: action) {
            HStack(spacing: DS.Spacing.md) {
                Image("GoogleLogo")
                    .resizable()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text("Continuar con Google")
                    .font(SignInButtonMetrics.font)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: SignInButtonMetrics.height)
            .foregroundStyle(Color(hex: dark ? "#E3E3E3" : "#1F1F1F") ?? .primary)
            .background(Color(hex: dark ? "#131314" : "#FFFFFF") ?? .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(Color(hex: dark ? "#8E918F" : "#747775") ?? .gray, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
    }
}

/// Un error de inicio de sesión, debajo de los botones.
struct ErrorNotice: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline)
            .foregroundStyle(.orange)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isStaticText)
    }
}

/// Mientras Apple, Google o Firebase responden.
struct BusyOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.12).ignoresSafeArea()
            ProgressView()
                .controlSize(.large)
                .padding(DS.Spacing.xxl)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
        }
        .transition(.opacity)
    }
}
