//
//  TypingChallengeGame.swift
//  Calarm
//

import SwiftUI

/// «Escribir»: copiar una frase corta tal cual, letra por letra, con tildes y
/// mayúsculas. Sin autocorrector ni mayúsculas automáticas, así que no hay
/// atajo: hay que leer y teclear. Una, dos o tres frases según la dificultad.
/// La frase se pinta carácter a carácter: verde lo acertado, rojo desde el
/// primer error, gris lo que falta. Se acepta sola en cuanto coincide.
struct TypingChallengeGame: View {
    let difficulty: WakeChallenge.Difficulty
    let onSolved: () -> Void

    @State private var phrases: [String] = []
    @State private var index = 0
    @State private var input = ""
    /// Sube con cada «Listo» en falso para sacudir el campo.
    @State private var shakeCount = 0
    @State private var solved = false
    @FocusState private var focused: Bool

    private var total: Int {
        switch difficulty {
        case .easy: 1
        case .medium: 2
        case .hard: 3
        }
    }

    private var phrase: String {
        phrases.indices.contains(index) ? phrases[index] : ""
    }

    /// Frases cortas y con ánimo, sin apóstrofes ni signos raros que el
    /// teclado pueda cambiar por su cuenta (las comillas «inteligentes»).
    private static var pool: [String] {
        [
            appLocalized("Hoy va a ser un gran día"),
            appLocalized("Arriba, el mundo te espera"),
            appLocalized("Un paso más cerca de tus metas"),
            appLocalized("El café no se va a hacer solo"),
            appLocalized("Cada mañana es una nueva oportunidad"),
            appLocalized("Respira hondo y a por todas"),
            appLocalized("El sol ya salió y tú también"),
            appLocalized("La cama puede esperar, tú no"),
            appLocalized("Sonríe, ya es de día"),
            appLocalized("Nadie va a vivir tu día por ti"),
            appLocalized("Despierta, que la vida no espera"),
            appLocalized("Un buen día empieza al levantarte"),
        ]
    }

    var body: some View {
        VStack(spacing: DS.Spacing.md) {
            Text(appLocalized("Frase \(index + 1) de \(total)"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            Text(highlightedPhrase)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 48)
                .padding(.horizontal, DS.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
                .id(index)
                .transition(.scale(scale: 0.95).combined(with: .opacity))
                .accessibilityLabel(Text(phrase))

            field

            // Con el teclado fuera el sitio escasea (iPhone mini, SE): la nota
            // solo se queda si hay un error que señalar.
            if mismatchIndex != nil || !focused {
                Text(mismatchIndex == nil
                     ? appLocalized("Escríbela tal cual, con tildes y mayúsculas.")
                     : appLocalized("Hay un error: revisa lo escrito."))
                    .font(.footnote)
                    .foregroundStyle(mismatchIndex == nil ? Color.secondary : Color.red)
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 18)
            }
        }
        .frame(maxWidth: 360)
        .onAppear(perform: start)
        .onChange(of: input) { _, _ in checkInput() }
        .task {
            // En una hoja recién presentada, pedir el foco en onAppear a veces
            // no saca el teclado: se insiste un instante después.
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled && !solved { focused = true }
        }
    }

    // MARK: - Partes

    private var field: some View {
        TextField(appLocalized("Escribe aquí la frase"), text: $input)
            .font(.body)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(.default)
            .submitLabel(.done)
            .focused($focused)
            .onSubmit(submit)
            .padding(.horizontal, DS.Spacing.md)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 2)
            )
            .modifier(TypingShake(animatableData: CGFloat(shakeCount)))
            .animation(DS.Motion.quick, value: mismatchIndex == nil)
    }

    private var borderColor: Color {
        if mismatchIndex != nil { return .red }
        return focused ? Color.accentColor.opacity(0.6) : .clear
    }

    /// La frase con cada carácter coloreado según lo escrito hasta ahora.
    private var highlightedPhrase: AttributedString {
        let target = Array(phrase)
        let typedCount = trimmed(input).count
        let firstError = mismatchIndex ?? Int.max
        var result = AttributedString()
        for (i, character) in target.enumerated() {
            var piece = AttributedString(String(character))
            if i >= typedCount {
                piece.foregroundColor = .secondary
            } else if i < firstError {
                piece.foregroundColor = .green
            } else {
                piece.foregroundColor = .red
            }
            result.append(piece)
        }
        return result
    }

    // MARK: - Lógica

    private func start() {
        guard phrases.isEmpty else { return }
        phrases = Array(Self.pool.shuffled().prefix(total))
        focused = true
    }

    /// Posición del primer carácter escrito que no coincide con la frase
    /// (también si se escribió de más), o nil si todo va bien hasta ahora.
    private var mismatchIndex: Int? {
        let target = Array(phrase)
        for (i, character) in trimmed(input).enumerated() {
            if i >= target.count || target[i] != character { return i }
        }
        return nil
    }

    /// Sin espacios ni saltos de línea al final: un espacio tras la última
    /// palabra no cuenta como error.
    private func trimmed(_ text: String) -> String {
        var rest = Substring(text)
        while let last = rest.last, last.isWhitespace { rest.removeLast() }
        return String(rest)
    }

    private func checkInput() {
        guard !solved, !phrase.isEmpty, trimmed(input) == phrase else { return }
        accept()
    }

    private func submit() {
        guard !solved else { return }
        if trimmed(input) == phrase {
            accept()
        } else {
            Haptics.error()
            withAnimation(.linear(duration: 0.4)) { shakeCount += 1 }
            focused = true
        }
    }

    private func accept() {
        input = ""
        if index + 1 >= total {
            solved = true
            onSolved()
        } else {
            Haptics.light()
            withAnimation(DS.Motion.snappy) { index += 1 }
            focused = true
        }
    }
}

/// Sacudida horizontal: cada unidad de `animatableData` son tres vaivenes.
private struct TypingShake: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let offset = 7 * sin(animatableData * .pi * 6)
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}
