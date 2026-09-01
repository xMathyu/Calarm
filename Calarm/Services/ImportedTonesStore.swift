//
//  ImportedTonesStore.swift
//  Calarm
//

import AVFoundation
import Foundation
import Observation
import os

/// Los tonos que la persona importa desde Archivos (o cualquier proveedor de
/// documentos) para usarlos como sonido de alarma.
///
/// AlarmKit solo acepta audio del bundle de la app o de `Library/Sounds` dentro
/// de su contenedor, y el bundle es de solo lectura en ejecución — así que todo
/// audio importado termina en `Library/Sounds`, convertido a un `.caf` que cumple
/// las reglas de AlarmKit: PCM, menos de 30 s y con el clip repetido hasta llenar
/// esa duración (el sistema no hace loop del sonido personalizado).
///
/// El manifiesto (id → nombre visible) vive en `UserDefaults`; el audio, en disco.
@MainActor
@Observable
final class ImportedTonesStore {
    static let shared = ImportedTonesStore()

    /// Duración del archivo generado. El límite de AlarmKit son 30 s.
    private static let targetDuration: TimeInterval = 28
    /// Tope de tonos importados, para que el contenedor no crezca sin control.
    static let maxTones = 12

    struct Tone: Codable, Identifiable, Hashable {
        let id: String
        var name: String
        var addedAt: Date
    }

    enum ImportError: Error {
        case unreadable
        case tooMany

        /// El texto para la alerta. No es `LocalizedError.errorDescription` porque
        /// ese requisito es nonisolated y `appLocalized` (que aplica el idioma
        /// elegido dentro de la app) vive en el main actor.
        var localizedMessage: String {
            switch self {
            case .unreadable:
                appLocalized("No se pudo leer ese audio. Prueba con un archivo .m4a, .mp3, .wav o .caf sin protección de copia.")
            case .tooMany:
                appLocalized("Ya tienes el máximo de tonos importados. Borra uno para agregar otro.")
            }
        }
    }

    private static let log = Logger(subsystem: "MathyuSolutions.Calarm", category: "tones")
    private static let defaultsKey = "importedTones.v1"

    private let defaults: UserDefaults
    private(set) var tones: [Tone]

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([Tone].self, from: data) {
            self.tones = decoded
        } else {
            self.tones = []
        }
        // Un tono cuyo archivo ya no está (restauración de respaldo, limpieza del
        // sistema) sale del manifiesto para no ofrecer algo que no suena.
        let missing = self.tones.filter { !FileManager.default.fileExists(atPath: url(forID: $0.id).path) }
        if !missing.isEmpty {
            self.tones.removeAll { tone in missing.contains(tone) }
            persist()
        }
    }

    /// `Library/Sounds` del contenedor de la app — el único sitio, además del
    /// bundle, donde AlarmKit busca sonidos.
    static var soundsDirectory: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("Sounds", isDirectory: true)
    }

    func url(forID id: String) -> URL {
        Self.soundsDirectory.appendingPathComponent("\(id).caf")
    }

    func name(forID id: String) -> String? {
        tones.first { $0.id == id }?.name
    }

    /// Convierte `source` a un `.caf` en `Library/Sounds` y lo registra.
    /// Devuelve el tono listo para asignar a una alarma.
    func importAudio(from source: URL) throws -> AlarmTone {
        guard tones.count < Self.maxTones else { throw ImportError.tooMany }

        // Los archivos que llegan del picker viven fuera del sandbox.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let id = UUID().uuidString
        let destination = url(forID: id)
        try FileManager.default.createDirectory(
            at: Self.soundsDirectory,
            withIntermediateDirectories: true
        )

        do {
            try Self.transcodeLooping(from: source, to: destination)
        } catch {
            Self.log.error("import falló: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: destination)
            throw ImportError.unreadable
        }

        let name = source.deletingPathExtension().lastPathComponent
        tones.append(Tone(id: id, name: name.isEmpty ? appLocalized("Tono importado") : name, addedAt: Date()))
        persist()
        return .imported(id)
    }

    func delete(_ tone: Tone) {
        try? FileManager.default.removeItem(at: url(forID: tone.id))
        tones.removeAll { $0.id == tone.id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(tones) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    // MARK: - Conversión

    /// Lee `source`, y escribe en `destination` un CAF mono PCM de 16 bits de
    /// `targetDuration` segundos repitiendo el clip tantas veces como haga falta
    /// (recortándolo si ya es más largo), con un fundido de salida al final.
    ///
    /// Mono y PCM no son casualidad: el reproductor de sonidos del sistema acepta
    /// Linear PCM, IMA4, µLaw y aLaw (no AAC), y mono deja el archivo en la mitad
    /// del tamaño dentro del contenedor de la app.
    private static func transcodeLooping(from source: URL, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let inputFormat = input.processingFormat
        guard input.length > 0, inputFormat.channelCount > 0 else { throw ImportError.unreadable }

        let targetFrames = AVAudioFramePosition(targetDuration * inputFormat.sampleRate)
        let clipFrames = AVAudioFrameCount(min(input.length, targetFrames))
        guard let source = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: clipFrames) else {
            throw ImportError.unreadable
        }
        try input.read(into: source, frameCount: clipFrames)
        guard source.frameLength > 0 else { throw ImportError.unreadable }

        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ), let clip = downmix(source, to: monoFormat) else {
            throw ImportError.unreadable
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: monoFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = try AVAudioFile(
            forWriting: destination,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        var written: AVAudioFramePosition = 0
        while written < targetFrames {
            let remaining = targetFrames - written
            // Cada vuelta escribe una copia: el fundido final no puede tocar
            // `clip`, que se vuelve a usar en la siguiente.
            let length = AVAudioFrameCount(min(remaining, AVAudioFramePosition(clip.frameLength)))
            guard let chunk = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: length) else { break }
            chunk.frameLength = length
            copy(from: clip, to: chunk, frames: length)
            written += AVAudioFramePosition(length)
            if written >= targetFrames { fadeOut(chunk, seconds: 0.15) }
            try output.write(from: chunk)
        }
    }

    /// Promedia los canales del buffer en uno solo.
    private static func downmix(_ buffer: AVAudioPCMBuffer, to monoFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
              let src = buffer.floatChannelData,
              let dst = mono.floatChannelData
        else { return nil }
        mono.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let stride = buffer.format.isInterleaved ? channels : 1
        for i in 0..<frames {
            var sum: Float = 0
            for ch in 0..<channels {
                sum += buffer.format.isInterleaved ? src[0][i * stride + ch] : src[ch][i]
            }
            dst[0][i] = sum / Float(channels)
        }
        return mono
    }

    /// Copia las primeras `frames` muestras de un buffer mono en otro.
    private static func copy(from src: AVAudioPCMBuffer, to dst: AVAudioPCMBuffer, frames: AVAudioFrameCount) {
        guard let s = src.floatChannelData, let d = dst.floatChannelData else { return }
        d[0].update(from: s[0], count: Int(min(frames, src.frameLength)))
    }

    private static func fadeOut(_ buffer: AVAudioPCMBuffer, seconds: TimeInterval) {
        guard let data = buffer.floatChannelData else { return }
        let total = Int(buffer.frameLength)
        let fade = min(total, Int(seconds * buffer.format.sampleRate))
        guard fade > 0 else { return }
        for i in 0..<fade {
            data[0][total - fade + i] *= Float(fade - i) / Float(fade)
        }
    }
}
