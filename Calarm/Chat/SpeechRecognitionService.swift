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

    /// Re-creates the recognizer for the user's language. Apple's
    /// `SFSpeechRecognizer(locale:)` returns nil for unsupported locales (e.g.
    /// `es_PE` isn't recognized — only `es_ES`, `es_MX`, etc are), so we walk
    /// down a fallback chain instead of letting it fall back to en_US.
    func refreshRecognizer() {
        let userLocale = LocalizationManager.shared.currentLocale
        let supported = SFSpeechRecognizer.supportedLocales()

        // 1. Exact match (e.g. es_PE → es_PE if Apple supports it).
        if let exact = supported.first(where: { $0.identifier == userLocale.identifier }),
           let r = SFSpeechRecognizer(locale: exact) {
            recognizer = r
            return
        }

        // 2. Same language + same region with different format. e.g. for
        //    `es_PE` look for any `es_PE` variant; for `es-419` look for `es_419`.
        let normalizedID = userLocale.identifier
            .replacingOccurrences(of: "-", with: "_")
        if let normalized = supported.first(where: { $0.identifier == normalizedID }),
           let r = SFSpeechRecognizer(locale: normalized) {
            recognizer = r
            return
        }

        // 3. Same language, any region (Spanish from Peru → falls back to es_MX
        //    or es_ES, whichever Apple has). Prefer the user's region if Apple
        //    has it for that language.
        if let langCode = userLocale.language.languageCode?.identifier {
            let sameLanguage = supported.filter {
                $0.language.languageCode?.identifier == langCode
            }
            // Pick same-region first.
            if let userRegion = userLocale.region?.identifier,
               let regionMatch = sameLanguage.first(where: { $0.region?.identifier == userRegion }),
               let r = SFSpeechRecognizer(locale: regionMatch) {
                recognizer = r
                return
            }
            // For Spanish specifically, prefer es_MX (Latin American) when
            // user's region isn't directly supported.
            if langCode == "es",
               let mx = sameLanguage.first(where: { $0.identifier == "es_MX" }),
               let r = SFSpeechRecognizer(locale: mx) {
                recognizer = r
                return
            }
            // Otherwise any locale that shares the language.
            if let any = sameLanguage.first,
               let r = SFSpeechRecognizer(locale: any) {
                recognizer = r
                return
            }
        }

        // 4. Last resort — system default. Will likely be en_US.
        recognizer = SFSpeechRecognizer()
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
        // Only force on-device when the recognizer has the offline model.
        // Otherwise Apple's on-device requirement fails silently if the user
        // hasn't downloaded the offline language pack.
        request.requiresOnDeviceRecognition = recognizer?.supportsOnDeviceRecognition ?? false
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
