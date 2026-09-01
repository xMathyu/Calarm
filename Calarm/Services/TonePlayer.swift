//
//  TonePlayer.swift
//  Calarm
//

import AVFoundation
import Observation

/// Reproduce un fragmento de un `AlarmTone` para que la persona lo escuche antes
/// de elegirlo. Nada que ver con la alarma real: eso lo toca AlarmKit desde el
/// bundle. Aquí solo hay una preescucha corta.
@MainActor
@Observable
final class TonePlayer {
    static let shared = TonePlayer()

    /// Cuántos segundos suena la preescucha. Los archivos duran 28 s (llevan el
    /// patrón repetido dentro), así que se corta en cuanto se oye el motivo.
    private static let previewDuration: Duration = .seconds(5)

    /// El tono que está sonando ahora, si hay alguno.
    private(set) var playing: AlarmTone?

    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?

    private init() {}

    /// Suena `tone`; si ya estaba sonando ese mismo tono, lo detiene (toggle).
    func preview(_ tone: AlarmTone) {
        if playing == tone {
            stop()
            return
        }
        stop()
        guard let url = tone.fileURL else { return }

        // `.playback` a propósito: una alarma suena con el interruptor de
        // silencio puesto, y la preescucha tiene que comportarse igual o parece
        // que el tono está roto.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        guard let newPlayer = try? AVAudioPlayer(contentsOf: url) else { return }
        newPlayer.prepareToPlay()
        newPlayer.play()
        player = newPlayer
        playing = tone

        stopTask = Task { [weak self] in
            try? await Task.sleep(for: Self.previewDuration)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        player?.stop()
        player = nil
        playing = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
