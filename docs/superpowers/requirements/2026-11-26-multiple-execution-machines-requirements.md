# Multiple Execution Machines — Requirements

**Status**: approved (2026-11-26, operator) — frozen. Changes require a scope
change request, not a review fix.
**Branch**: `feature/multiple-execution-machines`

**Amendments** (operator-approved 2026-11-27, recorded after design review
found two renders unimplementable as written):

1. The TUI machine prompt drops platform labels. The `(linux, default)` /
   `(macos)` annotations have no data source — `machines.toml` defines no `os`
   field. The prompt shows `(default)` and `(this machine)` only.
2. The session-list entry drops the `ai` kind token: `2  seal-harness  mac-mini`.
   No renderer in the harness emits a bare `ai` token (`TabKind` derives `show`,
   yielding `KindAi`), and the example carried one column more than the tab line
   it was illustrating.

**Scope**: Let an operator define several named execution machines, choose one
per session, and let the model choose one per tool call.

> **What this document is.** The operator's review surface: complete
> user-facing behaviour, nothing else. ~2 minutes to review.

---

## Behaviour

### Configuration

Execution machines are declared in a new file, `~/.seal/machines.toml`. It is a
sibling of `security.toml`, holds the same protection (mode `0600`, no opcode or
agent may read or write it, not inside the git-versioned `config/` tree), and is
written once on first run from a template and never overwritten.

```toml
default = "linux-builder"

[machines.linux-builder]
host        = "builder.example.com"
user        = "seal"
port        = 22
identity    = "/home/you/.ssh/id_ed25519"
workspace   = "/srv/seal/workspace"

[machines.mac-mini]
host        = "mac-mini.lan"
user        = "zoe"
workspace   = "/Users/zoe/seal-workspace"
```

- `default` names the machine used when the user does not choose one.
- Machine names are the keys; they are what the user types and what the model
  passes. Names are validated (no leading dash, no spaces, no control
  characters).
- `host`, `user` and `workspace` are required; `port` defaults to 22 and
  `identity` is optional. A machine missing a required field is listed as
  unusable, with the reason, and refused rather than silently attempted.
- **`local` is an implicit machine.** It is always present in the machine list
  and is not declared in the file. It names execution on the harness machine
  itself, and it is only selectable when `allow_localhost = true`.

### Host keys are pinned by the harness, not by the config

There is no `known_hosts` field. Every machine is pinned against one
harness-owned file, `~/.seal/exec-known-hosts`, which Seal populates itself:

- On first connection to a machine, Seal probes its host key and asks the human
  to confirm the host, key type and fingerprint. On approval the key is recorded
  in `~/.seal/exec-known-hosts`; on refusal the machine is refused.
- Afterwards the recorded key is required. A machine whose key has **changed** is
  refused outright — that is a possible interception, and re-adoption is never
  offered.
- Where no human is present to confirm (chat channels, unattended runs), an
  unknown key is refused rather than adopted. The machine is pinned from an
  interactive session first.
- A machine may be pre-pinned non-interactively by supplying its key, for
  scripted installs.

This is the same file the harness already uses for adopted keys, so a key
confirmed once is trusted for every session. It also means the operator never
hand-maintains a `known_hosts` path, and the file stays in harness-owned state
that no agent can reach.

### `allow_localhost` replaces `mode`

`~/.seal/security.toml` gains `allow_localhost` (default `true`) and loses
`[untrusted_execution] mode`.

- `allow_localhost = true` — `local` is a selectable machine. This is today's
  `mode = "local"` behaviour, and the default, so upgrading changes nothing.
- `allow_localhost = false` — `local` is not a selectable machine. It does not
  appear in the machine list, and neither the user nor the model can name it.
  This is today's `mode = "remote"` behaviour.
- The existing `[untrusted_execution.remote]` table is moved into
  `machines.toml` as a machine named `default`, on the first boot after upgrade,
  and removed from `security.toml` once the new copy is written. Its
  `known_hosts` value is dropped; its host key is re-confirmed into
  `~/.seal/exec-known-hosts` on first connection. An existing
  `mode = "remote"` becomes `allow_localhost = false`; an absent or
  `mode = "local"` becomes `allow_localhost = true`.
- The `-f remote-only-untrusted` build requires `allow_localhost = false` and
  refuses to start otherwise. It still physically lacks the local executor.
- An install with none of these files keeps working exactly as it does today.

### A "remote" machine may not be this machine

A machine configured with a host that is really the harness machine would defeat
the two-plane split, so such a machine is refused:

- A machine `host` of `localhost`, `127.0.0.1`, `::1` (and the equivalent
  loopback forms) is rejected at config load, with an error naming the machine.
- Independently, when connecting, if the machine presents a host key identical
  to the harness machine's own SSH host key, the connection is refused. This
  catches a non-loopback name or address that still resolves to this machine.

