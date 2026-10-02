# open_router_cli, for agents

Read README.md for the parts: OpenRouterKit (the library) and `openrouter`
(the CLI built on it). Warnings are errors, as CI builds it:

    swift build -Xswiftc -warnings-as-errors && swift test -Xswiftc -warnings-as-errors

## Changes

This repo is public. Every change to `main` goes through a pull request:
`main` is protected, direct pushes are rejected, and the CI check (the
tests) must pass before a pull request can merge. Keep each pull request
to one focused change, and say in it how the change was verified.

## Rules

- The library stays usable without the CLI (hosts embed it); the CLI's
  stream-json output stays compatible with Claude Code's, which hosts such
  as Visor drive unchanged.
- The CLI's configuration (key, default model) is its own: hosts never
  pass keys in.
- Never spend real API credit in tests: the tests run against a mock
  transport, in home folders of their own (`OPENROUTER_HOME`).
- The same when running the built CLI by hand: unset `OPENROUTER_API_KEY`
  and `OPEN_ROUTER_API_KEY` and point `OPENROUTER_HOME` at a scratch
  folder first. Without that it reads the real key from `~/.openrouter`,
  and a turn is a paid request and a session left in the real folder.
- An option a host passes must be one `Options.swift` knows: an unknown
  option is refused. The ones Visor passes are in README.md's table and
  in `OptionsTests.swift`; add an option there before a host sends it.
- No warnings: CI passes `-warnings-as-errors` on the command line. The
  flag stays out of Package.swift (no `unsafeFlags`), since hosts embed
  the library.
