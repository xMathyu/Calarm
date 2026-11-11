"""Builds a runnable harness from the REAL AssistantService/AssistantTools sources,
so the prompt and tool schemas under test never diverge from the app.

usage: gen.py <source root> <out.swift> <driver.swift> [<service with helpers>]
The optional 4th argument supplies the AssistantService helpers the driver needs
when <source root> is an older checkout that doesn't have them yet."""
import re, sys, pathlib
repo = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
driver = pathlib.Path(sys.argv[3]).read_text()
svc = (repo / "Calarm/Chat/AssistantService.swift").read_text().splitlines()
tools = (repo / "Calarm/Chat/AssistantTools.swift").read_text().splitlines()

# --- instructions: everything after `let now = Date()` up to the closing quotes
start = next(i for i, l in enumerate(svc) if "let now = Date()" in l) + 1
new_style = any("func instructionsText(replyLanguage" in l for l in svc)
if new_style:
    instr_open = next(i for i in range(start, len(svc)) if svc[i].strip() == 'return """')
    end = next(i for i in range(instr_open + 1, len(svc)) if svc[i].strip() == '"""')
    instr_code = "\n".join(svc[start:end + 1])
else:
    instr_open = next(i for i in range(start, len(svc)) if "Instructions(\"\"\"" in svc[i])
    end = next(i for i in range(instr_open, len(svc)) if svc[i].strip() == '""")')
    instr_code = "\n".join(svc[start:end + 1])

# --- nonisolated static helpers of AssistantService (prompt builders)
helper_svc = pathlib.Path(sys.argv[4]).read_text().splitlines() if len(sys.argv) > 4 else svc
helpers = []
i = 0
while i < len(helper_svc):
    if re.match(r"    nonisolated static let ", helper_svc[i]):
        helpers.append(helper_svc[i])
    elif re.match(r"    nonisolated static func ", helper_svc[i]):
        j = next(k for k in range(i, len(helper_svc)) if helper_svc[k] == "    }")
        helpers.append("\n".join(helper_svc[i:j + 1]))
        i = j
    i += 1
helper_src = "enum AssistantService {\n" + "\n".join(helpers) + "\n}\n"

# --- tools: struct header .. line before `@MainActor\n func call`
tool_src = []
i = 0
while i < len(tools):
    m = re.match(r"struct (\w+Tool): Tool \{", tools[i])
    if m:
        name = m.group(1)
        j = next(k for k in range(i, len(tools)) if "func call(arguments" in tools[k])
        body = tools[i:j - 1] if tools[j - 1].strip() == "@MainActor" else tools[i:j]
        tool_src.append("\n".join(body) + f"""
    func call(arguments: Arguments) async throws -> String {{
        return await MockLog.shared.handle(tool: name, args: "\\(arguments)")
    }}
}}
""")
        i = j
    i += 1

stubs = '''
import FoundationModels
import Foundation
import NaturalLanguage
struct ModelContainer {}
final class AssistantTurnContext: @unchecked Sendable { var userText = ""; var createdThisTurn: [UUID] = []; func begin(_ text: String) { userText = text; createdThisTurn = [] } }
struct ReminderScheduler {}
struct StubCat { var name: String }
final class CategoryStore: @unchecked Sendable { nonisolated(unsafe) static var shared: CategoryStore? = nil; var customCategories: [StubCat] = [] }
final class LocalizationManager: @unchecked Sendable { nonisolated(unsafe) static let shared = LocalizationManager(); var currentLocale = Locale(identifier: ProcessInfo.processInfo.environment["HARNESS_LOCALE"] ?? "en_US") }
'''
if new_style:
    fn = helper_src + "func instructionsText(now: Date, replyLanguage: String?) -> String {\n" + instr_code.replace("Self.", "AssistantService.") + "\n}\nfunc makeInstructions(now: Date, replyLanguage: String? = nil) -> Instructions { Instructions(instructionsText(now: now, replyLanguage: replyLanguage)) }\n"
else:
    fn = helper_src + "func makeInstructions(now: Date, replyLanguage: String? = nil) -> Instructions {\n" + instr_code.replace("Self.", "AssistantService.") + "\n        return instructions\n}\nfunc instructionsText(now: Date, replyLanguage: String?) -> String { \"\" }\n"
has_turn = any("let turn: AssistantTurnContext" in t for t in tool_src)
fn += "func makeCreateTool(_ turn: AssistantTurnContext) -> CreateReminderTool { CreateReminderTool(modelContainer: .init(), scheduler: .init()" + (", turn: turn" if has_turn else "") + ") }\n"
out.write_text(stubs + "\n" + "\n".join(tool_src) + "\n" + fn + "\n" + driver)
print("ok", len(tool_src), "tools")
