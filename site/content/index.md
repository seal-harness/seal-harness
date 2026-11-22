# Seal Harness

<p class="hero-eyebrow">Security-first agent runtime</p>

<h1 class="hero-title">An agent harness that can prove what it did.</h1>

<p class="hero-lede">
Most agent harnesses can't guarantee their own integrity: actions happen off the
record, and you can't trust what you can't verify. Seal Harness enforces its
guarantees structurally — two trust levels checked by the compiler, secrets
encrypted at rest, and an append-only transcript that agents cannot tamper with.
</p>

<div class="hero-actions">
  <a class="btn btn-primary" href="docs/getting-started.md">Get started</a>
  <a class="btn btn-ghost" href="https://github.com/seal-harness/seal-harness">GitHub</a>
</div>

## Install

Pre-built binaries are on the
[releases page](https://github.com/seal-harness/seal-harness/releases). The
tarball is self-contained — no Nix, no other installs:

```bash
curl -L https://github.com/seal-harness/seal-harness/releases/download/latest/seal-x86_64-linux.tar.gz | tar xz
./bin/seal --help
```

Then start the gateway and open <http://localhost:8080>:

```bash
./bin/seal serve
```

On macOS, clear the quarantine flag once (`xattr -dr com.apple.quarantine bin/`)
— release binaries are not yet signed with an Apple Developer ID.

<ul class="cards">
  <li class="card">
    <h3>Trust levels the compiler enforces</h3>
    <p>Every opcode is Untrusted or Trusted. A Trusted opcode that shells out
    fails to compile, because the capability handle simply isn't in scope.</p>
    <a href="docs/getting-started.md">How sessions work →</a>
  </li>
  <li class="card">
    <h3>An encrypted vault</h3>
    <p>API keys and tokens live in an age-encrypted vault, not in plaintext
    config or environment variables. Hardware tokens are supported, and stored
    values are write-only.</p>
    <a href="docs/getting-started.md">Set up the vault →</a>
  </li>
  <li class="card">
    <h3>Repo credentials, scoped</h3>
    <p>Register a repo with its own credential and the agent gets exactly that
    access — a PAT, a deploy key, or a machine account — with no secrets on
    disk.</p>
    <a href="docs/getting-started.md">Register a repo →</a>
  </li>
  <li class="card">
    <h3>One session, every surface</h3>
    <p>Start on your phone over Signal or Telegram, continue in the web UI. All
    of them are views onto the same transcript, so nothing is lost when a
    terminal dies.</p>
    <a href="docs/sessions-and-workdirs.md">Sessions and workdirs →</a>
  </li>
</ul>

## Reference

- [API documentation](api/index.html) — the gateway's OpenAPI 3.1 spec, as
  interactive Swagger UI.
- [Code coverage](coverage/main/hpc_index.html) — line and branch coverage for
  the current `main` build.

## License

**FSL-1.1-MIT** — source-available, converting to MIT two years after each
release. See [LICENSE](https://github.com/seal-harness/seal-harness/blob/main/LICENSE).