Neither refusal ever falls back to another machine or to `local`.

### Choosing a machine at session start

- **TUI** — starting a session prompts for a machine when more than one is
  selectable, listing the names and marking the default. Enter with no input
  takes the default. With exactly one selectable machine there is no prompt.
- **Web** — the new-tab form gains a machine picker, pre-selected to the
  default, shown only when more than one machine is selectable.
- **Chat channels** (Telegram, Signal) — no interactive prompt; the configured
  default is used.
- **`/new`** — accepts `-x`/`--machine` to override the default for that
  session.
- The chosen machine is recorded in `session.json` and shown on the session
  (sidebar / session list).
- Resuming a session uses the machine recorded for it, not the current default.
- A session whose recorded machine no longer exists, or is no longer usable,
  fails with an error naming it. It does not fall back to `default`.

### Choosing a machine per tool call

- Every untrusted opcode (`SHELL_EXEC`, `BIN_EXEC`, `FILE_READ`, `FILE_WRITE`,
  `FILE_PATCH`, `SEARCH_FILES`, `PROCESS_MANAGE`, `SETUP_REPO`) accepts an
  optional `machine` argument naming a selectable machine.
- The model sees the selectable machine names in its tool catalog and can pick a
  different machine per call, which is what lets it act on more than one
  operating system in one session.
- Selection is **not sticky**: every call resolves independently. Omitting
  `machine` always uses the session's machine.
- An unknown or unusable machine name is a tool error naming the valid choices;
  it never falls back to another machine.

### Precedence

Per-call `machine` (from the model) overrides the session's machine. The
session's machine overrides `default` in `machines.toml`. `allow_localhost`
gates whether `local` is selectable at all, above all three.

---

## What the user sees

Choosing at session start:

```text
execution machine [default: linux-builder]:
  1. local          (this machine)
  2. linux-builder  (linux, default)
  3. mac-mini       (macos)
> 3
session: anthropic / claude-opus-4-8  machine: mac-mini
```

Confirming a host key on first connection:

```text
machine "mac-mini" is not yet known.
  host: mac-mini.lan
  key:  ssh-ed25519 SHA256:9xQ…7fA
Trust this key? [y/N] y
```

A session list entry:

```text
2  seal-harness  mac-mini
```

The model choosing a machine mid-session, visible as the call argument:

```text
SHELL_EXEC  {"command": "sw_vers", "machine": "mac-mini"}
```

An unknown machine:

```text
SHELL_EXEC failed: unknown execution machine "macbook". Selectable machines:
local, linux-builder, mac-mini.
```

A configured but unusable machine:

```text
SHELL_EXEC failed: execution machine "mac-mini" is unusable: workspace not
configured. Fix it in ~/.seal/machines.toml.
```

A machine whose host key changed:

```text
SHELL_EXEC failed: host key for "mac-mini" does not match the key recorded in
~/.seal/exec-known-hosts. This can mean the machine was rebuilt, or that
something is intercepting the connection. Seal will not connect. If the machine
was rebuilt, remove its entry from that file and confirm the new key.
```

A machine that is this machine:

```text
machines.toml: machine "builder" is unusable: host "localhost" is this machine.
A remote execution machine must be a separate machine.
```

A deleted session machine:

```text
SHELL_EXEC failed: this session runs on execution machine "mac-mini", which is
no longer configured. Resuming it on another machine would run its work
somewhere it never ran. Add "mac-mini" back to ~/.seal/machines.toml, or start a
new session.
```

No machines configured while `allow_localhost = false`:

```text
SHELL_EXEC failed: allow_localhost is false and no execution machine is
configured. Add one under [machines.<name>] in ~/.seal/machines.toml.
```

---

## Constraints

- The model can never name a host, address, key, or path. It chooses from the
  selectable machine names; SSH coordinates always come from `machines.toml`.
- `allow_localhost = false` still means no untrusted opcode runs on the harness
  machine, and the `-f remote-only-untrusted` build still physically cannot run
  one locally. Neither is weakened by adding machine selection.
- Selection is never inferred. There is no automatic choice, no load balancing,
  and no retry on a different machine.
- Fail-closed is per machine and preserved: an unreachable or misconfigured
  machine errors out. It never falls back to another machine, and never to
  `local`.
- ACK-before-execute is unchanged: the invocation is durably recorded before any
  machine executes it, and the record names the machine that was asked for. The
  record carries the machine name and nothing else about it.
- Host-key pinning is unchanged in strength and now uniform: one
  harness-owned file, strict checking always on, a changed key is a hard failure
  that is never bypassed.
- An agent never reads or writes `machines.toml`, `security.toml`, or
  `~/.seal/exec-known-hosts`.
- A session never migrates between machines.

---

## Out of scope

