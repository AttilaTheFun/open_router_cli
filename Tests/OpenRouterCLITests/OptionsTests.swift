// The command line: what is taken, what is refused, and what is taken but
// will not do what its name says — which the CLI says, not hides.

import Foundation
import Testing
@testable import openrouter

/// The command line Visor runs a headless session with, in its manual mode.
private let visorManual = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                           "--mcp-config", "{\"mcpServers\":{}}", "--permission-mode", "acceptEdits",
                           "--permission-prompt-tool", "mcp__visor__approve", "--model", "a/b", "--effort", "high", "--resume", "abc"]

@Test func aHostsCommandLineIsTaken() throws {
    let options = try Options(visorManual)
    #expect(options.command == nil)
    #expect(options.flags == ["p", "verbose", "include-partial-messages"])
    #expect(options.values["input-format"] == "stream-json")
    #expect(options.values["output-format"] == "stream-json")
    #expect(options.values["model"] == "a/b")
    #expect(options.values["effort"] == "high")
    #expect(options.values["resume"] == "abc")
    // Nothing was taken for a prompt.
    #expect(options.positional == [])
}

@Test func optionsThatWillNotDoWhatTheySayAreNoted() throws {
    #expect(try Options(visorManual).notes == [
        "--permission-mode acceptEdits is not enforced: openrouter has one mode, and in it tools run without asking.",
        "--permission-prompt-tool is not used: openrouter's tools run without asking, and mcp__visor__approve is never asked.",
        "--mcp-config is not used: openrouter does not connect to MCP servers, and the model is not offered their tools.",
    ])
    // The mode that is the truth needs no note, and neither do the two
    // switches that change nothing because nothing needs changing.
    #expect(try Options(["-p", "--permission-mode", "bypassPermissions", "--verbose", "--dangerously-skip-permissions"]).notes == [])
    #expect(try Options(["-p", "hello"]).notes == [])
    // No note has the word a host takes for a failure on stderr.
    #expect(try Options(visorManual).notes.allSatisfy { !$0.lowercased().contains("error") })
}

/// An option that is not known is refused, as Claude Code refuses one:
/// taken as a switch, whatever followed it would be read as the prompt.
@Test func unknownOptionsAreRefused() throws {
    #expect(throws: Options.BadOption(message: "--nonsense is not an option openrouter takes")) { try Options(["-p", "--nonsense", "hello"]) }
    #expect(throws: Options.BadOption(message: "--append-system-prompt is not an option openrouter takes")) {
        try Options(["-p", "--append-system-prompt", "Be terse", "fix it"])
    }
    #expect(throws: Options.BadOption(message: "--other is not an option openrouter takes")) { try Options(["--other=1"]) }
    #expect(throws: Options.BadOption(message: "--key is not an option openrouter takes")) { try Options(["auth", "login", "--key", "k"]) }
    #expect(throws: Options.BadOption(message: "-x is not an option openrouter takes")) { try Options(["-p", "-x", "hello"]) }
    // A switch takes no value.
    #expect(throws: Options.BadOption(message: "--include-partial-messages takes no value")) { try Options(["--include-partial-messages=true"]) }
}

/// What is not an option is the prompt, and after "--" everything is.
@Test func aPromptMayLookLikeAnything() throws {
    #expect(try Options(["-p", "- one", "-2", "-fix this"]).positional == ["- one", "-2", "-fix this"])
    let literal = try Options(["-p", "--", "--nonsense", "-x", "--model"])
    #expect(literal.positional == ["--nonsense", "-x", "--model"])
    #expect(literal.values == [:])
}

@Test func commandsShortOptionsAndEqualsForms() throws {
    let models = try Options(["models", "--free", "--tools", "--json"])
    #expect(models.command == "models")
    #expect(models.flags == ["free", "tools", "json"])
    #expect(try Options(["resume", "abc"]).positional == ["abc"])
    #expect(try Options(["-m", "x/y", "-h"]).values["model"] == "x/y")
    #expect(try Options(["-h"]).flags == ["help"])
    #expect(try Options(["--print", "--model=x/y", "hi"]).values == ["model": "x/y"])
    #expect(try Options(["--print", "--model=x/y", "hi"]).flags == ["p"])
    // A word that is a command only leads; later it is a prompt's word.
    #expect(try Options(["-p", "models"]).command == nil)
}

@Test func anOptionWithoutItsValueOrWithABadOneIsRefused() throws {
    #expect(throws: Options.BadOption(message: "--model needs a value")) { try Options(["-p", "--model"]) }
    #expect(throws: Options.BadOption(message: "--resume needs a value")) { try Options(["--resume"]) }
    #expect(throws: Options.BadOption(message: "-m needs a value")) { try Options(["-p", "-m"]) }
    // The two formats there are; Claude Code's `json` is not one of them.
    #expect(try Options(["--output-format", "text", "--input-format=stream-json"]).values == ["output-format": "text", "input-format": "stream-json"])
    #expect(throws: Options.BadOption(message: "--output-format is text or stream-json, not \"json\"")) { try Options(["-p", "--output-format", "json"]) }
    #expect(throws: Options.BadOption(message: "--input-format is text or stream-json, not \"xml\"")) { try Options(["-p", "--input-format=xml"]) }
    #expect(try Options(["--max-turns", "3"]).maxTurns == 3)
    #expect(try Options(["-p"]).maxTurns == nil)
    for bad in ["0", "-1", "many", "1.5", ""] {
        #expect(throws: Options.BadOption(message: "--max-turns takes a number above zero, not \"\(bad)\"")) { try Options(["--max-turns", bad]) }
    }
}
