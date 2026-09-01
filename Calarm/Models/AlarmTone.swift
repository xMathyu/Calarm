//
//  AlarmTone.swift
//  Calarm
//

import ActivityKit
import Foundation

/// El tono con el que suena una alarma.
///
/// AlarmKit solo reproduce audio que viva en el bundle de la app o en
/// `Library/Sounds` de su contenedor (`AlertConfiguration.AlertSound.named`): los
/// tonos del sistema no están expuestos a apps de terceros. De ahí los dos tipos
/// de caso: los tonos que trae Calarm (archivos en `Calarm/Sounds/`, generados
/// por `Tools/generate_tones.py`) y los que importa la persona
/// (`ImportedTonesStore`, que escribe en `Library/Sounds`).
///
/// Dos detalles de iOS 26 explican el diseño de los archivos: duran menos de 30 s
/// (el límite de AlarmKit) y traen el patrón ya repetido dentro, porque el
/// sistema reproduce el sonido personalizado UNA vez en lugar de repetirlo como
/// hace con su propio tono.
///
/// `rawValue` es lo que se persiste (en `Reminder.toneRaw` y en los ajustes), así
/// que agregar o reordenar tonos no reinterpreta alarmas ya guardadas.
enum AlarmTone: Hashable, Sendable, Identifiable {
    /// El tono de alarma propio de iOS — el único que el sistema repite
    /// indefinidamente hasta que la persona detiene la alarma.
    case system
    case chime
    case marimba
    case radar
    case arpeggio
    case pulse
    case harp
    /// Audio importado por la persona. El valor es el id del archivo dentro de
    /// `Library/Sounds` (ver `ImportedTonesStore`).
    case imported(String)

    /// El que se usa cuando nadie eligió nada.
    static let `default`: AlarmTone = .system

    /// Los tonos que trae la app, en el orden en que se listan.
    static let builtins: [AlarmTone] = [.system, .chime, .marimba, .radar, .arpeggio, .pulse, .harp]

    var id: String { rawValue }

    /// Nombre del archivo de audio; `nil` para el tono del sistema.
    var fileName: String? {
        switch self {
        case .system: nil
        case .chime: "tone-chime.caf"
        case .marimba: "tone-marimba.caf"
        case .radar: "tone-radar.caf"
        case .arpeggio: "tone-arpeggio.caf"
        case .pulse: "tone-pulse.caf"
        case .harp: "tone-harp.caf"
        case .imported(let id): "\(id).caf"
        }
    }

    var localizedTitle: String {
        switch self {
        case .system: appLocalized("Tono del sistema")
        case .chime: appLocalized("Campana")
        case .marimba: appLocalized("Marimba")
        case .radar: appLocalized("Radar")
        case .arpeggio: appLocalized("Arpegio")
        case .pulse: appLocalized("Pulso")
        case .harp: appLocalized("Arpa")
        // El nombre lo puso la persona al importar; si el archivo ya no está
        // (lo borró), queda el genérico.
        case .imported(let id): ImportedTonesStore.shared.name(forID: id) ?? appLocalized("Tono importado")
        }
    }

    var systemImage: String {
        switch self {
        case .system: "speaker.wave.2.fill"
        case .chime: "bell.and.waves.left.and.right.fill"
        case .marimba: "music.note"
        case .radar: "dot.radiowaves.left.and.right"
        case .arpeggio: "music.quarternote.3"
        case .pulse: "waveform"
        case .harp: "sparkles"
        case .imported: "waveform.circle.fill"
        }
    }

    /// El archivo de audio, o `nil` si es el tono del sistema (o si el recurso no
    /// está donde debería).
    var fileURL: URL? {
        guard let fileName else { return nil }
        if case .imported(let id) = self {
            let url = ImportedTonesStore.shared.url(forID: id)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let name = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        return Bundle.main.url(forResource: name, withExtension: ext)
    }

    /// Lo que recibe AlarmKit. Si el archivo no está se cae al tono del sistema
    /// en vez de programar una alarma muda.
    var alertSound: AlertConfiguration.AlertSound {
        guard let fileName, fileURL != nil else { return .default }
        return .named(fileName)
    }
}

extension AlarmTone: RawRepresentable, Codable {
    private static let importedPrefix = "imported:"

    nonisolated init?(rawValue: String) {
        if rawValue.hasPrefix(Self.importedPrefix) {
            let id = String(rawValue.dropFirst(Self.importedPrefix.count))
            guard !id.isEmpty else { return nil }
            self = .imported(id)
            return
        }
        switch rawValue {
        case "system": self = .system
        case "chime": self = .chime
        case "marimba": self = .marimba
        case "radar": self = .radar
        case "arpeggio": self = .arpeggio
        case "pulse": self = .pulse
        case "harp": self = .harp
        default: return nil
        }
    }

    nonisolated var rawValue: String {
        switch self {
        case .system: "system"
        case .chime: "chime"
        case .marimba: "marimba"
        case .radar: "radar"
        case .arpeggio: "arpeggio"
        case .pulse: "pulse"
        case .harp: "harp"
        case .imported(let id): Self.importedPrefix + id
        }
    }

    nonisolated init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AlarmTone(rawValue: raw) ?? .system
    }

    nonisolated func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
