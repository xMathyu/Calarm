//
//  CalarmApp.swift
//  Calarm
//

import CloudKit
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
            .modelContainer(modelContainer)
            .preferredColorScheme(settings.appearance.preferredColorScheme)
            .tint(.accentColor)
            // Forces every Text(...) to re-evaluate after a language switch.
            .id(localization.revision)
            .task {
                UIApplication.shared.installGlobalKeyboardDismissGesture()
                await syncAllReminders()
                if settings.teamsDetectionEnabled {
                    bootstrapTeamsCoordinator()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active, settings.onboardingCompleted {
                    Task { await syncAllReminders() }
                    Task { await teamsCoordinator?.sync() }
                }
            }
            .onChange(of: appDelegate.acceptedShareVersion) { _, version in
                guard version > 0, let metadata = appDelegate.pendingShareMetadata else { return }
                Task { @MainActor in
                    try? await sharedRemindersService.acceptShare(metadata: metadata)
                    appDelegate.pendingShareMetadata = nil
                    await syncAllReminders()
                }
            }
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
        let schema = Schema([Reminder.self])
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
