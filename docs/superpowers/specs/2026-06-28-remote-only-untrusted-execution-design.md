# Remote-Only Untrusted Execution — Design

> **Status:** Approved design. Implementation lands primarily in Phase 4 of the
> roadmap (`2026-06-28-seal-harness-roadmap.md`), built on the `TerminalBackend`
> tool-call-execution seam. This spec is the source of truth for the feature;
> the roadmap carries the phasing and the two new global invariants.

## 1. Problem & goal

Seal Harness must let an operator configure the system so that it is
**guaranteed** that no untrusted tool call ever executes on the harness machine —
every untrusted action runs on a separate remote machine reached over SSH. This
is a first-class security posture, not a convenience: the machine that holds the
secret vault and the append-only audit log must never also be the machine that
runs agent-driven shell commands, file writes, web fetches, or code execution.

The guarantee is offered in two strengths: a fail-closed runtime configuration
(default builds) and a hardened build that physically omits the local untrusted
executor from the binary (compile-time).

## 2. Threat model & the two-plane split

Execution is split into two planes:

- **Control plane** — the harness machine. Holds the agent loop, ISA dispatch,
  the transcript (audit log), the secret vault, and runs all **Trusted** and
  **Audited** opcodes. Never runs untrusted, agent-driven commands.
- **Untrusted plane** — a separate machine reached over SSH. Runs **all
  Untrusted opcodes** (Execution, Files, Web & Browser, Media). The agent's
  workspace (its files) lives here.

```
Control plane (harness machine)            Untrusted plane (remote, via SSH)
┌──────────────────────────────┐          ┌──────────────────────────────┐
│ agent loop, ISA dispatch      │  SSH     │ SHELL_EXEC, CODE_EXEC,         │
│ transcript (append-only audit)│ ───────▶ │ PROCESS_MANAGE                 │
│ secret vault (age)            │          │ FILE_READ/WRITE/SEARCH/PATCH   │
│ Trusted + Audited opcodes     │          │   (workspace lives here)       │
│ NO untrusted execution        │          │ WEB_*, BROWSER_*, media        │
└──────────────────────────────┘          │   (egress originates here)     │
                                           └──────────────────────────────┘
```

**Guarantee:** in remote-only configuration, no Untrusted opcode can execute on
the control-plane machine. A full compromise of the untrusted plane cannot read
the vault or rewrite the audit log, because neither ever leaves the control
plane. The transcript is written and fsync'd locally *before* any remote
dispatch (ACK-before-execute), so the record of an untrusted action always lives
on the trusted machine, never on the machine that performed it.

**Sharpening — local isolation does not count.** "Remote via SSH" means a
*genuinely separate machine*. A local container or VM runs on the harness
kernel and therefore does **not** satisfy "no untrusted execution on the harness
machine." In remote-only mode the set of allowed execution backends is
restricted to SSH-to-remote only; `Local` and local `Container` backends are
excluded from selection.

## 3. Enforcement — two layers

### Layer A — runtime, fail-closed (default builds)

A configuration setting selects where untrusted opcodes run:

```toml
[untrusted_execution]
mode = "remote"          # "local" (default) | "remote"
```

When `mode = "remote"`:

- Untrusted dispatch resolves **only** to an SSH backend. The backend-selection
  function never yields a `Local` (or local-container) target for an untrusted
  opcode.
- **Fail-closed.** If no usable SSH backend is available at call time (none
  configured, unreachable, auth failure, or host-key mismatch), the opcode
  returns a structured error, the attempt is recorded in the transcript, and the
  agent can surface it via `ASK_HUMAN`. It **never** falls back to local
  execution.
- **Boot always succeeds.** The control plane comes up even with zero remote
  backends configured or an unreachable remote — so the agent can still chat,
  ask the human, and use Trusted/Audited opcodes. Untrusted opcodes simply fail
  closed at call time until a remote is reachable.

### Layer B — compile-time, artifact-level (hardened builds)

A Cabal flag produces a binary that *cannot* run untrusted code locally because
the code to do so is not present:

```bash
cabal build -f remote-only-untrusted
```

When the flag is on:

- The local untrusted-executor module (`Seal.Tools.Exec.Local`) is excluded from
  `other-modules` / CPP-gated out. It is not compiled and not linked.
- The untrusted dispatch path is wired solely to the SSH executor
  (`Seal.Tools.Exec.Remote`).
- The `untrusted_execution.mode` setting is forced to `remote` (a `local`
  value is rejected at startup as a configuration error) — but the remote
  backend coordinates are still read and validated from config.
- Trusted/Audited local execution is unaffected.

