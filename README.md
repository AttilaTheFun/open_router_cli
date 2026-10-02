# open_router_cli

A Swift package for [OpenRouter](https://openrouter.ai): a library and a
coding-agent CLI.

- **OpenRouterKit** — the library. The API client (models, streamed chat
  completions with tool calls), the agent loop (`ORAgent`) with pluggable
  tools, the coding tools (`CodingTools.standard(cwd:)`: bash, read_file,
  write_file, edit_file, list_directory), sessions on disk
  (`ORSessionStore`), the config (`ORConfig`), and Claude Code's
  stream-json protocol (`StreamJSON`). A host can embed it as a Swift
  package, without the CLI. macOS 15 or later only: the bash tool runs a
  process, and the config and the sessions live in the user's home
  folder.
- **openrouter** — the CLI: a coding agent in the terminal, and a headless
  mode that speaks Claude Code's stream-json protocol, so anything that
  drives `claude -p` drives `openrouter -p` the same way.

## Setup

    swift build -c release
    cp .build/release/openrouter ~/.local/bin/      # or anywhere on PATH
    openrouter auth login                            # or export OPENROUTER_API_KEY=sk-or-…

The key lives in `~/.openrouter/config.json` (owner-only) or the
environment (`OPENROUTER_API_KEY`, `OPEN_ROUTER_API_KEY`, which win over
the file); `model` in the same file is the default model.
`OPENROUTER_HOME` moves the folder. `openrouter auth login` asks
OpenRouter whether it knows the key before keeping it.

## Use

    openrouter                                  chat in this folder, with tools
    openrouter --model qwen/qwen3.8-27b:free    a model (`openrouter models --free --tools` lists free ones)
    openrouter models --refresh                 fetch the model list with prices into ~/.openrouter/models.json
    openrouter resume <id>                      carry a session on (`openrouter sessions` lists them)
    openrouter -p "what does this repo do?"     one turn, headless
    openrouter -p --input-format stream-json --output-format stream-json --include-partial-messages [--resume <id>]
                                                Claude Code's protocol on stdin/stdout (what Visor runs)
    openrouter --help                           every command and option

### Claude Code's options

A host that drives `claude -p` passes it options, and `openrouter` takes
the same command line. What each does here:

| Option | Here |
| --- | --- |
| `-p`, `--model`, `--effort`, `--resume` | As in Claude Code. |
| `--input-format`, `--output-format` | `text` or `stream-json`, as in Claude Code. |
| `--session-id ID` | The id a new session gets. Refused when a session has that id already (that is `--resume`). |
| `--include-partial-messages` | As in Claude Code: with stream-json output, the reply's text as it is written (`stream_event` lines). Without it only whole messages are printed. |
| `--max-turns N` | The rounds of tool calls a turn may take (default 24); a turn that uses them all ends with an `error_max_turns` result. |
| `--permission-mode`, `--permission-prompt-tool` | **Taken and not acted on.** openrouter has one mode: its tools run without asking, and nothing is ever sent to a permission prompt tool. The `init` line says `"permissionMode":"bypassPermissions"` whatever was asked, and a mode other than that is noted on stderr. A host's "ask first" setting does not hold for an openrouter session. |
| `--mcp-config` | **Taken and not acted on.** openrouter does not connect to MCP servers; the model has the coding tools and no others (`"mcp_servers":[]` in the `init` line). Noted on stderr. |
| `--verbose`, `--dangerously-skip-permissions` | Taken; nothing to change (stream-json output is always whole, and tools already run without asking). |
| anything else | Refused (exit 2), as Claude Code refuses an option it does not know: `--output-format json`, an option openrouter does not take, one that needs a value and has none. A host that passes a new option needs an openrouter that takes it. |

Headless, a turn ends with a `result` line. Every `control_request` on
stdin is answered with a `control_response`: an interrupt with `success`,
any other with an `error` (openrouter takes no other). An interrupt stops
the turn in flight: the reply being written is dropped, a running command is killed,
the tools not yet run are not run, and the turn ends with an error result
("Interrupted", `error_during_execution`), as Claude Code's does; the
session is saved with every tool call answered, so it carries on from
there. A reply that fails part-way, ends before the model finished, or is
cut off at the model's output limit also ends the turn with an error
result, which says which. `openrouter -p PROMPT` exits 1 when its one turn
fails.

The model list (ids, names, prices per token, tool support) is kept in
`~/.openrouter/models.json`: `openrouter models` fetches it afresh, and a
headless run fetches it when what is there is more than a day old. It
needs no key (the list is public). Visor's model picker reads the file.

Sessions are kept in `~/.openrouter/sessions/<id>.json` — the messages,
the folder, the model — with a log beside each, `<id>.jsonl`: a line per
message (`{"id", "timestamp", "message"}`), appended as the message
lands, for a host to follow. An assistant message has one id, in the
stream-json lines (`message_start`, `assistant`) and on its log line; a
tool call has one id, on its `tool_use` block, its `tool_result`, and in
the log's `tool_calls` and `tool_call_id`. Sessions are resumed by id (up
to 128 letters, digits, `-`, `_` and `.`, starting with a letter or
digit; anything else is refused), and a resumed session works in the
folder it was working in unless `--cwd` names another. A turn whose
session cannot be written to disk ends with an error that says so.

Tools run without asking. The file tools reach only inside the session's
folder, but bash runs whatever the model writes, as you: keep the agent in
a folder you are happy for it to change, on a computer you are happy for
it to use.

## Tests

    swift build -Xswiftc -warnings-as-errors && swift test -Xswiftc -warnings-as-errors

Warnings are errors, as CI builds it. The tests run against a mock
transport and spend no API credit.

## License

Apache 2.0; see LICENSE.
