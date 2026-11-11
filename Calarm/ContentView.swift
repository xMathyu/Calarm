//
//  ContentView.swift
//  Calarm
//

import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ChallengeCoordinator.self) private var challenges
    @Environment(SharedRemindersService.self) private var sharedService

    let alarmScheduler: AlarmScheduler
    let onTeamsToggleChanged: (Bool) -> Void
    let teamsCoordinatorProvider: () -> SyncCoordinator?
    /// Reprograma las alarmas propias cuando un ajuste cambia la hora a la que
    /// el sistema tiene que recibirlas (hoy, la cuenta regresiva).
    let onCountdownChanged: () -> Void

    enum TabID: String, Hashable {
        case alarms, calendar, countdowns, assistant, settings
    }

    @State private var selection: TabID = .alarms

    #if DEBUG
    // Screenshot runs open a screen directly with `-demoScreen <name>`; see DemoData.
    @Query(sort: [SortDescriptor(\Reminder.date)]) private var demoReminders: [Reminder]
    @State private var demoTone: AlarmTone? = .marimba
    @State private var demoRecurrence: RecurrenceRule = .weekly(interval: 1, weekdays: [.monday, .wednesday])
    @State private var demoChallenge: WakeChallenge? = WakeChallenge(kind: .math)
    #endif

    var body: some View {
        TabView(selection: $selection) {
            Tab("Alarmas", systemImage: "bell.fill", value: TabID.alarms) {
                RemindersListView()
            }
            // Siempre visible: la vista de mes enseña las alarmas propias aunque
            // la lectura del calendario esté apagada (entonces va sin eventos).
            Tab("Calendario", systemImage: "calendar", value: TabID.calendar) {
                CalendarTabView(coordinator: teamsCoordinatorProvider())
            }
            Tab("Cuenta regresiva", systemImage: "hourglass", value: TabID.countdowns) {
                CountdownListView()
            }
            Tab("Asistente", systemImage: "sparkles", value: TabID.assistant) {
                CalarmChatView()
            }
            Tab("Ajustes", systemImage: "gearshape", value: TabID.settings) {
                SettingsView(
                    alarmScheduler: alarmScheduler,
                    onTeamsToggleChanged: onTeamsToggleChanged,
                    teamsCoordinatorProvider: teamsCoordinatorProvider,
                    onCountdownChanged: onCountdownChanged
                )
            }
        }
        .sheet(isPresented: .constant(!settings.onboardingCompleted)) {
            OnboardingView(alarmScheduler: alarmScheduler)
        }
        // La pantalla del reto: aparece cuando suena una alarma con reto y solo
        // se va al resolverlo (o al posponer, si la alarma lo permite).
        .fullScreenCover(item: Binding(
            get: { challenges.session },
            set: { if $0 == nil { challenges.sessionAlarmEnded() } }
        )) { session in
            ChallengeView(mode: .alarm(session))
        }
        .modifier(DemoScreenModifier(selection: $selection))
        .onReceive(NotificationCenter.default.publisher(for: .calarmOpenReminder)) { _ in
            selection = .alarms
        }
        // «Nueva alarma» del Centro de control: la lista de alarmas abre el editor.
        .onReceive(NotificationCenter.default.publisher(for: .calarmNewAlarm)) { _ in
            selection = .alarms
        }
        // Un toque en el widget de cuenta regresiva.
        .onReceive(NotificationCenter.default.publisher(for: .calarmOpenCountdown)) { _ in
            selection = .countdowns
        }
        // An invitation being accepted: «agregando…» while CloudKit works, then
        // the alarm's name once it's on the list. Before this, the person tapped
        // the link and watched the list for several seconds with no sign of life.
        .overlay(alignment: .top) {
            if let status = sharedService.incomingShare {
                IncomingShareToast(status: status) { id in
                    sharedService.clearIncomingShare()
                    if case .acceptedCountdown = status {
                        CountdownOpenRequest.post(id)
                    } else {
                        NotificationCenter.default.post(name: .calarmOpenReminder, object: id)
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(DS.Motion.bouncy, value: sharedService.incomingShare)
        .onChange(of: sharedService.incomingShare) { _, status in
            // Show the list it landed on, wherever the person was.
            switch status {
            case .accepted:
                Haptics.success()
                selection = .alarms
            case .acceptedCountdown:
                Haptics.success()
                selection = .countdowns
            default:
                break
            }
        }
        .task(id: sharedService.incomingShare) {
            guard let status = sharedService.incomingShare else { return }
            // The confirmation goes away on its own; the «agregando…» one only
            // if the accept never reports back (CloudKit stuck without a network).
            let delay: Duration = status.isAccepting ? .seconds(60) : .seconds(4)
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            sharedService.clearIncomingShare()
        }
        #if DEBUG
        .sheet(isPresented: .constant(DemoData.requestedScreen == "editor")) {
            if let birthday = demoReminders.first(where: { $0.category == .birthday }) {
                ReminderEditorView(editing: birthday)
            }
        }
        .sheet(isPresented: .constant(DemoData.requestedScreen == "recurrence")) {
            NavigationStack {
                RecurrencePickerView(rule: $demoRecurrence, baseDate: Date())
            }
        }
        .sheet(isPresented: .constant(DemoData.requestedScreen == "tones")) {
            NavigationStack {
                TonePickerView(selection: $demoTone, fallback: .chime)
            }
        }
        .sheet(isPresented: .constant(DemoData.requestedScreen == "helpers")) {
            NavigationStack {
                DelegationSettingsView()
            }
        }
        // Los widgets pintados dentro de la app, para verlos sin la pantalla de inicio.
        .sheet(isPresented: .constant(DemoData.requestedScreen == "widgets")) {
            WidgetPreviewGallery()
        }
        .sheet(isPresented: .constant(DemoData.requestedScreen == "challengePicker")) {
            NavigationStack {
                ChallengePickerView(selection: $demoChallenge, alarmTitle: "Despertar")
            }
        }
        // El reto en modo de prueba: `-demoScreen challenge` (cálculo) o
        // `-demoScreen challenge-<kind>` con el rawValue de `WakeChallenge.Kind`.
        .fullScreenCover(isPresented: .constant(Self.demoChallengeKind != nil)) {
            if let kind = Self.demoChallengeKind {
                // Con el nombre de la alarma de demo («Despertador» / «Wake up»),
                // que sale en las capturas de los dos idiomas.
                ChallengeView(mode: .practice(WakeChallenge(kind: kind, code: kind == .qr ? "demo" : nil), title: appLocalized("Despertador")))
            }
        }
        // Calarmi Plus: `-demoScreen paywall` (con los retos Arcade resaltados) y
        // `-demoScreen appIcons`. Con `-demoPlus` se ven como si ya hubiera Plus.
        .sheet(isPresented: .constant(DemoData.requestedScreen == "paywall")) {
            PlusPaywallView(highlight: .arcadeChallenges)
        }
        .sheet(isPresented: .constant(DemoData.requestedScreen == "appIcons")) {
            NavigationStack {
                AppIconPickerView()
            }
        }
        #endif
    }
}

#if DEBUG
extension ContentView {
    /// `challenge` abre el de cálculo; `challenge-<rawValue>` cualquier otro.
    static var demoChallengeKind: WakeChallenge.Kind? {
        guard let screen = DemoData.requestedScreen, screen.hasPrefix("challenge") else { return nil }
        let raw = screen.dropFirst("challenge".count).drop(while: { $0 == "-" })
        return raw.isEmpty ? .math : WakeChallenge.Kind(rawValue: String(raw))
    }
}
#endif

/// Selects the tab a screenshot run asked for. Does nothing in release builds.
private struct DemoScreenModifier: ViewModifier {
    @Binding var selection: ContentView.TabID

    func body(content: Content) -> some View {
        #if DEBUG
        content.task {
            switch DemoData.requestedScreen {
            case "calendar", "agenda": selection = .calendar
            case "countdowns", "countdownDetail", "countdownEditor", "countdownNew", "countdownReceived": selection = .countdowns
            case "assistant": selection = .assistant
            case "settings", "helpers": selection = .settings
            default: break
            }
        }
        #else
        content
        #endif
    }
}
