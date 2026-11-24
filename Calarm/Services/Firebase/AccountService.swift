//
//  AccountService.swift
//  Calarm
//
//  La cuenta obligatoria (calarmi-firebase/DESIGN.md › «Identidad»): iniciar
//  sesión con Apple, Google o correo y contraseña, el nombre que sale de la
//  cuenta, cambiar de cuenta en el mismo teléfono, cerrar sesión y borrar la
//  cuenta.
//
//  Lo único que no depende de la sesión es el motor de alarmas: AlarmKit, los
//  widgets y la Live Activity siguen con lo que hay en el teléfono, y la
//  pantalla del reto de una alarma que suena aparece aunque no haya sesión
//  (`ContentView`). Los datos propios siguen en SwiftData + iCloud; aquí solo se
//  decide quién es la persona ante lo compartido.
//

import AuthenticationServices
import CryptoKit
import FirebaseAuth
import FirebaseCore
import FirebaseFunctions
import Foundation
import GoogleSignIn
import Observation
import UIKit

/// Lo que la app muestra del usuario con sesión.
struct AccountUser: Equatable {
    var uid: String
    var name: String?
    var email: String?
    var isAnonymous: Bool
    /// `apple.com`, `google.com`, `password`.
    var providers: [String]

    var hasApple: Bool { providers.contains(AccountService.appleProviderID) }
}

@Observable
@MainActor
final class AccountService {
    static let functionsRegion = "us-central1"
    static let appleProviderID = "apple.com"
    static let googleProviderID = "google.com"
    static let passwordProviderID = "password"

    /// El último usuario que vio este teléfono (DESIGN.md › «Cambio de cuenta»).
    static let lastUIDKey = "calarm.account.lastUID"
    /// El nombre que Apple dio y que aún no llegó a la cuenta (Apple lo da solo
    /// la primera vez que la persona autoriza la app: si esa vez falla la red,
    /// el siguiente intento ya no lo trae). Por el id de Apple de la persona.
    private static let pendingAppleNameKey = "calarm.account.pendingAppleName"

    /// El usuario de Firebase, también el anónimo de una versión anterior
    /// (`isAnonymous`), o nil sin sesión.
    private(set) var user: AccountUser?
    /// False en una compilación sin `GoogleService-Info.plist`: la pantalla de
    /// inicio de sesión lo explica en vez de cerrar la app.
    let isAvailable: Bool
    /// Un inicio de sesión, cierre o borrado en curso.
    private(set) var isBusy = false
    /// Desde que el proveedor devuelve la credencial hasta que termina lo local
    /// de entrar («cambio de cuenta»): la pantalla de inicio de sesión sigue
    /// delante, para no enseñar lo de la cuenta anterior mientras se limpia.
    private(set) var isSigningIn = false
    /// Lo último que falló, para la pantalla en la que está la persona.
    var errorMessage: String?

    /// Lo que la app hace al entrar (leer lo compartido, migrar, unirse a las
    /// invitaciones que esperaban). Lo pone `CalarmApp`.
    @ObservationIgnored var onSignedIn: (() async -> Void)?

    private let sharing: SharedRemindersService
    private let delegation: DelegationService
    private let settings: AppSettings
    @ObservationIgnored private var authListener: AuthStateDidChangeListenerHandle?
    /// El nonce del «Continuar con Apple» en curso, sin hash (Apple recibe su SHA-256).
    @ObservationIgnored private var appleNonce: String?
    /// La escritura del nombre al entrar (perfil de Auth, `users/{uid}`, lo
    /// compartido): un cambio de nombre en Ajustes espera a que termine, o el
    /// nombre de la cuenta pisaría al recién escrito.
    @ObservationIgnored private var nameWrite: Task<Void, Never>?

