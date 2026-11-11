//
//  StarterAlarmsView.swift
//  Calarm
//
//  Lo que ve la lista de alarmas mientras está vacía: plantillas que se crean
//  con un toque en lugar de un «Sin alarmas» con un botón. Ver `AlarmTemplate`.
//

import SwiftUI

struct StarterAlarmsView: View {
    let onPick: (AlarmTemplate) -> Void
    let onBlank: () -> Void

    @State private var animate = false

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.xxl) {
                header

                VStack(spacing: DS.Spacing.md) {
                    ForEach(AlarmTemplate.starters) { template in
                        Button {
                            Haptics.light()
                            onPick(template)
                        } label: {
                            card(for: template)
                        }
                        .buttonStyle(.pressable)
                    }
                }

                Button {
                    Haptics.light()
                    onBlank()
                } label: {
                    Label("Empezar de cero", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.Spacing.xs)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.xxl)
        }
        .background(Color(.systemGroupedBackground))
        .onAppear {
            withAnimation(DS.Motion.bouncy.delay(0.1)) { animate = true }
        }
    }

    private var header: some View {
        VStack(spacing: DS.Spacing.md) {
            HeroIcon(systemName: "bell.badge.fill", size: DS.AvatarSize.xl)
                .scaleEffect(animate ? 1 : 0.7)
                .opacity(animate ? 1 : 0)
            Text("Tu primera alarma")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("Elige una para empezar. Se crea al cerrar el editor y la cambias cuando quieras.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DS.Spacing.lg)
    }

    private func card(for template: AlarmTemplate) -> some View {
        HStack(spacing: DS.Spacing.md) {
            ReminderIconView(
                iconKind: .symbol,
                iconValue: template.symbol,
                tint: template.category.tint
            )
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(template.label)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(detail(for: template))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DS.Spacing.sm)
            Image(systemName: "plus.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.appAccent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .cardSurface()
    }

    /// «De lunes a viernes · 7:00 a. m.», con la hora en el idioma de la app.
    private func detail(for template: AlarmTemplate) -> String {
        guard template.showsTime else { return template.detail }
        let time = template.firstDate().formatted(
            .dateTime.hour().minute().locale(LocalizationManager.shared.currentLocale)
        )
        return "\(template.detail) · \(time)"
    }
}
