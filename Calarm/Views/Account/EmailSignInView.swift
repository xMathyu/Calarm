//
//  EmailSignInView.swift
//  Calarm
//
//  Correo y contraseña (DESIGN.md › «Identidad»): «Iniciar sesión» con una
//  cuenta que ya existe, «Crear cuenta» con nombre, correo y una contraseña de
//  8 caracteres o más, y «¿Olvidaste tu contraseña?». No se exige verificar el
//  correo.
//

import SwiftUI

struct EmailSignInView: View {
    private enum Mode: Hashable {
        case signIn
        case create
    }

    private enum Field: Hashable {
        case name, email, password
    }

    @Environment(AccountService.self) private var account
    @State private var mode: Mode = .signIn
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var resetSentTo: String?
    @FocusState private var focus: Field?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSubmit: Bool {
        guard PasswordRules.looksLikeEmail(email), !password.isEmpty else { return false }
        guard mode == .create else { return true }
        return !trimmedName.isEmpty && PasswordRules.isLongEnough(password)
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: $mode) {
                    Text("Iniciar sesión").tag(Mode.signIn)
                    Text("Crear cuenta").tag(Mode.create)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                if mode == .create {
                    TextField("Nombre", text: $name)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                        .focused($focus, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focus = .email }
                }
                TextField("Correo", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                SecureField("Contraseña", text: $password)
                    .textContentType(mode == .create ? .newPassword : .password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(submit)
            } footer: {
                if mode == .create {
                    Text("La contraseña, de al menos 8 caracteres. Tu nombre es el que ven quienes comparten contigo; tu correo no se muestra a nadie.")
                }
            }

            Section {
                Button(action: submit) {
                    ZStack {
                        Text(mode == .create ? "Crear cuenta" : "Iniciar sesión")
                            .opacity(account.isBusy ? 0 : 1)
                        if account.isBusy {
                            ProgressView()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canSubmit || account.isBusy)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)

                if let message = account.errorMessage {
                    ErrorNotice(message: message)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                if mode == .signIn {
                    Button("¿Olvidaste tu contraseña?") {
                        Task { await resetPassword() }
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .disabled(account.isBusy)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
        }
        .navigationTitle("Correo y contraseña")
        .navigationBarTitleDisplayMode(.inline)
        .animation(DS.Motion.snappy, value: mode)
        .animation(DS.Motion.snappy, value: account.errorMessage)
        .onChange(of: mode) { _, _ in
            account.errorMessage = nil
        }
        .onAppear {
            account.errorMessage = nil
            focus = .email
        }
        .alert(
            "Revisa tu correo",
            isPresented: Binding(get: { resetSentTo != nil }, set: { if !$0 { resetSentTo = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(String(format: appLocalized("Si %@ tiene una cuenta en Calarmi, te llegará un enlace para elegir una contraseña nueva."), resetSentTo ?? ""))
        }
    }

    private func submit() {
        guard canSubmit, !account.isBusy else { return }
        focus = nil
        Task {
            let done = switch mode {
            case .signIn: await account.signIn(email: email, password: password)
            case .create: await account.createAccount(name: trimmedName, email: email, password: password)
            }
            if done { Haptics.success() } else { Haptics.light() }
        }
    }

    private func resetPassword() async {
        let typed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PasswordRules.looksLikeEmail(typed) else {
            account.errorMessage = appLocalized("Escribe tu correo arriba y vuelve a tocar «¿Olvidaste tu contraseña?».")
            focus = .email
            return
        }
        if await account.sendPasswordReset(email: typed) {
            resetSentTo = typed
        }
    }
}
