//
//  TonePickerView.swift
//  Calarm
//

import SwiftUI
import UniformTypeIdentifiers

/// Elige el tono de una alarma. Al tocar una fila se selecciona y se preescucha,
/// para no tener que adivinar cómo suena "Arpegio".
///
/// `fallback` distingue los dos usos: en el editor de una alarma se pasa el tono
/// predeterminado de Ajustes y aparece una fila extra para volver a él
/// (`selection == nil`, o sea "heredar"); en Ajustes se pasa `nil` y la lista es
/// una elección directa.
struct TonePickerView: View {
    @Binding var selection: AlarmTone?
    let fallback: AlarmTone?

    @State private var player = TonePlayer.shared
    @State private var imported = ImportedTonesStore.shared
    @State private var showingImporter = false
    @State private var importError: String?

    var body: some View {
        List {
            if let fallback {
                Section {
                    row(
                        tone: nil,
                        title: "\(appLocalized("Predeterminado")) · \(fallback.localizedTitle)",
                        systemImage: "gearshape.fill",
                        preview: fallback
                    )
                } footer: {
                    Text("Sigue el tono elegido en Ajustes. Si lo cambias ahí, esta alarma también cambia.")
                }
            }

            Section {
                ForEach(AlarmTone.builtins) { tone in
                    row(
                        tone: tone,
                        title: tone.localizedTitle,
                        systemImage: tone.systemImage,
                        preview: tone
                    )
                }
            } header: {
                Text("Tonos de Calarm")
            } footer: {
                Text("El tono del sistema se repite hasta que detienes la alarma. Los demás suenan 28 segundos.")
            }

            Section {
                ForEach(imported.tones) { tone in
                    row(
                        tone: .imported(tone.id),
                        title: tone.name,
                        systemImage: "waveform.circle.fill",
                        preview: .imported(tone.id)
                    )
                    .swipeActions {
                        Button(role: .destructive) {
                            delete(tone)
                        } label: {
                            Label("Borrar", systemImage: "trash")
                        }
                    }
                }

                Button {
                    Haptics.light()
                    showingImporter = true
                } label: {
                    Label("Importar audio…", systemImage: "square.and.arrow.down")
                }
                .disabled(imported.tones.count >= ImportedTonesStore.maxTones)
            } header: {
                Text("Mis tonos")
            } footer: {
                Text("Usa un audio tuyo desde Archivos. Calarm lo recorta a 28 segundos y lo repite hasta llenarlos.")
            }
        }
        .navigationTitle("Sonido")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { player.stop() }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert(
            appLocalized("No se pudo importar"),
            isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
        ) {
            Button("Entendido", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    /// Una fila del listado. `tone` es el valor que se guarda (`nil` = heredar) y
    /// `preview` el tono que suena al tocarla.
    @ViewBuilder
    private func row(tone: AlarmTone?, title: String, systemImage: String, preview: AlarmTone) -> some View {
        let isSelected = selection == tone
        Button {
            selection = tone
            Haptics.selection()
            player.preview(preview)
        } label: {
            HStack(spacing: DS.Spacing.md) {
                Image(systemName: systemImage)
                    .frame(width: 24)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    // El tono de iOS no es un archivo al que la app tenga acceso:
                    // se puede elegir, pero no suena aquí. Sin este aviso la fila
                    // parece estropeada.
                    if preview == .system {
                        Text("No se puede preescuchar: es el tono propio de iOS.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: DS.Spacing.sm)
                if player.playing == preview {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(.secondary)
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.vertical, 2)
            .contentShape(.rect)
        }
        // Sin `.plain` la List tiñe TODA la etiqueta del botón con el color de
        // acento y el nombre del tono se lee como un enlace.
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func handleImport(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            if case .failure(let error) = result { importError = error.localizedDescription }
            return
        }
        do {
            let tone = try imported.importAudio(from: url)
            selection = tone
            player.preview(tone)
            Haptics.success()
        } catch let error as ImportedTonesStore.ImportError {
            importError = error.localizedMessage
        } catch {
            importError = error.localizedDescription
        }
    }

    /// Al borrar el tono que estaba elegido hay que soltar la selección, o la
    /// alarma se quedaría apuntando a un archivo que ya no existe.
    private func delete(_ tone: ImportedTonesStore.Tone) {
        if selection == .imported(tone.id) {
            selection = fallback == nil ? .system : nil
        }
        player.stop()
        imported.delete(tone)
        Haptics.light()
    }
}
