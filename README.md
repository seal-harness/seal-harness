<p align="center">
  <img src="assets/SealLogo.png" alt="Seal Harness logo — baby seal" width="200">
</p>

<p align="center">
  <strong>Seal Harness</strong><br>
  <em>safer AND more productive</em>
</p>

<p align="center">
  <a href="https://github.com/seal-harness/seal-harness/actions/workflows/ci.yml"><img src="https://github.com/seal-harness/seal-harness/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-FSL--1.1--MIT-blue" alt="License"></a>
  <br>
  <a href="https://seal-harness.github.io/seal-harness/api/index.html">API Docs</a>
  &nbsp;&bull;&nbsp;
  <a href="https://seal-harness.github.io/seal-harness/coverage/main/hpc_index.html">Code Coverage</a>
</p>

---

> **Status:** Pre-alpha. Active design and development.

Most agent harnesses can't guarantee their own integrity. Actions happen off the record. You can't trust what you can't verify.

Agent frameworks are racing to hide what they do. Background steps you can't inspect. Tool calls summarized away. State changes with no record you can replay. Seal Harness goes the other way, fixing this at the architectural level. Not with policies to remember, but with structural guarantees enforced by the design of the system.

- Agents can't delete or tamper with their own logs, transcripts, or configs. This is the exact failure seen in the OpenAI/Hugging Face incident.
- Secrets are encrypted at rest, preventing the most common prompt injection attacks.
- Untrusted agent operations run in isolation.
- Start a conversation from your desktop, continue it from your phone. Same agent, same context, no handoff.
- Manage multiple agents simultaneously from any device. No tabbing through tmux panes.

---

## What Makes Seal Different

### Trust Every Agent Action

Security isn't a layer bolted on top. It's the foundation.

**Two trust levels, enforced by the system.** Every opcode is classified:

- **Untrusted** — interacts with the outside world (shell, files, web,
  browser). Runs in an isolated, disposable environment with no path to
  modify agent identity, memory, skills, or the audit trail.
- **Trusted** — harness-internal (sessions, scheduling, human
  interaction, state management). In-process, logged in the session
  transcript.

