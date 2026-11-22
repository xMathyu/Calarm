//
//  NameEntryView.swift
//  Calarm
//
//  «¿Cómo te llamas?»: obligatorio en la bienvenida y, para quien ya usaba la
//  app sin nombre, en una hoja que no se cierra hasta ponerlo.
//

import AuthenticationServices
import SwiftUI

/// Pide el nombre con el que la persona aparece ante quienes comparten con ella
/// (`ShareNames`). Lo más rápido es «Continuar con Apple»: Apple da el nombre de
/// la cuenta con un toque. Pero solo lo da la PRIMERA vez que alguien autoriza
/// la app (y la persona puede cambiarlo en esa hoja), así que también se puede
/// escribir. No se crea ninguna cuenta ni se guarda nada de Apple aparte del
/// nombre.
struct NameEntryView: View {
    /// Recibe el nombre ya recortado, nunca vacío.
    let onDone: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var name = ShareNames.myName ?? ""
    @State private var appleGaveNoName = false
    @FocusState private var fieldFocused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.xxl) {
                HeroIcon(systemName: "person.crop.circle.fill")
                    .padding(.top, DS.Spacing.xxxl)

                VStack(spacing: DS.Spacing.md) {
                    Text("¿Cómo te llamas?")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("Así te verán quienes comparten alarmas y cuentas regresivas contigo. Puedes cambiarlo en Ajustes.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SignInWithAppleButton(.continue) { request in
                    request.requestedScopes = [.fullName]
                } onCompletion: { result in
                    handleApple(result)
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 50)
                .clipShape(Capsule())

                HStack(spacing: DS.Spacing.md) {
                    Rectangle().fill(.quaternary).frame(height: 1)
                    Text("o escríbelo")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Rectangle().fill(.quaternary).frame(height: 1)
                }

                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    TextField("Tu nombre", text: $name)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($fieldFocused)
                        .onSubmit(finish)
                        .padding(.horizontal, DS.Spacing.lg)
                        .padding(.vertical, DS.Spacing.md)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                    if appleGaveNoName {
                        Text("Apple no compartió tu nombre. Escríbelo aquí.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, DS.Spacing.lg)
                    }
                }

                Button(action: finish) {
                    Text("Continuar")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(trimmed.isEmpty)
            }
            .padding(.horizontal, DS.Spacing.xxxl)
            .padding(.bottom, DS.Spacing.xxl)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func handleApple(_ result: Result<ASAuthorization, any Error>) {
        guard case .success(let authorization) = result,
              let credential = authorization.credential as? ASAuthorizationAppleIDCredential
        else {
            // Cancelado o sin cuenta de Apple en el dispositivo: queda escribirlo.
            fieldFocused = true
            return
        }
        let fromApple = credential.fullName
            .map { PersonNameComponentsFormatter().string(from: $0) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !fromApple.isEmpty else {
            // Apple solo da el nombre la primera vez que se autoriza la app.
            appleGaveNoName = true
            fieldFocused = true
            return
        }
        name = fromApple
        finish()
    }

    private func finish() {
        guard !trimmed.isEmpty else { return }
        Haptics.success()
        onDone(trimmed)
    }
}
