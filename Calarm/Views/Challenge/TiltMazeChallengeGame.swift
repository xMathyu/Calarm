//
//  TiltMazeChallengeGame.swift
//  Calarm
//

import CoreMotion
import SwiftUI

/// Inclinar el teléfono para llevar una bola hasta la bandera de salida. La
/// gravedad que mide el sensor de movimiento empuja la bola por un laberinto de
/// casillas y las paredes la frenan; con rozamiento, para que se pare sola al
/// dejar el teléfono plano. Sin sensores (el simulador) la bola se arrastra con
/// el dedo, también bloqueada por las paredes.
struct TiltMazeChallengeGame: View {
    let difficulty: WakeChallenge.Difficulty
    let onSolved: () -> Void

    @State private var maze: TiltMazeGrid
    @State private var ball: TiltMazeBall
    @State private var sensor = TiltMotionSensor()
    /// Lado del lienzo en puntos, para traducir el dedo a casillas.
    @State private var side: CGFloat = 0
    @State private var done = false
    @State private var lastBump: TimeInterval = 0

    /// Aceleración en casillas/s² con el teléfono de canto (gravedad entera).
    private static let gravityGain = 15.0
    /// Rozamiento: la velocidad decae a exp(-friction · t).
    private static let friction = 2.2
    /// Tope en casillas/s: con él un fotograma nunca atraviesa una pared.
    private static let maxSpeed = 6.0
    /// Cuánto rebota la bola al chocar (0 = se queda pegada).
    private static let restitution = 0.2
    /// Por debajo de esta inclinación el teléfono cuenta como plano.
    private static let deadZone = 0.03
    /// Paso máximo por iteración al arrastrar con el dedo, en casillas.
    private static let dragStep = 0.2

    init(difficulty: WakeChallenge.Difficulty, onSolved: @escaping () -> Void) {
        self.difficulty = difficulty
        self.onSolved = onSolved
        let maze = TiltMazeGrid.random(for: difficulty)
        _maze = State(initialValue: maze)
        _ball = State(initialValue: TiltMazeBall(at: maze.start))
    }

    var body: some View {
        VStack(spacing: DS.Spacing.md) {
            Text(hint)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(minHeight: 24)

            arena
        }
        .task { await run() }
    }

    private var hint: String {
        sensor.isAvailable
            ? appLocalized("Inclina el teléfono para llevar la bola hasta la bandera.")
            : appLocalized("Sin sensores: arrastra la bola.")
    }

    // MARK: - Lienzo

