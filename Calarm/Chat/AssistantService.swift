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
import NaturalLanguage
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
    /// "Spanish"/"English", detected from what the user wrote and written
    /// into the instructions: left to itself the model answered Spanish in
    /// English and the other way round, even with a CRITICAL rule.
    private var replyLanguage: String?
    /// Whether the previous turn created, changed or deleted an alarm. Right
    /// after one, "Se crearon dos alarmas" is a recap, not a false claim.
    private var lastTurnChangedAlarms = false
    private var tools: [any Tool] = []
    private let turn = AssistantTurnContext()
    /// The language the current session's instructions were written for.
    private var sessionLanguage: String?

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
            return appLocalized("este dispositivo no soporta Apple Intelligence")
        case .unavailable(.appleIntelligenceNotEnabled):
            return appLocalized("activa Apple Intelligence en Ajustes → Apple Intelligence & Siri")
        case .unavailable(.modelNotReady):
            return appLocalized("el modelo aún se está descargando, intenta más tarde")
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

        // A bare "ok" can't be told apart, so it keeps the previous turn's language.
        if let detected = Self.detectLanguage(of: trimmed) { replyLanguage = detected }

        let previousTurnChangedAlarms = lastTurnChangedAlarms
        lastTurnChangedAlarms = false

        do {
            var session = ensureSession()
            var turnStart = session.transcript.endIndex
            // The bubble keeps what the user wrote; the model gets the time
            // ranges already resolved to 24 h.
            let modelInput = Self.normalizeTimeRanges(trimmed)
            turn.begin(trimmed)
            var reply = try await stream(modelInput, in: session, into: placeholderID)
            var calledTools = Self.toolNames(in: session.transcript, since: turnStart)

            // The on-device model sometimes writes the tool call out as JSON, or
            // answers "listo, la creé" without ever calling the tool — and then
            // the alarm doesn't exist. Retry once from before that answer (left
            // in the transcript, the model just repeats "ya está creada"); if it
            // still doesn't act, say so instead of letting the user trust a lie.
            if Self.needsRepair(reply: reply, calledTools: calledTools, previousTurnChangedAlarms: previousTurnChangedAlarms) {
                setContent("", of: placeholderID)
                session = rollBack(session, to: turnStart)
                turnStart = session.transcript.endIndex
                reply = try await stream(
                    Self.retryPrompt(for: modelInput),
                    in: session,
                    into: placeholderID
                )
                calledTools = Self.toolNames(in: session.transcript, since: turnStart)
                if Self.needsRepair(reply: reply, calledTools: calledTools, previousTurnChangedAlarms: previousTurnChangedAlarms) {
                    setContent(appLocalized("No pude guardar ningún cambio. ¿Me lo repites con el día y la hora?"), of: placeholderID)
                    return
                }
            }
            lastTurnChangedAlarms = Self.didChangeAlarms(calledTools)
            if Self.displayText(reply).isEmpty {
                setContent(
                    Self.didChangeAlarms(calledTools)
                        ? appLocalized("Listo")
                        : appLocalized("No pude guardar ningún cambio. ¿Me lo repites con el día y la hora?"),
                    of: placeholderID
                )
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
        replyLanguage = nil
        sessionLanguage = nil
        lastTurnChangedAlarms = false
    }

    /// A session that forgets everything from `index` on — the failed answer
    /// and any lookups it made (only read-only tools: an alarm-changing call
    /// never triggers a retry).
    private func rollBack(_ session: LanguageModelSession, to index: Int) -> LanguageModelSession {
        let kept = Transcript(entries: session.transcript[session.transcript.startIndex..<index])
        let fresh = LanguageModelSession(model: SystemLanguageModel.default, tools: tools, transcript: kept)
        self.session = fresh
        return fresh
    }

    // MARK: - Streaming

    /// Streams one model answer into the placeholder bubble and returns the
    /// raw text. Anything that looks like JSON is kept out of the bubble.
    private func stream(_ prompt: String, in session: LanguageModelSession, into id: UUID) async throws -> String {
        var text = ""
        for try await snapshot in session.streamResponse(to: prompt) {
            // Each snapshot is the cumulative response so far. Use `.content`
            // to get the clean text — `String(describing:)` would dump the
            // wrapper struct including `rawContent` debug info.
            text = snapshot.content
            setContent(Self.displayText(text), of: id)
        }
        return text
    }

    private func setContent(_ text: String, of id: UUID) {
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].content = text
        }
    }

    // MARK: - Session setup

    /// The live session, created on first use. The reply language lives in
    /// the instructions: told inside the user's message ("[Reply in
    /// Spanish]"), the model stopped calling list_reminders for "¿qué tengo
    /// hoy?". When the user switches language mid-chat the session is rebuilt
    /// with the same history and the new instructions.
    private func ensureSession() -> LanguageModelSession {
        if let session {
            guard let replyLanguage, replyLanguage != sessionLanguage else { return session }
            var entries = Array(session.transcript)
            if case .instructions(var current)? = entries.first {
                current.segments = [.text(Transcript.TextSegment(content: instructionsText(replyLanguage: replyLanguage)))]
                entries[0] = .instructions(current)
            }
            let switched = LanguageModelSession(
                model: SystemLanguageModel.default,
                tools: tools,
                transcript: Transcript(entries: entries)
            )
            sessionLanguage = replyLanguage
            self.session = switched
            return switched
        }

        tools = [
            CreateReminderTool(modelContainer: modelContainer, scheduler: scheduler, turn: turn),
            ListRemindersTool(modelContainer: modelContainer),
            SearchRemindersTool(modelContainer: modelContainer),
            UpdateReminderTool(modelContainer: modelContainer, scheduler: scheduler),
            DeleteReminderTool(modelContainer: modelContainer, scheduler: scheduler),
        ]
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            tools: tools,
            instructions: Instructions(instructionsText(replyLanguage: replyLanguage))
        )
        sessionLanguage = replyLanguage
        self.session = session
        return session
    }

    private func instructionsText(replyLanguage: String?) -> String {
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

        // The on-device model can't do calendar math: "este sábado 14" came
        // back as February. Handing it the next two weeks already resolved
        // turns that into a lookup.
        let upcomingDays = Self.upcomingDaysText(from: now, timeZone: tz)

        let offsetHours = Double(tz.secondsFromGMT(for: now)) / 3600.0
        let offsetSign = offsetHours >= 0 ? "+" : ""

        let languageRule = replyLanguage.map {
            "The user writes in \($0): ALWAYS reply in \($0), even when a name or word in their message is in another language."
        } ?? "Reply in the language the user wrote their last message in (Spanish → Spanish, English → English). Only if you truly can't tell: \(locale.identifier)."

        let customNames = (CategoryStore.shared?.customCategories.map(\.name) ?? [])
            .filter { !$0.isEmpty }
        let customCategoriesText = customNames.isEmpty
            ? "The user has no custom categories — use only the built-in ones."
            : "The user's CUSTOM categories — pass the EXACT name as the category value when the user's intent matches one: " + customNames.joined(separator: ", ") + "."

        return """
        You are Calarm, an AI assistant inside an iOS alarms-and-reminders app. \
        Help the user create, find, update, and delete alarms by calling the \
        available tools. A message with a day and a time is a NEW alarm: call \
        create_reminder right away — don't search first, and don't ask for \
        confirmation, category or lead times; only a delete needs the user's \
        confirmation. NEVER write JSON or tool arguments in your reply: the \
        only way to create an alarm is calling create_reminder.

        ## Language — CRITICAL
        \(languageRule)

        ## Context
        - Current date/time IN USER'S LOCAL TIMEZONE: \(nowLocal)
        - User timezone: \(tz.identifier) (UTC\(offsetSign)\(String(format: "%g", offsetHours)))
        - User locale: \(locale.identifier)
        - The next days — look dates up here, never compute them yourself. A \
          day number without a month ("el sábado 14") is the next date with \
          that number in this list:
        \(upcomingDays)

        ## Date format — CRITICAL
        - Always emit dates in this exact local format: YYYY-MM-DDTHH:MM:SS
          (no Z, no timezone offset — dates are ALWAYS interpreted as the user's local time).
        - Example: "a las 2 de la tarde" → 14:00:00 (NOT 19:00:00 UTC).
        - Example: "mañana a las 8 am" with current local time \(nowLocal) → add 1 day, set hour 08:00:00.
        - A BARE TIME always means the NEXT time that clock time comes around. \
          If it has already gone by today, use TOMORROW — never a past moment. \
          Example: it is \(nowLocal) and the user says "a las 9" / "at 9": if 09:00 \
          already passed today, the alarm is TOMORROW at 09:00:00.

        ## Recurrence detection — CRITICAL
        Read the user's full message for recurrence hints and map them:
          • "every year" / "cada año" / "todos los años" / "yearly" / "annual" / "anual" / "anualmente" → yearly
          • "every month" / "cada mes" / "todos los meses" / "monthly" / "mensual" / "mensualmente" → monthly
          • "every week" / "cada semana" / "todas las semanas" / "weekly" / "semanal" / "semanalmente" → weekly
          • "every day" / "cada día" / "todos los días" / "daily" / "diaria" / "diariamente" → daily
          • Only choose "once" if the user gave a SPECIFIC date with NO recurrence words.
        Example: "Mom's birthday March 15 every year" → yearly (NOT once!).
        Example: "Cumple de mamá el 15 de marzo todos los años" → yearly.

        ## Named weekdays — CRITICAL
        When the user names REPEATING days of the week (plural or "every"), pass
        recurrence "weekly" AND the `weekdays` list (English lowercase names).
        Never use "daily" for these:
          • "todos los lunes" / "every Monday" / "los lunes" / "cada lunes" → weekly + ["monday"]
          • "los martes y jueves" / "Tuesdays and Thursdays" → weekly + ["tuesday", "thursday"]
          • "entre semana" / "weekdays" / "días laborales" → weekly + monday…friday
          • "fines de semana" / "weekends" → weekly + ["saturday", "sunday"]
        Set dateISO to the NEXT occurrence of the first named weekday, at the
        requested time.
        A SINGLE upcoming day is NOT weekly: "este sábado", "el sábado 14", \
        "el próximo lunes", "this Friday" → recurrence once on that date, \
        weekdays null. Only plural or "every" ("los sábados", "todos los \
        sábados", "cada sábado", "every Saturday") means weekly.

        ## The frequency is NOT in the title — CRITICAL
        Recurrence comes ONLY from how often the user says the alarm repeats,
        never from words inside the alarm's NAME. Many meetings are literally
        called "daily", "weekly", "standup", "mensual".
        Example: "Pon una alarma de mi daily todos los lunes" →
          title "Daily", recurrence weekly, weekdays ["monday"].
          It is NOT daily — "daily" there is the meeting's name, and "todos los
          lunes" is the real frequency.
        Example: "recuérdame el reporte mensual todos los viernes" →
          title "Reporte mensual", recurrence weekly, weekdays ["friday"] (NOT monthly).
        When the message contains both a name-word and a real frequency phrase,
        the frequency phrase always wins.

        ## Category detection
          • Birthday/cumpleaños → birthday
          • Anniversary/aniversario → anniversary
          • Meeting/event/reunión/cita → event
          • Generic reminder/recordatorio → reminder
          • \(customCategoriesText)
          • Prefer a custom category over a built-in one when the user's request clearly matches it.

        ## Default time when only a date is given
          • Birthdays & anniversaries → 09:00:00 (9am) — not midnight.
          • Other → ask the user politely for the time.
        NEVER default to 00:00:00 unless the user explicitly says "medianoche" / "midnight".

        ## Update flow — IMPORTANT
        When the user wants to MODIFY an existing reminder:
        1. First call search_reminders or list_reminders to find the exact id and CURRENT values.
        2. Only pass to update_reminder the fields the user explicitly changed.
        3. Pass null (or omit) every field the user did NOT mention.
        4. Example: "cambia el del dentista a las 11" → search for "dentista", get its current date, call update_reminder with only dateISO updated.

        ## Other rules
        - Be concise: under 80 words per response.
        - Don't include UUIDs in your replies to the user — they're internal.
        - When listing reminders, summarize naturally instead of dumping raw data.
        - Dates must be in the future when creating reminders.
        - You can chain tool calls — e.g. search first, then update by id.
        """
    }

    // MARK: - Prompt helpers

    /// The next two weeks as `2026-11-14 = Saturday / sábado` lines, with
    /// today and tomorrow marked. Both languages, since the user may write in
    /// either whatever the app's locale is.
    nonisolated static func upcomingDaysText(from now: Date, timeZone: TimeZone, days: Int = 14) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let iso = DateFormatter()
        iso.calendar = calendar
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.timeZone = timeZone
        iso.dateFormat = "yyyy-MM-dd"
        let english = DateFormatter()
        english.locale = Locale(identifier: "en_US")
        english.timeZone = timeZone
        english.dateFormat = "EEEE"
        let spanish = DateFormatter()
        spanish.locale = Locale(identifier: "es")
        spanish.timeZone = timeZone
        spanish.dateFormat = "EEEE"

        let today = calendar.startOfDay(for: now)
        return (0..<days).compactMap { offset -> String? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let marker = switch offset {
            case 0: " (today / hoy)"
            case 1: " (tomorrow / mañana)"
            default: ""
            }
            return "- \(iso.string(from: day)) = \(english.string(from: day)) / \(spanish.string(from: day))\(marker)"
        }
        .joined(separator: "\n")
    }

    /// "Spanish" or "English" when the message clearly is one of them (the
    /// app's two languages), nil for a bare "ok" or anything ambiguous.
    nonisolated static func detectLanguage(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.spanish, .english]
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= 0.9 else { return nil }
        return language == .spanish ? "Spanish" : "English"
    }

    /// Spells out which half of the day a time range means before the model
    /// sees it: "de 2 a 4 y de 9 a 11" → "de 14:00 a 16:00 y de 21:00 a 23:00".
    /// Rules and examples in the instructions didn't stick — the model copied
    /// the example's hours instead. Without "mañana"/"tarde"/am/pm, a range
    /// starting at 1–5 is afternoon, and one that would start before the
    /// previous range is the evening one. Anything else is left as written.
    nonisolated static func normalizeTimeRanges(_ text: String) -> String {
        let months = "enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|setiembre|octubre|noviembre|diciembre|january|february|march|april|may|june|july|august|september|october|november|december"
        let pattern = #"\b(de|from)\s+(\d{1,2})(?::(\d{2}))?\s*(?:a|to|until|till|-)\s*(\d{1,2})(?::(\d{2}))?(?!\d|:|\s*(?:de\s+)?(?:"# + months + #"))(\s*(?:de la (?:mañana|madrugada|tarde|noche)|en la (?:mañana|tarde|noche)|in the (?:morning|afternoon|evening)|a\.?\s?m\b\.?|p\.?\s?m\b\.?))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let source = text as NSString
        var result = ""
        var cursor = 0
        var previousStart: Int?
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            func group(_ index: Int) -> String? {
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : source.substring(with: range)
            }
            guard let word = group(1), let startHour = Int(group(2) ?? ""), let endHour = Int(group(4) ?? ""),
                  startHour <= 23, endHour <= 23 else { continue }
            let startMinute = Int(group(3) ?? "") ?? 0
            let endMinute = Int(group(5) ?? "") ?? 0
            let qualifier = (group(6) ?? "").lowercased()
            let saysMorning = ["mañana", "madrugada", "morning"].contains(where: qualifier.contains)
                || qualifier.range(of: #"^\s*a\.?\s?m"#, options: .regularExpression) != nil
            let saysEvening = ["tarde", "noche", "afternoon", "evening"].contains(where: qualifier.contains)
                || qualifier.range(of: #"^\s*p\.?\s?m"#, options: .regularExpression) != nil

            let afternoon: Bool
            if startHour > 12 || endHour > 12 || saysMorning {
                afternoon = false
            } else if saysEvening {
                afternoon = true
            } else if let previousStart, startHour * 60 + startMinute < previousStart {
                afternoon = true
            } else if (1...5).contains(startHour) {
                afternoon = true
            } else {
                // "de 9 a 11" on its own could be either: the model decides.
                previousStart = startHour * 60 + startMinute
                continue
            }
            let start = afternoon && startHour < 12 ? startHour + 12 : startHour
            let end = afternoon && endHour < 12 && endHour + 12 >= start ? endHour + 12 : endHour
            previousStart = start * 60 + startMinute
            guard afternoon || saysMorning else { continue }

            let connector = word.lowercased() == "from" ? "to" : "a"
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += String(format: "%@ %02d:%02d %@ %02d:%02d", word, start, startMinute, connector, end, endMinute)
            cursor = match.range.location + match.range.length
        }
        guard cursor > 0 else { return text }
        return result + source.substring(from: cursor)
    }

    /// Start times (minutes after midnight) of the ranges in the user's message
    /// once resolved to 24 h: "de 2 a 4 y de 9 a 11" → [840, 1260]. The model
    /// often creates only the first one, so the tool adds the others as extra
    /// schedules of the same alarm.
    nonisolated static func rangeStartTimes(in text: String) -> [Int] {
        let normalized = normalizeTimeRanges(text)
        let pattern = #"\b(?:de|from)\s+(\d{1,2}):(\d{2})\s+(?:a|to)\s+\d{1,2}:\d{2}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let source = normalized as NSString
        return regex.matches(in: normalized, range: NSRange(location: 0, length: source.length)).compactMap { match in
            guard let hour = Int(source.substring(with: match.range(at: 1))),
                  let minute = Int(source.substring(with: match.range(at: 2))),
                  hour < 24, minute < 60 else { return nil }
            return hour * 60 + minute
        }
    }

    /// Advance notices the user asked for, in minutes: "un día antes" → 1440,
    /// "media hora antes" → 30, "2 hours before" → 120. The model wrote them
    /// as 60, or as a second alarm the day before.
    nonisolated static func advanceNoticeMinutes(in text: String) -> [Int] {
        let lower = text.lowercased()
        var minutes: [Int] = []
        let fixed: [(String, Int)] = [
            (#"\b(un|1) d[ií]a antes\b|\bel d[ií]a anterior\b|\b(a|one|1) day before\b|\bthe day before\b"#, 1440),
            (#"\b(una|1) hora antes\b|\b(an|one|1) hour before\b"#, 60),
            (#"\bmedia hora antes\b|\bhalf an hour before\b"#, 30),
            (#"\b(una|1) semana antes\b|\b(a|one|1) week before\b"#, 10080),
        ]
        for (pattern, value) in fixed where lower.range(of: pattern, options: .regularExpression) != nil {
            minutes.append(value)
        }
        let counted: [(String, Int)] = [
            (#"\b(\d{1,3}) (?:minutos|min|minutes|mins)\s+(?:antes|before)\b"#, 1),
            (#"\b(\d{1,2}) (?:horas|hours)\s+(?:antes|before)\b"#, 60),
            (#"\b(\d{1,2}) (?:d[ií]as|days)\s+(?:antes|before)\b"#, 1440),
        ]
        for (pattern, unit) in counted {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let source = lower as NSString
            for match in regex.matches(in: lower, range: NSRange(location: 0, length: source.length)) {
                if let count = Int(source.substring(with: match.range(at: 1))), count > 0 {
                    minutes.append(count * unit)
                }
            }
        }
        return Array(Set(minutes)).sorted()
    }

    /// Whether the user named one upcoming weekday ("este sábado", "el sábado
    /// 14", "this Friday") and no repeating one ("los sábados", "cada lunes",
    /// "every Friday", "entre semana"). The model turned "este sábado 14" into
    /// a weekly alarm whatever the instructions said, so the user's own words
    /// decide.
    nonisolated static func meansSingleDay(_ text: String) -> Bool {
        let days = "lunes|martes|mi[eé]rcoles|jueves|viernes|s[aá]bado|domingo|monday|tuesday|wednesday|thursday|friday|saturday|sunday"
        let repeating = [
            #"\b(los|cada)\s+(?:"# + days + #")"#,
            #"\b(s[aá]bados|domingos|mondays|tuesdays|wednesdays|thursdays|fridays|saturdays|sundays)\b"#,
            #"\bevery\s+(?:"# + days + #"|day|week)\b"#,
            #"\b(entre semana|fines? de semana|cada semana|todas las semanas|todos los d[ií]as|cada d[ií]a|weekdays|weekends?)\b"#,
        ]
        let single = [
            #"\b(este|el|pr[oó]ximo|this|next|on)\s+(?:"# + days + #")\b"#,
            #"\b(?:"# + days + #")\s+\d{1,2}\b"#,
        ]
        func matches(_ pattern: String) -> Bool {
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        return single.contains(where: matches) && !repeating.contains(where: matches)
    }

    /// The user's message again after a failed answer was rolled back, with a
    /// reminder that only a tool call saves anything.
    nonisolated static func retryPrompt(for text: String) -> String {
        text + "\n\n[If this asks to create, change or delete an alarm, call the tool: saying it is done saves nothing. Never write JSON.]"
    }

    nonisolated static let alarmChangingTools: Set<String> = ["create_reminder", "update_reminder", "delete_reminder"]

    /// Names of the tools the model called from `start` on.
    nonisolated static func toolNames(in transcript: Transcript, since start: Int) -> [String] {
        guard start < transcript.endIndex else { return [] }
        return transcript[start..<transcript.endIndex].flatMap { entry -> [String] in
            guard case .toolCalls(let calls) = entry else { return [] }
            return calls.map(\.toolName)
        }
    }

    nonisolated static func didChangeAlarms(_ calledTools: [String]) -> Bool {
        calledTools.contains(where: alarmChangingTools.contains)
    }

    /// The answer can't be trusted: no alarm changed, yet it dumped JSON or
    /// said it created/changed/deleted something. A "done" claim only counts
    /// when the model looked nothing up and the previous turn didn't change
    /// alarms either — otherwise it's a recap ("se crearon dos alarmas") or an
    /// answer about what list/search returned.
    nonisolated static func needsRepair(reply: String, calledTools: [String], previousTurnChangedAlarms: Bool) -> Bool {
        guard !didChangeAlarms(calledTools) else { return false }
        if containsJSON(reply) { return true }
        return calledTools.isEmpty && !previousTurnChangedAlarms && claimsChange(reply)
    }

    nonisolated static func containsJSON(_ text: String) -> Bool {
        text.contains("```") || text.range(of: #"\{\s*""#, options: .regularExpression) != nil
    }

    /// First-person or passive "I just did it" forms in the app's two
    /// languages. Only past tenses — "¿quieres que la cree?" or "should I set
    /// it?" aren't claims — and no bare participles, since a list answer says
    /// "tienes una alarma programada" without having changed anything.
    nonisolated static func claimsChange(_ text: String) -> Bool {
        let patterns = [
            #"\b(creé|programé|configuré|agendé|guardé|añadí|agregué|actualicé|cambié|moví|borré|eliminé|puse)\b"#,
            #"\b(he|hemos) (creado|programado|configurado|agendado|guardado|añadido|agregado|actualizado|cambiado|movido|borrado|eliminado|puesto|establecido|fijado)\b"#,
            #"\b(ha|han) sido (cread|programad|configurad|agendad|guardad|añadid|agregad|actualizad|cambiad|movid|borrad|eliminad|establecid|fijad)[oa]s?\b"#,
            #"\bse (creó|crearon|programó|programaron|guardó|guardaron|actualizó|cambió|movió|borró|borraron|eliminó|eliminaron)\b"#,
            #"\b(alarma|recordatorio)s? (cread|borrad|eliminad)[oa]s?\b"#,
            #"\bi('ve| have) (just )?(created|set|scheduled|added|saved|updated|changed|moved|deleted|removed)\b"#,
            #"\bi (just )?(created|scheduled|added|saved|updated|changed|moved|deleted|removed)\b"#,
            #"\b(has|have) been (created|set|scheduled|added|saved|updated|changed|moved|deleted|removed)\b"#,
            #"\b(alarm|reminder)s? (created|deleted)\b"#,
        ]
        return patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// What the bubble shows: the answer without code fences or JSON objects,
    /// also mid-stream while a fence or object isn't closed yet.
    nonisolated static func displayText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"```[\s\S]*?(```|$)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\{\s*"[\s\S]*(\}|$)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
