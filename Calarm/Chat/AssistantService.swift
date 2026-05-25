//
//  AssistantService.swift
//  Calarm
//
//  Owns the conversational state with Apple Intelligence: messages, the
//  underlying `LanguageModelSession`, tool registration, and streaming
//  responses. Created once per chat session (cleared when user taps "Nueva").
//

import FoundationModels
import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class AssistantService {
    /// All chat turns shown in the UI.
    private(set) var messages: [ChatMessage] = []
    /// True while the model is producing a response (used to disable the
    /// send button + show a typing indicator).
    private(set) var isResponding: Bool = false
    private(set) var lastError: String?

    private let modelContainer: ModelContainer
    private let scheduler: ReminderScheduler
    private var session: LanguageModelSession?

    init(modelContainer: ModelContainer, scheduler: ReminderScheduler) {
        self.modelContainer = modelContainer
        self.scheduler = scheduler
    }

    /// True when Apple Intelligence is set up and the model is downloaded.
    var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Human-readable reason why the assistant isn't available, or nil when it is.
    var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible):
            return String(localized: "este dispositivo no soporta Apple Intelligence")
        case .unavailable(.appleIntelligenceNotEnabled):
            return String(localized: "activa Apple Intelligence en Ajustes → Apple Intelligence & Siri")
        case .unavailable(.modelNotReady):
            return String(localized: "el modelo aún se está descargando, intenta más tarde")
        case .unavailable(let reason):
            return "\(reason)"
        }
    }

    // MARK: - Public API

    /// Sends a new user message and starts streaming the assistant's reply.
    /// Safe to call again immediately — concurrent sends are coalesced by
    /// `isResponding`.
    func send(_ userInput: String) async {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding else { return }

        guard isAvailable else {
            lastError = unavailableReason
            return
        }

        messages.append(ChatMessage(role: .user, content: trimmed))

        // Insert a placeholder assistant message that we'll mutate as chunks arrive.
        let placeholder = ChatMessage(role: .assistant, content: "")
        messages.append(placeholder)
        let placeholderID = placeholder.id

        isResponding = true
        defer { isResponding = false }

        do {
            let session = ensureSession()
            let stream = session.streamResponse(to: trimmed)
            for try await snapshot in stream {
                // Each snapshot is the cumulative response so far. Use `.content`
                // to get the clean text — `String(describing:)` would dump the
                // wrapper struct including `rawContent` debug info.
                if let idx = messages.firstIndex(where: { $0.id == placeholderID }) {
                    messages[idx].content = snapshot.content
                }
            }
        } catch {
            lastError = error.localizedDescription
            // Remove the empty placeholder if streaming failed before any text.
            if let idx = messages.firstIndex(where: { $0.id == placeholderID }),
               messages[idx].content.isEmpty {
                messages.remove(at: idx)
            }
        }
    }

    /// Resets the conversation. Next `send` creates a fresh session.
    func reset() {
        messages = []
        session = nil
        lastError = nil
    }

    // MARK: - Session setup

    private func ensureSession() -> LanguageModelSession {
        if let session { return session }

        let tools: [any Tool] = [
            CreateReminderTool(modelContainer: modelContainer, scheduler: scheduler),
            ListRemindersTool(modelContainer: modelContainer),
            SearchRemindersTool(modelContainer: modelContainer),
            UpdateReminderTool(modelContainer: modelContainer, scheduler: scheduler),
            DeleteReminderTool(modelContainer: modelContainer, scheduler: scheduler),
        ]

        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let locale = LocalizationManager.shared.currentLocale

        let instructions = Instructions("""
        You are Calarm, an AI assistant inside an iOS alarms-and-reminders app. \
        Help the user create, find, update, and delete alarms by calling the \
        available tools. Always confirm destructive actions (delete) before \
        calling the tool.

        Context:
        - Current date/time (ISO 8601): \(isoFormatter.string(from: now))
        - User locale: \(locale.identifier)

        Rules:
        - Reply in the user's language (Spanish or English).
        - Be concise: under 80 words per response.
        - Don't include UUIDs in your replies to the user — they're internal.
        - When listing reminders, summarize naturally instead of dumping raw data.
        - Dates must be in the future when creating reminders.
        - If the user is ambiguous (e.g. doesn't say a time), ask a short clarifying question.
        - You can chain tool calls — e.g. search first, then update by id.
        """)

        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            tools: tools,
            instructions: instructions
        )
        self.session = session
        return session
    }
}
