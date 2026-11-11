//
//  CountdownListView.swift
//  Calarm
//
//  La pestaña de cuentas regresivas: una tarjeta por evento, lo más próximo
//  primero, y los que ya pasaron al final. Los días cambian solos a medianoche.
//

import SwiftData
import SwiftUI

struct CountdownListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SharedRemindersService.self) private var sharedService

    @Query(sort: [SortDescriptor(\CountdownEvent.date)]) private var events: [CountdownEvent]

    @State private var showingNewEditor = false
    @State private var editingEvent: CountdownEvent?
    @State private var path: [UUID] = []
    @State private var plus = PlusStore.shared
    @State private var paywall: PlusFeature?

    #if DEBUG
    private static var demoScreenShown = false
    #endif

    var body: some View {
        NavigationStack(path: $path) {
            // Cada minuto basta: las tarjetas cuentan días, y así «¡Hoy!» llega
            // a medianoche aunque la app se quede abierta.
            TimelineView(.everyMinute) { context in
                content(now: context.date)
            }
            .navigationTitle("Cuenta regresiva")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.light()
                        startNewCountdown()
                    } label: {
                        Image(systemName: "plus")
                            .symbolEffect(.bounce, options: .nonRepeating, value: showingNewEditor)
                    }
                    .accessibilityLabel(Text("Nueva cuenta regresiva"))
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let event = events.first(where: { $0.id == id }) {
                    CountdownDetailView(event: event)
                }
            }
            .sheet(isPresented: $showingNewEditor) {
                CountdownEditorView(editing: nil)
            }
            .sheet(item: $editingEvent) { event in
                CountdownEditorView(editing: event)
            }
            .plusPaywall(for: $paywall)
            // El widget de cuenta regresiva: al llegar el toque o, si la app
            // arrancó con él, al aparecer la lista.
            .task { openRequestedCountdown() }
            .onReceive(NotificationCenter.default.publisher(for: .calarmOpenCountdown)) { _ in
                openRequestedCountdown()
            }
            #if DEBUG
            // Capturas: `-demoScreen countdownDetail` / `countdownEditor` abren la
            // primera cuenta (la del concierto) sin tocar la pantalla. Una sola
            // vez por arranque: `.task` vuelve a correr cada vez que se entra a
            // la pestaña, y el editor se abría solo cada vez.
            .task {
                guard !Self.demoScreenShown else { return }
                Self.demoScreenShown = true
                guard let first = Self.groups(events, now: Date()).upcoming.first(where: { $0.iconKind == .photo })
                        ?? events.first else { return }
                switch DemoData.requestedScreen {
                case "countdownDetail": path = [first.id]
                case "countdownEditor": editingEvent = first
                case "countdownNew": showingNewEditor = true
                case "countdownReceived":
                    if let received = events.first(where: \.isReceivedShare) { path = [received.id] }
                default: break
                }
            }
            #endif
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if events.isEmpty {
            EmptyStateView(
                systemImage: "hourglass",
                title: "Sin cuentas regresivas",
                message: "Cuenta los días que faltan para un concierto, un viaje o un cumpleaños. Ponle un emoji o una foto.",
                actionTitle: "Nueva cuenta regresiva"
            ) {
                showingNewEditor = true
            }
        } else {
            let groups = Self.groups(events, now: now)
            List {
                if !groups.upcoming.isEmpty {
                    Section {
                        ForEach(groups.upcoming) { event in
                            row(event, now: now)
                        }
                    }
                }
                if !groups.past.isEmpty {
                    Section {
                        ForEach(groups.past) { event in
                            row(event, now: now)
                        }
                    } header: {
                        Text("Pasados")
                    }
                }
            }
            .listStyle(.plain)
            .listSectionSpacing(DS.Spacing.lg)
            .animation(DS.Motion.smooth, value: events.count)
        }
    }

    private func row(_ event: CountdownEvent, now: Date) -> some View {
        Button {
            Haptics.light()
            path.append(event.id)
        } label: {
            CountdownCardView(content: event.cardContent, now: now)
        }
        .buttonStyle(.pressable)
        .listRowInsets(EdgeInsets(top: DS.Spacing.xs, leading: DS.Spacing.lg, bottom: DS.Spacing.xs, trailing: DS.Spacing.lg))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        // Una recibida no se edita (es de quien la compartió), solo se quita.
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                delete(event)
            } label: {
                deleteLabel(for: event)
            }
            if !event.isReceivedShare {
                Button {
                    editingEvent = event
                } label: {
                    Label("Editar", systemImage: "pencil")
                }
                .tint(.gray)
            }
        }
        .contextMenu {
            if !event.isReceivedShare {
                Button {
                    editingEvent = event
                } label: {
                    Label("Editar", systemImage: "pencil")
                }
            }
            Button(role: .destructive) {
                delete(event)
            } label: {
                deleteLabel(for: event)
            }
        }
    }

    /// Sin Plus caben `PlusStore.freeCountdownLimit` cuentas propias; las
    /// recibidas no cuentan. Las que ya había no se tocan aunque sean más.
    private func startNewCountdown() {
        let ownCount = events.filter { !$0.isReceivedShare }.count
        if plus.canCreateCountdown(ownCount: ownCount) {
            showingNewEditor = true
        } else {
            paywall = .unlimitedCountdowns
        }
    }

    private func openRequestedCountdown() {
        guard let request = CountdownOpenRequest.consume() else { return }
        showingNewEditor = false
        editingEvent = nil
        if let id = request, events.contains(where: { $0.id == id }) {
            path = [id]
        } else {
            path = []
        }
    }

    /// Los próximos (y los de hoy) del más cercano al más lejano; los pasados,
    /// del más reciente al más antiguo.
    static func groups(_ events: [CountdownEvent], now: Date) -> (upcoming: [CountdownEvent], past: [CountdownEvent]) {
        let withTargets = events.map { (event: $0, target: $0.target(now: now)) }
        let upcoming = withTargets
            .filter { !$0.event.status(now: now).isPast }
            .sorted { $0.target < $1.target }
            .map(\.event)
        let past = withTargets
            .filter { $0.event.status(now: now).isPast }
            .sorted { $0.target > $1.target }
            .map(\.event)
        return (upcoming, past)
    }

    private func deleteLabel(for event: CountdownEvent) -> some View {
        event.isReceivedShare
            ? Label("Quitar", systemImage: "minus.circle")
            : Label("Borrar", systemImage: "trash")
    }

    /// Borrar una propia también la quita a los invitados; quitar una recibida
    /// deja una marca para que no vuelva y sale del share.
    private func delete(_ event: CountdownEvent) {
        let id = event.id
        let wasReceived = event.isReceivedShare
        withAnimation(DS.Motion.smooth) {
            modelContext.delete(event)
        }
        try? modelContext.save()
        Haptics.warning()
        Task { await sharedService.countdownDeleted(id: id, wasReceived: wasReceived) }
    }
}

extension Notification.Name {
    /// Abrir la pestaña Cuenta regresiva; `object` es el UUID de la cuenta, o nil.
    static let calarmOpenCountdown = Notification.Name("CalarmOpenCountdown")
}

/// Un toque en el widget de cuenta regresiva (`calarm://countdown/<id>`). Se
/// guarda por si la app arranca en frío y la pestaña aún no existe.
enum CountdownOpenRequest {
    /// `.some(nil)` = la pestaña sin cuenta concreta.
    private static var pending: UUID??

    static func post(_ id: UUID?) {
        pending = .some(id)
        NotificationCenter.default.post(name: .calarmOpenCountdown, object: id)
    }

    static func consume() -> UUID?? {
        defer { pending = nil }
        return pending
    }
}
