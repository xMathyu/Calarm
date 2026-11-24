//
//  AccountLogicTests.swift
//  CalarmTests
//
//  La cuenta obligatoria (calarmi-firebase/DESIGN.md › «Identidad»): el nombre
//  que ya tiene la cuenta no se toca, y el orden en que se elige si no tiene
//  (con los relés de Apple), qué mensaje sale de cada
//  error de Apple, Google, Firebase y Functions (y que cancelar no diga nada), y
//  cuándo un inicio de sesión es un «cambio de cuenta». Sin red ni SDK.
//

import Foundation
import Testing
@testable import Calarm

struct AccountLogicTests {

    // MARK: - Nombre

    private static func resolve(
        display: String? = nil,
        provider: String? = nil,
        legacy: String? = nil,
        email: String? = nil
    ) -> String {
        AccountNaming.resolve(
            currentDisplayName: display,
            providerName: provider,
            legacyName: legacy,
            email: email,
            fallback: "Usuario de Calarmi"
        )
    }

    @Test func anExistingDisplayNameIsNeverOverwritten() {
        // Editado en Ajustes u otro dispositivo: ni Google, ni Apple, ni el
        // «Nombre» de «Crear cuenta» lo pisan.
        #expect(Self.resolve(display: "Mati", provider: "Mathias Yu", legacy: "Mathyu", email: "mathyu@gmail.com") == "Mati")
        #expect(Self.resolve(display: "  Mati ", provider: "Otro") == "Mati")
    }

    @Test func newAccountsTakeTheProviderName() {
        #expect(Self.resolve(display: nil, provider: "Ana García", legacy: "Anita", email: "ana@gmail.com") == "Ana García")
        // Lo que no es un nombre (vacío o solo espacios) no cuenta.
        #expect(Self.resolve(display: "   ", provider: "Ana García", legacy: "Anita") == "Ana García")
    }

    @Test func thenTheNameFromBefore() {
        #expect(Self.resolve(display: "", provider: "  ", legacy: "  Anita  ", email: "ana@gmail.com") == "Anita")
    }

    @Test func thenTheEmailBeforeTheAt() {
        #expect(Self.resolve(email: "ana.garcia@gmail.com") == "Ana.garcia")
        #expect(Self.resolve(email: "  mathyu@example.com ") == "Mathyu")
        #expect(Self.resolve(email: "Zoe@x.io") == "Zoe")
    }

    @Test func appleRelayEmailsAreNotNames() {
        #expect(Self.resolve(email: "x7kd92mq4p@privaterelay.appleid.com") == "Usuario de Calarmi")
        #expect(Self.resolve(email: "X7KD92MQ4P@PrivateRelay.AppleID.com") == "Usuario de Calarmi")
        #expect(AccountNaming.name(fromEmail: "abc@privaterelay.appleid.com") == nil)
    }

    @Test func fallbackWhenNothingElse() {
        #expect(Self.resolve() == "Usuario de Calarmi")
        #expect(Self.resolve(email: "@gmail.com") == "Usuario de Calarmi")
        #expect(Self.resolve(email: "sin-arroba") == "Usuario de Calarmi")
    }

    @Test func namesAreClippedToWhatTheRulesAccept() {
        let long = String(repeating: "a", count: 80)
        #expect(Self.resolve(provider: long).count == 60)
    }

    @Test func appleFullName() {
        var components = PersonNameComponents()
        components.givenName = "Ana"
        components.familyName = "García"
        #expect(AccountNaming.fullName(components)?.contains("Ana") == true)
        #expect(AccountNaming.fullName(components)?.contains("García") == true)
        // Apple no da nada después de la primera vez.
        #expect(AccountNaming.fullName(PersonNameComponents()) == nil)
        #expect(AccountNaming.fullName(nil) == nil)
    }

    // MARK: - Errores

    private static let auth = "FIRAuthErrorDomain"

    @Test func wrongPasswordAndUnknownEmailShareOneMessage() {
        // invalidCredential (con la protección contra la enumeración de correos),
        // wrongPassword y userNotFound.
        for code in [17004, 17009, 17011] {
            #expect(SignInFailure.from(domain: Self.auth, code: code) == .wrongCredentials)
        }
    }