**Encrypted secrets vault.** API keys, bearer tokens, and encryption keys
don't live in plaintext config files or environment variables. They live in
an [age](https://age-encryption.org)-encrypted vault with public-key
cryptography and hardware token support (YubiKey, NitroKey). Three unlock
modes: explicit unlock at startup, automatic unlock on first access, or
decrypt-from-disk on every operation. Atomic writes — no partial states.
Rekey support re-encrypts the entire vault with a new key, verified
byte-for-byte before the old vault is replaced.

Seal Harness allows you to guarantee complete machine separation between
the untrusted and trusted environments. Untrusted operations can run on a
separate machine, so even full compromise of the execution environment
can't reach the control plane.

### Command Multiple Agents Effortlessly From Anywhere

Running multiple agents at once is the hard part — not the coding, the
*awareness*. A tmux TUI tells you *which* agent is idle, but each is still an
isolated conversation you tab into and out of. Check from your phone? Let a
teammate glance at the state? Watch two agents at once? You're back to
tabbing.

Seal Harness treats every agent session as a first-class, persistent object
— a **tab** — that multiple channels can subscribe to simultaneously.

- **Session transcript is the source of truth.** Web frontend renders the
  transcript directly with full fidelity — every message, tool call, skill
  load, and permission prompt, with channel attribution, timestamps, raw JSON
  inspection, and branching from any point. This is where you do deep work.
- **Manage multiple in-flight tasks.** Easily juggle multiple tasks even with
  append-only chat interfaces. Get notified when tasks are waiting on you, and
  direct them from your phone wherever you are.

Start a conversation on Telegram from your phone, continue it from the
web UI at your desk, watch it unfold on Signal — all three stay in sync
because they're views into the same transcript. The state of every agent
(idle, thinking, waiting on a permission prompt) is visible from any
subscribed channel. No conversation is lost when a tmux session dies —
the transcript is on disk.

### Built-in Git Repo and Credential Management

Working across repos in different organizations is usually a juggling act —
SSH keys or Personal Access Tokens scattered around, tokens in env vars, one
credential often granting access to far more than it should. Seal Harness
handles this for you, allowing you to use the Principle of Least Privilege to
only give agents the access they need for the task at hand.

Point a session at a repo URL and Seal clones it into the workspace for
you — no manual `git clone`, no hoping the agent runs the right command.
You tell Seal about a repo, supply the appropriate credential, and then you
never have to think about it again.

### See Everything Your Agents Do

When an agent acts, you see everything. No hidden layers, no off-the-record
decisions.

**Every tool call is user-visible.** The web frontend renders the transcript
directly — every message, tool call, skill load, and permission prompt with
full fidelity: channel attribution, timestamps, raw JSON inspection,
collapsible structured views. Nothing is summarized behind the scenes. Branch
from any point and you branch from the real record.

**Agents can't tamper with the logs.** Prevent agents from tampering with your
audit trail and rest easy knowing that you have full visibily into the workings
of your agent organization.

## The SealOp ISA

Every other agent framework has ad-hoc tool calls: `shell`, `read_file`,
`web_search`, whatever the developer thought of that week. No unifying
design. No privilege model.

Seal Harness defines a formal Instruction Set Architecture — a closed set
of opcodes where every instruction has:

- **Defined input/output JSON schema** — not "whatever JSON the LLM generates"
- **Trust classification** — Untrusted or Trusted
- **Transcript entry format** — how the execution is recorded in the audit log

### The Wired Opcode Catalog

The registry currently exposes these opcodes to the model. Legacy
single-action opcodes (e.g. `MEMORY_WRITE`, `SKILL_LOAD`) still exist for
backward-compatibility transcript replay but are hidden from the model's
tool catalog, superseded by the consolidated `*_MANAGE` opcodes.

| Group | Visible Opcodes | Trust |
|---|---|---|
| **Memory** | `MEMORY_MANAGE` | Trusted |
| **Skills** | `SKILL_MANAGE` | Trusted |
| **Agent Defs** | `AGENT_DEF_MANAGE` | Trusted |
| **Agent Runtime** | `AGENT_MANAGE` | Trusted |
| **Sessions** | `SESSION_MANAGE`, `SESSION_NEW` | Trusted |
| **Secrets** | `SECRET_MANAGE` | Trusted |
| **Human Interaction** | `ASK_HUMAN`, `SHOW_HUMAN` | Trusted |
| **Harnesses** | `HARNESS_LIST`, `HARNESS_START`, `HARNESS_STOP` | Trusted |
| **Execution** | `SHELL_EXEC`, `BIN_EXEC`, `PROCESS_MANAGE`, `SETUP_REPO` | Untrusted |
| **Files** | `FILE_READ`, `FILE_WRITE`, `FILE_PATCH`, `SEARCH_FILES` | Untrusted |
| **Web** | `WEB_FETCH`, `WEB_SEARCH` | Untrusted |
| **Introspection** | `OPCODE_DESCRIBE`, `OPCODE_LIST` | Trusted |

## Quick Start

### Prerequisites

- **Nix** (recommended) — [install Nix](https://nixos.org/download) for
  fully reproducible builds
- **Or** GHC 9.12+ and Cabal — via [GHCup](https://www.haskell.org/ghcup/)
- An API key from your AI provider of choice (Anthropic or a local Ollama
  instance)

### Install and Run

You can either download a pre-built binary or build from source:

#### Download a pre-built binary (no Nix required)

Pre-built binaries are available on the
[Releases page](https://github.com/seal-harness/seal-harness/releases).

**Stable releases** (versioned, e.g. `v0.1.0`):

```bash
# Linux (x86_64)
curl -L https://github.com/seal-harness/seal-harness/releases/download/v0.1.0/seal-v0.1.0-seal-x86_64-linux.tar.gz | tar xz
chmod +x seal
./seal --help
```

**Bleeding edge** (rolling `latest` tag, rebuilt on every push to main):

```bash
# Linux (x86_64)
curl -L https://github.com/seal-harness/seal-harness/releases/download/latest/seal-x86_64-linux.tar.gz | tar xz
chmod +x seal
./seal --help
```

Verify download integrity with the SHA256 checksums provided alongside
each release asset.

#### Build from source

```bash
# Clone the repository
git clone https://github.com/seal-harness/seal-harness.git
cd seal-harness

# Nix (reproducible, no system deps needed)
nix develop            # enter dev shell with GHC + cabal + hlint
nix build              # build the executable
nix run                # run directly

# Or Cabal (requires GHC toolchain)
cabal build
cabal run seal
```

### Start a Chat

From a running frontend, start a session with the `/new` command:

```
/new                              # fresh session in the current tab
/new -p anthropic -m claude       # Anthropic, explicit model
/new -p ollama -m llama3          # local Ollama, no API key needed
/new -r seal-harness -b main      # clone the -r repo, checking out `main` (branch or tag)
```

Provider credentials are read from the vault (set them with
`seal vault save`). Resume old sessions with `/session` and `/tab`.

## First run

There are two gates, in this order, and both are blocking.

1. **Access control** (passkey). `seal serve` mints an enrollment token on
   first boot and prints it; the web UI walks you through enrolling a passkey.
   If you explicitly waive it (`[access_control] mode = "none"`), that waiver
   is a decision you wrote down, not a default.
2. **Setup** (`vault` then `provider`). The wizard asks for:

   * a vault — a local `age` key (`age-keygen` on the gateway's `PATH`), a
     YubiKey (`age-plugin-yubikey` on `PATH`; the plugin needs a terminal for
     key generation, so the wizard hands you the exact command and a Re-check
     button), or an existing age identity (a recipient plus the path to the
     identity file);
   * an LLM provider — Anthropic, OpenRouter, Ollama, or any
     OpenAI-compatible endpoint (where you supply the base URL), plus its
     credential.

   The vault step writes exactly three values to `~/.seal/security.toml`
   (`vault_recipient`, `vault_identity`, `vault_key_type`) and creates
   `~/.seal/config/vault/vault.age`. The provider step writes
   `config.toml` as before. Key material is generated server-side and never
   sent to the browser; responses carry the public recipient and a key-type
   label only.

Everything after that is the CLI's job: `/vault setup` rotates a vault key (the
wizard only creates one), and `seal tui` is where you fix a state the wizard
can only describe — an orphan vault file, an unreadable identity, or a vault
file written by a different key.

The four endpoints behind the wizard are `GET /api/setup`,
`POST /api/setup/vault`, `POST /api/setup/vault/reopen`, and
`POST /api/providers/:name/test`. All are origin-guarded and passkey-gated;
`GET /api/setup` is `no-store` and path-free.

## Configuration files

The first run writes two documented files and never overwrites either: an
existing one is yours, and is left byte-for-byte alone (so an upgrade does not
re-hand you a template — copy one out of `config/templates/` in the repository
if you want to see it next to a file you already have).

* `~/.seal/config/config.toml` — the runtime options: session defaults, tool
  timeouts, sub-agents, web tools, prompt sections, memory search, chat
  channels. Also a git repository (`~/.seal/config`), so edits are diffable and
  revertable.
* `~/.seal/security.toml` — boot-only, agent-immutable settings: the vault, where
  untrusted code runs, the web gateway's bind address / Origin allowlist / TLS
  pair, and passkey access control. No opcode, tool or agent can read or write
  it. The gateway settings live here because they decide who can reach the
  agent, and a bind address is not a value to guess from.

Both files spell out the default for every option. A key is written out only
where writing it resolves to exactly what leaving it out resolves to;
everything else is commented out with its default named in the comment — an
unset value, a name only you know, a machine-absolute path, or a value derived
from another key. Seal re-encodes a file when it changes it (a `/provider`
change, `/vault setup`), and a re-encode does not keep comments.

## Web Access Control (passkeys)

`seal serve` exposes the whole agent surface — sending messages (which the
agent executes), every transcript, every slash command — over HTTP and
WebSocket. Access control is configured once, in `~/.seal/security.toml`;
the enrolled passkeys live next door in `~/.seal/credentials.toml`:

```toml
# ~/.seal/security.toml
[access_control]
# "passkey" (require a passkey) | "none" (run open — an explicit waiver)
mode = "passkey"

# Optional: only needed when a TLS reverse proxy fronts the gateway.
# origin = "https://seal.example.com"
# rp_id  = "seal.example.com"
```

```toml
# ~/.seal/credentials.toml — gateway-owned, mode 0600; do not edit by hand
version = 1

[credentials.<credential-id-base64url>]
public_key = "<base64url, 64-byte x||y>"
sign_count = 0
label      = "passkey"
created_at = "2026-10-30T14:00:00Z"
rp_id      = "localhost"
added_via  = "cli_token"   # cli_token | cli_window | assertion | legacy
```

Three states:

| `security.toml` | Gateway behaviour |
|---|---|
| no `[access_control]` table | **unconfigured** — the API is closed; the first browser visit shows a setup screen |
| `mode = "none"` | **open** — runs with no authentication (for a host only reachable over a VPN) |
| `mode = "passkey"` | **passkey** — every request needs a passkey-backed session |

**Enroll before you expose the port.** The first enrollment is a race: any
client that can reach the gateway and holds an enrollment token can win the
one slot. Nothing is escalated to before a passkey exists, and the operator
finds out immediately (their own attempt fails with `grant_invalid`), but the
winner holds the full agent surface until `seal access-control reset --yes`.
So enroll from the machine itself, then open the firewall or the tunnel.

Enrollment authority is always a secret presented on the request — never a
cookie:

```bash
seal access-control enroll                 # 10-minute token on stdout, hints on stderr
seal access-control enroll --ttl 90s       # s/m/h required; clamped to 30s-24h
seal access-control enroll --no-token      # loopback-only window, bootstrap state only
seal access-control enroll --cancel        # drop the outstanding grant
seal access-control status                 # mode, origin, credentials, armed grant
seal access-control disable --yes          # turn access control off (keeps credentials)
seal access-control reset --yes            # delete credentials.toml + the section
seal access-control migrate-credentials    # move pre-split credentials out of security.toml
```

On a terminal the boot banner prints the enrollment URL and the token; off a
terminal (`systemd`, `launchd`, a pipe) it writes the token to
`~/.seal/state/enrollment-token` at mode 0600 and prints only the path, so the
token never lands in a log. A restart does **not** mint a new token when one is
still valid.

Adding a second passkey no longer needs a terminal: from `/access` on a signed-in
device, Seal asks you to confirm with an existing passkey (a 120 s grant), then
runs the create prompt. `disable` and `reset` require the daemon stopped —
`serve.lock` is an advisory kernel lock, so a crashed daemon never blocks them.

Passkeys need a **secure context**: `http://localhost`, or HTTPS. That is why the
gateway's default `[gateway] host` is `localhost` — it is the origin Seal
verifies, the origin it allows for the WebSocket, and the one name every browser
treats as a secure context. `host` is authoritative: Seal passes it to the
listener, so a loopback default really does bind loopback, and an address that
cannot be bound refuses to start before anything listens.

The gateway can terminate TLS itself, so no reverse proxy is required:

```toml
# ~/.seal/security.toml
[gateway]
# "localhost" (the default) is loopback-only. Bind a specific address, or
# 0.0.0.0 to listen on every IPv4 interface, when clients are elsewhere.
host = "0.0.0.0"
port = 8443
tls  = true                       # serves ~/.seal/keys/tls/{cert,key}.pem
# tls_cert = "/etc/ssl/fullchain.pem"   # optional overrides for a real cert
# tls_key  = "/etc/ssl/privkey.pem"
# tls_hosts = ["seal.lan"]          # names for a generated certificate's SAN
```

The bind address, the Origin allowlist and the TLS pair are security settings:
they live in `~/.seal/security.toml`, not `config.toml`, so no opcode or agent
config writer can move the listener. An install that still carries `[gateway]`
in `config.toml` is migrated on the next `seal serve` or `seal tui` boot;
`seal provider`/`seal channel`/`seal agent` refuse to write `config.toml` until
that has happened.

`tls = true` is the whole configuration: the PEM paths default to
`~/.seal/keys/tls/cert.pem` and `~/.seal/keys/tls/key.pem`. Setting both paths
explicitly also turns TLS on, so pointing at a real certificate needs no flag.
If those files are absent, Seal generates a self-signed pair with `openssl`
(key written `0600`) on the next start.

The generated certificate is valid for **397 days**. Chromium and WebKit reject
anything longer outright — `ERR_CERT_VALIDITY_TOO_LONG` is not a warning the
user can click through — so a longer-lived pair is worse than useless. Its
subject alternative name covers every name and address the gateway answers on:

* `localhost`, `127.0.0.1` and `::1`
* this machine's hostname
* the host of `[access_control] origin`, when one is set (the name passkeys are
  bound to)
* every local interface address — LAN, VPN and overlay interfaces included
* everything in `tls_hosts`, which comes first in the list and becomes the CN

Anything `network-info` cannot see (it reports one address per family per
interface) can be added to `tls_hosts`, which accepts names and IP literals.

**When an existing pair is replaced.** A pair Seal generated at the default
paths is Seal's to maintain, and is regenerated at boot when it cannot serve a
browser a legal certificate: its window exceeds 397 days, or it does not load
(a truncated file, or a certificate next to the wrong key). The previous pair is
kept as `keys/tls/cert.pem.bak` and `keys/tls/key.pem.bak` so the change can be
undone by hand. Replacing the pair means a **new key**, so the certificate has
to be trusted again on every device that uses this gateway.

Changing `tls_hosts` does **not** by itself regenerate a pair: the names in an
existing certificate are not re-derived on every restart. Delete
`keys/tls/cert.pem` and `keys/tls/key.pem` after editing `tls_hosts`, or the
certificate keeps the old names and the browser rejects the ceremony. The same
deletion is the way to force a fresh key at any other time; when a generated
pair comes within 30 days of expiry, `serve` logs a warning telling you so.

A pair you point at with `tls_cert` / `tls_key` is never validated, replaced or
rotated — a real certificate or a private PKI may legitimately outlive 397
days — so its renewal is your business. A missing file at those paths is
created, exactly as before.

Seal never touches your DNS configuration or zone files, and it never downgrades
the listener to plain HTTP: with `tls = false` it serves HTTP because you asked
it to, and it does not change that setting on its own.

```toml
# ~/.seal/security.toml — must be the https URL clients actually use
[access_control]
origin = "https://seal.example.com:8443"
```

Both PEM paths are required together. Turning TLS on makes `origin` mandatory
and `https://`: the loopback default is `http://localhost:<port>`, which no
ceremony could ever match. A reverse proxy still works too — leave
`tls_cert`/`tls_key` unset and point `origin` / `rp_id` at the proxy's URL.

**A generated certificate does not make passkeys work on its own.** Since Chrome
110 a browser disables WebAuthn outright on a site whose certificate it does not
trust — clicking through the warning is not enough — so the generated
certificate has to be *installed* on the phone (and marked trusted) before any
ceremony will run. It also has to name a hostname: an IP can never be an RP ID,
so set `tls_hosts` to the name the device will use. For the same effort,
`tailscale cert <name>` produces a certificate that every device already
trusts, with no installation step — that is the better default when you have a
tailnet.

**Troubleshooting: "The passkey prompt was cancelled or timed out."** When no
Touch ID / Windows Hello prompt appears at all and the ceremony fails
instantly, the browser is refusing WebAuthn because it does not trust the
certificate — the prose about cancellation is misleading, since `NotAllowedError`
covers both user cancellation and a browser-side refusal. The definitive check
is the address bar: "Not Secure" or a struck-through padlock means the cert is
not trusted, and no ceremony will run until it is. A padlock means the cert is
trusted and the failure is elsewhere.

On macOS, trust the generated certificate in the **System** keychain (Chrome and
Safari read the system trust store, not the login keychain alone):

```sh
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ~/.seal/keys/tls/cert.pem
```

Then **fully quit** the browser — `⌘Q` on macOS, not just closing the window.
Browsers cache certificate-trust decisions for the lifetime of the process, so a
reopened tab inherits the old "Not Secure" verdict until the whole browser is
restarted. Reopen, confirm the address bar shows a padlock, then try the
passkey again.

A subtle trap: `seal serve` regenerates its managed certificate when the SAN
list changes or the existing pair cannot serve a legal certificate (see above),
which gives the new pair a **new key** — and a different fingerprint from the
one you just trusted. If the "Not Secure" warning returns after a restart, the
cert on disk no longer matches what is in the keychain. Verify by comparing
fingerprints:

```sh
# What the gateway is actually serving:
openssl s_client -connect <host>:<port> -showcerts </dev/null 2>/dev/null \
  | openssl x509 -fingerprint -sha256 -noout
# What the keychain holds:
security find-certificate -c <host> -p /Library/Keychains/System.keychain \
  | openssl x509 -fingerprint -sha256 -noout
```

Mismatched fingerprints mean the cert was regenerated after you trusted it;
re-run `add-trusted-cert` against the current `~/.seal/keys/tls/cert.pem`. To
avoid this entirely, prefer `mkcert` (a local CA you install once, after which
every generated cert is trusted with no per-cert step) or `tailscale cert` (a
publicly-trusted pair when the host is on your tailnet) over trusting the
self-signed pair by hand.

**A hostname is required, not just TLS.** A WebAuthn RP ID must be a domain
string, so `https://192.168.1.42:8443` still cannot register a passkey — Chrome
raises `SecurityError` before the ceremony starts. Use a name that resolves on
the client (a tailnet name, a DNS record for the LAN address, or
`tailscale cert` for a real certificate) and set `origin`/`rp_id` to it.

Deleting the last **usable** passkey is refused; an orphaned one (registered
for another address) is safe to remove.

`reset` is the terminal-only escape hatch: no opcode and no HTTP route can turn
access control off — `POST /api/auth/waive` was removed, and `mode = "none"` can
only be written by `seal access-control disable --yes`. The agent runs as the
same uid and can read `~/.seal/`, so passkeys defend the **network** — not a
compromised agent.

## Development

Everything runs through the **Nix flake dev shell** — never install GHC,
cabal, or hlint yourself. Use the Makefile wrappers (all run inside
`nix develop`; `direnv` users: `echo "use flake" > .envrc && direnv allow`):

```bash
make build    # cabal build all (-Werror clean)
make test     # cabal test
make lint     # hlint src/ test/ — must report: No hints
make check    # build + test + lint — the full local gate; what CI runs
make serve    # rebuild frontend + launch gateway
```

**SIGPIPE pitfall:** never pipe Haskell binaries (`cabal`, `hlint`,
`ghcid`) through `head`/`tail`. The RTS sets `SIGPIPE` to `SIG_IGN`, so
the writer hangs in its exception handler instead of dying and the
command appears to hang forever. Redirect to a file, then page through
the file:

```bash
nix develop --command cabal test >test.log 2>&1; head -80 test.log
```

(`make`, `rg`, `git` are unaffected — they use the default SIGPIPE handler.)

**Frontend:** React 18 + TS + Vite + Tailwind, embedded into the binary,
so `frontend/dist` must exist when `cabal build` runs
(the Makefile gates this).

### Project Standards

- **GHC flags:** `-Wall -Werror` with strict warnings (incomplete
  patterns, name shadowing, unused imports)
- **TDD:** Red-green methodology — failing tests first, implementation
  second. Security-critical pure functions get property-based tests.
- **Linting:** hlint clean required before merge
- **CI:** GitHub Actions with Nix builds (Linux + macOS)

## Naming Philosophy

User-facing terminology uses **descriptive words**, not metaphors that
may be unfamiliar. A user should understand what an opcode does from its
name alone, without learning a domain-specific vocabulary first. Internal
implementation details and developer-facing API names may use specialized
terminology, but anything an end user or contributor encounters in
documentation, CLI output, or configuration should be plain and
self-explanatory.

## License

**FSL-1.1-MIT** (Functional Source License) — source-available with a
"Competing Use" restriction. Each version converts to MIT license two
years after its release date. See [LICENSE](LICENSE) for details.
