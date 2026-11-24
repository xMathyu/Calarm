//
//  FirebaseSession.swift
//  Calarm
//
//  La puerta a Firebase: configuración al arrancar, el usuario con cuenta, el
//  documento `users/{uid}` (nombre, idioma, tokens de push) y el token de FCM.
//
//  Lo compartido vive en Firebase para que un iPhone y un Android puedan
//  compartir (contrato en calarmi-firebase/DESIGN.md); lo propio sigue en
//  SwiftData + iCloud y no pasa por aquí.
//
//  La cuenta es obligatoria (DESIGN.md › «Identidad»): la abre `AccountService`
//  con Apple, Google o correo. Ya no hay sesiones anónimas; la de un probador de
//  una versión anterior se vincula a la cuenta al iniciar sesión, y mientras
//  tanto no cuenta como sesión (`uid` es nil). FCM arranca apagado
//  (`FirebaseMessagingAutoInitEnabled` = NO en Info.plist) y se enciende al
//  entrar.
//

import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions
import FirebaseMessaging
import Foundation
import os

@MainActor
final class FirebaseSession: NSObject {
    static let shared = FirebaseSession()

    /// Sin `GoogleService-Info.plist` en el bundle (una compilación sin la
    /// configuración) Firebase no arranca: lo compartido avisa con un error en
    /// vez de cerrar la app.
    private(set) var isConfigured = false

    private static let log = Logger(subsystem: "MathyuSolutions.Calarm", category: "firebase")
    /// El último token de FCM subido a `users/{uid}.tokens`, para quitarlo
    /// cuando FCM lo cambie.
    private static let uploadedTokenKey = "calarm.firebase.uploadedFCMToken"
    /// El último token de FCM de este dispositivo, con o sin sesión: al entrar
    /// se sube a la cuenta.
    nonisolated private static let currentTokenKey = "calarm.firebase.currentFCMToken"

    // MARK: - Arranque

    /// Llamado desde `AppDelegate` al arrancar, antes de cualquier otra cosa
    /// de Firebase.
    func configure() {
        guard !isConfigured else { return }
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else {
            Self.log.error("GoogleService-Info.plist no está en el bundle: lo compartido queda apagado")
            ShareDiagnostics.log("⚠️ Firebase sin configurar (falta GoogleService-Info.plist)")
            return
        }
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        isConfigured = true
        #if DEBUG
        useEmulatorsIfRequested()
        #endif
        Messaging.messaging().delegate = self
        // La sesión vive en el llavero: con cuenta, su token de push vuelve a
        // llegar al arrancar.
        if uid != nil {
            Messaging.messaging().isAutoInitEnabled = true
        }
    }

