//
//  SlingshotScene.swift
//  Calarm
//

import Observation
import SpriteKit

/// Lo que la escena del tirachinas cuenta a SwiftUI.
@Observable
final class SlingshotHUD {
    enum Message: Equatable {
        /// Antes del primer tiro: cómo se lanza.
        case aim
        case cleared
        case outOfShots
    }

    let required: Int
    let shotsPerLevel: Int
    var knocked = 0
    var shotsLeft: Int
    var message: Message? = .aim

    init(required: Int, shotsPerLevel: Int) {
        self.required = required
        self.shotsPerLevel = shotsPerLevel
        shotsLeft = shotsPerLevel
    }
}

/// «Tirachinas»: se estira la goma hacia atrás y se suelta para lanzar una
/// bola contra torres de tablones con despertadores encima. Un despertador
/// cuenta como derribado si cae, se desplaza, vuelca o recibe la bola de
/// lleno. Los derribos se acumulan entre torres: si se acaban los tiros sale
/// una torre nueva, y lo mismo al despejar una antes de llegar al total.
///
/// Coordenadas de SpriteKit: 360 × 280 con la y hacia arriba. La física mide
/// la gravedad en m/s² a 150 puntos por metro (comprobado: con −5 m/s² un
/// cuerpo acelera 750 pt/s²) y las velocidades en puntos por segundo.
final class SlingshotScene: SKScene, SKPhysicsContactDelegate {
    struct Config {
        let required: Int
        let shots: Int
        /// Segundos de trayectoria prevista que se dibujan al estirar.
        let preview: Double
        let layouts: [[Piece]]

        init(difficulty: WakeChallenge.Difficulty) {
            switch difficulty {
            case .easy:
                required = 3; shots = 4; preview = 0.55
                layouts = [Layouts.tower, Layouts.twins]
            case .medium:
                required = 4; shots = 3; preview = 0.3
                layouts = [Layouts.tower, Layouts.twoStory, Layouts.twins, Layouts.bunker]
            case .hard:
                required = 6; shots = 3; preview = 0
                layouts = [Layouts.twoStoryPlus, Layouts.twinsPlus, Layouts.bunkerPlus]
            }
        }
    }

    struct Piece {
        enum Kind {
            case block
            case target
        }

        let kind: Kind
        let center: CGPoint
        let size: CGSize

        static func post(_ x: CGFloat, on bottom: CGFloat, height: CGFloat = 46) -> Piece {
            Piece(kind: .block, center: CGPoint(x: x, y: bottom + height / 2), size: CGSize(width: 10, height: height))
        }

        static func plank(_ x: CGFloat, on bottom: CGFloat, width: CGFloat) -> Piece {
            Piece(kind: .block, center: CGPoint(x: x, y: bottom + 5), size: CGSize(width: width, height: 10))
        }

        static func target(_ x: CGFloat, on bottom: CGFloat) -> Piece {
            Piece(kind: .target, center: CGPoint(x: x, y: bottom + targetSize / 2), size: CGSize(width: targetSize, height: targetSize))
        }
    }

    /// Las torres. `g` es el suelo; cada pieza se apoya sobre la anterior.
    enum Layouts {
        static let g = SlingshotScene.groundY

        /// Mesa con un despertador encima y otro en el suelo, detrás.
        static let tower: [Piece] = [
            .post(232, on: g), .post(284, on: g),
            .plank(258, on: g + 46, width: 72),
            .target(258, on: g + 56),
            .target(322, on: g),
        ]

        /// Dos pisos: uno resguardado entre los postes de arriba y otro en lo alto.
        static let twoStory: [Piece] = [
            .post(230, on: g), .post(290, on: g),
            .plank(260, on: g + 46, width: 80),
            .post(238, on: g + 56, height: 36), .post(282, on: g + 56, height: 36),
            .target(260, on: g + 56),
            .plank(260, on: g + 92, width: 64),
            .target(260, on: g + 102),
        ]

        static let twoStoryPlus = twoStory + [.target(330, on: g)]