- **Syncing files between machines.** Each machine has its own workspace.
  `SETUP_REPO` clones into one machine; the same relative path on another
  machine is a different file, or absent. Copying, mirroring or caching a
  workspace across machines is not part of this change.
- **Machine management UI.** Adding, editing and removing machines stays
  hand-edited TOML for now. Web CRUD — including Seal retrieving and confirming
  a host key when the operator adds a machine — is a follow-on; this change only
  lays down the single pinned file such a UI would write to.
- **Non-SSH machines.** Containers and VMs on the harness kernel remain
  unsupported as configured machines — only `local` (the harness itself) and
  SSH-reached machines are selectable.
- **Per-machine agent/skill/memory state.** Those stay on the control plane.
- **Machine health checking / pre-flight probing.** Reachability is discovered
  on first use.
- **Making opcodes that do not use SSH selectable by machine.** See the note
  below.

---

## Done when

1. `machines.toml` declares several machines; `seal` boots and lists them,
   including the implicit `local`.
2. An install with `[untrusted_execution.remote]` in `security.toml` boots and
   finds those coordinates as a machine named `default` in `machines.toml`, with
   the old block gone, `mode = "remote"` became `allow_localhost = false`, and
   the machine pinned against `~/.seal/exec-known-hosts`.
3. An install with no `[untrusted_execution]` gets `allow_localhost = true` and
   behaves as it does today.
4. With `allow_localhost = false`, `local` is absent from the list and cannot be
   selected by the user or the model.
5. A machine with a loopback `host`, or one presenting the harness's own host
   key, is refused with an error naming it.
6. An unknown host key prompts once interactively and is refused without a
   prompt when no human is present; a changed host key is refused outright.
7. Starting a TUI session with 2+ selectable machines prompts for one and uses
   the default on empty input; with one machine it does not prompt.
8. Starting a web session offers the machine picker, defaulted, when 2+
   machines are selectable.
9. A session started on machine A keeps using A when resumed, even after
   `default` changes to B.
10. A session whose recorded machine was deleted fails with an error naming it,
    and does not fall back to `default`.
11. A tool call naming `machine = "<selectable>"` runs on that machine, and a
    second call naming a different machine runs on that one, in the same
    session.
12. A tool call omitting `machine` runs on the session's machine, every time
    (no stickiness from a previous call).
13. A tool call naming an unknown machine fails with an error listing the
    selectable names, and runs nothing anywhere.
14. The transcript entry for an untrusted call records the machine name.
15. `make check` passes, including `-f remote-only-untrusted`.

---

## Notes for the design phase

Not requirements — facts the design should not have to rediscover.

- Today one `SshConfig` is resolved at boot from `security.toml`, and
  `mkSessionExec` builds a single `SessionExec` (`UIOEnv` + `WorkdirFs` +
  `WorkspaceRoot`) from it. `Seal.Session.ExecCache` memoizes that one value per
  session, keyed by a `Show`-based fingerprint of the exec config.
- Untrusted opcodes deliberately never see the backend: they call `uio*`
  functions (`Seal.Tools.Exec.UIO`) that read one `UntrustedIO` from a
  `ReaderT` environment. This change makes the backend a per-call choice, so
  that seam is the one that moves.
- `Seal.Tools.Exec.Untrusted.selectExecBackend` / `selectUntrustedBackend` are
  the existing pure selectors and already fail closed per config.
  `enforceRemoteOnly` is the `-f remote-only-untrusted` startup check, which
  becomes the `allow_localhost` check.
- `Seal.Tools.Exec.HostKeyAdoption` already implements probe → human
  confirmation → append-to-file, and already documents
  `~/.seal/exec-known-hosts` as its target; today the path is supplied per
  machine via `scKnownHosts`, and `ssh -o UserKnownHostsFile=` is wired in
  `Seal.Tools.Exec.Remote` and `Seal.Session.AgentMetaCache`. Making the path
  harness-derived rather than config-supplied is the change.
- The per-session workdir is created once per session: locally at
  `~/.seal/cache/workdirs/<sid>`, remotely at `<workspace>/workdirs/<sid>`.
  With N machines it must be created per machine, per session.
- `Seal.Session.Meta.SessionMeta` is the `session.json` record; a machine field
  belongs there, tolerant on decode like the other optional fields.
- `Seal.Config.Migrate` already implements the idempotent, strip-only-after-
  successful-write, fail-open migration pattern this change needs.
- `Seal.Config.Templates` seeds the config files from embedded templates with a
  never-overwrite invariant.
- **Pre-existing, not introduced here:** `WEB_FETCH` and `WEB_SEARCH` are
  labelled Untrusted but run in-process on the control plane (an `http-client`
  `Manager`, via `uioLiftIO`), so they never traverse SSH today, in either mode.
  They are therefore not machine-selectable under this change. Whether that is
  the intended posture for egress is a separate question and should not be
  settled by this feature.
