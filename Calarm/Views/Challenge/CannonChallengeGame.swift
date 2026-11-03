//
//  CannonChallengeGame.swift
//  Calarm
//

import SwiftUI

/// «Cañón»: artillería por turnos contra un despertador al otro lado de una
/// colina. Se apunta arrastrando el dedo por el campo y se dispara manteniendo
/// el botón: la fuerza sube y baja mientras se mantiene, y se suelta en el
/// punto justo. El viento desvía el disparo; cada explosión abre un cráter en
/// el terreno. La barra de fuerza marca la del tiro anterior y queda dibujada
/// su trayectoria, para corregir. El viento y el sitio del despertador solo
/// cambian tras un impacto, así que fallar sirve para afinar.
struct CannonChallengeGame: View {
    let difficulty: WakeChallenge.Difficulty
    let onSolved: () -> Void

    @State private var game: CannonGame
    @Environment(\.colorScheme) private var colorScheme

    init(difficulty: WakeChallenge.Difficulty, onSolved: @escaping () -> Void) {
        self.difficulty = difficulty
        self.onSolved = onSolved
        _game = State(initialValue: CannonGame(difficulty: difficulty))
    }

    var body: some View {
        VStack(spacing: DS.Spacing.md) {
            ArcadeProgressHeader(
                label: appLocalized("Impactos \(game.hits) de \(game.required)"),
                value: game.hits,
                total: game.required
            )
            arena
            powerBar
            fireButton
        }
        .task { await run() }
    }

    // MARK: - Escenario

