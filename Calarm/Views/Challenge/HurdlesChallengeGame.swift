//
//  HurdlesChallengeGame.swift
//  Calarm
//

import SwiftUI

/// «Ovejas»: una oveja corre de noche hacia el amanecer y hay que hacerla
/// saltar las vallas. Un toque es un salto corto; mantener el dedo la eleva
/// más, y las vallas altas solo se pasan así. Cada valla saltada sube el sol.
/// Tropezar no resta: tras un instante se toca para seguir.
struct HurdlesChallengeGame: View {
    let difficulty: WakeChallenge.Difficulty
    let onSolved: () -> Void

    @State private var game: HurdlesGame

    init(difficulty: WakeChallenge.Difficulty, onSolved: @escaping () -> Void) {
        self.difficulty = difficulty
        self.onSolved = onSolved
        _game = State(initialValue: HurdlesGame(difficulty: difficulty))
    }

    var body: some View {
        VStack(spacing: DS.Spacing.md) {
            ArcadeProgressHeader(
                label: appLocalized("Vallas \(game.cleared) de \(game.required)"),
                value: game.cleared,
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
        .arcadeArena(aspectRatio: HurdlesGame.width / HurdlesGame.height)
        .overlay(alignment: .top) {
            if game.phase == .ready {
                ArcadeBanner("Toca para saltar; mantén pulsado para saltar más alto")
            } else if game.phase == .crashed, game.canContinue {
                ArcadeBanner("¡Ups! Toca para seguir")
            }
        }
        .animation(DS.Motion.quick, value: game.phase)
        .animation(DS.Motion.quick, value: game.canContinue)
        .onPress(began: { game.press() }, ended: { game.release() })
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        var ctx = context
        let scale = size.width / HurdlesGame.width
        ctx.scaleBy(x: scale, y: scale)
        let width = HurdlesGame.width
        let height = HurdlesGame.height
        let groundY = HurdlesGame.groundY
        // De la noche (0) al día (1) según el progreso.
        let dawn = min(Double(game.cleared) / Double(game.required), 1)

        // Cielo: azul noche → amanecer.
        let top = Self.mix((0.05, 0.07, 0.20), (0.42, 0.70, 0.95), dawn)
        let bottom = Self.mix((0.17, 0.14, 0.32), (1.00, 0.80, 0.58), dawn)
        ctx.fill(
            Path(CGRect(x: 0, y: 0, width: width, height: height)),
            with: .linearGradient(Gradient(colors: [top, bottom]), startPoint: .zero, endPoint: CGPoint(x: 0, y: groundY))
        )

        // Estrellas que se apagan al amanecer.
        if dawn < 1 {
            var stars = Path()
            for star in Self.stars {
                stars.addEllipse(in: CGRect(x: star.x - star.size / 2, y: star.y - star.size / 2, width: star.size, height: star.size))
            }
            ctx.fill(stars, with: .color(.white.opacity(0.8 * (1 - dawn))))
        }

        // El sol sale por detrás de las colinas.
        let sunCenter = CGPoint(x: 280, y: groundY + 26 - dawn * 150)
        ctx.fill(
            Path(ellipseIn: CGRect(x: sunCenter.x - 44, y: sunCenter.y - 44, width: 88, height: 88)),
            with: .radialGradient(
                Gradient(colors: [Color(red: 1, green: 0.85, blue: 0.4).opacity(0.55), .clear]),
                center: sunCenter, startRadius: 18, endRadius: 44
            )
        )
        ctx.fill(
            Path(ellipseIn: CGRect(x: sunCenter.x - 20, y: sunCenter.y - 20, width: 40, height: 40)),
            with: .color(Color(red: 1, green: 0.78, blue: 0.30))
        )

        // Colinas lejanas, que se mueven despacio.
        var hills = Path()
        hills.move(to: CGPoint(x: 0, y: groundY))
        var x = 0.0
        while x <= width {
            let worldX = x + game.scroll * 0.2
            let y = groundY - 26 - 14 * sin(worldX / 53) - 8 * sin(worldX / 21 + 1.3)
            hills.addLine(to: CGPoint(x: x, y: y))
            x += 6
        }
        hills.addLine(to: CGPoint(x: width, y: groundY))
        hills.closeSubpath()
        ctx.fill(hills, with: .color(Self.mix((0.10, 0.14, 0.24), (0.42, 0.62, 0.45), dawn)))

        // Hierba con matas que corren con el suelo.
        let grass = Self.mix((0.13, 0.25, 0.17), (0.40, 0.70, 0.33), dawn)
        ctx.fill(Path(CGRect(x: 0, y: groundY, width: width, height: height - groundY)), with: .color(grass))
        ctx.fill(Path(CGRect(x: 0, y: groundY, width: width, height: 3)), with: .color(.black.opacity(0.18)))
        var tufts = Path()
        let gap = 34.0
        var tx = -arcadeWrap(game.scroll, gap)
        while tx < width + gap {
            tufts.move(to: CGPoint(x: tx, y: groundY + 18))
            tufts.addLine(to: CGPoint(x: tx + 3, y: groundY + 11))
            tufts.move(to: CGPoint(x: tx + 6, y: groundY + 18))
            tufts.addLine(to: CGPoint(x: tx + 6, y: groundY + 10))
            tx += gap
        }
        ctx.stroke(tufts, with: .color(.black.opacity(0.18)), style: StrokeStyle(lineWidth: 2, lineCap: .round))

        // Vallas de madera.
        let wood = Color(red: 0.62, green: 0.42, blue: 0.24)
        let woodDark = Color(red: 0.45, green: 0.29, blue: 0.15)
        for obstacle in game.obstacles {
            for fenceX in obstacle.fenceXs {
                let h = obstacle.height
                var posts = Path()
                posts.addRoundedRect(in: CGRect(x: fenceX, y: groundY - h, width: 5, height: h), cornerSize: CGSize(width: 2, height: 2))
                posts.addRoundedRect(in: CGRect(x: fenceX + HurdlesGame.fenceWidth - 5, y: groundY - h, width: 5, height: h), cornerSize: CGSize(width: 2, height: 2))
                ctx.fill(posts, with: .color(woodDark))
                var rails = Path()
                rails.addRoundedRect(in: CGRect(x: fenceX - 2, y: groundY - h + 4, width: HurdlesGame.fenceWidth + 4, height: 5), cornerSize: CGSize(width: 2, height: 2))
                rails.addRoundedRect(in: CGRect(x: fenceX - 2, y: groundY - h * 0.45, width: HurdlesGame.fenceWidth + 4, height: 5), cornerSize: CGSize(width: 2, height: 2))
                ctx.fill(rails, with: .color(wood))
            }
        }

        // La oveja: los pies a `jumpHeight` del suelo; al tropezar rueda.
        let sheep = ctx.resolve(Text("🐑").font(.system(size: 40)))
        let spin = game.phase == .crashed ? -min(game.crashElapsed / 0.3, 1) * 100 : 0
        let center = CGPoint(x: HurdlesGame.sheepX, y: groundY - game.jumpHeight - 17)
        ctx.drawSprite(sheep, at: center, rotation: .degrees(spin), flipped: true)
    }

    private static func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> Color {
        Color(red: a.0 + (b.0 - a.0) * t, green: a.1 + (b.1 - a.1) * t, blue: a.2 + (b.2 - a.2) * t)
    }

    private struct Star {
        let x: Double
        let y: Double
        let size: Double
    }

    private static let stars: [Star] = {
        var rng = SplitMix64(seed: 7)
        return (0..<26).map { _ in
            Star(
                x: .random(in: 4...356, using: &rng),
                y: .random(in: 6...130, using: &rng),
                size: .random(in: 1.2...2.6, using: &rng)
            )
        }
    }()

    // MARK: - Bucle

    private func run() async {
        await ArcadeLoop.run { dt in
            for event in game.step(dt: dt) {
                switch event {
                case .cleared: Haptics.light()
                case .crashed: Haptics.warning()
                case .solved: onSolved()
                }
            }
            return game.phase != .done
        }
    }
}

// MARK: - Lógica

/// La partida de «Ovejas», sin nada de SwiftUI: coordenadas lógicas de
/// 360 × 240. La x crece hacia la derecha; la altura del salto se mide hacia
/// arriba desde el suelo.
struct HurdlesGame {
    enum Phase: Equatable {
        case ready
        case playing
        case crashed
        case done
    }

    enum Event: Equatable {
        case cleared
        case crashed
        case solved
    }

    enum Kind: Equatable {
        /// Se salta con un toque.
        case low
        /// Hay que mantener el dedo.
        case tall
        /// Dos vallas bajas seguidas: también hay que mantener.
        case double
    }

    struct Obstacle: Identifiable, Equatable {
        let id: Int
        var x: Double
        let kind: Kind

        var height: Double {
            kind == .tall ? HurdlesGame.tallHeight : HurdlesGame.lowHeight
        }

        /// Dónde empieza cada valla del obstáculo.
        var fenceXs: [Double] {
            kind == .double ? [x, x + HurdlesGame.fenceWidth + HurdlesGame.doubleGap] : [x]
        }

        var width: Double {
            kind == .double ? HurdlesGame.fenceWidth * 2 + HurdlesGame.doubleGap : HurdlesGame.fenceWidth
        }

        var cleared = false
    }

    static let width = 360.0
    static let height = 240.0
    static let groundY = 204.0
    static let sheepX = 72.0
    /// Caja de choque de la oveja, más pequeña que el dibujo.
    static let sheepHalfWidth = 12.0
    static let fenceWidth = 22.0
    static let doubleGap = 24.0
    static let lowHeight = 30.0
    /// Más alta de lo que llega un toque corto (unos 56): pide mantener.
    static let tallHeight = 64.0
    /// Lo que se perdona de cada valla: ni sus bordes ni su remate cuentan.
    static let fenceForgiveness = 4.0
    static let jumpSpeed = 600.0
    /// Gravedad mientras sube con el dedo apoyado: manteniendo llega a ~120.
    static let holdGravity = 1500.0
    /// Gravedad al soltar o al caer: el salto corto es corto de verdad.
    static let fallGravity = 2000.0
    /// Al soltar pronto, la subida se recorta a esta velocidad.
    static let releaseSpeed = 300.0
    /// Un toque poco antes de aterrizar no se pierde: salta al tocar suelo.
    static let jumpBuffer = 0.12
    static let crashCooldown = 0.6

    let required: Int
    let baseSpeed: Double
    /// Separación entre obstáculos, en segundos de carrera.
    let spacing: ClosedRange<Double>
    let tallChance: Double
    let doubleChance: Double

    private(set) var phase: Phase = .ready
    private(set) var cleared = 0
    /// Altura de los pies sobre el suelo.
    private(set) var jumpHeight = 0.0
    private(set) var obstacles: [Obstacle] = []
    private(set) var scroll = 0.0
    private(set) var crashElapsed = 0.0
    private var velocity = 0.0
    private var holding = false
    /// Si el dedo sigue apoyado (para el salto guardado).
    private var pressed = false
    private var buffered = 0.0
    private var untilNext = 0.0
    private var nextID = 0
    private var rng: SplitMix64

    init(difficulty: WakeChallenge.Difficulty, seed: UInt64 = .random(in: .min ... .max)) {
        switch difficulty {
        case .easy:
            required = 8; baseSpeed = 200; spacing = 1.25...2.0; tallChance = 0; doubleChance = 0
        case .medium:
            required = 12; baseSpeed = 225; spacing = 1.1...1.7; tallChance = 0.3; doubleChance = 0
        case .hard:
            required = 16; baseSpeed = 250; spacing = 1.0...1.5; tallChance = 0.35; doubleChance = 0.2
        }
        rng = SplitMix64(seed: seed)
    }

    var canContinue: Bool {
        phase == .crashed && crashElapsed >= Self.crashCooldown
    }

    var isOnGround: Bool {
        jumpHeight <= 0 && velocity <= 0
    }

    /// Acelera un poco con cada valla, hasta un tope.
    var speed: Double {
        baseSpeed + min(Double(cleared) * 3, 40)
    }

    mutating func press() {
        pressed = true
        switch phase {
        case .ready:
            phase = .playing
            untilNext = 0
            jump()
        case .playing:
            if isOnGround {
                jump()
            } else {
                buffered = Self.jumpBuffer
            }
        case .crashed:
            guard canContinue else { return }
            obstacles.removeAll()
            jumpHeight = 0
            velocity = 0
            untilNext = 0.6
            phase = .playing
        case .done:
            break
        }
    }

    mutating func release() {
        pressed = false
        holding = false
        if velocity > Self.releaseSpeed {
            velocity = Self.releaseSpeed
        }
    }

    mutating func step(dt: Double) -> [Event] {
        switch phase {
        case .ready, .done:
            return []
        case .crashed:
            crashElapsed += dt
            applyGravity(dt: dt)
            return []
        case .playing:
            break
        }

        var events: [Event] = []
        applyGravity(dt: dt)
        if buffered > 0 {
            buffered -= dt
            if isOnGround {
                buffered = 0
                jump()
                // Si ya soltó, es un salto corto.
                if !pressed { release() }
            }
        }

        let distance = speed * dt
        scroll += distance
        for i in obstacles.indices {
            obstacles[i].x -= distance
        }
        obstacles.removeAll { $0.x + $0.width < -10 }

        untilNext -= dt
        if untilNext <= 0 {
            spawn()
        }

        let sheepLeft = Self.sheepX - Self.sheepHalfWidth
        for i in obstacles.indices where !obstacles[i].cleared && obstacles[i].x + obstacles[i].width < sheepLeft {
            obstacles[i].cleared = true
            cleared += 1
            if cleared >= required {
                phase = .done
                return events + [.cleared, .solved]
            }
            events.append(.cleared)
        }

        if collides() {
            phase = .crashed
            crashElapsed = 0
            holding = false
            buffered = 0
            velocity = min(velocity, 0)
            events.append(.crashed)
        }
        return events
    }

    // MARK: - Interno

    private mutating func jump() {
        guard isOnGround else { return }
        velocity = Self.jumpSpeed
        holding = true
    }

    private mutating func applyGravity(dt: Double) {
        guard jumpHeight > 0 || velocity > 0 else { return }
        let gravity = holding && velocity > 0 ? Self.holdGravity : Self.fallGravity
        velocity -= gravity * dt
        jumpHeight += velocity * dt
        if jumpHeight <= 0 {
            jumpHeight = 0
            velocity = 0
        }
    }

    private mutating func spawn() {
        let roll = Double.random(in: 0..<1, using: &rng)
        let kind: Kind = roll < doubleChance ? .double : (roll < doubleChance + tallChance ? .tall : .low)
        obstacles.append(Obstacle(id: nextID, x: Self.width + 10, kind: kind))
        nextID += 1
        var wait = Double.random(in: spacing, using: &rng)
        if kind == .double { wait += 0.2 }
        untilNext = wait
    }

    private func collides() -> Bool {
        let sheepLeft = Self.sheepX - Self.sheepHalfWidth
        let sheepRight = Self.sheepX + Self.sheepHalfWidth
        let margin = Self.fenceForgiveness
        for obstacle in obstacles {
            for fenceX in obstacle.fenceXs {
                let overlapsX = fenceX + margin < sheepRight && fenceX + Self.fenceWidth - margin > sheepLeft
                if overlapsX && jumpHeight < obstacle.height - margin {
                    return true
                }
            }
        }
        return false
    }
}