    init(sharing: SharedRemindersService, delegation: DelegationService, settings: AppSettings) {
        self.sharing = sharing
        self.delegation = delegation
        self.settings = settings
        FirebaseSession.shared.configure()
        isAvailable = FirebaseSession.shared.isConfigured
        #if DEBUG
        if Self.isDemo {
            user = Self.demoUser
            return
        }
        #endif
        guard isAvailable else { return }
        let current = Auth.auth().currentUser
        user = current.map(Self.snapshot)
        // Quien ya tenía sesión (también la anónima de un probador) es el
        // «último usuario» de este teléfono: lo que recuerda de Firebase es suyo.
        if let current, UserDefaults.standard.string(forKey: Self.lastUIDKey) == nil {
            UserDefaults.standard.set(current.uid, forKey: Self.lastUIDKey)
        }
        // Con cuenta, la copia del nombre para CloudKit (p. ej. tras reinstalar:
        // la sesión vive en el llavero, la copia no).
        if let current, !current.isAnonymous, ShareNames.myName == nil,
           let name = FirestoreMapping.validName(current.displayName) {
            Task { await sharing.accountNameDidChange(name, changed: false) }
        }
        authListener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.user = user.map(Self.snapshot)
                // La sesión se cerró sola (p. ej. la cuenta se borró desde otro
                // dispositivo): nada sigue escuchando con ella.
                if user == nil {
                    self.sharing.stopFirestoreListener()
                }
            }
        }
    }

    /// Sin una cuenta de verdad (no anónima), la app no se usa (DESIGN.md).
    var requiresSignIn: Bool {
        #if DEBUG
        if Self.isDemo { return Self.forcesSignInScreen }
        #endif
        guard let user, !user.isAnonymous else { return true }
        return isSigningIn
    }

    private static func snapshot(_ user: User) -> AccountUser {
        AccountUser(
            uid: user.uid,
            // Si el perfil aún no tiene el nombre (sin red al entrar), su copia.
            name: FirestoreMapping.validName(user.displayName)
                ?? (user.isAnonymous ? nil : FirestoreMapping.validName(ShareNames.myName)),
            email: user.email ?? user.providerData.lazy.compactMap(\.email).first,
            isAnonymous: user.isAnonymous,
            providers: user.providerData.map(\.providerID)
        )
    }

    private func refreshUser() {
        guard isAvailable else { return }
        user = Auth.auth().currentUser.map(Self.snapshot)
    }

    // MARK: - Continuar con Apple

    /// La petición del botón de Apple: nombre y correo, con un nonce para que
    /// Firebase compruebe que el token es de esta petición.
    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonce()
        appleNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
    }

    func completeApple(_ result: Result<ASAuthorization, any Error>) async {
        errorMessage = nil
        switch result {
        case .failure(let error):
            report(error, context: "Apple")
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8),
                  let nonce = appleNonce
            else {
                ShareDiagnostics.log("❌ cuenta: Apple no devolvió el token")
                errorMessage = SignInFailure.unknown.message
                return
            }
            // Apple da el nombre solo la primera vez: se guarda de inmediato.
            var pending = UserDefaults.standard.dictionary(forKey: Self.pendingAppleNameKey) as? [String: String] ?? [:]
            if let name = AccountNaming.fullName(credential.fullName) {
                pending[credential.user] = name
                UserDefaults.standard.set(pending, forKey: Self.pendingAppleNameKey)
            }
            let firebaseCredential = OAuthProvider.appleCredential(
                withIDToken: idToken,
                rawNonce: nonce,
                fullName: credential.fullName
            )
            let signedIn = await signIn(with: firebaseCredential, providerName: pending[credential.user], via: "Apple")
            if signedIn {
                pending[credential.user] = nil
                UserDefaults.standard.set(pending, forKey: Self.pendingAppleNameKey)
            }
        }
    }

    // MARK: - Continuar con Google

    func signInWithGoogle() async {
        errorMessage = nil
        guard isAvailable, let clientID = FirebaseApp.app()?.options.clientID else {
            errorMessage = SignInFailure.unavailable.message
            return
        }
        guard let presenter = UIApplication.shared.topViewController else { return }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard let idToken = result.user.idToken?.tokenString else {
                ShareDiagnostics.log("❌ cuenta: Google no devolvió el token")
                errorMessage = SignInFailure.unknown.message
                return
            }
            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: result.user.accessToken.tokenString
            )
            await signIn(with: credential, providerName: result.user.profile?.name, via: "Google")
        } catch {
            report(error, context: "Google")
        }
    }

    /// El regreso de Google a la app (`com.googleusercontent.apps…://`).
    func handle(_ url: URL) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }

    // MARK: - Correo y contraseña

    /// «Iniciar sesión»: una cuenta que ya existe. Nunca vincula la sesión
    /// anónima (vincular un correo nuevo crearía una cuenta).
    @discardableResult
    func signIn(email: String, password: String) async -> Bool {
        errorMessage = nil
        guard isAvailable else {
            errorMessage = SignInFailure.unavailable.message
            return false
        }
        isBusy = true
        isSigningIn = true
        defer { isBusy = false; isSigningIn = false }
        do {
            let result = try await Auth.auth().signIn(withEmail: Self.clean(email), password: password)
            await finishSignIn(result.user, providerName: nil, via: "correo")
            return true
        } catch {
            report(error, context: "correo")
            return false
        }
    }

    /// «Crear cuenta»: con la sesión anónima de un probador, la vincula (mismo
    /// uid, conserva lo compartido). Si el correo ya tiene cuenta, entra en ella.
    @discardableResult
    func createAccount(name: String, email: String, password: String) async -> Bool {
        errorMessage = nil
        guard isAvailable else {
            errorMessage = SignInFailure.unavailable.message
            return false
        }
        let email = Self.clean(email)
        let name = FirestoreMapping.validName(name)
        isBusy = true
        isSigningIn = true
        defer { isBusy = false; isSigningIn = false }
        do {
            let result: AuthDataResult
            if let anonymous = Auth.auth().currentUser, anonymous.isAnonymous {
                do {
                    result = try await anonymous.link(with: EmailAuthProvider.credential(withEmail: email, password: password))
                    ShareDiagnostics.log("🔗 cuenta: correo vinculado a la sesión anónima")
                } catch let error as NSError where Self.isAlreadyInUse(error) {
                    result = try await signInExisting(email: email, password: password)
                }
            } else {
                do {
                    result = try await Auth.auth().createUser(withEmail: email, password: password)
                } catch let error as NSError where Self.isAlreadyInUse(error) {
                    result = try await signInExisting(email: email, password: password)
                }
            }
            await finishSignIn(result.user, providerName: name, via: "correo nuevo")
            return true
        } catch {
            report(error, context: "crear cuenta")
            return false
        }
    }

    /// El correo ya tiene cuenta: se entra en ella si la contraseña es la suya
    /// (DESIGN.md). Si no, el mensaje es «ya hay una cuenta», no «contraseña
    /// incorrecta»: la persona estaba creando una.
    private func signInExisting(email: String, password: String) async throws -> AuthDataResult {
        do {
            return try await Auth.auth().signIn(withEmail: email, password: password)
        } catch {
            if SignInFailure.from(error) == .wrongCredentials {
                throw NSError(domain: SignInFailure.firebaseAuthDomain, code: SignInFailure.AuthCode.emailAlreadyInUse)
            }
            throw error
        }
    }

    /// «¿Olvidaste tu contraseña?». Firebase no dice si el correo tiene cuenta.
    func sendPasswordReset(email: String) async -> Bool {
        errorMessage = nil
        guard isAvailable else {
            errorMessage = SignInFailure.unavailable.message
            return false
        }
        isBusy = true
        defer { isBusy = false }
        do {
            Auth.auth().languageCode = InviteLink.pageLanguage()
            try await Auth.auth().sendPasswordReset(withEmail: Self.clean(email))
            return true
        } catch {
            report(error, context: "restablecer contraseña")
            return false
        }
    }

    private static func clean(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Entrar

    /// Apple y Google: con la sesión anónima de un probador se vincula la
    /// credencial (mismo uid). Si ya es de otra cuenta, se entra en esa y se
    /// aplica «cambio de cuenta».
    @discardableResult
    private func signIn(with credential: AuthCredential, providerName: String?, via provider: String) async -> Bool {
        isBusy = true
        isSigningIn = true
        defer { isBusy = false; isSigningIn = false }
        do {
            let result: AuthDataResult
            if let anonymous = Auth.auth().currentUser, anonymous.isAnonymous {
                do {
                    result = try await anonymous.link(with: credential)
                    ShareDiagnostics.log("🔗 cuenta: \(provider) vinculado a la sesión anónima")
                } catch let error as NSError where Self.isAlreadyInUse(error) {
                    // El token de Apple no se puede usar dos veces: Firebase da otro.
                    let updated = error.userInfo[AuthErrors.userInfoUpdatedCredentialKey] as? AuthCredential
                    result = try await Auth.auth().signIn(with: updated ?? credential)
                }
            } else {
                result = try await Auth.auth().signIn(with: credential)
            }
            await finishSignIn(result.user, providerName: providerName, via: provider)
            return true
        } catch {
            report(error, context: provider)
            return false
        }
    }

    private static func isAlreadyInUse(_ error: NSError) -> Bool {
        error.domain == SignInFailure.firebaseAuthDomain
            && [SignInFailure.AuthCode.credentialAlreadyInUse, SignInFailure.AuthCode.emailAlreadyInUse].contains(error.code)
    }

    /// Ya con la cuenta: «cambio de cuenta» si hace falta, el nombre (DESIGN.md)
    /// y lo que la app hace al entrar. Lo local va primero y sin red, para que la
    /// pantalla de inicio de sesión se vaya ya; lo demás sigue detrás.
    private func finishSignIn(_ user: User, providerName: String?, via provider: String) async {
        let defaults = UserDefaults.standard
        let lastUID = defaults.string(forKey: Self.lastUIDKey)
        let decision = AccountSwitch.decision(
            lastUID: lastUID,
            newUID: user.uid,
            hasLocalFirebaseState: SharedRemindersService.hasFirestoreState
        )
        if decision == .cleanUp {
            await forgetLocalAccountState()
        }
        defaults.set(user.uid, forKey: Self.lastUIDKey)
        ShareDiagnostics.log("🔑 cuenta: sesión iniciada con \(provider)\(decision == .cleanUp ? " (otra cuenta)" : "")")

        // El `displayName` que ya tenga la cuenta no se toca (DESIGN.md). Si no
        // tiene, el nombre de antes solo vale si es de esta persona: la versión
        // anterior (sin «último usuario») o esta misma cuenta.
        let legacyName = lastUID == nil || lastUID == user.uid ? ShareNames.myName : nil
        let name = AccountNaming.resolve(
            currentDisplayName: user.displayName,
            providerName: providerName,
            legacyName: legacyName,
            email: user.email,
            fallback: appLocalized("Usuario de Calarmi")
        )
        let changed = FirestoreMapping.validName(ShareNames.myName) != name
        refreshUser()
        if self.user?.name != name { self.user?.name = name }

        let sharing = sharing
        let onSignedIn = onSignedIn
        let previous = nameWrite
        let write = Task {
            await previous?.value
            await Self.saveDisplayName(name, for: user)
            await sharing.accountNameDidChange(name, changed: changed)
            refreshUser()
        }
        nameWrite = write
        Task {
            await write.value
            await FirebaseSession.shared.didSignIn()
            await onSignedIn?()
        }
    }

    /// El nombre en el perfil de Firebase Auth, la fuente de verdad.
    private static func saveDisplayName(_ name: String, for user: User) async {
        guard user.displayName != name else { return }
        let request = user.createProfileChangeRequest()
        request.displayName = name
        do {
            try await request.commitChanges()
        } catch {
            ShareDiagnostics.log("❌ cuenta: nombre en el perfil: \(error.localizedDescription)")
        }
    }

    /// «Cambio de cuenta» (y lo mismo al borrar la cuenta): lo de la cuenta
    /// anterior que el teléfono guardaba. Las alarmas propias se quedan.
    private func forgetLocalAccountState() async {
        await sharing.forgetFirebaseAccount()
        if !(await delegation.forgetFirebaseAccount()) {
            settings.delegationEnabled = false
        }
        FirebaseSession.shared.forgetUploadedPushToken()
    }

    // MARK: - Nombre

    /// Ajustes › Cuenta: el mismo camino que al iniciar sesión (Auth,
    /// `users/{uid}` y los `ownerName` / `members.<uid>.name` de lo compartido).
    func rename(to newName: String) async {
        guard let name = FirestoreMapping.validName(newName), name != user?.name else { return }
        #if DEBUG
        if Self.isDemo {
            user?.name = name
            return
        }
        #endif
        guard let current = Auth.auth().currentUser, !current.isAnonymous else { return }
        user?.name = name
        let previous = nameWrite
        let sharing = sharing
        let write = Task {
            await previous?.value
            await Self.saveDisplayName(name, for: current)
            await sharing.accountNameDidChange(name, changed: true)
            refreshUser()
        }
        nameWrite = write
        await write.value
    }

    // MARK: - Cerrar sesión

    /// Ajustes › Cuenta › «Cerrar sesión»: el token de push sale de la cuenta, se
    /// paran las escuchas y vuelve la pantalla de inicio de sesión. Las alarmas
    /// del teléfono se quedan y siguen sonando.
    func signOut() async {
        #if DEBUG
        if Self.isDemo { return }
        #endif
        isBusy = true
        defer { isBusy = false }
        sharing.stopFirestoreListener()
        await FirebaseSession.shared.unregisterPushToken()
        GIDSignIn.sharedInstance.signOut()
        do {
            try Auth.auth().signOut()
            ShareDiagnostics.log("🚪 cuenta: sesión cerrada")
        } catch {
            ShareDiagnostics.log("❌ cuenta: cerrar sesión: \(error.localizedDescription)")
        }
        refreshUser()
    }

    // MARK: - Borrar la cuenta

    /// Ajustes › Cuenta › «Borrar cuenta», ya confirmado (DESIGN.md › «Borrar
    /// cuenta»): con Apple, revoca su token; luego la función `deleteAccount`
    /// borra los datos y el usuario, y el teléfono se limpia como en «cambio de
    /// cuenta». True si se borró; false si la persona canceló o falló (con
    /// `errorMessage`).
    func deleteAccount() async -> Bool {
        errorMessage = nil
        #if DEBUG
        if Self.isDemo { return false }
        #endif
        guard let current = Auth.auth().currentUser, !current.isAnonymous else { return false }
        if current.providerData.contains(where: { $0.providerID == Self.appleProviderID }) {
            do {
                let code = try await AppleReauthorization().authorizationCode()
                do {
                    try await Auth.auth().revokeToken(withAuthorizationCode: code)
                    ShareDiagnostics.log("🍎 cuenta: token de Apple revocado")
                } catch {
                    // Exige la llave de Sign in with Apple en Firebase: sin ella se
                    // sigue (la cuenta se borra igual).
                    ShareDiagnostics.log("⚠️ cuenta: revocar el token de Apple: \(error.localizedDescription)")
                }
            } catch {
                guard SignInFailure.from(error) != nil else { return false }   // canceló
                ShareDiagnostics.log("⚠️ cuenta: autorización de Apple para borrar: \(error.localizedDescription)")
            }
        }
        isBusy = true
        defer { isBusy = false }
        sharing.stopFirestoreListener()
        do {
            _ = try await Functions.functions(region: Self.functionsRegion).httpsCallable("deleteAccount").call()
        } catch {
            ShareDiagnostics.log("❌ cuenta: deleteAccount: \(error.localizedDescription)")
            let failure = SignInFailure.from(error)
            errorMessage = failure == .network
                ? failure?.message
                : appLocalized("No se pudo borrar la cuenta. Inténtalo de nuevo en unos minutos.")
            sharing.startFirestoreListener()
            return false
        }
        ShareDiagnostics.log("🗑️ cuenta borrada")
        await forgetLocalAccountState()
        UserDefaults.standard.removeObject(forKey: Self.lastUIDKey)
        GIDSignIn.sharedInstance.signOut()
        try? Auth.auth().signOut()
        refreshUser()
        return true
    }

    // MARK: - Errores

    private func report(_ error: any Error, context: String) {
        guard let failure = SignInFailure.from(error) else { return }   // canceló
        let nsError = error as NSError
        ShareDiagnostics.log("❌ cuenta (\(context)): \(nsError.domain) \(nsError.code) \(error.localizedDescription)")
        errorMessage = failure.message
    }

    // MARK: - Nonce

    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in charset[Int(generator.next() % UInt64(charset.count))] })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Demostración

