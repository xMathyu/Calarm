//
//  CountdownDetailView.swift
//  Calarm
//
//  Una cuenta regresiva a pantalla grande: la foto (o el color) de fondo, los
//  días en grande y, si tiene hora, la cuenta segundo a segundo. Desde aquí se
//  puede poner una alarma para ese día e invitar amigos (o, en una recibida,
//  ver quién la compartió).
//

import CloudKit
import SwiftData
import SwiftUI

struct CountdownDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(SharedRemindersService.self) private var sharedService

    let event: CountdownEvent

    @State private var showingEditor = false
    @State private var showingAlarmEditor = false
    @State private var confirmingDelete = false

    // Compartir
    @State private var existingShare: CKShare?
    @State private var participants: [ShareParticipantInfo] = []
    @State private var sharedBy: SharedByPerson?
    @State private var isPreparingShare = false
    @State private var pendingInvite: InviteDelivery?
    @State private var shareError: String?
    @State private var showingManageSheet = false

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.xl) {
                hero
                details
                    .padding(.horizontal, DS.Spacing.lg)
            }
            .padding(.bottom, DS.Spacing.xxxl)
        }
        .ignoresSafeArea(edges: .top)
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Una recibida es de quien la compartió: aquí solo se mira.
            if !event.isReceivedShare {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Editar") {
                        Haptics.light()
                        showingEditor = true
                    }
                }
            }
        }
        .sheet(isPresented: $showingEditor) {
            // Borrada desde el editor: no queda nada que enseñar aquí.
            CountdownEditorView(editing: event, onDelete: deleteAfterLeaving)
        }
        .sheet(isPresented: $showingAlarmEditor) {
            ReminderEditorView(editing: nil, initialDate: alarmDate, initialTitle: event.title)
        }
        .confirmationDialog(
            appLocalized(event.isReceivedShare ? "¿Quitar esta cuenta regresiva de tu lista?" : "¿Borrar esta cuenta regresiva?"),
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button(appLocalized(event.isReceivedShare ? "Quitar" : "Borrar"), role: .destructive) { deleteAfterLeaving() }
        } message: {
            if event.isReceivedShare {
                Text("Dejarás de recibir sus cambios. Para volver a tenerla, pide que te la compartan otra vez.")
            }
        }
        // Mandar el enlace por WhatsApp, Mensajes…; al cerrar, ver quién se unió.
        .inviteDelivery($pendingInvite) {
            Task { await refreshShare() }
        }
        .sheet(isPresented: $showingManageSheet, onDismiss: { Task { await refreshShare() } }) {
            if let share = existingShare {
                CloudSharingView(
                    share: share,
                    container: CKContainer(identifier: sharedService.containerIdentifier)
                ) { showingManageSheet = false }
            }
        }
        .alert("Error al compartir", isPresented: Binding(
            get: { shareError != nil },
            set: { if !$0 { shareError = nil } }
        )) {
            Button("OK") { shareError = nil }
        } message: {
            Text(shareError ?? "")
        }
        .task { await refreshShare() }
    }

    // MARK: - Hero

    private var hero: some View {
        let content = event.cardContent
        let photo = content.backgroundPhoto.flatMap { CountdownPhoto.image(for: $0, key: content.id) }
        return TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            VStack(spacing: DS.Spacing.lg) {
                Spacer(minLength: 96)
                if photo == nil {
                    CountdownIconTile(content: content, size: 96)
                }
                VStack(spacing: DS.Spacing.xs) {
                    Text(event.title)
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)
                    CountdownDateLabel(content: content, now: now)
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.85))
                }
                CountdownCounter(status: content.status(now: now), numberSize: 96)
                    .animation(DS.Motion.smooth, value: content.status(now: now))
                if let parts = exactRemaining(now: now) {
                    breakdown(parts)
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(photo == nil ? 0.12 : 0.35), radius: 8, y: 2)
            .padding(.horizontal, DS.Spacing.xl)
            .padding(.bottom, DS.Spacing.xxxl)
            .frame(maxWidth: .infinity, minHeight: 460)
            .background {
                CountdownBackground(content: content, photo: photo)
            }
        }
        .clipShape(UnevenRoundedRectangle(
            bottomLeadingRadius: DS.Radius.xl * 1.5,
            bottomTrailingRadius: DS.Radius.xl * 1.5,
            style: .continuous
        ))
    }

    /// Días, horas, minutos y segundos hasta la hora exacta. Solo con hora: sin
    /// ella el desglose contaría hasta la medianoche y desdiría al número grande.
    private func exactRemaining(now: Date) -> DateComponents? {
        guard event.includesTime else { return nil }
        let target = event.target(now: now)
        guard target > now else { return nil }
        return Calendar.current.dateComponents([.day, .hour, .minute, .second], from: now, to: target)
    }

    private func breakdown(_ parts: DateComponents) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            unitBox(parts.day ?? 0, label: appLocalized("días"))
            unitBox(parts.hour ?? 0, label: appLocalized("horas"))
            unitBox(parts.minute ?? 0, label: appLocalized("min"))
            unitBox(parts.second ?? 0, label: appLocalized("seg"))
        }
    }

    private func unitBox(_ value: Int, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value, format: .number)
                .font(.title2.weight(.bold).monospacedDigit())
                .contentTransition(.numericText(value: Double(value)))
                .animation(DS.Motion.snappy, value: value)
            Text(label)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .opacity(0.85)
        }
        .frame(minWidth: 64)
        .padding(.vertical, DS.Spacing.sm)
        .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
    }

    // MARK: - Details

    @ViewBuilder
    private var details: some View {
        VStack(spacing: DS.Spacing.md) {
            if event.isReceivedShare {
                sharedByCard
            }

            if let notes = event.notes, !notes.isEmpty {
                Text(notes)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface()
            }

            if canSetAlarm {
                actionRow(title: appLocalized("Poner una alarma para ese día"), systemImage: "alarm.fill", tint: event.color) {
                    showingAlarmEditor = true
                }
            }

            if !event.isReceivedShare {
                actionRow(
                    title: appLocalized("Invitar amigos"),
                    systemImage: "person.badge.plus",
                    tint: event.color,
                    isWorking: isPreparingShare
                ) {
                    Task { await invite() }
                }
                .disabled(isPreparingShare)

                if !participants.isEmpty {
                    participantsCard
                }
            }

            actionRow(
                title: appLocalized(event.isReceivedShare ? "Quitar de mi lista" : "Borrar"),
                systemImage: event.isReceivedShare ? "minus.circle" : "trash",
                tint: .red
            ) {
                confirmingDelete = true
            }
        }
    }

    /// Quién la compartió (se lee de iCloud cada vez; no se guarda).
    private var sharedByCard: some View {
        HStack(spacing: DS.Spacing.md) {
            if let sharedBy {
                PersonAvatarView(name: sharedBy.name, email: sharedBy.email, phone: sharedBy.phone, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sharedBy.name)
                        .font(.subheadline.weight(.semibold))
                    Text("Te compartió esta cuenta regresiva")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(event.color)
                    .frame(width: 28)
                Text("Compartida contigo")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: DS.Spacing.lg)
    }

    /// Quién aceptó la invitación, y el acceso a gestionarla (quitar a alguien
    /// o dejar de compartir).
    private var participantsCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "person.2.fill").font(.caption)
                Text("Personas")
                    .font(.footnote.weight(.semibold))
                    .textCase(.uppercase)
                Spacer()
                if existingShare != nil {
                    Button("Gestionar") {
                        Haptics.light()
                        showingManageSheet = true
                    }
                    .font(.footnote.weight(.semibold))
                }
            }
            .foregroundStyle(.secondary)
            ForEach(participants) { person in
                HStack(spacing: DS.Spacing.md) {
                    PersonAvatarView(name: person.name, email: person.email, phone: person.phone, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.name)
                            .font(.subheadline)
                            .lineLimit(1)
                        Text(person.statusLabel)
                            .font(.caption)
                            .foregroundStyle(person.status == .accepted ? .green : .secondary)
                    }
                    Spacer()
                    if person.status == .accepted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: DS.Spacing.lg)
    }

    private func actionRow(
        title: String,
        systemImage: String,
        tint: Color,
        isWorking: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            HStack(spacing: DS.Spacing.md) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28)
                Text(title)
                    .foregroundStyle(tint == .red ? .red : .primary)
                Spacer()
                if isWorking { ProgressView() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(padding: DS.Spacing.lg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    // MARK: - Actions

    /// Hay alarma que poner mientras el evento no haya pasado.
    private var canSetAlarm: Bool {
        !event.status().isPast
    }

    /// La alarma suena a la hora del evento o, si no tiene, a las 9:00 de ese día.
    private var alarmDate: Date {
        let target = event.target()
        if event.includesTime { return target }
        return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: target) ?? target
    }

    // MARK: - Compartir

    /// Prepara el share en iCloud y abre la hoja de compartir con un enlace de
    /// Calarm, que enseña la cuenta (y la ofrece a quien aún no tiene la app).
    @MainActor
    private func invite() async {
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            let share = try await sharedService.prepareShare(forCountdown: event)
            guard let url = share.url else {
                shareError = SharedRemindersError.shareURLUnavailable.errorDescription
                return
            }
            existingShare = share
            // Sin el enlace propio no hay invitación: un enlace de iCloud a
            // secas lo abriría como alarma una versión anterior de la app.
            guard let link = InviteLink.make(
                kind: .countdown,
                title: event.title,
                date: event.target(),
                hasTime: event.includesTime,
                tintHex: event.colorHex,
                emoji: event.iconKind == .emoji && isEmojiIcon(event.iconValue) ? event.iconValue : nil,
                symbol: event.iconKind == .symbol ? event.iconValue : nil,
                photo: event.iconKind == .photo ? event.photoData.flatMap(InvitePhoto.thumbnail(from:)) : nil,
                shareURL: url
            ) else {
                shareError = SharedRemindersError.shareURLUnavailable.errorDescription
                return
            }
            pendingInvite = InviteDelivery(
                title: event.title,
                url: link,
                customMessage: appLocalized("Te invito a la cuenta regresiva «\(event.title)» en Calarmi")
            )
        } catch {
            shareError = error.localizedDescription
        }
    }

    /// Quién la compartió (recibida) o quién se unió (propia).
    @MainActor
    private func refreshShare() async {
        if event.isReceivedShare {
            sharedBy = await sharedService.owner(ofReceived: event.id)
            return
        }
        let share = await sharedService.existingShare(forCountdown: event)
        existingShare = share
        participants = share.map { sharedService.participantInfos(of: $0).filter { !$0.isOwner } } ?? []
    }

    /// Vuelve a la lista y borra después: si se borra con la pantalla todavía
    /// puesta, SwiftUI la redibuja leyendo un modelo que ya no existe (y se cae).
    private func deleteAfterLeaving() {
        let event = event
        let context = modelContext
        let sharing = sharedService
        let id = event.id
        let wasReceived = event.isReceivedShare
        // Desde el editor: primero se va la hoja, luego esta pantalla.
        let fromEditor = showingEditor
        showingEditor = false
        Haptics.warning()
        Task {
            if fromEditor { try? await Task.sleep(for: .milliseconds(350)) }
            dismiss()
            try? await Task.sleep(for: .milliseconds(450))
            context.delete(event)
            try? context.save()
            await sharing.countdownDeleted(id: id, wasReceived: wasReceived)
        }
    }
}
