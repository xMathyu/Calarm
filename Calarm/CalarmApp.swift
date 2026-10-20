//
//  CalarmApp.swift
//  Calarm
//

import AppIntents
import CloudKit
import os
import SwiftData
import SwiftUI

@main
struct CalarmApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var settings: AppSettings
    @State private var reminderScheduler: ReminderScheduler
    @State private var teamsCoordinator: SyncCoordinator?
    @State private var meetingPreferences: MeetingPreferencesStore
    @State private var sharedRemindersService: SharedRemindersService
    @State private var delegationService: DelegationService
    @State private var categoryStore: CategoryStore
    @State private var challengeCoordinator: ChallengeCoordinator
    @State private var localization = LocalizationManager.shared

    private let alarmScheduler: AlarmScheduler
    private let modelContainer: ModelContainer
    private let calendarSource: CalendarSource

    @Environment(\.scenePhase) private var scenePhase

    init() {
        let settings = AppSettings()
        let alarmStore = AlarmStore()
        let alarmScheduler = AlarmScheduler(store: alarmStore)
        let reminderScheduler = ReminderScheduler(scheduler: alarmScheduler, settings: settings)
        let calendarSource = EventKitCalendarSource()
        let meetingPreferences = MeetingPreferencesStore(settings: settings)
        let modelContainer = Self.makeModelContainer()

        self._settings = State(initialValue: settings)
        self._reminderScheduler = State(initialValue: reminderScheduler)
        self._teamsCoordinator = State(initialValue: nil)
        self._meetingPreferences = State(initialValue: meetingPreferences)
        let sharedRemindersService = SharedRemindersService(modelContainer: modelContainer, scheduler: reminderScheduler)
        self._sharedRemindersService = State(initialValue: sharedRemindersService)
        let delegationService = DelegationService(modelContainer: modelContainer, sharing: sharedRemindersService, scheduler: reminderScheduler)
        self._delegationService = State(initialValue: delegationService)
        self._categoryStore = State(initialValue: CategoryStore(context: modelContainer.mainContext))
        let challengeCoordinator = ChallengeCoordinator(
            alarmScheduler: alarmScheduler,
            reminderScheduler: reminderScheduler,
            modelContainer: modelContainer,
            settings: settings
        )
        self._challengeCoordinator = State(initialValue: challengeCoordinator)
        // «Detener» en la pantalla de bloqueo o el reloj sobre una alarma con
        // reto sin resolver: vuelve a sonar al minuto. El intent corre en este
        // proceso, así que el hook llega aunque la app estuviera cerrada.
        StopAlarmIntent.onStop = { alarmID in
            await challengeCoordinator.userStopped(alarmID: alarmID)
        }
        self.alarmScheduler = alarmScheduler
        self.calendarSource = calendarSource
        self.modelContainer = modelContainer

        // Silent CloudKit push: the owner of an alarm shared with us edited or
        // deleted it (a new time also posts a notification, see
        // `ShareChangeNotifier`), OR, for a principal, a trusted helper edited/
        // deleted one of their alarms in the delegation zone. Installed here, not
        // as an `.onReceive`, so it also runs when the push wakes the app in the
        // background with no window.
        let resyncSharedData: () async -> Void = {
            await sharedRemindersService.importAllSharedReminders()
            if settings.delegationEnabled {
                await delegationService.pullPrincipalChanges()
            }
            await Self.syncAllReminders(in: modelContainer, with: reminderScheduler)
        }
        AppDelegate.remoteChangeHandler = resyncSharedData
        // An invitation deleted on another device of this iCloud account: the
        // re-scan drops this device's copy too.
        DeletedSharesStore.startSyncing(onChange: resyncSharedData)

        // Re-register the Siri phrases on every launch so the system picks up
        // changes to CalarmAppShortcuts (and AppShortcuts.xcstrings) without
        // requiring a reinstall.
        CalarmAppShortcuts.updateAppShortcutParameters()

        #if DEBUG
        if DemoData.isRequested {
            DemoData.seed(into: modelContainer, settings: settings)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                alarmScheduler: alarmScheduler,
                onTeamsToggleChanged: handleTeamsToggle,
                teamsCoordinatorProvider: { teamsCoordinator },
                onCountdownChanged: { Task { await syncAllReminders() } }
            )
            .environment(settings)
            .environment(reminderScheduler)
            .environment(meetingPreferences)
            .environment(sharedRemindersService)
            .environment(delegationService)
            .environment(categoryStore)
            .environment(challengeCoordinator)
            .modelContainer(modelContainer)
            .preferredColorScheme(settings.appearance.preferredColorScheme)
            .tint(settings.accentColor)
            // Drives FormatStyle resolution (dates, numbers) so they match
            // the language override even when iOS's locale would say otherwise.
            .environment(\.locale, localization.currentLocale)
            // Forces every Text(...) to re-evaluate after a language switch.
            .id(localization.revision)
            // Invitations arriving as Calarm links (calarm-puce.vercel.app/i/…).
            // The CloudKit share metadata callbacks never fire for these, since
            // iOS only raises those for icloud.com URLs it opens itself.
            .onOpenURL { url in
                // El botón «Resolver» de la Live Activity de una alarma con reto.
                if let alarmID = ChallengeRequest.alarmID(from: url) {
                    challengeCoordinator.present(alarmID: alarmID)
                    return
                }
                // El enlace de una entrada del calendario «Calarm» abre su alarma.
                if let reminderID = CalendarMirrorService.reminderID(from: url) {
                    NotificationCenter.default.post(name: .calarmOpenReminder, object: reminderID)
                    return
                }
                guard InviteLink.isInvite(url) else { return }
                Task { await acceptInviteLink(url) }
            }
            .task {
                UIApplication.shared.installGlobalKeyboardDismissGesture()
                // Bring up the calendar coordinator FIRST so the "Calendario" tab
                // appears immediately on launch, instead of after the CloudKit work
                // below finishes (which made the tab show up several seconds late).
                if settings.teamsDetectionEnabled {
                    bootstrapTeamsCoordinator()
                }
                // Aparte: el aviso del permiso espera a que la persona conteste, y
                // el arranque de abajo no tiene por qué esperarla.
                Task { await requestCalendarAccessIfNeeded() }
                await syncAllReminders()
                // Si arranca con una alarma con reto sonando, el reto sale ya.
                challengeCoordinator.presentIfAlerting()
                // Cancel system alarms that no longer belong to anything: tracked
                // entries whose reminder was deleted, and alarms AlarmKit still has
                // but the store never knew about (pre-v2 formats). Without this,
                // a lost entry means the alarm rings forever with no way to stop it.
                await reconcileOrphanAlarms()
                // Accept + ingest a share captured before the UI subscribed
                // (e.g. a cold launch straight from the invite link).
                if let pending = PendingShare.metadata {
                    ShareDiagnostics.log("🧊 pendiente en arranque")
                    await acceptIncomingShare(pending)
                }
                // Reliable fallback: scan the shared DB for received reminders,
                // since the acceptance callback is unreliable in SwiftUI.
                await sharedRemindersService.importAllSharedReminders()
                await syncAllReminders()
                // Subscribe so owner edits/deletes arrive via silent push (the
                // scan above stays as a fallback if a push is missed).
                await sharedRemindersService.ensureSharedSubscription()
                // Delegation sync: pull helper changes (they ring here), push our
                // own changes up, and subscribe for future helper edits.
                if settings.delegationEnabled {
                    await delegationService.ensurePrincipalSubscription()
                    await delegationService.pullPrincipalChanges()
                    await delegationService.reconcileUp()
                    await syncAllReminders()
                }
            }
            .onChange(of: settings.onboardingCompleted) { _, completed in
                guard completed else { return }
                Task { await requestCalendarAccessIfNeeded() }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active, settings.onboardingCompleted {
                    challengeCoordinator.presentIfAlerting()
                    Task { await syncAllReminders() }
                    Task { await teamsCoordinator?.sync() }
                    // Re-scan on foreground — this is when a freshly accepted
                    // share's zone shows up ("Calarm se abre sola" after Open).
                    Task {
                        await sharedRemindersService.importAllSharedReminders()
                        await syncAllReminders()
                        await requestChangeNotificationsIfNeeded()
                    }
                    if settings.delegationEnabled {
                        Task {
                            await delegationService.pullPrincipalChanges()
                            await delegationService.reconcileUp()
                            await syncAllReminders()
                        }
                    }
                }
            }
            // «Resolver reto» en la alerta del sistema (`SolveChallengeIntent`).
            .onReceive(NotificationCenter.default.publisher(for: .calarmSolveChallenge)) { note in
                guard let alarmID = note.object as? UUID else { return }
                ChallengeRequest.clear()
                challengeCoordinator.present(alarmID: alarmID)
            }
            // Reliable handoff for share acceptance (see AppDelegate): the system
            // callback posts this notification, which we always receive here.
            .onReceive(NotificationCenter.default.publisher(for: .calarmDidAcceptShare)) { note in
                ShareDiagnostics.log("🔔 notificación recibida")
                guard let metadata = note.object as? CKShare.Metadata else { return }
                Task { await acceptIncomingShare(metadata) }
            }
            // A reminder was created/edited outside the main editor (AI assistant).
            // Push an edit to the invitees of a shared alarm, and mirror it up to
            // trusted helpers.
            .onReceive(NotificationCenter.default.publisher(for: .calarmLocalRemindersChanged)) { note in
                Task {
                    if let id = note.object as? UUID {
                        let descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.id == id })
                        if let reminder = try? modelContainer.mainContext.fetch(descriptor).first {
                            await sharedRemindersService.pushUpdateIfShared(reminder)
                        }
                    }
                    if settings.delegationEnabled {
                        await delegationService.reconcileUp()
                    }
                }
            }
            // A reminder was deleted outside the main editor (AI assistant): remove
            // its shared record, so invitees lose it too (a no-op for one that was
            // never shared, or was received), and its delegation zone record.
            .onReceive(NotificationCenter.default.publisher(for: .calarmReminderDeleted)) { note in
                guard let id = note.object as? UUID else { return }
                Task {
                    // A received invitation (the assistant tombstoned it before
                    // posting): drop out of its share instead, so the owner's
                    // «Personas» list stops showing us as joined.
                    if DeletedSharesStore.contains(id) {
                        await sharedRemindersService.leaveShare(forReminderID: id)
                        return
                    }
                    await sharedRemindersService.deleteSharedRecord(forReminderID: id)
                    if settings.delegationEnabled {
                        await delegationService.deleteZoneRecord(forReminderID: id)
                    }
                }
            }
            .alert(
                "No se pudo aceptar la invitación",
                isPresented: Binding(
                    get: { sharedRemindersService.acceptErrorMessage != nil },
                    set: { if !$0 { sharedRemindersService.clearAcceptError() } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(sharedRemindersService.acceptErrorMessage ?? "")
            }
        }
    }

    /// Accepts an invitation that arrived through one of Calarm's own links.
    ///
    /// Recovers the CloudKit share URL the link carries, fetches its metadata,
    /// and then hands it to exactly the same accept path the system callbacks
    /// use — so a link invitation and a native one end up in the same place.
    @MainActor
    private func acceptInviteLink(_ url: URL) async {
        guard let shareURL = InviteLink.shareURL(from: url) else {
            ShareDiagnostics.log("❌ enlace de invitación ilegible")
            return
        }
        // Feedback from the first instant: fetching the metadata, accepting and
        // ingesting are three CloudKit round trips, and the list only changes at
        // the very end — several seconds of nothing otherwise.
        sharedRemindersService.beginAcceptingShare()
        do {
            let metadata = try await sharedRemindersService.shareMetadata(for: shareURL)
            ShareDiagnostics.log("📥 invitación recibida (enlace Calarm)")
            await acceptIncomingShare(metadata)
        } catch {
            PendingShare.log.error("Invite link failed: \(error.localizedDescription)")
            ShareDiagnostics.log("❌ enlace de invitación: \(error.localizedDescription)")
            // Until now this failed in silence: no alarm and no error either.
            sharedRemindersService.reportAcceptFailure(error)
        }
    }

    @MainActor
    private func acceptIncomingShare(_ metadata: CKShare.Metadata) async {
        // A DELEGATION share (the whole-list, read/write kind) must NOT be ingested
        // into local SwiftData — that would make the principal's alarms ring on this
        // helper's phone. Route it to DelegationService, which only records access.
        //
        // Detect it two ways, because the custom `shareType` field doesn't always
        // survive in the accept metadata: (1) the shareType matches, or (2) the share
        // is ZONE-WIDE (no root record). A per-record reminder share always has a
        // root record; the delegation share is zone-wide and has none. Routing a
        // zone-wide share to the per-record path would fail to ingest (there's no
        // root record to fetch) — exactly the "no funciona invitarme a controlar tus
        // alarmas" symptom.
        let shareType = metadata.share[CKShare.SystemFieldKey.shareType] as? String
        let rootRecordID = metadata.hierarchicalRootRecordID ?? (metadata.rootRecordID as CKRecord.ID?)
        let isZoneWideShare = rootRecordID == nil
        if shareType == DelegationService.shareType || isZoneWideShare {
            ShareDiagnostics.log("🤝 ruteo a delegación (tipo=\(shareType ?? "nil"), zoneWide=\(isZoneWideShare))")
            // Not an alarm for this list: the «agregando…» toast doesn't apply.
            sharedRemindersService.clearIncomingShare()
            await delegationService.acceptDelegationShare(metadata: metadata)
            PendingShare.clear()
            return
        }
        do {
            try await sharedRemindersService.acceptShare(metadata: metadata)
            PendingShare.clear()
            await syncAllReminders()
            await requestChangeNotificationsIfNeeded()
        } catch {
            // `acceptShare` already recorded `acceptErrorMessage` for the alert.
            PendingShare.log.error("Share ingest failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func reconcileOrphanAlarms() async {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<Reminder>()
        let reminders = (try? context.fetch(descriptor)) ?? []
        let validReminderIDs = Set(reminders.map(\.id))
        await alarmScheduler.reconcileWithSystem { ownerID in
            // Calendar-owned alarms are reconciled by SyncCoordinator itself. The
            // rest (la alarma y los refuerzos de su reto) valen mientras exista
            // la alarma de Calarm detrás.
            if ownerID.hasPrefix(SyncCoordinator.ownerIDPrefix) { return true }
            guard let reminderID = ReminderScheduler.reminderID(fromOwnerID: ownerID) else { return false }
            return validReminderIDs.contains(reminderID)
        }
    }

    @MainActor
    private func syncAllReminders() async {
        await Self.syncAllReminders(in: modelContainer, with: reminderScheduler)
    }

    @MainActor
    private static func syncAllReminders(in modelContainer: ModelContainer, with reminderScheduler: ReminderScheduler) async {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<Reminder>()
        guard let reminders = try? context.fetch(descriptor) else { return }
        await reminderScheduler.syncAlarms(for: reminders)
    }

    /// An invitee hears about a shared alarm's new time through a notification,
    /// which needs permission. Asked once, and only once there's a received alarm
    /// to be notified about — not on top of onboarding.
    @MainActor
    private func requestChangeNotificationsIfNeeded() async {
        guard settings.onboardingCompleted, sharedRemindersService.hasReceivedShares else { return }
        await ShareChangeNotifier.requestAuthorizationIfNeeded()
    }

    /// El interruptor del calendario viene encendido, así que el aviso que salía
    /// al encenderlo no lo veía nadie: la lectura fallaba en silencio y la pestaña
    /// Calendario se quedaba vacía. Se pide al terminar la bienvenida (que no pide
    /// nada antes de presentarse) y, para quien ya la pasó, al abrir la app.
    @MainActor
    private func requestCalendarAccessIfNeeded() async {
        guard settings.onboardingCompleted, settings.teamsDetectionEnabled else { return }
        await teamsCoordinator?.requestAccessIfNeeded()
    }

    @MainActor
    private func handleTeamsToggle(_ enabled: Bool) {
        if enabled {
            bootstrapTeamsCoordinator()
            Task {
                _ = try? await calendarSource.requestAccess()
                teamsCoordinator?.start()
            }
        } else {
            teamsCoordinator?.stop()
            teamsCoordinator = nil
        }
    }

    /// Builds the SwiftData container. Tries iCloud-synced (private database) first;
    /// falls back to local-only if CloudKit isn't configured for the build.
    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema([Reminder.self, CustomCategory.self])
        let configuration = ModelConfiguration(
            schema: schema,
            cloudKitDatabase: .automatic
        )
        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            let localOnly = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            do {
                return try ModelContainer(for: schema, configurations: localOnly)
            } catch {
                fatalError("ModelContainer failed to initialize: \(error)")
            }
        }
    }

    @MainActor
    private func bootstrapTeamsCoordinator() {
        guard teamsCoordinator == nil else { return }
        let coordinator = SyncCoordinator(
            source: calendarSource,
            scheduler: alarmScheduler,
            settings: settings,
            preferences: meetingPreferences
        )
        teamsCoordinator = coordinator
        coordinator.start()
    }
}
