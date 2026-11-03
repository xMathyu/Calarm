//
//  FlapChallengeGame.swift
//  Calarm
//

import SwiftUI

/// «Vuelo»: una abeja que cae sola y sube un poco con cada toque. Hay que
/// pasarla por los huecos de las columnas que llegan desde la derecha. Chocar
/// no resta: tras un instante se toca para seguir y los huecos ya pasados se
/// conservan, así que el reto siempre se puede terminar.
struct FlapChallengeGame: View {
    let difficulty: WakeChallenge.Difficulty
    let onSolved: () -> Void

    @State private var game: FlapGame
    @Environment(\.colorScheme) private var colorScheme

    init(difficulty: WakeChallenge.Difficulty, onSolved: @escaping () -> Void) {
        self.difficulty = difficulty
        self.onSolved = onSolved
        _game = State(initialValue: FlapGame(difficulty: difficulty))
    }

    var body: some View {
        VStack(spacing: DS.Spacing.md) {
            ArcadeProgressHeader(
                label: appLocalized("Huecos \(game.passed) de \(game.required)"),
                value: game.passed,
                total: game.required
            )
            arena
        }
        .task { await run() }
    }

    // MARK: - Escenario

    private var arena: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            draw(in: context, size: size)
        }
        .arcadeArena(aspectRatio: FlapGame.width / FlapGame.height)
        .overlay {
            if game.phase == .ready {
                ArcadeBanner("Toca para volar")
            } else if game.phase == .crashed, game.canContinue {
                ArcadeBanner("¡Choque! Toca para seguir")
            }
        }
        .animation(DS.Motion.quick, value: game.phase)
        .animation(DS.Motion.quick, value: game.canContinue)
        .onPress(began: { game.press() })
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        var ctx = context
        let scale = size.width / FlapGame.width
        ctx.scaleBy(x: scale, y: scale)
        let width = FlapGame.width
        let height = FlapGame.height
        let groundY = FlapGame.groundY
        let dark = colorScheme == .dark

        // Cielo.
        let sky = dark
            ? [Color(red: 0.05, green: 0.09, blue: 0.20), Color(red: 0.16, green: 0.22, blue: 0.38)]
            : [Color(red: 0.55, green: 0.80, blue: 0.98), Color(red: 0.92, green: 0.97, blue: 1.00)]
        ctx.fill(
            Path(CGRect(x: 0, y: 0, width: width, height: height)),
            with: .linearGradient(Gradient(colors: sky), startPoint: .zero, endPoint: CGPoint(x: 0, y: height))
        )

        // Nubes lejanas, más lentas que las columnas.
        let cloudColor = Color.white.opacity(dark ? 0.10 : 0.85)
        for cloud in Self.clouds {
            let x = arcadeWrap(cloud.x - game.scroll * 0.3, width + 140) - 70
            var puff = Path()
            puff.addEllipse(in: CGRect(x: x - 26 * cloud.scale, y: cloud.y - 8 * cloud.scale, width: 52 * cloud.scale, height: 22 * cloud.scale))
            puff.addEllipse(in: CGRect(x: x - 14 * cloud.scale, y: cloud.y - 18 * cloud.scale, width: 30 * cloud.scale, height: 26 * cloud.scale))
            ctx.fill(puff, with: .color(cloudColor))
        }

        // Columnas: se prolongan por fuera del escenario para que solo se vean
        // redondeadas las esquinas del hueco.
        let columnWidth = FlapGame.columnWidth
        for column in game.columns {
            let top = CGRect(x: column.x, y: -30, width: columnWidth, height: column.gapTop + 30)
            let bottom = CGRect(x: column.x, y: column.gapBottom, width: columnWidth, height: groundY - column.gapBottom + 30)
            for rect in [top, bottom] {
                let shape = Path(roundedRect: rect, cornerRadius: 14, style: .continuous)
                ctx.fill(
                    shape,
                    with: .linearGradient(
                        Gradient(colors: [Color.accentColor, Color.accentColor.opacity(0.72)]),
                        startPoint: CGPoint(x: rect.minX, y: 0),
                        endPoint: CGPoint(x: rect.maxX, y: 0)
                    )
                )
                let shine = CGRect(x: rect.minX + 8, y: rect.minY + 10, width: 7, height: max(0, rect.height - 20))
                ctx.fill(Path(roundedRect: shine, cornerRadius: 3.5), with: .color(.white.opacity(0.22)))
            }
        }

        // Suelo con marcas que corren a la velocidad de las columnas.
        let ground = CGRect(x: 0, y: groundY, width: width, height: height - groundY)
        ctx.fill(Path(ground), with: .color(dark ? Color(red: 0.20, green: 0.30, blue: 0.18) : Color(red: 0.55, green: 0.78, blue: 0.40)))
        ctx.fill(Path(CGRect(x: 0, y: groundY, width: width, height: 4)), with: .color(.black.opacity(0.12)))
        var marks = Path()
        let gap = 26.0
        let offset = arcadeWrap(game.scroll, gap)
        var x = -offset
        while x < width + gap {
            marks.move(to: CGPoint(x: x, y: groundY + 12))
            marks.addLine(to: CGPoint(x: x + 8, y: groundY + 20))
            x += gap
        }
        ctx.stroke(marks, with: .color(.black.opacity(0.15)), style: StrokeStyle(lineWidth: 3, lineCap: .round))

        // La abeja: se inclina hacia arriba al subir y hacia abajo al caer.
        let bee = ctx.resolve(Text("🐝").font(.system(size: 34)))
        let tilt = game.phase == .crashed ? 80 : min(max(game.beeVY / 700 * 40, -25), 55)
        ctx.drawSprite(bee, at: CGPoint(x: FlapGame.beeX, y: game.beeY), rotation: .degrees(tilt), flipped: true)
    }

    private struct Cloud {
        let x: Double
        let y: Double
        let scale: Double
    }

    private static let clouds = [
        Cloud(x: 40, y: 60, scale: 1.0),
        Cloud(x: 210, y: 110, scale: 0.8),
        Cloud(x: 330, y: 40, scale: 1.2),
        Cloud(x: 130, y: 200, scale: 0.7),
    ]

    // MARK: - Bucle

    private func run() async {
        await ArcadeLoop.run { dt in
            for event in game.step(dt: dt) {
                switch event {
                case .passed: Haptics.light()
                case .crashed: Haptics.warning()
                case .solved: onSolved()
                }
            }
            return game.phase != .done
        }
    }
}