    #if DEBUG
    /// `-firebaseEmulators`: Auth, Firestore y Functions contra el Local Emulator
    /// Suite de calarmi-firebase (`firebase emulators:start`), en los puertos de
    /// su firebase.json. Para probar el correo y la contraseña sin crear cuentas
    /// de verdad.
    private func useEmulatorsIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-firebaseEmulators") else { return }
        let host = "127.0.0.1"
        Auth.auth().useEmulator(withHost: host, port: 9099)
        let settings = Firestore.firestore().settings
        settings.host = "\(host):8080"
        settings.isSSLEnabled = false
        settings.cacheSettings = MemoryCacheSettings()
        Firestore.firestore().settings = settings
        Functions.functions(region: AccountService.functionsRegion).useEmulator(withHost: host, port: 5001)
        ShareDiagnostics.log("🧪 Firebase: emuladores locales")
    }
    #endif

    // MARK: - Sesión

    /// El usuario con cuenta de este dispositivo, o nil sin sesión. Una sesión
    /// anónima de una versión anterior no cuenta: hasta que la persona inicie
    /// sesión (y se vincule) no se lee ni se escribe nada con ella.
    var uid: String? {
        guard isConfigured, let user = Auth.auth().currentUser, !user.isAnonymous else { return nil }
        return user.uid
    }

    var db: Firestore { Firestore.firestore() }

    /// El uid para compartir: sin cuenta, el error que lo explica. La pantalla
    /// de inicio de sesión tapa la app, así que esto solo pasa justo al cerrar
    /// sesión o con una invitación que llegó antes de iniciarla.
    func requireUID() throws -> String {
        guard isConfigured else { throw SharedRemindersError.firebaseUnavailable }
        guard let uid else { throw SharedRemindersError.signInRequired }
        return uid
    }

    /// Recién iniciada la sesión (y escrito `users/{uid}`): enciende FCM y sube
    /// el token que ya hubiera (el de una sesión anterior se quedó en el
    /// documento de esa cuenta).
    func didSignIn() async {
        guard isConfigured else { return }
        Messaging.messaging().isAutoInitEnabled = true
        if let token = UserDefaults.standard.string(forKey: Self.currentTokenKey) {
            await register(fcmToken: token)
        }
    }

    /// Antes de cerrar sesión: el token de este teléfono sale de
    /// `users/{uid}.tokens`, para que los avisos de esa cuenta dejen de llegar
    /// aquí. Sin red no espera más de unos segundos (la escritura queda en
    /// cola de esa cuenta).
    func unregisterPushToken() async {
        let defaults = UserDefaults.standard
        defer { defaults.removeObject(forKey: Self.uploadedTokenKey) }
        guard let uid, let token = defaults.string(forKey: Self.uploadedTokenKey) else { return }
        let ref = db.collection("users").document(uid)
        let removed = await Self.withTimeout(seconds: 4) {
            try? await ref.updateData([FieldPath(["tokens", token]): FieldValue.delete()])
        }
        ShareDiagnostics.log(removed ? "🔕 Firebase: token de push quitado" : "⚠️ Firebase: token de push sin quitar (sin red)")
    }

    /// Tras un cambio de cuenta o borrar la cuenta: el token subido era de la
    /// otra cuenta; el de esta se sube al entrar.
    func forgetUploadedPushToken() {
        UserDefaults.standard.removeObject(forKey: Self.uploadedTokenKey)
    }

    /// Corre `operation` y devuelve true si terminó antes del plazo. Las
    /// escrituras de Firestore no vuelven hasta que el servidor confirma (sin
    /// red, nunca) y no se pueden cancelar: la operación sigue sola si se pasa.
    static func withTimeout(seconds: Double, _ operation: @escaping @MainActor () async -> Void) async -> Bool {
        final class Once {
            private var done = false
            func claim() -> Bool {
                defer { done = true }
                return !done
            }
        }
        let once = Once()
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                await operation()
                if once.claim() { continuation.resume(returning: true) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                if once.claim() { continuation.resume(returning: false) }
            }
        }
    }

    // MARK: - Perfil

    /// `users/{uid}`: el nombre que ven los demás, el idioma y la plataforma.
    /// Solo con la sesión ya abierta. El nombre es el de la cuenta (su copia en
    /// `ShareNames`).
    func updateProfile() async {
        guard let uid else { return }
        var data: [String: Any] = [
            "language": InviteLink.pageLanguage(),
            "platform": "ios",
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        if let name = FirestoreMapping.validName(ShareNames.myName)
            ?? FirestoreMapping.validName(Auth.auth().currentUser?.displayName) {
            data["name"] = name
        }
        do {
            try await db.collection("users").document(uid).setData(data, merge: true)
        } catch {
            ShareDiagnostics.log("❌ Firebase: perfil: \(error.localizedDescription)")
        }
    }

    // MARK: - Push

    /// El token de APNs, a mano: el proxy de Firebase está apagado
    /// (`FirebaseAppDelegateProxyEnabled` = NO) para que no se meta entre la app
    /// y los avisos de CloudKit, que siguen llegando por el mismo delegado.
    func setAPNsToken(_ token: Data) {
        guard isConfigured else { return }
        Messaging.messaging().apnsToken = token
    }

    /// Sube el token de FCM a `users/{uid}.tokens` (y quita el anterior), para
    /// que las funciones sepan a dónde mandar los avisos. Sin sesión no hace
    /// nada: se sube cuando se abra.
    func register(fcmToken: String) async {
        guard let uid else { return }
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: Self.uploadedTokenKey)
        let ref = db.collection("users").document(uid)
        do {
            try await ref.setData([
                "tokens": [fcmToken: ["platform": "ios", "updatedAt": FieldValue.serverTimestamp()]],
                "platform": "ios",
                "updatedAt": FieldValue.serverTimestamp(),
            ], merge: true)
            if let previous, previous != fcmToken {
                try? await ref.updateData([FieldPath(["tokens", previous]): FieldValue.delete()])
            }
            defaults.set(fcmToken, forKey: Self.uploadedTokenKey)
            if previous != fcmToken {
                ShareDiagnostics.log("🔔 Firebase: token de push registrado")
            }
        } catch {
            ShareDiagnostics.log("❌ Firebase: token de push: \(error.localizedDescription)")
        }
    }
}

extension FirebaseSession: MessagingDelegate {
    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken else { return }
        UserDefaults.standard.set(fcmToken, forKey: FirebaseSession.currentTokenKey)
        Task { @MainActor in
            await FirebaseSession.shared.register(fcmToken: fcmToken)
        }
    }
}

// MARK: - Valores leídos

/// Lo que devuelve Firestore, listo para `FirestoreMapping`: cada `Timestamp`
/// pasa a `Date`, también dentro de mapas y listas.
nonisolated enum FirestoreValues {
    /// Los datos de un documento (o vacío si no existe).
    static func document(_ data: [String: Any]?) -> [String: Any] {
        (data ?? [:]).mapValues(normalized)
    }

    static func normalized(_ value: Any) -> Any {
        switch value {
        case let timestamp as Timestamp: return timestamp.dateValue()
        case let map as [String: Any]: return map.mapValues(normalized)
        case let list as [Any]: return list.map(normalized)
        default: return value
        }
    }

    /// Permiso denegado: en un share que no existe también (las reglas leen
    /// `resource.data` y sobre un documento ausente fallan), así que para el
    /// dueño significa «no existe o no es mío».
    static func isPermissionDenied(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == FirestoreErrorDomain
            && nsError.code == FirestoreErrorCode.permissionDenied.rawValue
    }

    static func isNotFound(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == FirestoreErrorDomain
            && nsError.code == FirestoreErrorCode.notFound.rawValue
    }
}
