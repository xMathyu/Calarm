//
//  CalarmApp.swift
//  Calarm
//

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
        self._sharedRemindersService = State(initialValue: SharedRemindersService(modelContainer: modelContainer))
        self._categoryStore = State(initialValue: CategoryStore(context: modelContainer.mainContext))
        self.alarmScheduler = alarmScheduler
        self.calendarSource = calendarSource
        self.modelContainer = modelContainer
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
                // Ingest a share accepted before the UI subscribed (e.g. a cold
                // launch straight from the invite link).
                if let pending = appDelegate.pendingShareMetadata {
                    ShareDiagnostics.log("🧊 pendiente en arranque")
                    await acceptIncomingShare(pending)
                }
                // Reliable fallback: scan the shared DB for received reminders,
                // since the acceptance callback is unreliable in SwiftUI.
                await sharedRemindersService.importAllSharedReminders()
                await syncAllReminders()
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
                }
            }
            // Reliable handoff for share acceptance (see AppDelegate): the system
            // callback posts this notification, which we always receive here.
            .onReceive(NotificationCenter.default.publisher(for: .calarmDidAcceptShare)) { note in
                ShareDiagnostics.log("🔔 notificación recibida")
                guard let metadata = note.object as? CKShare.Metadata else { return }
                Task { await acceptIncomingShare(metadata) }
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
        do {
            try await sharedRemindersService.acceptShare(metadata: metadata)
            appDelegate.clearPendingShareMetadata()
            await syncAllReminders()
        } catch {
            // `acceptShare` already recorded `acceptErrorMessage` for the alert.
            AppDelegate.log.error("Share ingest failed: \(error.localizedDescription)")
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
