# open_router_cli

A Swift package for [OpenRouter](https://openrouter.ai): a library and a
coding-agent CLI.

- **OpenRouterKit** — the library. The API client (models, streamed chat
  completions with tool calls), the agent loop (`ORAgent`) with pluggable
  tools, the coding tools (`CodingTools.standard(cwd:)`: bash, read_file,
  write_file, edit_file, list_directory), sessions on disk
  (`ORSessionStore`), the config (`ORConfig`), and Claude Code's
  stream-json protocol (`StreamJSON`). Shared by Visor and the Universal
  UI Playground through rules_swift_package_manager.
- **openrouter** — the CLI: a coding agent in the terminal, and a headless
  mode that speaks Claude Code's stream-json protocol, so anything that
  drives `claude -p` drives `openrouter -p` the same way.

## Setup

    swift build -c release
    cp .build/release/openrouter ~/.local/bin/      # or anywhere on PATH
    openrouter auth login                            # or export OPENROUTER_API_KEY=sk-or-…

The key lives in `~/.openrouter/config.json` (owner-only) or the
environment (`OPENROUTER_API_KEY`, `OPEN_ROUTER_API_KEY`); `model` in the
same file is the default model. `OPENROUTER_HOME` moves the folder.

## Use

    openrouter                                  chat in this folder, with tools
    openrouter --model qwen/qwen3.8-27b:free    a model (`openrouter models --free --tools` lists free ones)
    openrouter models --refresh                 fetch the model list with prices into ~/.openrouter/models.json
    openrouter resume <id>                      carry a session on (`openrouter sessions` lists them)
    openrouter -p "what does this repo do?"     one turn, headless
    openrouter -p --input-format stream-json --output-format stream-json --include-partial-messages [--resume <id>]
                                                Claude Code's protocol on stdin/stdout (what Visor runs)

The model list (ids, names, prices per token, tool support) is kept in
`~/.openrouter/models.json` and refreshed when older than a day, by
`openrouter models` or any headless run; Visor's model picker reads it.

Sessions are kept in `~/.openrouter/sessions/<id>.json` — the messages,
the folder, the model — and resumed by id. Tools run without asking; keep
the agent in a folder you are happy for it to change.

## Tests

    swift test

## License

Apache 2.0; see LICENSE.
