# open_router_cli, for agents

Read README.md for the parts: OpenRouterKit (the library) and `openrouter`
(the CLI built on it). `swift build && swift test` builds and tests both.

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
  transport.