    @Test func eachAuthErrorHasItsMessage() {
        #expect(SignInFailure.from(domain: Self.auth, code: 17007) == .emailInUse)
        #expect(SignInFailure.from(domain: Self.auth, code: 17025) == .emailInUse)
        #expect(SignInFailure.from(domain: Self.auth, code: 17026) == .weakPassword)
        #expect(SignInFailure.from(domain: Self.auth, code: 17008) == .invalidEmail)
        #expect(SignInFailure.from(domain: Self.auth, code: 17020) == .network)
        #expect(SignInFailure.from(domain: Self.auth, code: 17010) == .tooManyRequests)
        #expect(SignInFailure.from(domain: Self.auth, code: 17005) == .accountDisabled)
        #expect(SignInFailure.from(domain: Self.auth, code: 17012) == .otherProvider)
        #expect(SignInFailure.from(domain: Self.auth, code: 17999) == .unknown)
    }

    @Test func cancellingSaysNothing() {
        // ASAuthorizationError.canceled, GIDSignInError.canceled, la ventana web
        // de Firebase cerrada y una petición cancelada.
        #expect(SignInFailure.from(domain: "com.apple.AuthenticationServices.AuthorizationError", code: 1001) == nil)
        #expect(SignInFailure.from(domain: "com.google.GIDSignIn", code: -5) == nil)
        #expect(SignInFailure.from(domain: Self.auth, code: 17058) == nil)
        #expect(SignInFailure.from(domain: NSURLErrorDomain, code: NSURLErrorCancelled) == nil)
        // Lo demás de Apple o Google sí se dice.
        #expect(SignInFailure.from(domain: "com.apple.AuthenticationServices.AuthorizationError", code: 1000) == .unknown)
        #expect(SignInFailure.from(domain: "com.google.GIDSignIn", code: -1) == .unknown)
    }

    @Test func networkErrors() {
        #expect(SignInFailure.from(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet) == .network)
        // Functions: unavailable y deadlineExceeded.
        #expect(SignInFailure.from(domain: "com.firebase.functions", code: 14) == .network)
        #expect(SignInFailure.from(domain: "com.firebase.functions", code: 4) == .network)
        #expect(SignInFailure.from(domain: "com.firebase.functions", code: 16) == .unknown)
        // Un error de Firebase cuya causa es la red.
        let wrapped = NSError(
            domain: Self.auth,
            code: 17999,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)]
        )
        #expect(SignInFailure.from(wrapped) == .network)
    }

    @Test func everyFailureHasAMessage() {
        let all: [SignInFailure] = [
            .wrongCredentials, .emailInUse, .weakPassword, .invalidEmail, .network,
            .tooManyRequests, .accountDisabled, .otherProvider, .unavailable, .unknown,
        ]
        for failure in all {
            #expect(!failure.message.isEmpty)
        }
        #expect(Set(all.map(\.message)).count == all.count)
    }

    // MARK: - Cambio de cuenta

    @Test func sameAccountKeepsEverything() {
        #expect(AccountSwitch.decision(lastUID: "A", newUID: "A", hasLocalFirebaseState: true) == .keep)
    }

    @Test func anotherAccountCleansUp() {
        #expect(AccountSwitch.decision(lastUID: "A", newUID: "B", hasLocalFirebaseState: true) == .cleanUp)
        #expect(AccountSwitch.decision(lastUID: "A", newUID: "B", hasLocalFirebaseState: false) == .cleanUp)
    }

    @Test func firstAccountOnThisPhone() {
        // Quien venía de la 1.0.19 (nunca tuvo sesión): nada que limpiar.
        #expect(AccountSwitch.decision(lastUID: nil, newUID: "A", hasLocalFirebaseState: false) == .keep)
        // Sin «último usuario» pero con restos de Firestore: eran de una sesión
        // que se perdió, no de esta cuenta.
        #expect(AccountSwitch.decision(lastUID: nil, newUID: "A", hasLocalFirebaseState: true) == .cleanUp)
    }

    // MARK: - Correo y contraseña

    @Test func passwordNeedsEightCharacters() {
        #expect(!PasswordRules.isLongEnough("1234567"))
        #expect(PasswordRules.isLongEnough("12345678"))
    }

    @Test func emailShape() {
        #expect(PasswordRules.looksLikeEmail("ana@gmail.com"))
        #expect(PasswordRules.looksLikeEmail("  ana@mail.example.co  "))
        #expect(!PasswordRules.looksLikeEmail("ana"))
        #expect(!PasswordRules.looksLikeEmail("@gmail.com"))
        #expect(!PasswordRules.looksLikeEmail("ana@gmail"))
        #expect(!PasswordRules.looksLikeEmail("ana @gmail.com"))
        #expect(!PasswordRules.looksLikeEmail("ana@.com"))
    }
}
