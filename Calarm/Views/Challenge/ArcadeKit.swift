//
//  ArcadeKit.swift
//  Calarm
//

import SwiftUI

// Piezas comunes de los retos de arcade (Vuelo, Ovejas, Cañón y Tirachinas):
// el bucle de fotogramas, la cabecera de progreso, el marco del escenario, la
// pulsación mantenida y un generador aleatorio con semilla para que la lógica
// de cada juego se pueda probar fuera de la app.

/// Bucle de fotogramas para los juegos que se simulan en SwiftUI.
enum ArcadeLoop {
    /// Llama a `step` unas 60 veces por segundo con los segundos transcurridos
    /// desde la llamada anterior, hasta que la tarea se cancele o `step`
    /// devuelva `false`. El paso se acota: si la app estuvo en segundo plano no
    /// se integra de golpe el tiempo perdido.
    static func run(_ step: (Double) -> Bool) async {
        var last = ContinuousClock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(16), tolerance: .milliseconds(2))
            if Task.isCancelled { return }
            let now = ContinuousClock.now
            let dt = min(seconds(now - last), 1.0 / 30.0)
            last = now
            if !step(dt) { return }
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// Generador con semilla (SplitMix64): la app lo siembra al azar y las
/// pruebas con una semilla fija, para repetir la misma partida.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64 = .random(in: .min ... .max)) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// «Huecos 3 de 8» con su barra, igual que en «Atrapa».
struct ArcadeProgressHeader: View {
    let label: String
    let value: Int
    let total: Int

    var body: some View {
        VStack(spacing: DS.Spacing.sm) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(DS.Motion.quick, value: value)
            ProgressView(value: Double(min(value, total)), total: Double(total))
                .tint(Color.accentColor)
                .animation(DS.Motion.smooth, value: value)
        }
        .frame(maxWidth: 360)
    }
}

/// Un aviso flotante sobre el escenario («Toca para volar»). No intercepta
/// toques: el escenario de debajo sigue recibiéndolos.
struct ArcadeBanner: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.sm)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(DS.Spacing.md)
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

extension View {
    /// El marco de todos los escenarios de arcade: proporción fija, esquinas
    /// redondeadas y borde suave. Con VoiceOver los toques llegan directos al
    /// juego.
    func arcadeArena(aspectRatio: CGFloat) -> some View {
        self
            .aspectRatio(aspectRatio, contentMode: .fit)
            .frame(maxWidth: 360)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .accessibilityAddTraits(.allowsDirectInteraction)
    }

    /// Avisa al apoyar el dedo y al levantarlo, sin esperar a que termine el
    /// toque como `onTapGesture`. Si el sistema cancela el gesto también llega
    /// `ended`, así que nunca se queda «pulsado».
    func onPress(began: @escaping () -> Void, ended: @escaping () -> Void = {}) -> some View {
        modifier(PressModifier(began: began, ended: ended))
    }
}

private struct PressModifier: ViewModifier {
    let began: () -> Void
    let ended: () -> Void

    @GestureState private var pressing = false

    func body(content: Content) -> some View {
        content
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressing) { _, state, _ in state = true }
            )
            .onChange(of: pressing) { _, isPressing in
                isPressing ? began() : ended()
            }
    }
}

extension GraphicsContext {
    /// Dibuja un texto ya resuelto (un emoji) centrado en `point`, girado y,
    /// si hace falta, volteado en horizontal: los emojis de animales de Apple
    /// miran a la izquierda y en los juegos avanzan hacia la derecha.
    func drawSprite(
        _ text: ResolvedText,
        at point: CGPoint,
        rotation: Angle = .zero,
        flipped: Bool = false
    ) {
        var context = self
        context.translateBy(x: point.x, y: point.y)
        context.rotate(by: rotation)
        if flipped { context.scaleBy(x: -1, y: 1) }
        context.draw(text, at: .zero, anchor: .center)
    }
}

/// Resto siempre positivo, para que los fondos que se desplazan den la vuelta.
func arcadeWrap(_ value: Double, _ period: Double) -> Double {
    let r = value.truncatingRemainder(dividingBy: period)
    return r < 0 ? r + period : r
}
