//
//  ParseAlarmService.swift
//  Calarm
//
//  Wraps the Foundation Models framework (Apple Intelligence on-device LLM)
//  to extract structured alarm data from natural language input.
//
//  Example input: "Cumple de mi mamá el 15 de marzo todos los años a las 8am"
//  Output: title="Cumpleaños de mamá", date=2026-03-15T08:00, recurrence=yearly, …
//

import FoundationModels
import Foundation

/// Structured output the language model fills in.
@Generable
struct ParsedAlarmDraft: Sendable {
    @Guide(description: "Short, clear title for the alarm — in the user's language. Do NOT include the date or time.")
    let title: String

    @Guide(description: "When the alarm fires, ISO 8601 format like 2026-03-15T08:00:00. Must be in the future.")
    let dateISO: String

    @Guide(description: "Category. Pick exactly one of: birthday, anniversary, event, reminder, other.")
    let category: String

    @Guide(description: "Recurrence. Pick exactly one of: once, daily, weekly, monthly, yearly.")
    let recurrence: String

    @Guide(description: "Minutes before the alarm to alert the user. 0 means at the moment. Examples: [0], [5], [0, 60], [0, 60, 1440]. Default to [0] if user does not specify.")
    let leadTimesMinutes: [Int]
}

/// Service that parses natural language alarm requests via Apple Intelligence.
@MainActor
final class ParseAlarmService {
    static let shared = ParseAlarmService()
    private init() {}

    enum ParseError: LocalizedError {
        case modelUnavailable(reason: String)
        case parseFailed(any Error)

        var errorDescription: String? {
            switch self {
            case .modelUnavailable(let reason):
                return "Apple Intelligence no está disponible: \(reason)"
            case .parseFailed(let error):
                return "No pude entender la alarma: \(error.localizedDescription)"
            }
        }
    }

    /// True when Apple Intelligence is set up and the device can run the model.
    var isAvailable: Bool {
        switch SystemLanguageModel.default.availability {
        case .available: return true
        default: return false
        }
    }

    /// Parses `input` into structured fields using the on-device model.
    /// Throws if the model isn't available or the response can't be generated.
    func parse(_ input: String, locale: Locale) async throws -> ParsedAlarmDraft {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(.deviceNotEligible):
            throw ParseError.modelUnavailable(reason: "este dispositivo no soporta Apple Intelligence")
        case .unavailable(.appleIntelligenceNotEnabled):
            throw ParseError.modelUnavailable(reason: "activa Apple Intelligence en Ajustes → Apple Intelligence & Siri")
        case .unavailable(.modelNotReady):
            throw ParseError.modelUnavailable(reason: "el modelo aún se está descargando, intenta más tarde")
        case .unavailable(let reason):
            throw ParseError.modelUnavailable(reason: "\(reason)")
        }

        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let nowISO = isoFormatter.string(from: now)

        let instructions = Instructions("""
        You are an alarm parser for the Calarm iOS app. Given a user's natural-language \
        description, extract structured alarm data and respond ONLY with the requested fields.

        Rules:
        - title: short, in the user's language, suitable for an alarm label. Do NOT include date or time.
        - dateISO: must be in the future, ISO 8601. If only a time is given, assume today if it hasn't passed, otherwise tomorrow.
        - category: pick the closest from [birthday, anniversary, event, reminder, other].
        - recurrence: pick from [once, daily, weekly, monthly, yearly]. Default to once if not specified.
        - leadTimesMinutes: list of minutes before the event. Examples: [0] for at-start only, [0, 60] for both at-start and 1 hour before, [1440] for 1 day before. Default to [0].

        Be concise. Respect the user's language (Spanish or English).
        """)

        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: instructions
        )

        let prompt = """
        Current date/time: \(nowISO)
        User locale: \(locale.identifier)
        Parse this alarm request and return the structured fields:
        "\(input)"
        """

        do {
            let response = try await session.respond(
                to: prompt,
                generating: ParsedAlarmDraft.self
            )
            return response.content
        } catch {
            throw ParseError.parseFailed(error)
        }
    }
}
