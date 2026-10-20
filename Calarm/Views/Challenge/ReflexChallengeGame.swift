//
//  ReflexChallengeGame.swift
//  Calarm
//

import SwiftUI

/// «Atrapa»: emojis que asoman en puntos al azar del escenario y se esconden
/// enseguida. Hay que tocarlos antes de que desaparezcan; dejar escapar uno no
/// resta, solo no suma. El bucle que los hace aparecer vive en `.task`, así
/// muere con la vista; cada objetivo lleva su propia cuenta atrás en otro
/// `.task` que se cancela solo cuando el objetivo se retira.
struct ReflexChallengeGame: View {
    let difficulty: WakeChallenge.Difficulty
    let onSolved: () -> Void

    @State private var targets: [ReflexTarget] = []
    @State private var caught = 0
    @State private var arenaSize: CGSize = .zero
    /// Dónde estuvo el último objetivo: el siguiente sale en otro sitio, para
    /// que haya que mover el dedo.
    @State private var lastSpot: CGPoint?
    @State private var solved = false

    private static let targetSize: CGFloat = 64
    private static let emojis = ["🐣", "☕️", "🌞", "⏰", "🥐", "🚀"]

    private var required: Int {
        switch difficulty {
        case .easy: 10
        case .medium: 15
        case .hard: 20
        }
    }

    /// Segundos que un objetivo se deja ver antes de esconderse.
    private var lifetime: Double {
        switch difficulty {
        case .easy: 1.6
        case .medium: 1.2
        case .hard: 0.9
        }
    }

    private var maxVisible: Int {
        difficulty == .hard ? 2 : 1
    }

    var body: some View {
        VStack(spacing: DS.Spacing.md) {
            VStack(spacing: DS.Spacing.sm) {
                Text(appLocalized("Atrapados \(caught) de \(required)"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(DS.Motion.quick, value: caught)
                ProgressView(value: Double(min(caught, required)), total: Double(required))
                    .tint(Color.accentColor)
                    .animation(DS.Motion.smooth, value: caught)
            }
            .frame(maxWidth: 360)

            arena
        }
        .task { await spawnLoop() }
    }

    // MARK: - Partes

    private var arena: some View {
        GeometryReader { geo in
            ZStack {
                if caught == 0 && targets.isEmpty {
                    Text("Atento…")
                        .font(.headline)
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
                }
                ForEach(targets) { target in
                    ReflexTargetView(target: target, size: Self.targetSize, lifetime: lifetime) {
                        catchTarget(target.id)
                    }
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.3).combined(with: .opacity),
                        removal: .scale(scale: 0.4).combined(with: .opacity)
                    ))
                    .position(target.center)
                    .task(id: target.popped) { await retire(target) }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onChange(of: geo.size, initial: true) { _, size in
                arenaSize = size
            }
        }
        .frame(height: 320)
        .frame(maxWidth: 360)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous))
    }

    // MARK: - Lógica

    /// Saca objetivos mientras haya hueco, con una pausa corta y variable entre
    /// uno y otro. Para en cuanto se resuelve o se cancela la tarea.
    @MainActor
    private func spawnLoop() async {
        // El escenario aún no se ha medido: espera a tener tamaño.
        while arenaSize == .zero {
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return }
        }
        try? await Task.sleep(for: .milliseconds(600))
        if Task.isCancelled { return }
        while !Task.isCancelled && !solved {
            if targets.filter({ !$0.popped }).count < maxVisible {
                spawn()
            }
            try? await Task.sleep(for: .milliseconds(Int.random(in: 300...650)))
            if Task.isCancelled { return }
        }
    }

    private func spawn() {
        var occupied = targets.map(\.center)
        if let lastSpot { occupied.append(lastSpot) }
        guard let center = Self.freeSpot(in: arenaSize, size: Self.targetSize, avoiding: occupied) else { return }
        lastSpot = center
        let emoji = Self.emojis.randomElement() ?? "⏰"
        withAnimation(DS.Motion.bouncy) {
            targets.append(ReflexTarget(emoji: emoji, center: center))
        }
    }

    /// Espera a que el objetivo caduque (o a que termine su animación de
    /// captura) y lo retira. Se cancela sola si el objetivo ya no está.
    @MainActor
    private func retire(_ target: ReflexTarget) async {
        try? await Task.sleep(for: target.popped ? .milliseconds(240) : .seconds(lifetime))
        if Task.isCancelled { return }
        if target.popped {
            // Ya se desvaneció con la animación de captura: solo se quita.
            targets.removeAll { $0.id == target.id }
        } else {
            // Se escondió sin que lo atraparan.
            withAnimation(.easeIn(duration: 0.2)) {
                targets.removeAll { $0.id == target.id }
            }
        }
    }

    private func catchTarget(_ id: UUID) {
        guard !solved,
              let i = targets.firstIndex(where: { $0.id == id }),
              !targets[i].popped else { return }
        Haptics.light()
        withAnimation(DS.Motion.quick) {
            targets[i].popped = true
            caught += 1
        }
        if caught >= required {
            solved = true
            onSolved()
        }
    }

    /// Un punto al azar con el objetivo entero dentro del escenario y sin pisar
    /// los puntos a evitar. Si tras muchos intentos no hay sitio limpio (solo
    /// pasaría en un escenario minúsculo) devuelve el último candidato: antes
    /// solapar que dejar al jugador sin nada que tocar.
    private static func freeSpot(in area: CGSize, size: CGFloat, avoiding occupied: [CGPoint]) -> CGPoint? {
        let inset = size / 2 + 6
        guard area.width > inset * 2, area.height > inset * 2 else { return nil }
        let minDistance = size + 12
        var candidate = CGPoint(x: area.width / 2, y: area.height / 2)
        for _ in 0..<40 {
            candidate = CGPoint(
                x: .random(in: inset...(area.width - inset)),
                y: .random(in: inset...(area.height - inset))
            )
            let clear = occupied.allSatisfy { hypot($0.x - candidate.x, $0.y - candidate.y) >= minDistance }
            if clear { return candidate }
        }
        return candidate
    }
}

// MARK: - Modelo

/// Un objetivo en pantalla: qué emoji, dónde está y si ya lo atraparon.
struct ReflexTarget: Identifiable, Equatable {
    let id = UUID()
    let emoji: String
    let center: CGPoint
    var popped = false
}

/// El emoji dentro de un disco, con un anillo que se consume mientras dura.
/// Al atraparlo se infla y se desvanece.
private struct ReflexTargetView: View {
    let target: ReflexTarget
    let size: CGFloat
    let lifetime: Double
    let onTap: () -> Void

    @State private var remaining: CGFloat = 1

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.14), radius: 6, y: 3)
                Circle()
                    .trim(from: 0, to: remaining)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(2)
                Text(target.emoji)
                    .font(.system(size: size * 0.55))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .scaleEffect(target.popped ? 1.5 : 1)
        .opacity(target.popped ? 0 : 1)
        .allowsHitTesting(!target.popped)
        .accessibilityLabel(Text(target.emoji))
        .onAppear {
            withAnimation(.linear(duration: lifetime)) { remaining = 0 }
        }
    }
}