// MARK: - Lógica

/// La partida de «Vuelo», sin nada de SwiftUI: coordenadas lógicas de
/// 360 × 360 con la y hacia abajo.
struct FlapGame {
    enum Phase: Equatable {
        /// La abeja flota esperando el primer toque.
        case ready
        case playing
        /// Chocó: cae al suelo y, pasado `crashCooldown`, un toque sigue.
        case crashed
        case done
    }

    enum Event: Equatable {
        case passed
        case crashed
        case solved
    }

    struct Column: Identifiable, Equatable {
        let id: Int
        var x: Double
        let gapTop: Double
        let gapBottom: Double
        var passed = false
    }

    static let width = 360.0
    static let height = 360.0
    static let groundY = 330.0
    static let beeX = 92.0
    /// Radio de choque de la abeja: algo menor que el dibujo, para perdonar
    /// los roces.
    static let beeRadius = 12.0
    static let columnWidth = 56.0
    static let gravity = 1350.0
    static let flapSpeed = -400.0
    static let maxFallSpeed = 620.0
    static let crashCooldown = 0.6
    /// Margen mínimo entre el hueco y el techo o el suelo.
    static let gapMargin = 34.0

    let required: Int
    let gap: Double
    let speed: Double
    let spacing: Double
    /// Cuánto puede moverse el centro del hueco de una columna a la siguiente.
    let maxShift: Double

    private(set) var phase: Phase = .ready
    private(set) var passed = 0
    private(set) var beeY: Double
    private(set) var beeVY = 0.0
    private(set) var columns: [Column] = []
    /// Distancia recorrida, para desplazar el suelo y las nubes.
    private(set) var scroll = 0.0
    private var time = 0.0
    private var crashElapsed = 0.0
    private var nextID = 0
    private var lastGapCenter: Double
    private var rng: SplitMix64

