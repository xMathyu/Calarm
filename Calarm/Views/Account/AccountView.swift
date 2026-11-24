//
//  AccountView.swift
//  Calarm
//
//  Ajustes › Cuenta (DESIGN.md › «Identidad»): el nombre y el correo, cambiar
//  el nombre (llega a todo lo compartido, como antes «Tu nombre»), cerrar sesión
//  y borrar la cuenta, que la App Store exige tener en la app.
//

import SwiftUI

struct AccountView: View {
    @Environment(AccountService.self) private var account
    @State private var name = ""
    @State private var confirmingSignOut = false
    @State private var confirmingDelete = false
    @FocusState private var nameFocused: Bool

    private var user: AccountUser? { account.user }

    var body: some View {
        Form {
            Section {
                VStack(spacing: DS.Spacing.sm) {
                    AccountAvatar(name: user?.name ?? "", size: 76)
                    Text(user?.name ?? appLocalized("Usuario de Calarmi"))
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    if let email = user?.email {
                        Text(verbatim: email)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section {
                TextField("Tu nombre", text: $name)
                    .textContentType(.name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($nameFocused)
                    .onSubmit(saveName)
            } header: {
                Text("Nombre")
            } footer: {
                Text("Así te ven las personas con las que compartes alarmas y cuentas regresivas.")
            }

            Section {
                LabeledContent {
                    Text(verbatim: user?.email ?? "—")
                        .foregroundStyle(.secondary)
                } label: {
                    Label("Correo", systemImage: "envelope.fill")
                }
                LabeledContent {
                    Text(providerTitle)
                        .foregroundStyle(.secondary)
                } label: {
                    Label("Inicio de sesión", systemImage: "person.badge.key.fill")
                }
            } footer: {
                Text("Tu correo no se muestra a nadie ni viaja con lo que compartes.")
            }

            Section {
                Button {
                    confirmingSignOut = true
                } label: {
                    Label("Cerrar sesión", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } footer: {
                Text("Tus alarmas se quedan en este iPhone y siguen sonando.")
            }

            Section {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Borrar cuenta", systemImage: "trash")
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("Borra tu cuenta y lo que compartes con otras personas. Las alarmas de este iPhone se quedan.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Cuenta")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(account.isBusy)
        .overlay {
            if account.isBusy {
                BusyOverlay()
            }
        }
        .onAppear { name = user?.name ?? "" }
        // Lo escrito se guarda también al salir sin pulsar Listo.
        .onDisappear(perform: saveName)
        .onChange(of: user?.name) { _, newValue in
            if !nameFocused { name = newValue ?? "" }
        }
        .confirmationDialog("¿Cerrar sesión?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Cerrar sesión", role: .destructive) {
                Task { await account.signOut() }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Tus alarmas se quedan en este iPhone y siguen sonando.")
        }
        .alert("¿Borrar tu cuenta?", isPresented: $confirmingDelete) {
            Button("Borrar cuenta", role: .destructive) {
                Task {
                    if await account.deleteAccount() { Haptics.success() }
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se borran tu cuenta y lo que compartes; las alarmas de este teléfono se quedan.")
        }
        .alert(
            "No se pudo borrar la cuenta",
            isPresented: Binding(
                get: { account.errorMessage != nil && !confirmingDelete },
                set: { if !$0 { account.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(account.errorMessage ?? "")
        }
    }

    private var providerTitle: String {
        let providers = user?.providers ?? []
        if providers.contains(AccountService.appleProviderID) { return "Apple" }
        if providers.contains(AccountService.googleProviderID) { return "Google" }
        return appLocalized("Correo y contraseña")
    }

    /// El nombre es obligatorio: borrarlo del todo deja el que había.
    private func saveName() {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else {
            name = user?.name ?? ""
            return
        }
        guard typed != user?.name else { return }
        Task { await account.rename(to: typed) }
    }
}

/// Un círculo con las iniciales de la persona, en el color de la app. (Sin la
/// foto de Contactos de `PersonAvatarView`: aquí no se pide ese permiso.)
struct AccountAvatar: View {
    let name: String
    var size: CGFloat = 44

    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [Color.appAccent, Color.appAccent.opacity(0.65)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                if initials.isEmpty {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    Text(verbatim: initials)
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var initials: String {
        name.split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
    }
}
