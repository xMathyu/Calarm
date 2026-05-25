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
        let locale = LocalizationManager.shared.currentLocale
        let tz = TimeZone.current

        // Format the current local time as a naive ISO string (no timezone
        // suffix), matching how we want the model to emit dates.
        let localFormatter = DateFormatter()
        localFormatter.locale = Locale(identifier: "en_US_POSIX")
        localFormatter.timeZone = tz
        localFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let nowLocal = localFormatter.string(from: now)

        let offsetHours = Double(tz.secondsFromGMT(for: now)) / 3600.0
        let offsetSign = offsetHours >= 0 ? "+" : ""

        let instructions = Instructions("""
        You are Calarm, an AI assistant inside an iOS alarms-and-reminders app. \
        Help the user create, find, update, and delete alarms by calling the \
        available tools. Always confirm destructive actions (delete) before \
        calling the tool.

        ## Context
        - Current date/time IN USER'S LOCAL TIMEZONE: \(nowLocal)
        - User timezone: \(tz.identifier) (UTC\(offsetSign)\(String(format: "%g", offsetHours)))
        - User locale: \(locale.identifier)

        ## Date format — CRITICAL
        - Always emit dates in this exact local format: YYYY-MM-DDTHH:MM:SS
          (no Z, no timezone offset — dates are ALWAYS interpreted as the user's local time).
        - Example: when user says "a las 2 de la tarde" → 14:00:00 (NOT 19:00:00 UTC).
        - Example: "mañana a las 8 am" with current local time \(nowLocal) → add 1 day, set hour 08:00:00.

        ## Update flow — IMPORTANT
        When the user wants to MODIFY an existing reminder:
        1. First call search_reminders or list_reminders to find the exact id and CURRENT values.
        2. Only pass to update_reminder the fields the user explicitly changed.
        3. Pass null (or omit) every field the user did NOT mention.
        4. Example: user says "cambia el del dentista a las 11" → search for "dentista", get its current full date (e.g. "2026-06-05T10:00:00"), call update_reminder with dateISO="2026-06-05T11:00:00" and ALL OTHER FIELDS NULL.
        5. Never invent or default values for fields the user didn't mention.

        ## Other rules
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
