//
//  FirebaseSession.swift
//  Calarm
//
//  La puerta a Firebase: configuración al arrancar, la sesión anónima, el
//  documento `users/{uid}` (nombre, idioma, tokens de push) y el token de FCM.
//
//  Lo compartido vive en Firebase para que un iPhone y un Android puedan
//  compartir (contrato en calarmi-firebase/DESIGN.md); lo propio sigue en
//  SwiftData + iCloud y no pasa por aquí.
//
//  La sesión se abre SOLO cuando la persona usa algo compartido (invitar,
//  aceptar, personas de confianza, o una invitación de CloudKit que migra): cada
//  usuario anónimo cuenta para la cuota, y quien no comparte no tiene por qué
//  dejar rastro en ningún servidor. Por lo mismo FCM arranca apagado
//  (`FirebaseMessagingAutoInitEnabled` = NO en Info.plist) y se enciende al abrir
//  la sesión.
//

import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
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

    private var signInTask: Task<String, any Error>?

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
        Messaging.messaging().delegate = self
        // Quien ya compartió antes conserva la sesión (vive en el llavero): su
        // token de push vuelve a llegar al arrancar.
        if uid != nil {
            Messaging.messaging().isAutoInitEnabled = true
        }
    }

    // MARK: - Sesión

    /// El usuario anónimo de este dispositivo, si ya se abrió la sesión alguna vez.
    var uid: String? {
        isConfigured ? Auth.auth().currentUser?.uid : nil
    }

    var db: Firestore { Firestore.firestore() }

    /// Abre (o devuelve) la sesión anónima. La primera vez también deja el
    /// perfil en `users/{uid}` y enciende FCM.
    func signIn() async throws -> String {
        guard isConfigured else { throw SharedRemindersError.firebaseUnavailable }
        if let uid { return uid }
        // Dos pantallas que piden la sesión a la vez comparten la misma.
        if let running = signInTask { return try await running.value }
        let task = Task { () throws -> String in
            try await Auth.auth().signInAnonymously().user.uid
        }
        signInTask = task
        defer { signInTask = nil }
        let uid: String
        do {
            uid = try await task.value
        } catch {
            ShareDiagnostics.log("❌ Firebase: no se pudo abrir la sesión: \(error.localizedDescription)")
            throw SharedRemindersError.signInFailed(error)
        }
        ShareDiagnostics.log("🔑 Firebase: sesión anónima abierta")
        await updateProfile()
        Messaging.messaging().isAutoInitEnabled = true
        return uid
    }

    // MARK: - Perfil

    /// `users/{uid}`: el nombre que ven los demás, el idioma y la plataforma.
    /// Solo con la sesión ya abierta.
    func updateProfile() async {
        guard let uid else { return }
        var data: [String: Any] = [
            "language": InviteLink.pageLanguage(),
            "platform": "ios",
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        if let name = FirestoreMapping.validName(ShareNames.myName) {
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
