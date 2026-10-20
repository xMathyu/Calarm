//
//  WakeChallenge.swift
//  Calarm
//

import Foundation

/// El reto que hay que resolver EN LA APP para apagar una alarma.
///
/// iOS dibuja su propio control «Desliza para detener» y la app no puede
/// quitarlo, así que el reto no impide detener la alarma: hace que detenerla sin
/// resolverlo no sirva de nada. Mientras el reto siga pendiente, la alarma
/// vuelve a sonar: al minuto de detenerla y, por si el sistema no avisa de esa
/// detención, con refuerzos programados de antemano a los 2, 5 y 10 minutos
/// (ver `ReminderScheduler.syncBackups`).
///
/// Se persiste como JSON en `Reminder.challengeData` y viaja en el sobre de
/// compartir, así que todo campo que se añada después lleva valor por defecto
/// al decodificar.
struct WakeChallenge: Codable, Hashable, Sendable {
    /// Los retos se agrupan en el selector por lo que piden: pensar, moverse o
    /// levantarse de la cama.
    enum Group: CaseIterable, Identifiable, Sendable {
        case mind
        case body
        case getUp

        var id: Self { self }

        var localizedTitle: String {
            switch self {
            case .mind: appLocalized("Mente")
            case .body: appLocalized("Cuerpo")
            case .getUp: appLocalized("Levantarte")
            }
        }
    }

    /// El orden de los casos es el orden en que se listan dentro de cada grupo.
    /// El `rawValue` se persiste y viaja al compartir: no renombrar.
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        // Mente
        case math
        case memory
        case order
        case pairs
        case colors
        case odd
        case typing
        // Cuerpo
        case shake
        case steps
        case tilt
        case reflex
        // Levantarte
        case qr

        var id: String { rawValue }

        var group: Group {
            switch self {
            case .math, .memory, .order, .pairs, .colors, .odd, .typing: .mind
            case .shake, .steps, .tilt, .reflex: .body
            case .qr: .getUp
            }
        }

        static func kinds(in group: Group) -> [Kind] {
            allCases.filter { $0.group == group }
        }

        var localizedTitle: String {
            switch self {
            case .math: appLocalized("Cálculo")
            case .memory: appLocalized("Memoria")
            case .order: appLocalized("Ordenar números")
            case .pairs: appLocalized("Parejas")
            case .colors: appLocalized("Colores")
            case .odd: appLocalized("El distinto")
            case .typing: appLocalized("Escribir")
            case .shake: appLocalized("Sacudir")
            case .steps: appLocalized("Caminar")
            case .tilt: appLocalized("Laberinto")
            case .reflex: appLocalized("Atrapa")
            case .qr: appLocalized("Código QR")
            }
        }

        var localizedDescription: String {
            switch self {
            case .math: appLocalized("Resuelve operaciones con el teclado numérico.")
            case .memory: appLocalized("Repite la secuencia de casillas que se ilumina.")
            case .order: appLocalized("Toca los números en orden, del 1 al último, en una cuadrícula revuelta.")
            case .pairs: appLocalized("Da la vuelta a las cartas y encuentra todas las parejas de emojis.")
            case .colors: appLocalized("Toca el color de la tinta, no la palabra que lees.")
            case .odd: appLocalized("Encuentra el emoji que no es como los demás.")
            case .typing: appLocalized("Copia una frase letra por letra, sin autocorrector.")
            case .shake: appLocalized("Sacude el teléfono con ganas hasta llenar la barra.")
            case .steps: appLocalized("Da unos pasos con el teléfono en la mano: cuenta los pasos de verdad.")
            case .tilt: appLocalized("Inclina el teléfono para llevar la bola hasta la salida.")
            case .reflex: appLocalized("Toca los objetivos que aparecen antes de que desaparezcan.")
            case .qr: appLocalized("Escanea un código QR o de barras que registres, por ejemplo el de la pasta de dientes.")
            }
        }

        var systemImage: String {
            switch self {
            case .math: "plus.forwardslash.minus"
            case .memory: "square.grid.3x3.fill"
            case .order: "number.square"
            case .pairs: "rectangle.on.rectangle.angled"
            case .colors: "paintpalette.fill"
            case .odd: "eye.fill"
            case .typing: "keyboard"
            case .shake: "iphone.radiowaves.left.and.right"
            case .steps: "figure.walk"
            case .tilt: "circle.dotted.and.circle"
            case .reflex: "scope"
            case .qr: "qrcode.viewfinder"
            }
        }
    }

    enum Difficulty: Int, Codable, CaseIterable, Identifiable, Sendable {
        case easy = 1
        case medium = 2
        case hard = 3

        var id: Int { rawValue }

        var localizedTitle: String {
            switch self {
            case .easy: appLocalized("Fácil")
            case .medium: appLocalized("Media")
            case .hard: appLocalized("Difícil")
            }
        }
    }

    var kind: Kind
    var difficulty: Difficulty
    /// Si la pantalla del reto ofrece «Posponer». Con reto, el botón secundario
    /// de la alerta del sistema pasa a ser «Resolver reto», así que posponer
    /// solo existe ahí dentro.
    var allowsSnooze: Bool
    /// Para `.qr`: el contenido del código que hay que escanear.
    var code: String?

    init(kind: Kind, difficulty: Difficulty = .medium, allowsSnooze: Bool = true, code: String? = nil) {
        self.kind = kind
        self.difficulty = difficulty
        self.allowsSnooze = allowsSnooze
        self.code = code
    }

    private enum CodingKeys: String, CodingKey {
        case kind, difficulty, allowsSnooze, code
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        difficulty = try container.decodeIfPresent(Difficulty.self, forKey: .difficulty) ?? .medium
        allowsSnooze = try container.decodeIfPresent(Bool.self, forKey: .allowsSnooze) ?? true
        code = try container.decodeIfPresent(String.self, forKey: .code)
    }

    /// Un reto QR sin código registrado no se puede resolver: cuenta como «sin
    /// reto» hasta que se registre uno.
    var isReady: Bool {
        kind != .qr || !(code ?? "").isEmpty
    }

    /// «Cálculo · Media», para la fila del editor.
    var localizedSummary: String {
        "\(kind.localizedTitle) · \(difficulty.localizedTitle)"
    }

    /// Huella estable para la comparación de contenido de una alarma programada
    /// (`AlarmScheduler.contentHash`): cambiar el reto reprograma la alarma.
    var fingerprint: String {
        "\(kind.rawValue):\(difficulty.rawValue):\(allowsSnooze ? 1 : 0):\(code ?? "")"
    }

    // MARK: - Insistencia

    /// A cuánto de la hora de la alarma suenan los refuerzos si nadie resolvió
    /// el reto. Pocos y espaciados: muchas alarmas seguidas hacen que AlarmKit
    /// las entregue tarde o se las salte.
    static let backupOffsets: [TimeInterval] = [120, 300, 600]
    /// Cuánto sigue «viva» una ocurrencia a efectos de refuerzos.
    static let backupWindow: TimeInterval = 660
    /// Cuánto tarda en volver a sonar tras un «Detener» sin resolver.
    static let reRingDelay: TimeInterval = 60
    /// Tope de insistencia desde el primer «Detener» sin resolver: pasado este
    /// tiempo se deja de reprogramar, por si la persona no puede llegar a la app.
    static let maxInsistence: TimeInterval = 30 * 60

    // MARK: - JSON

    static func decode(_ data: Data) -> WakeChallenge? {
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(WakeChallenge.self, from: data)
    }

    func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }
}
