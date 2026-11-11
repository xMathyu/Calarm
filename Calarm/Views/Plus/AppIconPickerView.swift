//
//  AppIconPickerView.swift
//  Calarm
//
//  El color del ícono en la pantalla de inicio. El coral es el de siempre y es
//  gratis; los demás son de Calarmi Plus. Quien deja de tener Plus conserva el
//  ícono que eligió: cambiárselo por su cuenta sería un castigo sin sentido.
//
//  Los íconos alternativos son `AppIcon<Color>.appiconset` en el catálogo,
//  registrados en `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`. iOS no deja
//  leer un ícono de la app como imagen, así que cada uno tiene además una vista
//  previa en `IconPreview<Color>.imageset`.
//

import SwiftUI
import UIKit

enum AppIconOption: String, CaseIterable, Identifiable {
    case coral, blue, purple, green, pink

    var id: String { rawValue }

    /// El nombre que se le pasa a `setAlternateIconName`; `nil` es el principal.
    var iconName: String? {
        switch self {
        case .coral: nil
        case .blue: "AppIconBlue"
        case .purple: "AppIconPurple"
        case .green: "AppIconGreen"
        case .pink: "AppIconPink"
        }
    }

    var previewName: String {
        switch self {
        case .coral: "IconPreviewDefault"
        case .blue: "IconPreviewBlue"
        case .purple: "IconPreviewPurple"
        case .green: "IconPreviewGreen"
        case .pink: "IconPreviewPink"
        }
    }

    var localizedTitle: String {
        switch self {
        case .coral: appLocalized("Coral")
        case .blue: appLocalized("Azul")
        case .purple: appLocalized("Morado")
        case .green: appLocalized("Verde")
        case .pink: appLocalized("Rosa")
        }
    }

    var requiresPlus: Bool { iconName != nil }

    static var current: AppIconOption {
        let name = UIApplication.shared.alternateIconName
        return allCases.first { $0.iconName == name } ?? .coral
    }
}

struct AppIconPickerView: View {
    @State private var plus = PlusStore.shared
    @State private var current = AppIconOption.current
    @State private var paywall: PlusFeature?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: DS.Spacing.md)], spacing: DS.Spacing.lg) {
                    ForEach(AppIconOption.allCases) { option in
                        iconButton(option)
                    }
                }
                .padding(.vertical, DS.Spacing.sm)
            } footer: {
                if !plus.isPlus {
                    Text("El ícono coral es gratis; los demás colores vienen con Calarmi Plus.")
                }
            }
        }
        .navigationTitle("Ícono de la app")
        .navigationBarTitleDisplayMode(.inline)
        .plusPaywall(for: $paywall)
        .alert(
            appLocalized("No se pudo cambiar el ícono"),
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("Entendido", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func iconButton(_ option: AppIconOption) -> some View {
        let isSelected = option == current
        let isLocked = option.requiresPlus && !plus.isPlus
        return Button {
            select(option)
        } label: {
            VStack(spacing: DS.Spacing.sm) {
                Image(option.previewName)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .padding(4)
                    .overlay {
                        RoundedRectangle(cornerRadius: 19, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0)
                    }
                    .overlay(alignment: .topTrailing) {
                        if isLocked {
                            Image(systemName: "lock.fill")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(Circle().fill(Color.black.opacity(0.55)))
                        }
                    }
                Text(option.localizedTitle)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(option.localizedTitle))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func select(_ option: AppIconOption) {
        guard option != current else { return }
        if option.requiresPlus && !plus.isPlus {
            Haptics.light()
            paywall = .appIcons
            return
        }
        guard UIApplication.shared.supportsAlternateIcons else { return }
        Task {
            do {
                try await UIApplication.shared.setAlternateIconName(option.iconName)
                Haptics.selection()
                withAnimation(DS.Motion.snappy) { current = option }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
