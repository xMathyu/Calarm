//
//  CountdownDetailView.swift
//  Calarm
//
//  Una cuenta regresiva a pantalla grande: la foto (o el color) de fondo, los
//  días en grande y, si tiene hora, la cuenta segundo a segundo. Desde aquí se
//  puede poner una alarma para ese día.
//

import SwiftData
import SwiftUI

struct CountdownDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let event: CountdownEvent

    @State private var showingEditor = false
    @State private var showingAlarmEditor = false
    @State private var confirmingDelete = false

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
            ToolbarItem(placement: .topBarTrailing) {
                Button("Editar") {
                    Haptics.light()
                    showingEditor = true
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
            appLocalized("¿Borrar esta cuenta regresiva?"),
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Borrar", role: .destructive) { deleteAfterLeaving() }
        }
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
            actionRow(title: appLocalized("Borrar"), systemImage: "trash", tint: .red) {
                confirmingDelete = true
            }
        }
    }

    private func actionRow(title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
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

    /// Vuelve a la lista y borra después: si se borra con la pantalla todavía
    /// puesta, SwiftUI la redibuja leyendo un modelo que ya no existe (y se cae).
    private func deleteAfterLeaving() {
        let event = event
        let context = modelContext
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
        }
    }
}
