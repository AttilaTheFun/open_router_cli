// The command line: what is taken, what is refused, and what is taken but
// will not do what its name says — which the CLI says, not hides.

import Foundation
import Testing
import OpenRouterKit
import TestSupport
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
    // Nothing was taken for a prompt, and nothing is unknown.
    #expect(options.positional == [])
    #expect(options.unknown == [])
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
    #expect(try Options(visorManual + ["--nonsense"]).notes.allSatisfy { !$0.lowercased().contains("error") })
}

@Test func unknownOptionsAreIgnoredAndSaid() throws {
    let options = try Options(["-p", "--nonsense", "--other=1", "hello", "there"])
    #expect(options.unknown == ["--nonsense", "--other"])
    #expect(options.positional == ["hello", "there"])
    #expect(options.notes == ["--nonsense is not an option openrouter knows; it is ignored.",
                              "--other is not an option openrouter knows; it is ignored."])
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
    #expect(try Options(["--max-turns", "3"]).maxTurns == 3)
    #expect(try Options(["-p"]).maxTurns == nil)
    for bad in ["0", "-1", "many", "1.5", ""] {
        #expect(throws: Options.BadOption(message: "--max-turns takes a number above zero, not \"\(bad)\"")) { try Options(["--max-turns", bad]) }
    }
}
