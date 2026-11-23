//
//  FirebaseSmokeTest.swift
//  Calarm
//
//  `-firebaseSmokeTest` (solo DEBUG): recorre contra el proyecto real lo que el
//  dueño hace en Firestore — sesión anónima, compartir una alarma con foto,
//  editarla, ver a quién se unió, quitarlo, la lista de personas de confianza
//  con un cambio de un ayudante — y lo borra todo al final (share, invitaciones,
//  perfil y el usuario anónimo). El otro lado (unirse, salir, editar como
//  ayudante) lo hace un segundo usuario por la API REST, con las mismas reglas.
//  Cada paso sale por consola como «SMOKE …».
//
//  Úsalo en un simulador aparte: comparte TODAS las alarmas locales con la
//  lista de confianza mientras dura.
//

#if DEBUG
import FirebaseAuth
import FirebaseFirestore
import SwiftData
import UIKit

enum FirebaseSmokeTest {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-firebaseSmokeTest")
    }

    /// `-firebaseSmokeCleanup`: solo borra el perfil y el usuario anónimo de este
    /// simulador (tras probar el lado del invitado con `-demoOpenURL calarm://s/…`).
    static var isCleanupRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-firebaseSmokeCleanup")
    }

    @MainActor
    static func cleanUpUser() async {
        guard let uid = FirebaseSession.shared.uid else {
            say("cleanup: sin sesión")
            return
        }
        try? await FirebaseSession.shared.db.collection("users").document(uid).delete()
        do {
            try await Auth.auth().currentUser?.delete()
            say("cleanup: anonymous user deleted")
        } catch {
            say("cleanup: delete failed \(error.localizedDescription)")
        }
    }

    static let title = "ZZ Prueba Firebase (borrar)"

    private static func say(_ line: String) {
        print("SMOKE \(line)")
        ShareDiagnostics.log("🧪 \(line)")
    }

    @MainActor
    static func run(
        sharing: SharedRemindersService,
        delegation: DelegationService,
        settings: AppSettings,
        container: ModelContainer
    ) async {
        let context = container.mainContext
        let db = FirebaseSession.shared.db
        var reminder: Reminder?
        do {
            if ShareNames.myName == nil { ShareNames.setForDemo("Smoke iOS") }
            let uid = try await FirebaseSession.shared.signIn()
            say("signin ok uid=\(uid)")

            // 1. Compartir una alarma con foto.
            let alarm = Reminder(
                title: title,
                date: Date().addingTimeInterval(3 * 86_400),
                category: .event,
                iconKind: .photo,
                recurrence: .weekly(interval: 1, weekdays: [.monday, .wednesday]),
                leadTimes: [.atStart, .min15]
            )
            alarm.photoData = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 600)).image { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
            }.jpegData(compressionQuality: 0.8)
            context.insert(alarm)
            try context.save()
            reminder = alarm
            let url = try await sharing.prepareFirestoreInvite(for: alarm)
            let token = InviteLink.firestoreToken(from: url) ?? "?"
            say("invite url=\(url.absoluteString) share=\(alarm.id.uuidString) token=\(token)")
            let invite = try await sharing.fetchInvite(token)
            say("invite read kind=\(invite.kind.rawValue) targetMatches=\(invite.targetID == alarm.id.uuidString) ownerMatches=\(invite.ownerUID == uid)")
            let photo = try await db.collection("shares").document(alarm.id.uuidString)
                .collection("photo").document("current").getDocument(source: .server)
            say("photo doc exists=\(photo.exists) bytes=\((photo.data()?["jpeg"] as? Data)?.count ?? 0)")

            // 2. El dueño la edita: revision + 1.
            alarm.title = title + " v2"
            alarm.updatedAt = Date()
            try context.save()
            await sharing.pushUpdateIfShared(alarm)
            let shareDoc = try await db.collection("shares").document(alarm.id.uuidString).getDocument(source: .server)
            let content = shareDoc.data()?["alarm"] as? [String: Any]
            say("after edit revision=\(shareDoc.data()?["revision"] ?? "nil") title=\(content?["title"] ?? "nil")")

            // 3. Esperar a que el segundo usuario se una (REST).
            say("WAITING_JOIN")
            var overview = await sharing.shareOverview(forReminder: alarm)
            for _ in 0..<90 where overview.people.isEmpty {
                try await Task.sleep(for: .seconds(2))
                overview = await sharing.shareOverview(forReminder: alarm)
            }
            say("members=\(overview.people.map(\.name)) firestore=\(overview.isOnFirestore)")
            if let person = overview.people.first {
                try await sharing.removeParticipant(person, from: overview, id: alarm.id)
                overview = await sharing.shareOverview(forReminder: alarm)
                say("after owner removal members=\(overview.people.count)")
            }

            // 4. Personas de confianza: lista, invitación y un cambio del ayudante.
            let delegationURL = try await delegation.enable()
            settings.delegationEnabled = true
            say("delegation url=\(delegationURL.absoluteString) principal=\(uid) reminder=\(alarm.id.uuidString)")
            say("WAITING_HELPER")
            var helpers = await delegation.participantInfos()
            for _ in 0..<90 where helpers.isEmpty {
                try await Task.sleep(for: .seconds(2))
                helpers = await delegation.participantInfos()
            }
            say("helpers=\(helpers.map(\.name))")
            var applied = false
            for _ in 0..<45 {
                await delegation.pullPrincipalChanges()
                if alarm.title == "ZZ editada por ayudante" { applied = true; break }
                try await Task.sleep(for: .seconds(2))
            }
            say("helper edit applied=\(applied) title=\(alarm.title)")
            if let helper = helpers.first {
                await delegation.removeHelper(helper)
                say("after helper removal helpers=\(await delegation.participantInfos().count)")
            }
        } catch {
            say("FAIL \(error) \(error.localizedDescription)")
        }

        // 5. Limpieza: nada de la prueba queda en Firebase ni en el teléfono.
        let delegationToken = UserDefaults.standard.string(forKey: DelegationService.inviteTokenKey)
        if settings.delegationEnabled {
            await delegation.disableDelegation()
            settings.delegationEnabled = false
        }
        if let reminder {
            let id = reminder.id
            let token = FirestoreShareStore.owned(id)?.inviteToken
            await sharing.deleteSharedRecord(forReminderID: id)
            let gone = (try? await db.collection("shares").document(id.uuidString).getDocument(source: .server)) == nil
            say("share deleted (unreadable now)=\(gone)")
            if let token {
                let revoked = try? await db.collection("invites").document(token).getDocument(source: .server).data()?["revoked"]
                say("invite revoked=\(String(describing: revoked))")
                try? await db.collection("invites").document(token).delete()
            }
            context.delete(reminder)
            try? context.save()
        }
        if let token = delegationToken {
            try? await db.collection("invites").document(token).delete()
        }
        if let uid = FirebaseSession.shared.uid {
            try? await db.collection("users").document(uid).delete()
            do {
                try await Auth.auth().currentUser?.delete()
                say("anonymous user deleted")
            } catch {
                say("anonymous user delete failed: \(error.localizedDescription)")
            }
        }
        say("DONE")
    }
}
#endif