#if DEBUG
extension AccountService {
    /// Las capturas de la tienda (`-seedDemoData`, `-demoScreen`) y las pruebas
    /// a mano (`-skipSignIn`) no pasan por la pantalla de inicio de sesión: usan
    /// una cuenta de mentira que no toca Firebase. `-demoScreen signIn` (y
    /// `signInEmail`, con el formulario del correo abierto) la enseña.
    static var isDemo: Bool {
        DemoData.isRequested || DemoData.requestedScreen != nil
            || ProcessInfo.processInfo.arguments.contains("-skipSignIn")
    }

    static var forcesSignInScreen: Bool {
        DemoData.requestedScreen?.hasPrefix("signIn") == true
    }

    static var demoUser: AccountUser? {
        if forcesSignInScreen { return nil }
        return AccountUser(
            uid: "demo",
            name: ShareNames.myName ?? "Ana",
            email: "ana@example.com",
            isAnonymous: false,
            providers: [appleProviderID]
        )
    }
}
#endif

// MARK: - Apple otra vez (para borrar la cuenta)

/// Pide de nuevo la autorización de Apple y devuelve su código, que Firebase
/// usa para revocar el token de Sign in with Apple (exigido al borrar la cuenta).
@MainActor
private final class AppleReauthorization: NSObject, ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<String, any Error>?
    private var keepAlive: AppleReauthorization?
    private let anchor: ASPresentationAnchor?

    override init() {
        anchor = UIApplication.shared.foregroundKeyWindow
    }

    func authorizationCode() async throws -> String {
        guard anchor != nil else {
            throw NSError(domain: SignInFailure.appleAuthDomain, code: ASAuthorizationError.failed.rawValue)
        }
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = []
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        keepAlive = self
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        let code = (authorization.credential as? ASAuthorizationAppleIDCredential)?
            .authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
        MainActor.assumeIsolated {
            if let code {
                finish(.success(code))
            } else {
                finish(.failure(NSError(domain: SignInFailure.appleAuthDomain, code: ASAuthorizationError.failed.rawValue)))
            }
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        MainActor.assumeIsolated {
            finish(.failure(error))
        }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            // Comprobada en `authorizationCode()`.
            anchor ?? UIApplication.shared.foregroundKeyWindow!
        }
    }

    private func finish(_ result: Result<String, any Error>) {
        continuation?.resume(with: result)
        continuation = nil
        keepAlive = nil
    }
}

// MARK: - Ventanas

extension UIApplication {
    /// La ventana principal de la escena en primer plano.
    var foregroundKeyWindow: UIWindow? {
        let scenes = connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.keyWindow ?? scene?.windows.first
    }

    /// Desde donde presentar el inicio de sesión de Google.
    var topViewController: UIViewController? {
        var top = foregroundKeyWindow?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
