//
//  ChallengePickerView.swift
//  Calarm
//

import SwiftUI

/// Elige el reto de una alarma: tipo, dificultad, si se puede posponer y, para
/// el QR, el código que habrá que escanear. «Probar reto» abre el juego en seco
/// para que nadie descubra al sonar la alarma que no entiende el reto.
struct ChallengePickerView: View {
    @Binding var selection: WakeChallenge?
    let alarmTitle: String

    @State private var showingRegister = false
    @State private var showingPractice = false

    var body: some View {
        List {
            Section {
                kindRow(nil)
            } header: {
                Text("Reto")
            } footer: {
                Text(selection == nil
                     ? "Sin reto, la alarma se apaga con un toque."
                     : "La alarma no se apaga hasta resolver el reto. Si la detienes desde la pantalla de bloqueo o el reloj, vuelve a sonar al minuto y a los 2, 5 y 10 minutos.")
            }

            ForEach(WakeChallenge.Group.allCases) { group in
                Section {
                    ForEach(WakeChallenge.Kind.kinds(in: group)) { kind in
                        kindRow(kind)
                    }
                } header: {
                    Text(group.localizedTitle)
                }
            }

            if let current = selection {
                Section {
                    Picker("Dificultad", selection: difficultyBinding) {
                        ForEach(WakeChallenge.Difficulty.allCases) { level in
                            Text(level.localizedTitle).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Dificultad")
                }

                if current.kind == .qr {
                    Section {
                        Button {
                            showingRegister = true
                        } label: {
                            Label(current.code == nil ? "Registrar código" : "Cambiar código", systemImage: "qrcode")
                        }
                        if let code = current.code {
                            LabeledContent("Código registrado") {
                                Text(code)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } footer: {
                        if current.code == nil {
                            Text("Falta registrar el código: sin él la alarma se apaga como siempre.")
                        }
                    }
                }

                Section {
                    Toggle("Permitir posponer", isOn: allowsSnoozeBinding)
                }

                Section {
                    Button {
                        showingPractice = true
                    } label: {
                        Label("Probar reto", systemImage: "play.circle")
                    }
                    .disabled(!current.isReady)
                }
            }
        }
        .navigationTitle("Reto para apagar")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingRegister) {
            RegisterCodeSheet { code in
                selection?.code = code
            }
        }
        .fullScreenCover(isPresented: $showingPractice) {
            if let current = selection {
                ChallengeView(mode: .practice(current, title: alarmTitle))
            }
        }
    }

    // MARK: - Filas

    @ViewBuilder
    private func kindRow(_ kind: WakeChallenge.Kind?) -> some View {
        let isSelected = selection?.kind == kind
        Button {
            select(kind)
        } label: {
            HStack(spacing: DS.Spacing.md) {
                Image(systemName: kind?.systemImage ?? "bell.slash")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text(kind?.localizedTitle ?? appLocalized("Ninguno"))
                        .foregroundStyle(.primary)
                    if let kind {
                        Text(kind.localizedDescription)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func select(_ kind: WakeChallenge.Kind?) {
        Haptics.selection()
        withAnimation(DS.Motion.snappy) {
            guard let kind else {
                selection = nil
                return
            }
            if selection?.kind == kind { return }
            selection = WakeChallenge(
                kind: kind,
                difficulty: selection?.difficulty ?? .medium,
                allowsSnooze: selection?.allowsSnooze ?? true,
                code: kind == .qr ? selection?.code : nil
            )
        }
    }

    private var difficultyBinding: Binding<WakeChallenge.Difficulty> {
        Binding {
            selection?.difficulty ?? .medium
        } set: { newValue in
            selection?.difficulty = newValue
            Haptics.selection()
        }
    }

    private var allowsSnoozeBinding: Binding<Bool> {
        Binding {
            selection?.allowsSnooze ?? true
        } set: { newValue in
            selection?.allowsSnooze = newValue
        }
    }
}

/// Registra el código que apagará la alarma: se escanea una vez aquí y se
/// guarda su contenido en el reto.
private struct RegisterCodeSheet: View {
    let onRegister: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: DS.Spacing.lg) {
                Text("Apunta la cámara al código que querrás escanear para apagar la alarma.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DS.Spacing.lg)
                CodeScannerView { code in
                    Haptics.success()
                    onRegister(code)
                    dismiss()
                }
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
                .padding(.horizontal, DS.Spacing.lg)
            }
            .padding(.vertical, DS.Spacing.lg)
            .navigationTitle("Registrar código")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
    }
}
