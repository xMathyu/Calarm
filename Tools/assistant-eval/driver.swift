// Driver for the assistant harness. gen.py prepends the app's real prompt,
// tool schemas and AssistantService helpers; the tools here are mocks that
// only record what the model asked for. Modes (env): HARNESS_EVAL (graded
// cases), HARNESS_UNIT (pure helpers), HARNESS_TOKENS, default = chats
// (HARNESS_TURNS="a||b" for a custom one). The clock is fixed at the friend's
// report: Tue 2026-11-10 18:59, America/Lima — run with TZ=America/Lima.
setlinebuf(stdout)
actor MockLog {
    static let shared = MockLog()
    var calls: [String] = []
    var createdKeys: Set<String> = []
    func reset() { calls = [] }
    func resetConversation() { calls = []; createdKeys = [] }
    func handle(tool: String, args: String) -> String {
        calls.append("\(tool) \(args)")
        switch tool {
        case "create_reminder":
            let title = firstMatch(#"title: "([^"]*)""#, args) ?? "?"
            let date = firstMatch(#"dateISO: "([^"]*)""#, args) ?? "?"
            if !createdKeys.insert(title.lowercased() + "|" + date).inserted {
                return "Already existed, not created again: '\(title)' for \(date). It is saved — confirm it to the user."
            }
            return "Created reminder '\(title)' for \(date). ID: 3F2504E0-4F89-11D3-9A0C-0305E82C3301"
        case "list_reminders": return "No alarms in that range."
        case "search_reminders":
            let q = firstMatch(#"query: "([^"]*)""#, args) ?? ""
            return "No alarm matches \"\(q)\". Don't search again: tell the user and ask which alarm they mean."
        default: return "Error: reminder not found"
        }
    }
    func firstMatch(_ p: String, _ s: String) -> String? {
        guard let r = try? Regex(p), let m = s.firstMatch(of: r), m.count > 1,
              let sub = m[1].substring else { return nil }
        return String(sub)
    }
}

let sharedTurn = AssistantTurnContext()
/// BASELINE=1 scores the code as it was at a git ref (see run.sh): no host
/// rules, no retry, no range normalization, no language in the instructions.
let baseline = ProcessInfo.processInfo.environment["BASELINE"] != nil
nonisolated(unsafe) var hostRules = !baseline
nonisolated(unsafe) var currentUserText = ""
struct Conversation { let name: String; let turns: [String] }
let conversations: [Conversation] = {
    let env = ProcessInfo.processInfo.environment
    if let only = env["HARNESS_TURNS"] {
        return [Conversation(name: "custom", turns: only.components(separatedBy: "||"))]
    }
    return [
        Conversation(name: "A (captura 1)", turns: [
            "hay treasure hours en fortnite este sabado 14 en peru de 2 a 4 y de 9 a 11. colocalo porfa para entrar a buscar el token dorado",
            "solo estos por ahora",
        ]),
        Conversation(name: "B (captura 2)", turns: [
            "hay treasure hours en fortnite este sabado 14 en peru de 2 a 4 y de 9 a 11. colocalo porfa para buscar el token dorado",
            "recodartoris",
            "si",
        ]),
    ]
}()

if ProcessInfo.processInfo.environment["HARNESS_TOKENS"] != nil {
    var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 10; c.hour = 18; c.minute = 59
    let n = Calendar.current.date(from: c)!
    let model = SystemLanguageModel.default
    let toolsT: [any Tool] = [
        makeCreateTool(sharedTurn),
        ListRemindersTool(modelContainer: .init()),
        SearchRemindersTool(modelContainer: .init()),
        UpdateReminderTool(modelContainer: .init(), scheduler: .init()),
        DeleteReminderTool(modelContainer: .init(), scheduler: .init()),
    ]
    let i = try await model.tokenCount(for: makeInstructions(now: n))
    let t = try await model.tokenCount(for: toolsT)
    print("contextSize=\(model.contextSize) instructions=\(i) tools=\(t) total=\(i + t)")
    exit(0)
}
if ProcessInfo.processInfo.environment["HARNESS_UNIT"] != nil {
    let claims: [(String, Bool)] = [
        ("He creado una alarma para mañana a las 8:00 para el pastillero.", true),
        ("¡Claro! He creado una alarma de tipo daily para lunes a las 9 este martes.", true),
        ("¡Creé la reunión con Ana el jueves a las 18:00.", true),
        ("Una alarma ha sido creada para mañana a las 8 a.m.", true),
        ("I've set up two reminders for Treasure Hours.", true),
        ("I've set an alarm for the gym this Friday at 7 AM.", true),
        ("Alarm created for Friday.", true),
        ("¿Quieres que la cree para las 9?", false),
        ("Should I set it for 9 AM?", false),
        ("Tienes una alarma programada para mañana a las 8.", false),
        ("You have 2 alarms scheduled today.", false),
        ("¡Perfecto! Solo esas dos alarmas para el sábado 14.", false),
        ("No hay alarmas con ese nombre. ¿Podrías aclarar?", false),
        ("¿A qué hora quieres la reunión con Ana?", false),
    ]
    var fails = 0
    for (t, want) in claims where AssistantService.claimsChange(t) != want { fails += 1; print("CLAIM MISMATCH want=\(want): \(t)") }
    let leak1 = "```json\n{\n  \"fecha\": \"14:00:00\",\n  \"titulo\": \"Treasure Hours Fortnite\"\n}\n```"
    let leak2 = "Voy a crear la primera.\n```json\n{\n  \"title\": \"Treasure\",\n  \"dateISO\": \"2026-11"
    let leak3 = "{\"title\": \"x\", \"dateISO\": \"2026-11-14T14:00:00\"}"
    for (t, wantShown) in [(leak1, ""), (leak2, "Voy a crear la primera."), (leak3, ""), ("Hola {sin json}", "Hola {sin json}")] {
        let shown = AssistantService.displayText(t)
        if shown != wantShown { fails += 1; print("DISPLAY MISMATCH got=[\(shown)] want=[\(wantShown)]") }
    }
    for t in [leak1, leak2, leak3] where !AssistantService.containsJSON(t) { fails += 1; print("JSON MISSED: \(t)") }
    if AssistantService.containsJSON("Hola {sin json}") { fails += 1; print("JSON FALSE POSITIVE") }
    print(AssistantService.needsRepair(reply: leak1, calledTools: [], previousTurnChangedAlarms: false) ? "ok repair json" : "FAIL repair json")
    print(AssistantService.needsRepair(reply: leak1, calledTools: ["create_reminder"], previousTurnChangedAlarms: false) ? "FAIL no-repair after create" : "ok no repair after create")
    print(AssistantService.upcomingDaysText(from: Date(timeIntervalSince1970: 1794355140), timeZone: TimeZone(identifier: "America/Lima")!))
    let ranges: [(String, String)] = [
        ("hay treasure hours en fortnite este sabado 14 en peru de 2 a 4 y de 9 a 11. colocalo porfa",
         "hay treasure hours en fortnite este sabado 14 en peru de 14:00 a 16:00 y de 21:00 a 23:00. colocalo porfa"),
        ("fútbol todos los sábados de 3 a 5", "fútbol todos los sábados de 15:00 a 17:00"),
        ("gym de 9 a 11", "gym de 9 a 11"),
        ("gym de 6 a 8 de la mañana", "gym de 06:00 a 08:00"),
        ("clase de 7 a 9 de la noche", "clase de 19:00 a 21:00"),
        ("meeting from 2 to 3pm", "meeting from 14:00 to 15:00"),
        ("vacaciones de 15 a 20 de noviembre", "vacaciones de 15 a 20 de noviembre"),
        ("de 14 a 16 y de 9 a 11", "de 14 a 16 y de 21:00 a 23:00"),
        ("de 2:30 a 4", "de 14:30 a 16:00"),
        ("Pon una alarma mañana a las 8am", "Pon una alarma mañana a las 8am"),
        ("de 11 a 1", "de 11 a 1"),
    ]
    for (input, want) in ranges {
        let got = AssistantService.normalizeTimeRanges(input)
        if got != want { fails += 1; print("RANGE MISMATCH [\(input)] → [\(got)] want [\(want)]") }
    }
    let single: [(String, Bool)] = [
        ("hay treasure hours en fortnite este sabado 14 en peru de 2 a 4", true),
        ("este sábado a las 10 tengo dentista", true),
        ("Set an alarm this Friday at 7am for the gym", true),
        ("el próximo lunes a las 8", true),
        ("fútbol todos los sábados de 3 a 5", false),
        ("pon una alarma de mi daily todos los lunes a las 9", false),
        ("recuérdame sacar la basura los martes y jueves a las 8 pm", false),
        ("gym every Friday at 7", false),
        ("misa los domingos a las 8", false),
        ("Pon una alarma mañana a las 8am", false),
        ("cada viernes y este sábado", false),
    ]
    for (t, want) in single where AssistantService.meansSingleDay(t) != want { fails += 1; print("SINGLE MISMATCH want=\(want): \(t)") }
    let starts: [(String, [Int])] = [
        ("hay treasure hours este sabado 14 de 2 a 4 y de 9 a 11", [840, 1260]),
        ("fútbol todos los sábados de 3 a 5", [900]),
        ("gym de 9 a 11", []),
    ]
    for (t, want) in starts where AssistantService.rangeStartTimes(in: t) != want { fails += 1; print("STARTS MISMATCH \(t) → \(AssistantService.rangeStartTimes(in: t))") }
    let notices: [(String, [Int])] = [
        ("avísame el 20 a las 10 que pague la luz, un día antes también", [1440]),
        ("recuérdame 30 minutos antes y una hora antes", [30, 60]),
        ("remind me 2 hours before", [120]),
        ("call mom the day before", [1440]),
        ("Pon una alarma mañana a las 8am", []),
    ]
    for (t, want) in notices where AssistantService.advanceNoticeMinutes(in: t) != want { fails += 1; print("NOTICE MISMATCH \(t) → \(AssistantService.advanceNoticeMinutes(in: t))") }
    print("unit fails=\(fails)")
    exit(0)
}
// ---------------- graded eval ----------------
struct Call { let tool: String; let args: String
    func s(_ key: String) -> String? {
        guard let r = try? Regex(key + #": (?:Optional\()?"([^"]*)""#), let m = args.firstMatch(of: r), let sub = m[1].substring else { return nil }
        return String(sub)
    }
    var weekdays: [String] {
        guard let r = args.range(of: #"weekdays: Optional\(\[[^\]]*\]\)"#, options: .regularExpression) else { return [] }
        return args[r].matches(of: try! Regex(#""([a-z]+)""#)).compactMap { $0[1].substring.map(String.init) }
    }
    var leads: String { args.range(of: #"leadTimesMinutes: .*$"#, options: .regularExpression).map { String(args[$0]) } ?? "" }
    /// Mirrors ToolHelpers.recurrence: explicit once wins, else weekdays → weekly.
    var effectiveRec: String {
        let rec = (s("recurrence") ?? "once").lowercased()
        if rec == "once" { return "once" }
        let mapped = weekdays.isEmpty ? rec : "weekly"
        if hostRules, mapped == "weekly", AssistantService.meansSingleDay(currentUserText) { return "once" }
        return mapped
    }
}
struct Case { let text: String; let check: ([Call], String) -> String? }
func rawCreates(_ c: [Call]) -> [Call] { c.filter { $0.tool == "create_reminder" } }
/// What the real CreateReminderTool would leave saved (mirrors its host rules).
func creates(_ c: [Call]) -> [Call] {
    let raw = rawCreates(c)
    guard hostRules else { return raw }
    let notices = AssistantService.advanceNoticeMinutes(in: currentUserText)
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    var kept: [Call] = []
    for call in raw {
        guard let d = call.s("dateISO").flatMap(f.date) else { kept.append(call); continue }
        // a call at (another call - notice) is that alarm's advance notice
        let isNotice = raw.contains { other in
            guard other.args != call.args, let od = other.s("dateISO").flatMap(f.date) else { return false }
            return notices.contains(Int((od.timeIntervalSince(d) / 60).rounded()))
        }
        if !isNotice { kept.append(call) }
    }
    return kept
}
func effectiveTimes(_ c: [Call]) -> Set<String> {
    var out = Set<String>()
    let starts = hostRules ? AssistantService.rangeStartTimes(in: currentUserText) : []
    for call in creates(c) {
        guard let iso = call.s("dateISO") else { continue }
        out.insert(iso)
        let parts = iso.split(separator: "T")
        guard parts.count == 2 else { continue }
        let hm = parts[1].split(separator: ":").compactMap { Int($0) }
        guard hm.count >= 2, starts.count > 1, starts.contains(hm[0] * 60 + hm[1]) else { continue }
        for st in starts { out.insert(String(format: "%@T%02d:%02d:00", String(parts[0]), st / 60, st % 60)) }
    }
    return out
}
func one(_ c: [Call], date: String, rec: String, days: [String]? = nil) -> String? {
    let cr = creates(c)
    guard cr.count == 1 else { return "expected 1 create, got \(cr.count)" }
    let x = cr[0]
    if !(x.s("dateISO") ?? "").hasPrefix(date) { return "date \(x.s("dateISO") ?? "nil") ≠ \(date)" }
    if x.effectiveRec != rec { return "rec \(x.effectiveRec) ≠ \(rec)" }
    if let days, Set(x.weekdays) != Set(days) { return "weekdays \(x.weekdays) ≠ \(days)" }
    return nil
}
let cases: [Case] = [
    Case(text: "hay treasure hours en fortnite este sabado 14 en peru de 2 a 4 y de 9 a 11. colocalo porfa para entrar a buscar el token dorado") { c, _ in
        let d = effectiveTimes(c)
        if d != ["2026-11-14T14:00:00", "2026-11-14T21:00:00"] { return "dates \(d.sorted())" }
        if creates(c).contains(where: { $0.effectiveRec != "once" }) { return "not once" }
        return nil },
    Case(text: "Cumple de mi mamá el 15 de marzo cada año") { c, _ in
        if let e = one(c, date: "20", rec: "yearly") { return e }
        return (creates(c)[0].s("dateISO") ?? "").contains("-03-15T") ? nil : "date \(creates(c)[0].s("dateISO") ?? "nil")" },
    Case(text: "Pon una alarma mañana a las 8am para el pastillero") { c, _ in one(c, date: "2026-11-11T08:00", rec: "once") },
    Case(text: "pon una alarma de mi daily todos los lunes a las 9") { c, _ in one(c, date: "", rec: "weekly", days: ["monday"]) },
    Case(text: "recuérdame sacar la basura los martes y jueves a las 8 pm") { c, _ in one(c, date: "", rec: "weekly", days: ["tuesday", "thursday"]) },
    Case(text: "¿Qué tengo hoy?") { c, _ in c.contains { $0.tool == "list_reminders" } ? nil : "no list_reminders" },
    Case(text: "cambia el del dentista a las 11") { c, _ in c.contains { $0.tool == "search_reminders" || $0.tool == "list_reminders" } ? nil : "no search" },
    Case(text: "borra la alarma del gym") { c, _ in c.contains { $0.tool == "delete_reminder" } ? "deleted without confirm" : nil },
    Case(text: "Set an alarm this Friday at 7am for the gym") { c, _ in one(c, date: "2026-11-13T07:00", rec: "once") },
    Case(text: "Reunión con Ana el jueves") { c, _ in creates(c).isEmpty ? nil : "created without time" },
    Case(text: "fútbol todos los sábados de 3 a 5") { c, _ in one(c, date: "2026-11-14T15:00", rec: "weekly", days: ["saturday"]) },
    Case(text: "avísame el 20 a las 10 que pague la luz, un día antes también") { c, _ in
        if let e = one(c, date: "2026-11-20T10:00", rec: "once") { return e }
        let hostLeads = hostRules ? AssistantService.advanceNoticeMinutes(in: currentUserText) : []
        return (hostLeads.contains(1440) || creates(c)[0].leads.contains("1440")) ? nil : "lead \(creates(c)[0].leads)" },
    Case(text: "remind me to call mom tomorrow at 6pm") { c, _ in one(c, date: "2026-11-11T18:00", rec: "once") },
    Case(text: "este sábado a las 10 tengo dentista") { c, _ in one(c, date: "2026-11-14T10:00", rec: "once") },
    Case(text: "misa todos los domingos a las 8 de la mañana") { c, _ in one(c, date: "", rec: "weekly", days: ["sunday"]) },
]

if ProcessInfo.processInfo.environment["HARNESS_EVAL"] != nil {
    let trials = Int(ProcessInfo.processInfo.environment["HARNESS_TRIALS"] ?? "3") ?? 3
    var c0 = DateComponents(); c0.year = 2026; c0.month = 11; c0.day = 10; c0.hour = 18; c0.minute = 59
    let now0 = Calendar.current.date(from: c0)!
    var totalFail = 0, totalLang = 0, totalRepairs = 0, totalFallback = 0
    let only = ProcessInfo.processInfo.environment["HARNESS_ONLY"].map { Set($0.split(separator: ",").compactMap { Int($0) }) }
    for (idx, k) in cases.enumerated() where only?.contains(idx) ?? true {
        var fails: [String] = []
        for _ in 1...trials {
            let tools: [any Tool] = [
                makeCreateTool(sharedTurn),
                ListRemindersTool(modelContainer: .init()),
                SearchRemindersTool(modelContainer: .init()),
                UpdateReminderTool(modelContainer: .init(), scheduler: .init()),
                DeleteReminderTool(modelContainer: .init(), scheduler: .init()),
            ]
            currentUserText = k.text
            sharedTurn.begin(k.text)
            let lang = AssistantService.detectLanguage(of: k.text)
            let session = LanguageModelSession(model: .default, tools: tools, instructions: makeInstructions(now: now0, replyLanguage: baseline ? nil : lang))
            await MockLog.shared.resetConversation()
            let prompt = baseline ? k.text : AssistantService.normalizeTimeRanges(k.text)
            do {
                let start = session.transcript.endIndex
                var raw = try await session.respond(to: prompt).content
                var names = AssistantService.toolNames(in: session.transcript, since: start)
                var shown = AssistantService.displayText(raw)
                if !baseline, AssistantService.needsRepair(reply: raw, calledTools: names, previousTurnChangedAlarms: false) {
                    totalRepairs += 1
                    print("    [retry] first answer: \(raw)")
                    let kept = Transcript(entries: session.transcript[session.transcript.startIndex..<start])
                    let retry = LanguageModelSession(model: .default, tools: tools, transcript: kept)
                    let start2 = retry.transcript.endIndex
                    raw = try await retry.respond(to: AssistantService.retryPrompt(for: prompt)).content
                    names = AssistantService.toolNames(in: retry.transcript, since: start2)
                    if AssistantService.needsRepair(reply: raw, calledTools: names, previousTurnChangedAlarms: false) { totalFallback += 1; shown = "<FALLBACK>" } else { shown = AssistantService.displayText(raw) }
                }
                let calls = await MockLog.shared.calls.map { line -> Call in
                    let sp = line.split(separator: " ", maxSplits: 1)
                    return Call(tool: String(sp[0]), args: sp.count > 1 ? String(sp[1]) : "")
                }
                if let f = k.check(calls, shown) { fails.append(f) }
                if let l = lang, let got = AssistantService.detectLanguage(of: shown), got != l { totalLang += 1; fails.append("lang:\(got)") }
                if !AssistantService.didChangeAlarms(names) && AssistantService.claimsChange(shown) { fails.append("LIAR: \(shown)") }
            } catch { fails.append("error \(error)") }
        }
        totalFail += fails.filter { !$0.hasPrefix("lang:") }.count
        print("\(fails.filter { !$0.hasPrefix("lang:") }.isEmpty ? "PASS" : "FAIL") \(trials - fails.filter { !$0.hasPrefix("lang:") }.count)/\(trials)  \(k.text.prefix(55))\(fails.isEmpty ? "" : "  ← " + fails.joined(separator: " · "))")
    }
    print("TOTAL \(baseline ? "baseline" : "app") failures=\(totalFail)/\(cases.count * trials) wrongLang=\(totalLang) repairs=\(totalRepairs) fallbacks=\(totalFallback)")
    exit(0)
}

let trials = Int(ProcessInfo.processInfo.environment["HARNESS_TRIALS"] ?? "3") ?? 3
// Friend's report: Tuesday 2026-11-10, 18:59 in Lima.
var comps = DateComponents(); comps.year = 2026; comps.month = 11; comps.day = 10; comps.hour = 18; comps.minute = 59
let now = Calendar.current.date(from: comps)!

for conv in conversations {
    for t in 1...trials {
        print("\n===== \(conv.name) — trial \(t) =====")
        let tools: [any Tool] = [
            makeCreateTool(sharedTurn),
            ListRemindersTool(modelContainer: .init()),
            SearchRemindersTool(modelContainer: .init()),
            UpdateReminderTool(modelContainer: .init(), scheduler: .init()),
            DeleteReminderTool(modelContainer: .init(), scheduler: .init()),
        ]
        var session: LanguageModelSession? = nil
        var sessionLang: String? = nil
        var created = 0
        var leakedJSON = false
        var repairs = 0, fallbacks = 0, liar = 0, wrongLang = 0
        var replyLanguage: String? = nil
        var lastTurnChanged = false
        await MockLog.shared.resetConversation()
        for turn in conv.turns {
            await MockLog.shared.reset()
            print("USER: \(turn)")
            if let d = AssistantService.detectLanguage(of: turn) { replyLanguage = d }
            let prevChanged = lastTurnChanged
            lastTurnChanged = false
            do {
                // ensureSession(): create with the language, rebuild on a switch
                if let live = session {
                    if !baseline, let lang = replyLanguage, lang != sessionLang {
                        var entries = Array(live.transcript)
                        if case .instructions(var cur)? = entries.first {
                            cur.segments = [.text(Transcript.TextSegment(content: instructionsText(now: now, replyLanguage: lang)))]
                            entries[0] = .instructions(cur)
                        }
                        session = LanguageModelSession(model: .default, tools: tools, transcript: Transcript(entries: entries))
                        sessionLang = lang
                        print("  [language switch → \(lang)]")
                    }
                } else {
                    session = LanguageModelSession(model: .default, tools: tools, instructions: makeInstructions(now: now, replyLanguage: baseline ? nil : replyLanguage))
                    sessionLang = replyLanguage
                }
                var s = session!
                var start = s.transcript.endIndex
                sharedTurn.begin(turn)
                let modelInput = baseline ? turn : AssistantService.normalizeTimeRanges(turn)
                if modelInput != turn { print("  [normalized] \(modelInput)") }
                var raw = try await s.respond(to: modelInput).content
                var names = AssistantService.toolNames(in: s.transcript, since: start)
                var shown = AssistantService.displayText(raw)
                if !baseline, AssistantService.needsRepair(reply: raw, calledTools: names, previousTurnChangedAlarms: prevChanged) {
                    repairs += 1
                    print("  [RETRY] first answer: \(raw)")
                    s = LanguageModelSession(model: .default, tools: tools, transcript: Transcript(entries: s.transcript[s.transcript.startIndex..<start]))
                    session = s
                    start = s.transcript.endIndex
                    raw = try await s.respond(to: AssistantService.retryPrompt(for: modelInput)).content
                    names = AssistantService.toolNames(in: s.transcript, since: start)
                    if AssistantService.needsRepair(reply: raw, calledTools: names, previousTurnChangedAlarms: prevChanged) {
                        fallbacks += 1
                        print("  [FALLBACK] second answer: \(raw)")
                        shown = "<FALLBACK: No pude guardar ningún cambio…>"
                    } else {
                        shown = AssistantService.displayText(raw)
                    }
                }
                lastTurnChanged = AssistantService.didChangeAlarms(names)
                for c in await MockLog.shared.calls { print("  TOOL→ \(c)") }
                created += await MockLog.shared.calls.filter { $0.hasPrefix("create_reminder") }.count
                if raw.contains("{") || raw.contains("```") { leakedJSON = true }
                if !AssistantService.didChangeAlarms(names) && AssistantService.claimsChange(shown) && !prevChanged { liar += 1 }
                if let l = replyLanguage, let got = AssistantService.detectLanguage(of: shown), got != l { wrongLang += 1 }
                print("BOT: \(shown)")
            } catch {
                print("ERROR: \(error)")
            }
        }
        print("RESULT: created=\(created) leakedJSON=\(leakedJSON) repairs=\(repairs) fallbacks=\(fallbacks) liar=\(liar) wrongLang=\(wrongLang)")
    }
}