        /// Dos mesas de distinta altura.
        static let twins: [Piece] = [
            .post(206, on: g, height: 40), .post(242, on: g, height: 40),
            .plank(224, on: g + 40, width: 52),
            .target(224, on: g + 50),
            .post(290, on: g, height: 58), .post(326, on: g, height: 58),
            .plank(308, on: g + 58, width: 52),
            .target(308, on: g + 68),
        ]

        static let twinsPlus = twins + [.target(266, on: g)]

        /// Un despertador bajo techo y otro sobre el techo.
        static let bunker: [Piece] = [
            .post(238, on: g, height: 36), .post(286, on: g, height: 36),
            .target(262, on: g),
            .plank(262, on: g + 36, width: 70),
            .target(262, on: g + 46),
        ]

        static let bunkerPlus = bunker + [.post(206, on: g, height: 30), .target(326, on: g)]
    }

    static let sceneSize = CGSize(width: 360, height: 280)
    static let groundY: CGFloat = 28
    static let pouch = CGPoint(x: 64, y: 98)
    /// Puntas de la horquilla, a ambos lados de la bola en reposo.
    static let backTip = CGPoint(x: 50, y: 106)
    static let frontTip = CGPoint(x: 78, y: 106)
    static let forkJoint = CGPoint(x: 64, y: 70)
    static let maxPull: CGFloat = 64
    static let maxSpeed: CGFloat = 560
    /// Gravedad en m/s²; en puntos es ×150.
    static let gravity: CGFloat = 5.2
    static let ballRadius: CGFloat = 10
    static let targetSize: CGFloat = 26
    /// Tiempo para que las torres se asienten antes de contar derribos.
    static let settleTime: TimeInterval = 0.9

    private enum Category {
        static let ball: UInt32 = 1
        static let block: UInt32 = 2
        static let target: UInt32 = 4
        static let ground: UInt32 = 8
    }

    private final class TargetNode {
        let node: SKSpriteNode
        var rest: CGPoint = .zero
        var popped = false

        init(node: SKSpriteNode) {
            self.node = node
        }
    }

    private enum BallState {
        case empty
        case loaded
        case pulling
        case flying
    }

    let config: Config
    let hud: SlingshotHUD
    private var rng: SplitMix64

    private var built = false
    private var finished = false
    private var lastUpdate: TimeInterval?
    private var levelAge: TimeInterval = 0
    private var armed = false
    private var levelEnding = false
    private var lastLayout: Int?

    private var levelNodes: [SKNode] = []
    private var targets: [TargetNode] = []
    private var pendingHits: Set<ObjectIdentifier> = []

    private var ball: SKShapeNode?
    private var ballState: BallState = .empty
    private var pull: CGVector = .zero
    /// Dónde se apoyó el dedo: la goma se estira lo que el dedo se aleja de ahí.
    private var pullOrigin: CGPoint = .zero
    private var flightTime: TimeInterval = 0
    private var slowTime: TimeInterval = 0
    private var trailClock: TimeInterval = 0

    private let bandBack = SKShapeNode()
    private let bandFront = SKShapeNode()
    private var previewDots: [SKShapeNode] = []
    private var trail: [SKShapeNode] = []
    private var previousTrail: [SKShapeNode] = []
    private lazy var targetTexture = Self.emojiTexture("⏰", side: Self.targetSize + 6)

