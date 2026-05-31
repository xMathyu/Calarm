//
//  ShareDiagnosticsView.swift
//  Calarm
//
//  Shows the persisted trace of the last share accept → ingest attempts so a
//  failing invitation can be diagnosed on-device without Console.app.
//

import SwiftUI
import UIKit

struct ShareDiagnosticsView: View {
    @State private var entries: [String] = []

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView(
                    "Sin eventos todavía",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Acepta una invitación y vuelve aquí para ver el trazo del proceso.")
                )
            } else {
                Section {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                } footer: {
                    Text("De arriba (más antiguo) a abajo (más reciente). Mantén presionado para copiar una línea, o usa “Copiar”.")
                }
            }
        }
        .navigationTitle("Compartir: diagnóstico")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Limpiar", role: .destructive) {
                    ShareDiagnostics.clear()
                    entries = []
                }
                .disabled(entries.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = entries.joined(separator: "\n")
                    Haptics.light()
                } label: {
                    Label("Copiar", systemImage: "doc.on.doc")
                }
                .disabled(entries.isEmpty)
            }
        }
        .onAppear { entries = ShareDiagnostics.entries() }
        .refreshable { entries = ShareDiagnostics.entries() }
    }
}
