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
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case math
        case memory
        case qr

        var id: String { rawValue }

        var localizedTitle: String {
            switch self {
            case .math: appLocalized("Cálculo")
            case .memory: appLocalized("Memoria")
            case .qr: appLocalized("Código QR")
            }
        }

        var localizedDescription: String {
            switch self {
            case .math: appLocalized("Resuelve operaciones con el teclado numérico.")
            case .memory: appLocalized("Repite la secuencia de casillas que se ilumina.")
            case .qr: appLocalized("Escanea un código QR o de barras que registres, por ejemplo el de la pasta de dientes.")
            }
        }

        var systemImage: String {
            switch self {
            case .math: "plus.forwardslash.minus"
            case .memory: "square.grid.3x3.fill"
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
