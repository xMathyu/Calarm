//
//  AccountLogic.swift
//  Calarm
//
//  Las decisiones de la cuenta obligatoria (calarmi-firebase/DESIGN.md ›
//  «Identidad»), separadas de las llamadas a Firebase para poder probarlas:
//  qué nombre se elige al iniciar sesión, qué mensaje ve la persona cuando algo
//  falla y si el teléfono cambió de cuenta.
//
//  No importa Firebase a propósito (como `FirestoreMapping`): los errores se
//  reconocen por dominio y código, los mismos que las pruebas fijan.
//

import Foundation

// MARK: - Nombre

enum AccountNaming {
    /// Los correos de «Ocultar mi correo» de Apple: su parte antes de la `@` es
    /// un código al azar, no un nombre.
    static let appleRelayDomain = "privaterelay.appleid.com"

    /// El nombre con el que la persona aparece ante los demás, el primero que
    /// exista (DESIGN.md › «El nombre sale de la cuenta»):
    /// 1. el que da el proveedor al iniciar sesión (Google, Apple la primera vez,
    ///    el campo «Nombre» de «Crear cuenta»);
    /// 2. el `displayName` que ya tenía el usuario de Firebase;
    /// 3. el que el teléfono guardaba de antes (`ShareNames.myName`);
    /// 4. la parte del correo antes de la `@`, con mayúscula inicial (salvo los
    ///    relés de Apple);
    /// 5. «Usuario de Calarmi», en el idioma de la app.
    static func resolve(
        providerName: String?,
        currentDisplayName: String?,
        legacyName: String?,
        email: String?,
        fallback: String
    ) -> String {
        for candidate in [providerName, currentDisplayName, legacyName] {
            if let name = FirestoreMapping.validName(candidate) { return name }
        }
        return name(fromEmail: email) ?? fallback
    }

    /// «ana.garcia@gmail.com» → «Ana.garcia». Nil sin correo, con uno sin parte
    /// local o con un relé de Apple.
    static func name(fromEmail email: String?) -> String? {
        let trimmed = (email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.lastIndex(of: "@") else { return nil }
        let domain = trimmed[trimmed.index(after: at)...].lowercased()
        guard domain != appleRelayDomain, !domain.hasSuffix("." + appleRelayDomain) else { return nil }
        let local = String(trimmed[..<at])
        guard let first = local.first else { return nil }
        return FirestoreMapping.validName(String(first).uppercased() + local.dropFirst())
    }

    /// «Ana María García» a partir de lo que da Apple (o nil si no dio nada).
    static func fullName(_ components: PersonNameComponents?) -> String? {
        guard let components else { return nil }
        return FirestoreMapping.validName(PersonNameComponentsFormatter().string(from: components))
    }
}

// MARK: - Cambio de cuenta

enum AccountSwitch {
    enum Decision: Equatable {
        /// La misma cuenta de antes (o la primera en este teléfono): todo sigue.
        case keep
        /// Otra cuenta: se borran las copias de lo que compartieron con la
        /// anterior y lo de personas de confianza; lo propio queda sin compartir.
        case cleanUp
    }

    /// `lastUID`: el último usuario que vio este teléfono (anónimo incluido).
    /// Sin él, lo que el teléfono recuerde de Firebase es de una sesión que se
    /// perdió: tampoco es de la cuenta que entra.
    static func decision(lastUID: String?, newUID: String, hasLocalFirebaseState: Bool) -> Decision {
        if let lastUID { return lastUID == newUID ? .keep : .cleanUp }
        return hasLocalFirebaseState ? .cleanUp : .keep
    }
}

// MARK: - Errores

/// Lo que la persona ve cuando iniciar sesión (o borrar la cuenta) falla. Nil
/// en `from(...)` = canceló: no se dice nada.
enum SignInFailure: Equatable {
    /// Correo o contraseña equivocados, o no hay cuenta con ese correo: un solo
    /// mensaje, para no revelar qué correos tienen cuenta.
    case wrongCredentials
    case emailInUse
    case weakPassword
    case invalidEmail
    case network
    case tooManyRequests
    case accountDisabled
    /// El correo ya tiene cuenta con otro método (p. ej. contraseña y ahora Apple).
    case otherProvider
    /// Compilación sin `GoogleService-Info.plist`.
    case unavailable
    case unknown