    private var arena: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            draw(in: context, size: size)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 360)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            side = width
        }
        .gesture(dragGesture, including: sensor.isAvailable ? .none : .all)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in dragBall(to: value.location) }
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        let n = maze.size
        let cell = size.width / CGFloat(n)

        func rect(row: Int, col: Int) -> CGRect {
            CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
        }

        // Paredes en un solo trazado: los bloques contiguos no dejan juntas.
        var walls = Path()
        for row in 0..<n {
            for col in 0..<n where maze.isWall(row: row, col: col) {
                walls.addRect(rect(row: row, col: col))
            }
        }
        context.fill(walls, with: .color(Color(.systemGray3)))

        // Salida: casilla verde con bandera.
        let exitRect = rect(row: maze.exit.row, col: maze.exit.col)
        let exitInset = exitRect.insetBy(dx: cell * 0.08, dy: cell * 0.08)
        context.fill(
            Path(roundedRect: exitInset, cornerRadius: cell * 0.2),
            with: .linearGradient(
                Gradient(colors: [.green, .mint]),
                startPoint: exitInset.origin,
                endPoint: CGPoint(x: exitInset.maxX, y: exitInset.maxY)
            )
        )
        let flag = context.resolve(
            Text(Image(systemName: "flag.checkered"))
                .font(.system(size: cell * 0.5, weight: .bold))
                .foregroundStyle(.white)
        )
        context.draw(flag, at: CGPoint(x: exitRect.midX, y: exitRect.midY), anchor: .center)

        // Bola con sombra suave y un brillo descentrado que le da volumen.
        let r = cell * 0.34
        let center = CGPoint(x: CGFloat(ball.x) * cell, y: CGFloat(ball.y) * cell)
        let ballRect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.35), radius: r * 0.5, x: 0, y: r * 0.3))
            layer.fill(Path(ellipseIn: ballRect), with: .color(Color.accentColor))
        }
        context.fill(
            Path(ellipseIn: ballRect),
            with: .radialGradient(
                Gradient(colors: [.white.opacity(0.55), .clear]),
                center: CGPoint(x: center.x - r * 0.35, y: center.y - r * 0.4),
                startRadius: 0,
                endRadius: r * 1.1
            )
        )
    }

    // MARK: - Simulación

    /// Bucle a ~60 Hz mientras la vista está en pantalla y el reto sin resolver.
    /// Solo hace falta con sensores: sin ellos la bola se mueve con el dedo.
    @MainActor
    private func run() async {
        sensor.start()
        defer { sensor.stop() }
        guard sensor.isAvailable else { return }
        var last = ContinuousClock.now
        while !Task.isCancelled, !done {
            try? await Task.sleep(for: .milliseconds(16), tolerance: .milliseconds(2))
            if Task.isCancelled || done { return }
            let now = ContinuousClock.now
            let elapsed = now - last
            last = now
            // Si la app estuvo en segundo plano, no se integra el tiempo perdido.
            let dt = min(Self.seconds(elapsed), 1.0 / 30.0)
            step(dt: dt)
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private func step(dt: Double) {
        var b = ball
        // En vertical, `gravity.y` es negativa: la bola cae hacia abajo en pantalla.
        let gx = abs(sensor.gravityX) < Self.deadZone ? 0 : sensor.gravityX
        let gy = abs(sensor.gravityY) < Self.deadZone ? 0 : sensor.gravityY
        b.vx += gx * Self.gravityGain * dt
        b.vy += -gy * Self.gravityGain * dt

        let damping = exp(-Self.friction * dt)
        b.vx *= damping
        b.vy *= damping

        let speed = hypot(b.vx, b.vy)
        if speed > Self.maxSpeed {
            b.vx *= Self.maxSpeed / speed
            b.vy *= Self.maxSpeed / speed
        }

        if b.moveX(by: b.vx * dt, in: maze) {
            bump(speed: abs(b.vx))
            b.vx = -b.vx * Self.restitution
        }
        if b.moveY(by: b.vy * dt, in: maze) {
            bump(speed: abs(b.vy))
            b.vy = -b.vy * Self.restitution
        }

        if b != ball { ball = b }
        if maze.isExit(b) { finish() }
    }

    /// Un toque al golpear una pared con ganas, como mucho uno cada 150 ms.
    private func bump(speed: Double) {
        guard speed > 2.5 else { return }
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastBump > 0.15 else { return }
        lastBump = now
        Haptics.light()
    }

    /// Sin sensores: la bola sigue al dedo en pasitos cortos, resolviendo las
    /// paredes en cada uno, así no salta a través de ellas.
    private func dragBall(to location: CGPoint) {
        guard !done, side > 0 else { return }
        let cell = Double(side) / Double(maze.size)
        let target = (x: Double(location.x) / cell, y: Double(location.y) / cell)
        var b = ball
        b.vx = 0
        b.vy = 0
        for _ in 0..<64 {
            let dx = target.x - b.x
            let dy = target.y - b.y
            if abs(dx) < 0.01, abs(dy) < 0.01 { break }
            let sx = max(-Self.dragStep, min(Self.dragStep, dx))
            let sy = max(-Self.dragStep, min(Self.dragStep, dy))
            let before = b
            _ = b.moveX(by: sx, in: maze)
            _ = b.moveY(by: sy, in: maze)
            // Bloqueada por una pared en ambos ejes: hasta aquí llega.
            if b == before { break }
        }
        if b != ball { ball = b }
        if maze.isExit(b) { finish() }
    }

    private func finish() {
        guard !done else { return }
        done = true
        onSolved()
    }
}

// MARK: - Modelo

/// La bola, en coordenadas de casilla (el centro de la casilla (0,0) es (0,5, 0,5)).
private struct TiltMazeBall: Equatable {
    var x: Double
    var y: Double
    var vx = 0.0
    var vy = 0.0

    /// Radio de colisión en casillas: menor que media casilla para que la bola
    /// quepa por los pasillos y pueda doblar las esquinas.
    static let radius = 0.3
    /// Holgura con la que se deja la bola al chocar: justo fuera de la pared,
    /// nunca sobre el borde exacto de la casilla.
    private static let epsilon = 0.001

    init(at cell: (row: Int, col: Int)) {
        x = Double(cell.col) + 0.5
        y = Double(cell.row) + 0.5
    }

    /// Desplaza en X y, si la caja de la bola entra en una pared, la deja pegada
    /// a ella. Devuelve si chocó. Como el paso es menor que una casilla, solo
    /// puede haber entrado en la columna siguiente en el sentido del movimiento,
    /// y se comprueba en todas las filas que la caja cubre (así tampoco se cuela
    /// por una esquina).
    mutating func moveX(by dx: Double, in maze: TiltMazeGrid) -> Bool {
        guard dx != 0 else { return false }
        x += dx
        let r = Self.radius
        let rows = Int(floor(y - r))...Int(floor(y + r))
        if dx > 0 {
            let col = Int(floor(x + r))
            if rows.contains(where: { maze.isWall(row: $0, col: col) }) {
                x = Double(col) - r - Self.epsilon
                return true
            }
        } else {
            let col = Int(floor(x - r))
            if rows.contains(where: { maze.isWall(row: $0, col: col) }) {
                x = Double(col + 1) + r + Self.epsilon
                return true
            }
        }
        return false
    }

    mutating func moveY(by dy: Double, in maze: TiltMazeGrid) -> Bool {
        guard dy != 0 else { return false }
        y += dy
        let r = Self.radius
        let cols = Int(floor(x - r))...Int(floor(x + r))
        if dy > 0 {
            let row = Int(floor(y + r))
            if cols.contains(where: { maze.isWall(row: row, col: $0) }) {
                y = Double(row) - r - Self.epsilon
                return true
            }
        } else {
            let row = Int(floor(y - r))
            if cols.contains(where: { maze.isWall(row: row, col: $0) }) {
                y = Double(row + 1) + r + Self.epsilon
                return true
            }
        }
        return false
    }
}

/// Un laberinto cuadrado de casillas: `#` pared, `.` pasillo, `S` salida de la
/// bola y `E` meta. Fuera del tablero todo es pared.
private struct TiltMazeGrid {
    let size: Int
    let walls: [[Bool]]
    let start: (row: Int, col: Int)
    let exit: (row: Int, col: Int)

    init(_ lines: [String]) {
        var walls: [[Bool]] = []
        var start = (row: 0, col: 0)
        var exit = (row: 0, col: 0)
        for (row, line) in lines.enumerated() {
            var cells: [Bool] = []
            for (col, character) in line.enumerated() {
                cells.append(character == "#")
                if character == "S" { start = (row, col) }
                if character == "E" { exit = (row, col) }
            }
            walls.append(cells)
        }
        self.size = lines.count
        self.walls = walls
        self.start = start
        self.exit = exit
    }

    func isWall(row: Int, col: Int) -> Bool {
        guard walls.indices.contains(row), walls[row].indices.contains(col) else { return true }
        return walls[row][col]
    }

    func isExit(_ ball: TiltMazeBall) -> Bool {
        Int(floor(ball.x)) == exit.col && Int(floor(ball.y)) == exit.row
    }

    static func random(for difficulty: WakeChallenge.Difficulty) -> TiltMazeGrid {
        let options: [[String]]
        switch difficulty {
        case .easy: options = easy
        case .medium: options = medium
        case .hard: options = hard
        }
        return TiltMazeGrid(options.randomElement() ?? easy[0])
    }

    // Todos comprobados: la meta siempre se alcanza desde la salida.

    private static let easy: [[String]] = [
        [
            "#######",
            "#S..#.#",
            "#.#.#.#",
            "#.#...#",
            "#.###.#",
            "#....E#",
            "#######",
        ],
        [
            "#######",
            "#...#E#",
            "#.#.#.#",
            "#.#...#",
            "#.#####",
            "#S....#",
            "#######",
        ],
        [
            "#######",
            "#E#...#",
            "#.#.#.#",
            "#...#.#",
            "###.#.#",
            "#S....#",
            "#######",
        ],
    ]

    private static let medium: [[String]] = [
        [
            "#########",
            "#S..#...#",
            "#.#.#.#.#",
            "#.#...#.#",
            "#.#####.#",
            "#...#...#",
            "###.#.###",
            "#...#..E#",
            "#########",
        ],
        [
            "#########",
            "#...#..E#",
            "#.#.#.#.#",
            "#.#...#.#",
            "#.###.#.#",
            "#...#.#.#",
            "#.#.#...#",
            "#S#.....#",
            "#########",
        ],
        [
            "#########",
            "#E..#...#",
            "###.#.#.#",
            "#...#.#.#",
            "#.###.#.#",
            "#.....#.#",
            "#.###.#.#",
            "#S..#...#",
            "#########",
        ],
    ]

    private static let hard: [[String]] = [
        [
            "###########",
            "#S..#.....#",
            "#.#.#.###.#",
            "#.#...#...#",
            "#.#####.#.#",
            "#...#...#.#",
            "###.#.###.#",
            "#...#.#...#",
            "#.###.#.###",
            "#.....#..E#",
            "###########",
        ],
        [
            "###########",
            "#...#.....#",
            "#.#.#.###.#",
            "#.#...#.#.#",
            "#.###.#.#.#",
            "#...#...#.#",
            "#.#.#####.#",
            "#.#.....#.#",
            "#.#####.#.#",
            "#S....#..E#",
            "###########",
        ],
        [
            "###########",
            "#E#.......#",
            "#.#.#####.#",
            "#...#...#.#",
            "#.###.#.#.#",
            "#.#...#...#",
            "#.#.#####.#",
            "#.#.#.....#",
            "#.#.#.###.#",
            "#...#...#S#",
            "###########",
        ],
    ]
}

// MARK: - Sensor

/// Entrega la gravedad del sensor de movimiento a 60 Hz. Las actualizaciones
/// llegan en la cola principal, así que se escriben directamente.
@MainActor
private final class TiltMotionSensor {
    private let manager = CMMotionManager()
    private(set) var gravityX = 0.0
    private(set) var gravityY = 0.0

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            let gx = motion.gravity.x
            let gy = motion.gravity.y
            MainActor.assumeIsolated {
                self?.gravityX = gx
                self?.gravityY = gy
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}
