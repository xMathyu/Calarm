//
//  AlarmPermissionBanner.swift
//  Calarm
//
//  Aviso sobre la lista de alarmas cuando iOS no deja a Calarm programarlas.
//  Sin ese permiso no suena ninguna, y el único rastro estaba en Ajustes
//  («Denegado»): la persona creaba su despertador, no sonaba y borraba la app.
//
//  Dos casos: nunca se preguntó (la bienvenida se cerró con «Continuar de todas
//  formas») y entonces se pregunta aquí mismo; o se negó, y entonces solo
//  Ajustes lo puede cambiar. Al volver a la app, `CalarmApp` reprograma todo.
//

import AlarmKit
import SwiftUI
import UIKit

struct AlarmPermissionBanner: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppSettings.self) private var settings

    /// Reprograma las alarmas en cuanto el permiso se concede aquí mismo. Si se
    /// concede en Ajustes no hace falta: al volver, `CalarmApp` ya lo hace.
    var onAuthorized: () async -> Void = {}

    @State private var state = AlarmManager.shared.authorizationState
    @State private var isRequesting = false

    var body: some View {
        Group {
            // Antes de la bienvenida el permiso todavía no se ha pedido, y la
            // bienvenida lo pide; avisar ahí sería avisar de algo que va a pasar.
            if settings.onboardingCompleted, state != .authorized, !isScreenshotRun {
                banner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(DS.Motion.smooth, value: state)
        .task {
            for await update in AlarmManager.shared.authorizationUpdates {
                state = update
            }
        }
        // El cambio hecho en Ajustes llega al volver a la app.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { state = AlarmManager.shared.authorizationState }
        }
    }

    private var isDenied: Bool { state == .denied }

    /// Las capturas de la tienda corren sin el permiso (ver `AlarmScheduler.schedule`)
    /// y no tienen que enseñar este aviso.
    private var isScreenshotRun: Bool {
        #if DEBUG
        return DemoData.requestedScreen != nil
        #else
        return false
        #endif
    }

    private var banner: some View {
        HStack(alignment: .top, spacing: DS.Spacing.md) {
            Image(systemName: "bell.slash.fill")
                .font(.title3)
                .foregroundStyle(.orange)
                .padding(.top, DS.Spacing.xxs)

            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text("Tus alarmas no van a sonar")
                        .font(.subheadline.bold())
                    // appLocalized en las dos ramas: un `cond ? a : b` de literales
                    // es un String y Text lo enseñaría sin traducir.
                    Text(isDenied
                         ? appLocalized("Calarm no tiene permiso para programar alarmas. Puedes dárselo en Ajustes.")
                         : appLocalized("Falta darle a Calarm permiso para programar alarmas."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: fix) {
                    if isRequesting {
                        ProgressView()
                    } else {
                        Text(isDenied ? appLocalized("Abrir Ajustes") : appLocalized("Permitir"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
                .disabled(isRequesting)
            }

            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.md)
        .background(
            Color.orange.opacity(0.12),
            in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
        )
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.bottom, DS.Spacing.sm)
    }

    private func fix() {
        Haptics.light()
        if isDenied {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
            return
        }
        isRequesting = true
        Task {
            defer { isRequesting = false }
            let granted = (try? await AlarmManager.shared.requestAuthorization())
                ?? AlarmManager.shared.authorizationState
            state = granted
            if granted == .authorized {
                await onAuthorized()
            }
        }
    }
}