    // Dominios y códigos de los SDK (fijados en AccountLogicTests).
    static let firebaseAuthDomain = "FIRAuthErrorDomain"
    static let appleAuthDomain = "com.apple.AuthenticationServices.AuthorizationError"
    static let googleSignInDomain = "com.google.GIDSignIn"
    static let functionsDomain = "com.firebase.functions"

    enum AuthCode {
        static let invalidCredential = 17004
        static let userDisabled = 17005
        static let emailAlreadyInUse = 17007
        static let invalidEmail = 17008
        static let wrongPassword = 17009
        static let tooManyRequests = 17010
        static let userNotFound = 17011
        static let accountExistsWithDifferentCredential = 17012
        static let networkError = 17020
        static let credentialAlreadyInUse = 17025
        static let weakPassword = 17026
        static let webContextCancelled = 17058
    }

    /// `ASAuthorizationError.canceled`.
    static let appleCanceled = 1001
    /// `GIDSignInError.canceled`.
    static let googleCanceled = -5
    /// `FunctionsErrorCode.unavailable` y `.deadlineExceeded`.
    static let functionsUnavailable = 14
    static let functionsDeadlineExceeded = 4

    static func from(_ error: any Error) -> SignInFailure? {
        let nsError = error as NSError
        if nsError.domain == firebaseAuthDomain || nsError.domain == functionsDomain,
           let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSURLErrorDomain {
            return .network
        }
        return from(domain: nsError.domain, code: nsError.code)
    }

    static func from(domain: String, code: Int) -> SignInFailure? {
        switch domain {
        case firebaseAuthDomain:
            switch code {
            case AuthCode.invalidCredential, AuthCode.wrongPassword, AuthCode.userNotFound:
                return .wrongCredentials
            case AuthCode.emailAlreadyInUse, AuthCode.credentialAlreadyInUse:
                return .emailInUse
            case AuthCode.weakPassword: return .weakPassword
            case AuthCode.invalidEmail: return .invalidEmail
            case AuthCode.networkError: return .network
            case AuthCode.tooManyRequests: return .tooManyRequests
            case AuthCode.userDisabled: return .accountDisabled
            case AuthCode.accountExistsWithDifferentCredential: return .otherProvider
            case AuthCode.webContextCancelled: return nil
            default: return .unknown
            }
        case appleAuthDomain:
            return code == appleCanceled ? nil : .unknown
        case googleSignInDomain:
            return code == googleCanceled ? nil : .unknown
        case functionsDomain:
            return code == functionsUnavailable || code == functionsDeadlineExceeded ? .network : .unknown
        case NSURLErrorDomain:
            return code == NSURLErrorCancelled ? nil : .network
        default:
            return .unknown
        }
    }

    var message: String {
        switch self {
        case .wrongCredentials:
            appLocalized("El correo o la contraseña no son correctos.")
        case .emailInUse:
            appLocalized("Ya hay una cuenta con este correo. Inicia sesión con él.")
        case .weakPassword:
            appLocalized("Esa contraseña es muy fácil de adivinar. Usa al menos 8 caracteres.")
        case .invalidEmail:
            appLocalized("Revisa el correo: no parece válido.")
        case .network:
            appLocalized("No hay conexión. Revisa tu internet e inténtalo de nuevo.")
        case .tooManyRequests:
            appLocalized("Demasiados intentos. Espera unos minutos e inténtalo de nuevo.")
        case .accountDisabled:
            appLocalized("Esta cuenta está desactivada.")
        case .otherProvider:
            appLocalized("Este correo ya tiene una cuenta. Entra con el método que usaste para crearla.")
        case .unavailable:
            appLocalized("Iniciar sesión no está disponible en esta versión de la app.")
        case .unknown:
            appLocalized("No se pudo iniciar sesión. Inténtalo de nuevo.")
        }
    }
}

// MARK: - Contraseña

enum PasswordRules {
    /// DESIGN.md: «contraseña de 8 caracteres o más».
    static let minimumLength = 8

    static func isLongEnough(_ password: String) -> Bool {
        password.count >= minimumLength
    }

    /// Lo justo para no mandar algo que seguro no es un correo.
    static func looksLikeEmail(_ email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.firstIndex(of: "@"), at != trimmed.startIndex else { return false }
        let domain = trimmed[trimmed.index(after: at)...]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".") && !trimmed.contains(" ")
    }
}
