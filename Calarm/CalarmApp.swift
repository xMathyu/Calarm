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
        let meetingPreferences = MeetingPreferencesStore()
        let modelContainer = Self.makeModelContainer()

        self._settings = State(initialValue: settings)
        self._reminderScheduler = State(initialValue: reminderScheduler)
        self._teamsCoordinator = State(initialValue: nil)
        self._meetingPreferences = State(initialValue: meetingPreferences)
        let sharedRemindersService = SharedRemindersService(modelContainer: modelContainer)
        self._sharedRemindersService = State(initialValue: sharedRemindersService)
        self._delegationService = State(initialValue: DelegationService(modelContainer: modelContainer, sharing: sharedRemindersService, scheduler: reminderScheduler))
        self._categoryStore = State(initialValue: CategoryStore(context: modelContainer.mainContext))
        self.alarmScheduler = alarmScheduler
        self.calendarSource = calendarSource
        self.modelContainer = modelContainer

        // Re-register the Siri phrases on every launch so the system picks up
        // changes to CalarmAppShortcuts (and AppShortcuts.xcstrings) without
        // requiring a reinstall.
        CalarmAppShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                alarmScheduler: alarmScheduler,
                onTeamsToggleChanged: handleTeamsToggle,
                teamsCoordinatorProvider: { teamsCoordinator }
            )
            .environment(settings)
            .environment(reminderScheduler)
            .environment(meetingPreferences)
            .environment(sharedRemindersService)
            .environment(delegationService)
            .environment(categoryStore)
            .modelContainer(modelContainer)
            .preferredColorScheme(settings.appearance.preferredColorScheme)
            .tint(settings.accentColor)
            // Drives FormatStyle resolution (dates, numbers) so they match
            // the language override even when iOS's locale would say otherwise.
            .environment(\.locale, localization.currentLocale)
            // Forces every Text(...) to re-evaluate after a language switch.
            .id(localization.revision)
            .task {
                UIApplication.shared.installGlobalKeyboardDismissGesture()
                await syncAllReminders()
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
                if settings.teamsDetectionEnabled {
                    bootstrapTeamsCoordinator()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active, settings.onboardingCompleted {
                    Task { await syncAllReminders() }
                    Task { await teamsCoordinator?.sync() }
                    // Re-scan on foreground — this is when a freshly accepted
                    // share's zone shows up ("Calarm se abre sola" after Open).
                    Task {
                        await sharedRemindersService.importAllSharedReminders()
                        await syncAllReminders()
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
            // Reliable handoff for share acceptance (see AppDelegate): the system
            // callback posts this notification, which we always receive here.
            .onReceive(NotificationCenter.default.publisher(for: .calarmDidAcceptShare)) { note in
                ShareDiagnostics.log("🔔 notificación recibida")
                guard let metadata = note.object as? CKShare.Metadata else { return }
                Task { await acceptIncomingShare(metadata) }
            }
            // Silent CloudKit push: a per-record share changed, OR (for a principal)
            // a trusted helper edited/deleted one of their alarms in the
            // delegation zone. Re-sync both paths.
            .onReceive(NotificationCenter.default.publisher(for: .calarmSharedDataChanged)) { _ in
                Task {
                    await sharedRemindersService.importAllSharedReminders()
                    if settings.delegationEnabled {
                        await delegationService.pullPrincipalChanges()
                    }
                    await syncAllReminders()
                }
            }
            // A reminder was created/edited outside the main editor (AI assistant).
            // Mirror it up to trusted helpers.
            .onReceive(NotificationCenter.default.publisher(for: .calarmLocalRemindersChanged)) { _ in
                guard settings.delegationEnabled else { return }
                Task { await delegationService.reconcileUp() }
            }
            // A reminder was deleted outside the main editor; remove its zone record.
            .onReceive(NotificationCenter.default.publisher(for: .calarmReminderDeleted)) { note in
                guard settings.delegationEnabled, let id = note.object as? UUID else { return }
                Task { await delegationService.deleteZoneRecord(forReminderID: id) }
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

    @MainActor
    private func acceptIncomingShare(_ metadata: CKShare.Metadata) async {
        // A DELEGATION share (the whole-list, read/write kind) must NOT be ingested
        // into local SwiftData — that would make the principal's alarms ring on this
        // helper's phone. Route it to DelegationService, which only records access.
        let shareType = metadata.share[CKShare.SystemFieldKey.shareType] as? String
        if shareType == DelegationService.shareType {
            await delegationService.acceptDelegationShare(metadata: metadata)
            PendingShare.clear()
            return
        }
        do {
            try await sharedRemindersService.acceptShare(metadata: metadata)
            PendingShare.clear()
            await syncAllReminders()
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
        let validOwnerIDs = Set(reminders.map { ReminderScheduler.ownerID(forReminderID: $0.id) })
        await alarmScheduler.reconcileWithSystem { ownerID in
            // Calendar-owned alarms are reconciled by SyncCoordinator itself.
            ownerID.hasPrefix(SyncCoordinator.ownerIDPrefix) || validOwnerIDs.contains(ownerID)
        }
    }

    @MainActor
    private func syncAllReminders() async {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<Reminder>()
        guard let reminders = try? context.fetch(descriptor) else { return }
        await reminderScheduler.syncAlarms(for: reminders)
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