This converts a checked runtime invariant ("we verify a flag before running
locally" — which can have bugs or be flipped by compromised config) into an
**artifact property**: the capability to run untrusted code on the control plane
does not exist in the binary. This is the meaningful security improvement over a
runtime-only toggle, and it is feasible without a pure type-level scheme (which
the architecture's existential CLI-wiring boundary would otherwise erase).

## 4. Types & modules

The feature builds on the `TerminalBackend` family (the tool-call-execution
backend introduced in Phase 4: `Local | Tmux | Ssh | Container`).

- **Executor split.**
  - `Seal.Tools.Exec.Local` — the untrusted *local* executor. Gated by the
    `remote-only-untrusted` Cabal flag (absent in hardened builds).
  - `Seal.Tools.Exec.Remote` — the SSH executor. Always present.
- **`UntrustedExecBackend`** — a smart-constructed type that can **only** be
  built from an `Ssh` backend. It is the type that untrusted dispatch consumes,
  so a backend carrying a local target structurally cannot reach untrusted
  execution. Backend selection is a pure function:
  `selectUntrustedBackend :: Config -> Opcode -> Either ExecError UntrustedExecBackend`,
  which is heavily QuickCheck-able (untrusted ⇒ `Ssh`-or-failure, never `Local`).

  > **Amendment (recorded during Phase 4 planning, 2026-07-07):** the
  > spec's single `selectUntrustedBackend :: Config -> Opcode -> Either
  > ExecError UntrustedExecBackend` is ambiguous for `mode=local`:
  > `UntrustedExecBackend` is Ssh-only by construction, so it cannot
  > represent the local executor. The implementation (Phase 4 task 4a-T2)
  > splits this into TWO pure functions and a sum type, both heavily
  > QuickCheck-able:
  >
  >   - `ExecBackend` sum: `EbLocal LocalExecHandle | EbRemote
  >     UntrustedExecBackend` (the dispatcher consumes this).
  >   - `selectUntrustedBackend :: UntrustedExecConfig -> TerminalBackend
  >     -> Either ExecError UntrustedExecBackend` — the spec's function,
  >     narrowed to the remote arm; `mode=remote` ⇒ `Right` only if `Ssh`
  >     configured, else `Left ExecRemoteRequired`; `mode=local` ⇒ always
  >     `Left` (this fn never yields Local). The QuickCheck property
  >     "untrusted ⇒ Ssh-or-failure, never Local" is preserved.
  >   - `selectExecBackend :: UntrustedExecConfig -> TerminalBackend ->
  >     Either ExecError ExecBackend` — the full-sum selector the
  >     dispatcher actually wires; `mode=local` + `TbLocal` ⇒ `Right
  >     (EbLocal ...)`; `mode=remote` + `TbSsh` ⇒ `Right (EbRemote ...)`;
  >     `mode=remote` + no remote ⇒ `Left ExecRemoteRequired`; never a
  >     local fallback under `mode=remote`.
  >
  > The core deliverable (untrusted ⇒ Ssh-or-failure, never Local under
  > `mode=remote`) is preserved in both functions; the split just makes
  > the `mode=local` case representable. This amendment is recorded here
  > per the plan contract ("where the plan and the spec disagree the spec
  > wins"; this is a clarification of an ambiguity, not a divergence).
- **Capability scoping.** In the handle pattern, the `Shell` handle (and any
  command-running capability) is wired **only** into Untrusted-opcode
  implementations. Trusted/Audited implementations never receive it, so "a
  Trusted opcode shells out" fails to type-check — it has no shell handle in
  scope.
- **SSH transport.** Untrusted execution shells out to the system `ssh` binary
  (mirroring the way the vault shells out to `age`), via fixed argv (no shell
  interpreter), with **mandatory host-key pinning**: `StrictHostKeyChecking` on
  and a pinned `known_hosts`. A host-key mismatch is a hard security failure and
  is never bypassed — otherwise a man-in-the-middle could redirect "remote"
  execution to an attacker-controlled host.
- **Workspace confinement.** `SafePath` re-anchors to the *remote* workspace
  root; untrusted file opcodes are confined relative to that remote root.

## 5. Configuration surface

```toml
[untrusted_execution]
mode = "remote"          # "local" (default) | "remote"; forced "remote" in hardened build

[untrusted_execution.remote]
host        = "exec.internal"
user        = "agent"
port        = 22
identity    = "~/.ssh/seal_exec"                  # SSH key file (or ssh-agent)
known_hosts = "~/.config/seal/exec_known_hosts"   # pinned; StrictHostKeyChecking=yes
workspace   = "/srv/agent-workspace"              # remote workspace root
```

SSH authentication uses standard SSH mechanisms (key file / ssh-agent), not the
vault, because execution shells out to `ssh`. Startup validates the remote block
when `mode = "remote"` (always, in a hardened build) but does not block boot if
the host is merely unreachable.

## 6. Two global invariants (apply beyond this feature)

These are recorded in the roadmap's Global Constraints because they are
cross-cutting architectural rules, not local to remote execution. They are the
reason the trust boundary cannot leak through a Trusted opcode.

### Invariant 1 — No shell-wrapping in Trusted/Audited opcodes

Trusted and Audited opcodes must **never** be implemented by wrapping a shell and
must **never** run an arbitrary or agent-supplied command. No shell interpreter
(`sh -c`), no constructed command strings. They use direct mechanisms only:
native Haskell libraries, direct file/network handles, in-process data-structure
manipulation, SQLite via a library binding, an STM scheduler, and so on.

The capability to run a command lives **exclusively** in the Untrusted opcode
path — which, in remote-only mode, only exists on the far side of the SSH
boundary. A Trusted opcode that shelled out would be arbitrary command execution
on the trust plane, defeating the whole model.

*Permitted as infrastructure (not opcode shell-wrapping):* fixed-argv invocation
of a specific, trusted binary with no shell interpreter and no agent-supplied
command — `age` (vault crypto), `ssh` (the untrusted transport), `tmux` (harness
control). These run a known program with a controlled argument vector, which is
categorically different from wrapping a raw or arbitrary shell command.

### Invariant 2 — Type-guaranteed argument sanitization

Every value derived from user/LLM input that reaches a subprocess argv must be
carried by a validated, smart-constructed newtype — **never** raw `Text`/
`String`. The exec/subprocess wrappers accept only these validated types in their
signatures, so passing unsanitized input fails to compile. The type system, not
review, guarantees that no raw input reaches argv.

This extends the existing `SafePath` / `AuthorizedCommand` / `ContainerTarget`
pattern to a validated argument type (e.g. a `VaultKey` for the `age` seam,
validated remote paths/args for the `ssh` seam). The smart constructor must also
defend against **option injection**: a value beginning with `-` could be read as
a flag by the invoked binary. Defense is built into the constructor — reject
leading-dash values and/or always pass a leading `--` separator before
user-derived arguments.

## 7. Failure handling

| Condition | Behavior |
|---|---|
| `mode=remote`, no remote configured | Boot OK; untrusted opcodes fail closed at call time |
| Remote unreachable / SSH connect fail | Boot OK; untrusted opcode returns structured error, recorded, surfaced to agent |
| **Host-key mismatch** | Hard security failure; opcode refused; never proceeds |
| Hardened build with `mode=local` in config | Startup configuration error |
| Any untrusted op when remote-only | Resolves to SSH backend or fails — **never** local fallback |

## 8. Testing

- **Pure (QuickCheck).** `selectUntrustedBackend` never yields a `Local` (or
  local-container) target under remote-only configuration: ∀ config/opcode,
  untrusted ⇒ `Ssh`-or-failure.
- **Argument sanitization (QuickCheck).** No input to the validated argv
  newtypes yields an argument that begins with `-` past the `--` separator, and
  arbitrary input round-trips safely or is rejected.
- **Compile-time.** A CI build with `-f remote-only-untrusted` that asserts the
  local untrusted executor is absent from the build (the module is not compiled;
  a reference to it fails to resolve under the flag).
- **Fail-closed integration.** With the remote down, an untrusted opcode errors,
  no local execution occurs, and the transcript records the refused attempt.
- **Host-key.** A mismatched host key produces a hard failure, not a prompt or a
  bypass.
- **Capability scoping (type-level).** A Trusted-opcode implementation cannot be
  written against the `Shell` handle — there is no instance/handle in scope; a
  test that attempts it is a compile-failure fixture.

## 9. Roadmap phasing

- **Phase 2 (forward reference).** The ISA dispatcher must route untrusted
  opcodes through a backend seam (not execute inline), so Phase 4 can slot the
  Local/Remote executors behind it without reworking dispatch. The two global
  invariants are in force from the first opcode.
- **Phase 4 (implementation).** The `TerminalBackend` family, the Local vs
  Remote executor split, `UntrustedExecBackend`, the SSH transport with host-key
  pinning, the runtime `untrusted_execution` mode (fail-closed), and the
  `remote-only-untrusted` Cabal flag — alongside the Untrusted opcode breadth
  that this feature governs.