    init(config: Config, hud: SlingshotHUD, seed: UInt64 = .random(in: .min ... .max)) {
        self.config = config
        self.hud = hud
        rng = SplitMix64(seed: seed)
        super.init(size: Self.sceneSize)
        scaleMode = .aspectFit
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMove(to view: SKView) {
        guard !built else { return }
        built = true
        physicsWorld.gravity = CGVector(dx: 0, dy: -Self.gravity)
        physicsWorld.contactDelegate = self
        buildStage()
        buildLevel()
    }

    // MARK: - Escenario fijo

    private func buildStage() {
        let ground = SKShapeNode(rect: CGRect(x: -40, y: -20, width: size.width + 80, height: Self.groundY + 20))
        ground.fillColor = SKColor(red: 0.47, green: 0.66, blue: 0.33, alpha: 1)
        ground.strokeColor = .clear
        ground.zPosition = 0
        addChild(ground)
        let edge = SKShapeNode(rect: CGRect(x: -40, y: Self.groundY - 3, width: size.width + 80, height: 3))
        edge.fillColor = SKColor(white: 0, alpha: 0.15)
        edge.strokeColor = .clear
        edge.zPosition = 0.1
        addChild(edge)

        // El suelo físico acaba en el borde derecho: lo que se empuja más allá cae.
        let floor = SKNode()
        floor.physicsBody = SKPhysicsBody(edgeFrom: CGPoint(x: -200, y: Self.groundY), to: CGPoint(x: size.width, y: Self.groundY))
        floor.physicsBody?.friction = 0.9
        floor.physicsBody?.categoryBitMask = Category.ground
        addChild(floor)

        // Horquilla del tirachinas: el palo y el brazo de atrás quedan detrás
        // de la bola; el de delante, por encima, para que la bola quede dentro.
        let wood = SKColor(red: 0.45, green: 0.29, blue: 0.16, alpha: 1)
        let backFork = CGMutablePath()
        backFork.move(to: CGPoint(x: Self.forkJoint.x, y: Self.groundY))
        backFork.addLine(to: Self.forkJoint)
        backFork.addLine(to: Self.backTip)
        let frontFork = CGMutablePath()
        frontFork.move(to: Self.forkJoint)
        frontFork.addLine(to: Self.frontTip)
        for (path, z) in [(backFork, CGFloat(1)), (frontFork, CGFloat(4.5))] {
            let node = SKShapeNode(path: path)
            node.strokeColor = wood
            node.lineWidth = 6
            node.lineCap = .round
            node.lineJoin = .round
            node.zPosition = z
            addChild(node)
        }

        let band = SKColor(red: 0.30, green: 0.18, blue: 0.10, alpha: 1)
        for (node, z) in [(bandBack, CGFloat(2)), (bandFront, CGFloat(4))] {
            node.strokeColor = band
            node.lineWidth = 3.5
            node.lineCap = .round
            node.zPosition = z
            addChild(node)
        }
        updateBands(to: nil)

        previewDots = (0..<10).map { _ in
            let dot = SKShapeNode(circleOfRadius: 2.2)
            dot.fillColor = SKColor(white: 1, alpha: 0.85)
            dot.strokeColor = SKColor(white: 0, alpha: 0.25)
            dot.lineWidth = 0.5
            dot.zPosition = 5
            dot.isHidden = true
            addChild(dot)
            return dot
        }
    }

    // MARK: - Niveles

    private func buildLevel() {
        removeAction(forKey: "ending")
        removeAction(forKey: "reload")
        for node in levelNodes { node.removeFromParent() }
        levelNodes.removeAll()
        targets.removeAll()
        pendingHits.removeAll()
        ball?.removeFromParent()
        ball = nil
        ballState = .empty
        levelAge = 0
        armed = false
        levelEnding = false

        var index = Int.random(in: 0..<config.layouts.count, using: &rng)
        if config.layouts.count > 1, index == lastLayout {
            index = (index + 1) % config.layouts.count
        }
        lastLayout = index

        let woodFill = SKColor(red: 0.80, green: 0.58, blue: 0.36, alpha: 1)
        let woodLine = SKColor(red: 0.52, green: 0.34, blue: 0.18, alpha: 1)
        for piece in config.layouts[index] {
            switch piece.kind {
            case .block:
                let block = SKShapeNode(rectOf: piece.size, cornerRadius: 2)
                block.fillColor = woodFill
                block.strokeColor = woodLine
                block.lineWidth = 1
                // Un hueco mínimo para que cada pieza caiga y se asiente sola.
                block.position = CGPoint(x: piece.center.x, y: piece.center.y + 0.5)
                block.zPosition = 3
                let body = SKPhysicsBody(rectangleOf: piece.size)
                body.density = 1
                body.friction = 0.8
                body.restitution = 0.05
                body.linearDamping = 0.1
                body.angularDamping = 0.4
                body.categoryBitMask = Category.block
                block.physicsBody = body
                addChild(block)
                levelNodes.append(block)
            case .target:
                let sprite = SKSpriteNode(texture: targetTexture, size: CGSize(width: Self.targetSize + 6, height: Self.targetSize + 6))
                sprite.position = CGPoint(x: piece.center.x, y: piece.center.y + 0.5)
                sprite.zPosition = 3
                let body = SKPhysicsBody(rectangleOf: CGSize(width: Self.targetSize - 4, height: Self.targetSize - 2))
                body.density = 0.5
                body.friction = 0.8
                body.restitution = 0.05
                body.linearDamping = 0.1
                body.angularDamping = 0.4
                body.categoryBitMask = Category.target
                body.contactTestBitMask = Category.ball
                sprite.physicsBody = body
                addChild(sprite)
                levelNodes.append(sprite)
                targets.append(TargetNode(node: sprite))
            }
        }

        hud.shotsLeft = config.shots
        loadBall()
    }

    private func loadBall() {
        guard !finished, ballState == .empty, hud.shotsLeft > 0 else { return }
        let node = SKShapeNode(circleOfRadius: Self.ballRadius)
        node.fillColor = SKColor(red: 0.93, green: 0.42, blue: 0.24, alpha: 1)
        node.strokeColor = SKColor(red: 0.62, green: 0.22, blue: 0.10, alpha: 1)
        node.lineWidth = 1.5
        node.position = Self.pouch
        node.zPosition = 3
        let shine = SKShapeNode(circleOfRadius: 3)
        shine.fillColor = SKColor(white: 1, alpha: 0.55)
        shine.strokeColor = .clear
        shine.position = CGPoint(x: -3.5, y: 3.5)
        node.addChild(shine)
        let body = SKPhysicsBody(circleOfRadius: Self.ballRadius)
        body.isDynamic = false
        body.density = 4
        body.friction = 0.6
        body.restitution = 0.3
        // Sin amortiguación lineal: la trayectoria prevista es exacta.
        body.linearDamping = 0
        body.angularDamping = 0.5
        body.usesPreciseCollisionDetection = true
        body.categoryBitMask = Category.ball
        body.contactTestBitMask = Category.target
        node.physicsBody = body
        node.setScale(0.2)
        node.run(.scale(to: 1, duration: 0.15))
        addChild(node)
        ball = node
        ballState = .loaded
        pull = .zero
        updateBands(to: Self.pouch)
    }

    // MARK: - Lanzamiento (también lo usan las pruebas)

    /// Empieza a estirar si hay bola cargada y las torres ya se asentaron.
    @discardableResult
    func beginPull() -> Bool {
        guard ballState == .loaded, armed, !finished, !levelEnding else { return false }
        ballState = .pulling
        return true
    }

    /// Estira la goma: `offset` es cuánto se aleja la bola de su sitio.
    func movePull(by offset: CGVector) {
        guard ballState == .pulling, let ball else { return }
        let length = hypot(offset.dx, offset.dy)
        let factor = length > Self.maxPull ? Self.maxPull / length : 1
        pull = CGVector(dx: offset.dx * factor, dy: offset.dy * factor)
        ball.position = CGPoint(x: Self.pouch.x + pull.dx, y: Self.pouch.y + pull.dy)
        updateBands(to: ball.position)
        updatePreview()
    }

    /// Suelta: con poca tensión la bola vuelve a su sitio sin gastar el tiro.
    func endPull() {
        guard ballState == .pulling, let ball, let body = ball.physicsBody else { return }
        hidePreview()
        if hypot(pull.dx, pull.dy) < 10 {
            ballState = .loaded
            ball.run(.move(to: Self.pouch, duration: 0.12))
            updateBands(to: Self.pouch)
            return
        }
        body.isDynamic = true
        body.velocity = Self.launchVelocity(for: pull)
        ballState = .flying
        flightTime = 0
        slowTime = 0
        trailClock = 0
        hud.shotsLeft -= 1
        hud.message = nil
        updateBands(to: nil)
        for dot in previousTrail { dot.removeFromParent() }
        previousTrail = trail
        for dot in previousTrail { dot.alpha = 0.35 }
        trail = []
    }

    static func launchVelocity(for pull: CGVector) -> CGVector {
        CGVector(dx: -pull.dx / maxPull * maxSpeed, dy: -pull.dy / maxPull * maxSpeed)
    }

    #if os(iOS)
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        // Basta con apoyar el dedo en la mitad izquierda, no hace falta atinar a la bola.
        let location = touch.location(in: self)
        if location.x < size.width * 0.5, beginPull() {
            pullOrigin = location
            movePull(by: .zero)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard ballState == .pulling, let touch = touches.first else { return }
        let location = touch.location(in: self)
        movePull(by: CGVector(dx: location.x - pullOrigin.x, dy: location.y - pullOrigin.y))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endPull()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endPull()
    }
    #endif

    // MARK: - Bucle

    override func update(_ currentTime: TimeInterval) {
        let dt = min(currentTime - (lastUpdate ?? currentTime), 1.0 / 30)
        lastUpdate = currentTime
        levelAge += dt
        if !armed, levelAge >= Self.settleTime {
            armed = true
            for target in targets {
                target.rest = target.node.position
            }
        }
        guard ballState == .flying, let ball, let body = ball.physicsBody else { return }
        flightTime += dt
        trailClock += dt
        if trailClock >= 0.04 {
            trailClock = 0
            addTrailDot(at: ball.position)
        }
        let speed = hypot(body.velocity.dx, body.velocity.dy)
        slowTime = speed < 14 ? slowTime + dt : 0
        let p = ball.position
        let gone = p.x < -30 || p.x > size.width + 30 || p.y < -30
        if gone || slowTime > 0.5 || flightTime > 7 {
            endShot()
        }
    }

    override func didSimulatePhysics() {
        guard armed, !finished else { return }
        for target in targets where !target.popped {
            let p = target.node.position
            let fell = target.rest.y - p.y > 14
            let shifted = abs(p.x - target.rest.x) > 22
            let rotation = atan2(sin(target.node.zRotation), cos(target.node.zRotation))
            let tipped = abs(rotation) > 0.7
            let out = p.y < -10 || p.x > size.width + 20 || p.x < -20
            let struck = pendingHits.contains(ObjectIdentifier(target.node))
            if fell || shifted || tipped || out || struck {
                pop(target)
                if finished { return }
            }
        }
        pendingHits.removeAll()
    }

    func didBegin(_ contact: SKPhysicsContact) {
        let pair = [contact.bodyA, contact.bodyB]
        guard let ballBody = pair.first(where: { $0.categoryBitMask == Category.ball }),
              let targetBody = pair.first(where: { $0.categoryBitMask == Category.target }),
              let node = targetBody.node else { return }
        // Un roce lento no cuenta; un golpe de lleno sí, aunque no lo mueva.
        if hypot(ballBody.velocity.dx, ballBody.velocity.dy) > 140 {
            pendingHits.insert(ObjectIdentifier(node))
        }
    }

    // MARK: - Derribos y tiros

    private func pop(_ target: TargetNode) {
        target.popped = true
        let node = target.node
        node.physicsBody = nil
        node.run(.sequence([
            .group([.scale(to: 1.6, duration: 0.22), .fadeOut(withDuration: 0.22)]),
            .removeFromParent(),
        ]))
        hud.knocked += 1
        if hud.knocked >= hud.required {
            finish()
            return
        }
        if targets.allSatisfy(\.popped) {
            levelEnding = true
            hud.message = .cleared
            removeAction(forKey: "ending")
            run(.sequence([.wait(forDuration: 1.0), .run { [weak self] in self?.nextLevel() }]), withKey: "level")
        }
    }

    private func endShot() {
        guard let ball else { return }
        self.ball = nil
        ballState = .empty
        ball.physicsBody = nil
        ball.run(.sequence([.fadeOut(withDuration: 0.2), .removeFromParent()]))
        guard !finished, !levelEnding else { return }
        if hud.shotsLeft > 0 {
            run(.sequence([.wait(forDuration: 0.25), .run { [weak self] in self?.loadBall() }]), withKey: "reload")
        } else {
            // Deja que lo que se tambalea acabe de caer antes de rendirse.
            levelEnding = true
            run(.sequence([
                .wait(forDuration: 1.2),
                .run { [weak self] in self?.outOfShots() },
            ]), withKey: "ending")
        }
    }

    private func outOfShots() {
        guard !finished else { return }
        if targets.allSatisfy(\.popped) {
            // Lo último cayó durante la espera: `pop` ya preparó la torre siguiente.
            return
        }
        hud.message = .outOfShots
        run(.sequence([.wait(forDuration: 1.2), .run { [weak self] in self?.nextLevel() }]), withKey: "level")
    }

    private func nextLevel() {
        guard !finished else { return }
        hud.message = nil
        for dot in trail + previousTrail { dot.removeFromParent() }
        trail = []
        previousTrail = []
        buildLevel()
    }

    private func finish() {
        finished = true
        removeAllActions()
        hidePreview()
    }

    // MARK: - Dibujo auxiliar

    /// Con la goma estirada, las dos tiras abrazan la bola por detrás (el
    /// lado contrario al lanzamiento). En reposo, una sola tira recta entre
    /// las puntas, por detrás de la bola.
    private func updateBands(to point: CGPoint?) {
        let back = CGMutablePath()
        let front = CGMutablePath()
        let length = hypot(pull.dx, pull.dy)
        if let point, ballState == .pulling, length > 1 {
            let grip = CGPoint(
                x: point.x + pull.dx / length * Self.ballRadius,
                y: point.y + pull.dy / length * Self.ballRadius
            )
            back.move(to: Self.backTip)
            back.addLine(to: grip)
            front.move(to: Self.frontTip)
            front.addLine(to: grip)
        } else {
            back.move(to: Self.backTip)
            back.addLine(to: Self.frontTip)
        }
        bandBack.path = back
        bandFront.path = front
    }

    private func updatePreview() {
        guard config.preview > 0, hypot(pull.dx, pull.dy) >= 10, let ball else {
            hidePreview()
            return
        }
        let v = Self.launchVelocity(for: pull)
        let g = Self.gravity * 150
        for (i, dot) in previewDots.enumerated() {
            let t = config.preview * Double(i + 1) / Double(previewDots.count)
            dot.position = CGPoint(x: ball.position.x + v.dx * t, y: ball.position.y + v.dy * t - 0.5 * g * t * t)
            dot.isHidden = false
            dot.alpha = 1 - CGFloat(i) / CGFloat(previewDots.count) * 0.7
        }
    }

    private func hidePreview() {
        for dot in previewDots { dot.isHidden = true }
    }

    private func addTrailDot(at point: CGPoint) {
        guard trail.count < 120 else { return }
        let dot = SKShapeNode(circleOfRadius: 1.6)
        dot.fillColor = SKColor(white: 0.2, alpha: 0.5)
        dot.strokeColor = .clear
        dot.position = point
        dot.zPosition = 2.5
        addChild(dot)
        trail.append(dot)
    }

    private static func emojiTexture(_ emoji: String, side: CGFloat) -> SKTexture {
        let text = emoji as NSString
        #if canImport(UIKit)
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: side * 0.8)]
        let bounds = text.size(withAttributes: attributes)
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            text.draw(at: CGPoint(x: (side - bounds.width) / 2, y: (side - bounds.height) / 2), withAttributes: attributes)
        }
        return SKTexture(image: image)
        #else
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: side * 0.8)]
        let bounds = text.size(withAttributes: attributes)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            text.draw(at: CGPoint(x: (side - bounds.width) / 2, y: (side - bounds.height) / 2), withAttributes: attributes)
            return true
        }
        return SKTexture(image: image)
        #endif
    }

    // MARK: - Para las pruebas

    /// Estado de los despertadores del nivel: posición y si ya cayeron.
    var debugTargets: [(position: CGPoint, popped: Bool)] {
        targets.map { ($0.node.position, $0.popped) }
    }

    var isArmed: Bool { armed }
    var isBallLoaded: Bool { ballState == .loaded }
}
