//
//  SpeechRecognitionService.swift
//  Calarm
//
//  Tap-to-talk speech input for the assistant. Uses Apple's on-device
//  `SFSpeechRecognizer` so transcription stays private. The transcribed
//  text becomes the next user message in the chat.
//

import AVFoundation
import Foundation
import Observation
import Speech

@Observable
@MainActor
final class SpeechRecognitionService {
    private(set) var transcription: String = ""
    private(set) var isRecording: Bool = false
    private(set) var lastError: String?

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    init() {
        refreshRecognizer()
    }

    /// Re-creates the recognizer when the language override changes.
    func refreshRecognizer() {
        let locale = LocalizationManager.shared.currentLocale
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
    }

    /// Requests speech + microphone authorization. Returns true when both granted.
    func requestAuthorization() async -> Bool {
        // Speech recognition
        let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        // Microphone
        let micGranted: Bool = await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
        return speechStatus == .authorized && micGranted
    }

    /// Starts streaming microphone audio into the speech recognizer.
    /// Updates `transcription` live as the user speaks.
    func start() throws {
        guard !isRecording else { return }

        // Cancel any previous task.
        task?.cancel()
        task = nil

        // Configure the shared audio session for recording.
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        // Set up the recognition request.
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.request = request

        // Pipe mic buffer into the request.
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        transcription = ""
        isRecording = true
        lastError = nil

        guard let recognizer, recognizer.isAvailable else {
            lastError = "Reconocedor de voz no disponible para este idioma"
            stop()
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                Task { @MainActor in
                    self.transcription = result.bestTranscription.formattedString
                }
            }
            if let error {
                Task { @MainActor in
                    self.lastError = error.localizedDescription
                    self.stop()
                }
            }
        }
    }

    /// Stops recording and finalizes the transcription.
    func stop() {
        guard isRecording else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        task = nil
        isRecording = false
    }
}
