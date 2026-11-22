# Documentation

Seal Harness is a security-first runtime for AI agents. Every agent action is a
typed opcode with a schema, a trust classification, and an authorization gate,
and the append-only transcript is the record of everything that happened.

## Start here

- **[Getting started](getting-started.md)** — from a fresh install to a working
  session: the two-step setup wizard, adding a GitHub token to the vault,
  registering a repo, adding a chat channel, and browsing a session's files.

- **[Sessions and working directories](sessions-and-workdirs.md)** — the model
  behind the files: one fresh, isolated workdir per session, why it persists, and
  why branching a conversation does not branch its files.

## Elsewhere

- **[Web access control](https://github.com/seal-harness/seal-harness/blob/main/docs/web-access-control.md)**
  — passkeys, TLS, and reaching the gateway from another machine.
- **[README](https://github.com/seal-harness/seal-harness#readme)** — the full
  feature surface, the opcode catalog, and how to build from source.