    private var arena: some View {
        GeometryReader { geo in
            Canvas(rendersAsynchronously: false) { context, size in
                draw(in: context, size: size)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let scale = CannonGame.width / max(geo.size.width, 1)
                        game.aim(at: CGPoint(x: value.location.x * scale, y: value.location.y * scale))
                    }
            )
        }
        .arcadeArena(aspectRatio: CannonGame.width / CannonGame.height)
        .overlay(alignment: .bottom) {
            if !game.hasAimed, game.phase == .aiming {
                ArcadeBanner("Arrastra por el campo para apuntar")
            }
        }
        .animation(DS.Motion.quick, value: game.hasAimed)
    }

    private var powerBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.tertiarySystemFill))
                Capsule()
                    .fill(LinearGradient(colors: [.yellow, .orange, .red], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * game.power)
                if let last = game.lastPower {
                    // La fuerza del tiro anterior.
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(0.7))
                        .frame(width: 3, height: geo.size.height + 6)
                        .offset(x: geo.size.width * last - 1.5)
                }
            }
        }
        .frame(height: 12)
        .frame(maxWidth: 360)
        .accessibilityElement()
        .accessibilityLabel(Text("Fuerza"))
        .accessibilityValue(Text(game.power, format: .percent.precision(.fractionLength(0))))
    }

    private var fireButton: some View {
        let ready = game.phase == .aiming || game.phase == .charging
        return Text(game.phase == .charging ? "Suelta para disparar" : "Mantén pulsado para cargar")
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: 360)
            .frame(height: 50)
            .background(Color.accentColor.opacity(ready ? 1 : 0.4), in: Capsule())
            .scaleEffect(game.phase == .charging ? 0.97 : 1)
            .animation(DS.Motion.quick, value: game.phase)
            .contentShape(Capsule())
            .onPress(began: { game.beginCharge() }, ended: { game.releaseCharge() })
            .accessibilityAddTraits(.isButton)
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        var ctx = context
        let scale = size.width / CannonGame.width
        ctx.scaleBy(x: scale, y: scale)
        let width = CannonGame.width
        let height = CannonGame.height
        let dark = colorScheme == .dark

        // Cielo.
        let sky = dark
            ? [Color(red: 0.06, green: 0.10, blue: 0.20), Color(red: 0.18, green: 0.17, blue: 0.30)]
            : [Color(red: 0.70, green: 0.86, blue: 1.00), Color(red: 1.00, green: 0.95, blue: 0.86)]
        ctx.fill(
            Path(CGRect(x: 0, y: 0, width: width, height: height)),
            with: .linearGradient(Gradient(colors: sky), startPoint: .zero, endPoint: CGPoint(x: 0, y: height))
        )

        drawWind(in: ctx)

        // Trayectorias: la del tiro anterior, tenue; la del actual, marcada.
        let dotColor = dark ? Color.white : Color.black
        for (trail, opacity) in [(game.previousTrail, 0.18), (game.trail, 0.45)] {
            var dots = Path()
            for p in trail {
                dots.addEllipse(in: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3))
            }
            ctx.fill(dots, with: .color(dotColor.opacity(opacity)))
        }

        // Terreno: tierra con una franja de hierba encima.
        var ground = Path()
        ground.move(to: CGPoint(x: 0, y: height))
        var surface = Path()
        for (i, top) in game.terrain.enumerated() {
            let p = CGPoint(x: Double(i) * CannonGame.sampleStep, y: top)
            ground.addLine(to: p)
            i == 0 ? surface.move(to: p) : surface.addLine(to: p)
        }
        ground.addLine(to: CGPoint(x: width, y: height))
        ground.closeSubpath()
        let earth = dark
            ? [Color(red: 0.30, green: 0.22, blue: 0.16), Color(red: 0.18, green: 0.13, blue: 0.10)]
            : [Color(red: 0.66, green: 0.50, blue: 0.34), Color(red: 0.48, green: 0.35, blue: 0.24)]
        ctx.fill(ground, with: .linearGradient(Gradient(colors: earth), startPoint: CGPoint(x: 0, y: 120), endPoint: CGPoint(x: 0, y: height)))
        ctx.stroke(surface, with: .color(dark ? Color(red: 0.30, green: 0.55, blue: 0.30) : Color(red: 0.38, green: 0.68, blue: 0.32)), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))

        // El despertador.
        let target = game.target
        let clock = ctx.resolve(Text("⏰").font(.system(size: target.radius * 2.3)))
        ctx.drawSprite(clock, at: CGPoint(x: target.x, y: target.y))

        drawCannon(in: ctx)

        // El proyectil; si sale por arriba, una marca en el borde dice dónde va.
        if let shell = game.shell {
            if shell.y < 0 {
                var marker = Path()
                marker.move(to: CGPoint(x: shell.x, y: 2))
                marker.addLine(to: CGPoint(x: shell.x - 5, y: 10))
                marker.addLine(to: CGPoint(x: shell.x + 5, y: 10))
                marker.closeSubpath()
                ctx.fill(marker, with: .color(dotColor.opacity(0.6)))
            } else {
                let r = CannonGame.shellRadius
                ctx.fill(Path(ellipseIn: CGRect(x: shell.x - r, y: shell.y - r, width: r * 2, height: r * 2)), with: .color(dark ? .white : Color(white: 0.15)))
            }
        }

        // La explosión: crece y se apaga.
        if let blast = game.blast {
            let t = min(blast.age / CannonGame.blastDuration, 1)
            let r = CannonGame.blastRadius * (0.5 + t * 0.8)
            let rect = CGRect(x: blast.x - r, y: blast.y - r, width: r * 2, height: r * 2)
            ctx.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    Gradient(colors: [Color.yellow.opacity(1 - t), Color.orange.opacity(0.8 * (1 - t)), Color.red.opacity(0)]),
                    center: CGPoint(x: blast.x, y: blast.y), startRadius: 0, endRadius: r
                )
            )
        }
    }

    private func drawCannon(in ctx: GraphicsContext) {
        let pivot = CGPoint(x: CannonGame.cannonX, y: game.cannonY)
        let radians = game.angle * .pi / 180

        // Guía de puntería mientras se apunta.
        if game.phase == .aiming || game.phase == .charging {
            let start = CGPoint(x: pivot.x + cos(radians) * (CannonGame.barrelLength + 4), y: pivot.y - sin(radians) * (CannonGame.barrelLength + 4))
            let end = CGPoint(x: pivot.x + cos(radians) * (CannonGame.barrelLength + 46), y: pivot.y - sin(radians) * (CannonGame.barrelLength + 46))
            var guide = Path()
            guide.move(to: start)
            guide.addLine(to: end)
            ctx.stroke(guide, with: .color(Color.accentColor.opacity(0.7)), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 5]))
        }

        // Cañón: tubo girado sobre una base redonda.
        var barrelContext = ctx
        barrelContext.translateBy(x: pivot.x, y: pivot.y)
        barrelContext.rotate(by: .radians(-radians))
        let barrel = CGRect(x: 0, y: -4.5, width: CannonGame.barrelLength, height: 9)
        barrelContext.fill(Path(roundedRect: barrel, cornerRadius: 3), with: .color(Color(white: 0.28)))
        barrelContext.fill(Path(roundedRect: CGRect(x: CannonGame.barrelLength - 5, y: -5.5, width: 5, height: 11), cornerRadius: 2), with: .color(Color(white: 0.18)))
        ctx.fill(Path(ellipseIn: CGRect(x: pivot.x - 10, y: pivot.y - 10, width: 20, height: 20)), with: .color(Color.accentColor))
        ctx.fill(Path(ellipseIn: CGRect(x: pivot.x - 4, y: pivot.y - 4, width: 8, height: 8)), with: .color(.white.opacity(0.5)))

        // Ángulo actual.
        let label = ctx.resolve(Text(verbatim: "\(Int(game.angle.rounded()))°").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary))
        ctx.draw(label, at: CGPoint(x: pivot.x + 4, y: pivot.y - 44), anchor: .center)
    }

    /// «Viento» con una flecha cuyo largo depende de la fuerza.
    private func drawWind(in ctx: GraphicsContext) {
        let center = CGPoint(x: CannonGame.width / 2, y: 18)
        let strength = game.windStrength
        let title = ctx.resolve(Text("Viento \(strength)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary))
        ctx.draw(title, at: center, anchor: .center)
        guard strength > 0 else { return }
        let direction: Double = game.wind > 0 ? 1 : -1
        let length = 14 + Double(strength) * 7
        let y = center.y + 16
        let tail = CGPoint(x: center.x - direction * length / 2, y: y)
        let head = CGPoint(x: center.x + direction * length / 2, y: y)
        var arrow = Path()
        arrow.move(to: tail)
        arrow.addLine(to: head)
        arrow.move(to: CGPoint(x: head.x - direction * 6, y: y - 5))
        arrow.addLine(to: head)
        arrow.addLine(to: CGPoint(x: head.x - direction * 6, y: y + 5))
        ctx.stroke(arrow, with: .color(Color.accentColor), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    }

    // MARK: - Bucle

    private func run() async {
        await ArcadeLoop.run { dt in
            for event in game.step(dt: dt) {
                switch event {
                case .hit: Haptics.rigid()
                case .miss: Haptics.soft()
                case .solved: onSolved()
                }
            }
            return game.phase != .done
        }
    }
}

// MARK: - Lógica

/// La partida de «Cañón», sin nada de SwiftUI: coordenadas lógicas de
/// 360 × 280 con la y hacia abajo. El terreno es un mapa de alturas (la y de
/// la superficie cada `sampleStep` puntos) y el proyectil se integra a paso
/// fijo, el mismo que usa la búsqueda que garantiza que cada blanco tiene
/// solución.
struct CannonGame {
    enum Phase: Equatable {
        case aiming
        /// El dedo está en el botón: la fuerza sube y baja.
        case charging
        case flying
        case exploding
        case done
    }

    enum Event: Equatable {
        case hit
        case miss
        case solved
    }

    struct Target: Equatable {
        var x: Double
        var y: Double
        let radius: Double
    }

    struct Shell: Equatable {
        var x: Double
        var y: Double
        var vx: Double
        var vy: Double
    }

    struct Blast: Equatable {
        let x: Double
        let y: Double
        let hit: Bool
        var age = 0.0
    }

    static let width = 360.0
    static let height = 280.0
    static let sampleStep = 2.0
    static let gravity = 300.0
    static let minSpeed = 90.0
    static let maxSpeed = 430.0
    static let cannonX = 36.0
    static let barrelLength = 24.0
    static let shellRadius = 4.0
    static let blastRadius = 20.0
    static let blastDuration = 0.5
    /// Segundos que tarda la fuerza en ir de 0 al máximo (y otros tantos en
    /// volver): mantener el dedo sin más no da el disparo más fuerte.
    static let chargePeriod = 1.4
    /// Una pulsación más corta no dispara: así un roce no gasta el tiro.
    static let minCharge = 0.12
    static let angleRange = 10.0...85.0
    static let fixedStep = 1.0 / 120
    /// Zona donde puede aparecer el despertador.
    static let targetZone = 214.0...332.0

    let required: Int
    let targetRadius: Double
    let windRange: ClosedRange<Double>

    private(set) var phase: Phase = .aiming
    private(set) var hits = 0
    private(set) var terrain: [Double]
    private(set) var cannonY: Double
    private(set) var target: Target
    /// Aceleración horizontal del viento, en puntos/s² (positiva: hacia la derecha).
    private(set) var wind = 0.0
    private(set) var angle = 45.0
    private(set) var power = 0.0
    private(set) var lastPower: Double?
    private(set) var hasAimed = false
    private(set) var shell: Shell?
    private(set) var trail: [CGPoint] = []
    private(set) var previousTrail: [CGPoint] = []
    private(set) var blast: Blast?
    private var chargeElapsed = 0.0
    private var accumulator = 0.0
    private var flightSteps = 0
    private var rng: SplitMix64

    init(difficulty: WakeChallenge.Difficulty, seed: UInt64 = .random(in: .min ... .max)) {
        let hill: ClosedRange<Double>
        switch difficulty {
        case .easy:
            required = 2; targetRadius = 18; windRange = 0...20; hill = 35...55
        case .medium:
            required = 3; targetRadius = 15; windRange = 10...45; hill = 50...75
        case .hard:
            required = 4; targetRadius = 12; windRange = 25...65; hill = 65...95
        }
        var rng = SplitMix64(seed: seed)
        let terrain = Self.makeTerrain(hill: hill, using: &rng)
        self.terrain = terrain
        cannonY = Self.top(of: terrain, at: Self.cannonX) - 10
        target = Target(x: 280, y: 0, radius: targetRadius)
        self.rng = rng
        relocate(avoiding: nil)
    }

    /// Fuerza del viento en la escala que se enseña (0 a 7).
    var windStrength: Int {
        Int((abs(wind) / 10).rounded())
    }

    // MARK: - Controles

    /// Apunta hacia un punto del campo (coordenadas lógicas).
    mutating func aim(at point: CGPoint) {
        guard phase == .aiming || phase == .charging else { return }
        let dx = max(point.x - Self.cannonX, 1)
        let dy = cannonY - point.y
        let degrees = atan2(dy, dx) * 180 / .pi
        angle = min(max(degrees, Self.angleRange.lowerBound), Self.angleRange.upperBound)
        hasAimed = true
    }

    mutating func beginCharge() {
        guard phase == .aiming else { return }
        phase = .charging
        chargeElapsed = 0
        power = 0
    }

    mutating func releaseCharge() {
        guard phase == .charging else { return }
        if chargeElapsed < Self.minCharge {
            phase = .aiming
            power = 0
            return
        }
        fire()
    }

    // MARK: - Simulación

    mutating func step(dt: Double) -> [Event] {
        var events: [Event] = []
        switch phase {
        case .charging:
            chargeElapsed += dt
            power = Self.triangle(chargeElapsed / Self.chargePeriod)
        case .flying:
            accumulator += dt
            while accumulator >= Self.fixedStep, phase == .flying {
                accumulator -= Self.fixedStep
                if let event = advanceShell() {
                    events.append(event)
                }
            }
        case .exploding:
            guard var current = blast else {
                phase = .aiming
                break
            }
            current.age += dt
            blast = current
            if current.age >= Self.blastDuration {
                blast = nil
                if current.hit {
                    if hits >= required {
                        phase = .done
                        events.append(.solved)
                    } else {
                        relocate(avoiding: target.x)
                        phase = .aiming
                    }
                } else {
                    phase = .aiming
                }
            }
        case .aiming, .done:
            break
        }
        return events
    }

    private mutating func fire() {
        let speed = Self.speed(for: power)
        let radians = angle * .pi / 180
        let muzzle = Self.muzzle(pivotY: cannonY, radians: radians)
        shell = Shell(x: muzzle.x, y: muzzle.y, vx: cos(radians) * speed, vy: -sin(radians) * speed)
        lastPower = power
        previousTrail = trail
        trail = [muzzle]
        accumulator = 0
        flightSteps = 0
        phase = .flying
    }

    private mutating func advanceShell() -> Event? {
        guard var s = shell else { return nil }
        Self.advance(&s, wind: wind)
        flightSteps += 1
        if flightSteps % 3 == 0, s.y >= -20 {
            trail.append(CGPoint(x: s.x, y: s.y))
        }
        switch Self.outcome(of: s, terrain: terrain, target: target) {
        case .flying:
            shell = s
            return nil
        case .lost:
            shell = nil
            power = 0
            phase = .aiming
            return .miss
        case .impact:
            shell = nil
            trail.append(CGPoint(x: s.x, y: s.y))
            let hit = Self.isHit(x: s.x, y: s.y, target: target)
            carve(x: s.x, y: s.y)
            settleTarget()
            blast = Blast(x: s.x, y: s.y, hit: hit)
            power = 0
            phase = .exploding
            if hit {
                hits += 1
                return .hit
            }
            return .miss
        }
    }

    /// Abre un cráter: la superficie baja donde la alcanza el círculo de la
    /// explosión. Nunca bajo el cañón ni hasta el fondo del todo.
    private mutating func carve(x cx: Double, y cy: Double) {
        let r = Self.blastRadius
        for i in terrain.indices {
            let x = Double(i) * Self.sampleStep
            let dx = x - cx
            guard abs(dx) < r, abs(x - Self.cannonX) > 24 else { continue }
            let h = (r * r - dx * dx).squareRoot()
            if cy - h <= terrain[i], terrain[i] < cy + h {
                terrain[i] = min(cy + h, Self.height - 8)
            }
        }
    }

    /// El despertador descansa sobre lo más alto del suelo que tiene debajo.
    private mutating func settleTarget() {
        target.y = Self.restingY(x: target.x, radius: target.radius, terrain: terrain)
    }

    /// Nuevo sitio y nuevo viento para el despertador, con la garantía de que
    /// hay varias combinaciones de ángulo y fuerza que le dan.
    private mutating func relocate(avoiding previousX: Double?) {
        for _ in 0..<40 {
            let x = Double.random(in: Self.targetZone, using: &rng)
            if let previousX, abs(x - previousX) < 36 { continue }
            let magnitude = Double.random(in: windRange, using: &rng)
            let candidateWind = Bool.random(using: &rng) ? magnitude : -magnitude
            let candidate = Target(x: x, y: Self.restingY(x: x, radius: targetRadius, terrain: terrain), radius: targetRadius)
            if Self.solutionCount(terrain: terrain, cannonY: cannonY, target: candidate, wind: candidateWind, enough: 4) >= 4 {
                target = candidate
                wind = candidateWind
                return
            }
        }
        // Muy improbable: sin viento y en el centro de la zona siempre hay tiro.
        wind = 0
        let x = (Self.targetZone.lowerBound + Self.targetZone.upperBound) / 2
        target = Target(x: x, y: Self.restingY(x: x, radius: targetRadius, terrain: terrain), radius: targetRadius)
    }

    // MARK: - Física compartida

    enum Outcome {
        case flying
        case impact
        case lost
    }

    static func speed(for power: Double) -> Double {
        minSpeed + (maxSpeed - minSpeed) * power
    }

    static func muzzle(pivotY: Double, radians: Double) -> CGPoint {
        CGPoint(x: cannonX + cos(radians) * barrelLength, y: pivotY - sin(radians) * barrelLength)
    }

    static func advance(_ s: inout Shell, wind: Double) {
        s.vx += wind * fixedStep
        s.vy += gravity * fixedStep
        s.x += s.vx * fixedStep
        s.y += s.vy * fixedStep
    }

    static func outcome(of s: Shell, terrain: [Double], target: Target) -> Outcome {
        if hypot(s.x - target.x, s.y - target.y) <= target.radius + shellRadius {
            return .impact
        }
        if s.x >= 0, s.x <= width, s.y >= top(of: terrain, at: s.x) {
            return .impact
        }
        if s.x < -40 || s.x > width + 40 || s.y > height + 40 {
            return .lost
        }
        return .flying
    }

    static func isHit(x: Double, y: Double, target: Target) -> Bool {
        hypot(x - target.x, y - target.y) <= target.radius + blastRadius * 0.6
    }

    /// Cuántas combinaciones de una rejilla de ángulos y fuerzas aciertan.
    /// Para en cuanto llega a `enough`.
    static func solutionCount(terrain: [Double], cannonY: Double, target: Target, wind: Double, enough: Int) -> Int {
        var found = 0
        var angle = 14.0
        while angle <= 82 {
            let radians = angle * .pi / 180
            var power = 0.08
            while power <= 1.0001 {
                let speed = speed(for: power)
                let muzzle = muzzle(pivotY: cannonY, radians: radians)
                var s = Shell(x: muzzle.x, y: muzzle.y, vx: cos(radians) * speed, vy: -sin(radians) * speed)
                simulation: for _ in 0..<1200 {
                    advance(&s, wind: wind)
                    switch outcome(of: s, terrain: terrain, target: target) {
                    case .flying:
                        continue
                    case .lost:
                        break simulation
                    case .impact:
                        if isHit(x: s.x, y: s.y, target: target) {
                            found += 1
                            if found >= enough { return found }
                        }
                        break simulation
                    }
                }
                power += 0.02
            }
            angle += 3
        }
        return found
    }

    // MARK: - Terreno

    static func makeTerrain(hill: ClosedRange<Double>, using rng: inout SplitMix64) -> [Double] {
        let count = Int(width / sampleStep) + 1
        let phase1 = Double.random(in: 0...(2 * .pi), using: &rng)
        let phase2 = Double.random(in: 0...(2 * .pi), using: &rng)
        let hillX = Double.random(in: 130...185, using: &rng)
        let hillWidth = Double.random(in: 28...42, using: &rng)
        let hillHeight = Double.random(in: hill, using: &rng)
        var terrain = (0..<count).map { i -> Double in
            let x = Double(i) * sampleStep
            var y = 222.0
            y -= 12 * sin(x / 43 + phase1) + 7 * sin(x / 19 + phase2)
            let d = (x - hillX) / hillWidth
            y -= hillHeight * exp(-d * d)
            return min(max(y, 70), 250)
        }
        // Explanada para el cañón, que se funde con el terreno de alrededor.
        let base = min(top(of: terrain, at: cannonX), 215)
        for i in terrain.indices {
            let d = abs(Double(i) * sampleStep - cannonX)
            if d <= 20 {
                terrain[i] = base
            } else if d < 34 {
                let t = (d - 20) / 14
                terrain[i] = base + (terrain[i] - base) * t
            }
        }
        return terrain
    }

    /// La y de la superficie en `x`, interpolada entre muestras.
    static func top(of terrain: [Double], at x: Double) -> Double {
        let position = min(max(x / sampleStep, 0), Double(terrain.count - 1))
        let i = Int(position)
        let j = min(i + 1, terrain.count - 1)
        let t = position - Double(i)
        return terrain[i] + (terrain[j] - terrain[i]) * t
    }

    static func restingY(x: Double, radius: Double, terrain: [Double]) -> Double {
        var highest = Double.infinity
        var sx = x - radius * 0.6
        while sx <= x + radius * 0.6 {
            highest = min(highest, top(of: terrain, at: sx))
            sx += 1
        }
        return highest - radius
    }

    /// Onda triangular: 0 → 1 → 0 → 1… con periodo 2.
    static func triangle(_ t: Double) -> Double {
        let m = arcadeWrap(t, 2)
        return m <= 1 ? m : 2 - m
    }
}
