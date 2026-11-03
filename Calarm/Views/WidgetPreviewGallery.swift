//
//  WidgetPreviewGallery.swift
//  Calarm
//
//  DEBUG: los widgets pintados dentro de la app con el mismo resumen que leen
//  en la pantalla de inicio (`-demoScreen widgets`). Sirve para revisarlos en
//  el simulador, donde no hay forma de añadirlos a mano sin tocar la pantalla.
//  Los tamaños son los de un iPhone de 6,3".
//

#if DEBUG
import SwiftData
import SwiftUI
import WidgetKit

struct WidgetPreviewGallery: View {
    @Environment(\.modelContext) private var modelContext
    @State private var snapshot: WidgetSnapshot = .empty
    @State private var now = Date()

    private let small = CGSize(width: 170, height: 170)
    private let medium = CGSize(width: 364, height: 170)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                let countdown = snapshot.defaultCountdown(now: now)
                let photo = snapshot.countdowns.first { $0.photoFile != nil }
                let alarms = snapshot.alarms

                HStack(spacing: 16) {
                    home(size: small) {
                        CountdownWidgetContent(countdown: photo, now: now, family: .systemSmall)
                    } background: {
                        CountdownWidgetBackground(countdown: photo)
                    }
                    home(size: small) {
                        NextAlarmWidgetContent(alarms: alarms, alarmsEnabled: snapshot.alarmsEnabled, now: now, family: .systemSmall)
                    } background: {
                        NextAlarmWidgetBackground(alarm: alarms.first)
                    }
                }
                home(size: medium) {
                    CountdownWidgetContent(countdown: countdown, now: now, family: .systemMedium)
                } background: {
                    CountdownWidgetBackground(countdown: countdown)
                }
                home(size: medium) {
                    NextAlarmWidgetContent(alarms: alarms, alarmsEnabled: snapshot.alarmsEnabled, now: now, family: .systemMedium)
                } background: {
                    NextAlarmWidgetBackground(alarm: alarms.first)
                }

                // Pantalla bloqueada.
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        CountdownWidgetContent(countdown: countdown, now: now, family: .accessoryCircular)
                            .frame(width: 72, height: 72)
                        NextAlarmWidgetContent(alarms: alarms, alarmsEnabled: snapshot.alarmsEnabled, now: now, family: .accessoryCircular)
                            .frame(width: 72, height: 72)
                        CountdownWidgetContent(countdown: photo, now: now, family: .accessoryCircular)
                            .frame(width: 72, height: 72)
                    }
                    HStack(spacing: 12) {
                        CountdownWidgetContent(countdown: countdown, now: now, family: .accessoryRectangular)
                            .frame(width: 172, height: 76)
                        NextAlarmWidgetContent(alarms: alarms, alarmsEnabled: snapshot.alarmsEnabled, now: now, family: .accessoryRectangular)
                            .frame(width: 172, height: 76)
                    }
                    CountdownWidgetContent(countdown: countdown, now: now, family: .accessoryInline)
                    NextAlarmWidgetContent(alarms: alarms, alarmsEnabled: snapshot.alarmsEnabled, now: now, family: .accessoryInline)
                }
                .foregroundStyle(.white)
                .environment(\.colorScheme, .dark)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(colors: [.indigo, .black], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .onAppear {
            WidgetSnapshotWriter.update(container: modelContext.container)
            snapshot = WidgetSnapshotStore.load()
            now = Date()
        }
    }

    /// Un widget de la pantalla de inicio: fondo hasta el borde y contenido con
    /// el margen del sistema.
    private func home<Content: View, Background: View>(
        size: CGSize,
        @ViewBuilder content: () -> Content,
        @ViewBuilder background: () -> Background
    ) -> some View {
        content()
            .padding(16)
            .frame(width: size.width, height: size.height)
            .background { background() }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}
#endif