    init(difficulty: WakeChallenge.Difficulty, seed: UInt64 = .random(in: .min ... .max)) {
        switch difficulty {
        case .easy:
            required = 5; gap = 150; speed = 125; spacing = 205; maxShift = 100
        case .medium:
            required = 8; gap = 132; speed = 145; spacing = 195; maxShift = 130
        case .hard:
            required = 12; gap = 116; speed = 165; spacing = 190; maxShift = 150
        }
        rng = SplitMix64(seed: seed)
        beeY = Self.groundY / 2
        lastGapCenter = Self.groundY / 2
    }

    var canContinue: Bool {
        phase == .crashed && crashElapsed >= Self.crashCooldown
    }

    /// Un toque: arranca, aletea o, tras un choque, vuelve a empezar.
    mutating func press() {
        switch phase {
        case .ready:
            phase = .playing
            beeVY = Self.flapSpeed
        case .playing:
            beeVY = Self.flapSpeed
        case .crashed:
            guard canContinue else { return }
            restart()
        case .done:
            break
        }
    }

    mutating func step(dt: Double) -> [Event] {
        time += dt
        switch phase {
        case .ready:
            beeY = Self.groundY / 2 + sin(time * 3) * 6
            scroll += speed * 0.5 * dt
            return []
        case .crashed:
            crashElapsed += dt
            let floor = Self.groundY - Self.beeRadius
            if beeY < floor {
                beeVY = min(beeVY + Self.gravity * dt, Self.maxFallSpeed)
                beeY = min(beeY + beeVY * dt, floor)
            }
            return []
        case .done:
            return []
        case .playing:
            break
        }

        var events: [Event] = []
        beeVY = min(beeVY + Self.gravity * dt, Self.maxFallSpeed)
        beeY += beeVY * dt
        // El techo no mata: solo frena.
        if beeY < Self.beeRadius {
            beeY = Self.beeRadius
            beeVY = max(beeVY, 0)
        }

        scroll += speed * dt
        for i in columns.indices {
            columns[i].x -= speed * dt
        }
        columns.removeAll { $0.x + Self.columnWidth < -10 }
        spawnIfNeeded()

        for i in columns.indices where !columns[i].passed && columns[i].x + Self.columnWidth < Self.beeX - Self.beeRadius {
            columns[i].passed = true
            passed += 1
            if passed >= required {
                phase = .done
                return events + [.passed, .solved]
            }
            events.append(.passed)
        }

        if collides() {
            phase = .crashed
            crashElapsed = 0
            beeVY = max(beeVY, 0)
            events.append(.crashed)
        }
        return events
    }

    // MARK: - Interno

    private mutating func restart() {
        columns.removeAll()
        beeY = Self.groundY / 2
        lastGapCenter = beeY
        phase = .playing
        beeVY = Self.flapSpeed
    }

    private mutating func spawnIfNeeded() {
        let x: Double
        if let last = columns.last {
            guard last.x + spacing <= Self.width + 20 else { return }
            x = last.x + spacing
        } else {
            x = Self.width + 60
        }
        let half = gap / 2
        let lowest = Self.gapMargin + half
        let highest = Self.groundY - Self.gapMargin - half
        let low = max(lowest, lastGapCenter - maxShift)
        let high = min(highest, lastGapCenter + maxShift)
        let center = Double.random(in: low...high, using: &rng)
        lastGapCenter = center
        columns.append(Column(id: nextID, x: x, gapTop: center - half, gapBottom: center + half))
        nextID += 1
    }

    private func collides() -> Bool {
        if beeY + Self.beeRadius >= Self.groundY { return true }
        let bee = CGPoint(x: Self.beeX, y: beeY)
        for column in columns {
            let top = CGRect(x: column.x, y: -1000, width: Self.columnWidth, height: column.gapTop + 1000)
            let bottom = CGRect(x: column.x, y: column.gapBottom, width: Self.columnWidth, height: 1000)
            if Self.circle(bee, radius: Self.beeRadius, hits: top) || Self.circle(bee, radius: Self.beeRadius, hits: bottom) {
                return true
            }
        }
        return false
    }

    private static func circle(_ center: CGPoint, radius: Double, hits rect: CGRect) -> Bool {
        let nearestX = min(max(center.x, rect.minX), rect.maxX)
        let nearestY = min(max(center.y, rect.minY), rect.maxY)
        return hypot(center.x - nearestX, center.y - nearestY) < radius
    }
}
