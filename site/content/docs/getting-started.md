# Getting started

This guide takes you from a fresh install to an agent session that can read a
repo and answer you. It follows the order most people actually do things in.

## What you are setting up

Seal Harness is a runtime for AI agents. You run a **gateway** on your own
machine; it serves a web UI and an API, and it runs agent sessions that can use
tools — shell, files, web, git — on your behalf.

The **first-run setup wizard has exactly two steps**: create an encrypted
**vault**, then choose a **model provider**. That is all the wizard asks for.
Everything else in this guide — your GitHub token, a repo, a chat channel — is
set up *after* the wizard, in the app.

That split is deliberate. The wizard only asks for what the harness cannot run
without. The rest is configuration you should do when you need it, with the token
in hand.

## 1. Run the gateway

```bash
seal serve
```

By default this binds **loopback on port 8080**. Open
<http://localhost:8080>.

Because nothing is configured yet, you land on the setup screen rather than an
app. That is expected on a fresh install.

> **Exposing the port is a separate decision.** The default loopback bind is
> reachable only from your own machine. If you plan to reach the UI from
> anywhere else, read [Web access control](https://github.com/seal-harness/seal-harness/blob/main/docs/web-access-control.md)
> first — the gateway holds the full agent surface, and that includes the ability
> to run commands.

## 2. Setup step 1 — create the vault

The vault holds your secrets: API keys, tokens, private keys. It is an
[age](https://age-encryption.org)-encrypted file, not a plaintext config or an
environment variable, and it never stores a secret in the transcript.

The wizard offers the actions that make sense for the state it finds:

| Action | When you see it |
|---|---|
| **Create** | First run. Makes a new vault and records its key. |
| **Resume** | A key is already recorded but the vault file does not exist yet. |
| **Reopen** | The vault is configured but not open in this process (e.g. `startup` unlock mode). |
| **Re-check** | After you fix something outside the UI — an identity file, a permissions problem. |

You also pick an **unlock mode**, which decides when the vault decrypts: at
startup, on first access, or on every operation. A hardware token (YubiKey,
NitroKey) is supported; with one, expect to touch it when the vault opens.

When the vault step shows **ready**, the wizard moves on.

## 3. Setup step 2 — choose a model provider

An agent needs a model. Seal Harness supports:

- **Anthropic**
- **OpenAI**
- **OpenRouter**
- **Ollama** — a local model
- **Ollama Cloud**
- **OpenAI-compatible** — a self-hosted endpoint, which needs its own base URL
  and a unique name

Add credentials for the one you want, then pick which provider new sessions
should use. The API key goes into the vault you just created — you should not
find it in `config.toml` afterwards.

If you choose **Ollama**, the wizard may report that it is **not ready yet**.
That does not block you: you can finish setup and start Ollama later. The wizard
says so rather than pretending the step failed.

When both required steps are ready, the wizard completes and the app appears.

## 4. Add a GitHub token to the vault

Most useful sessions touch a repo, so the first thing to set up is a credential
for it.

1. Open **Secrets** in the sidebar.
2. Create a secret.
3. Give it a **name** and paste the token as the **value**.

Two rules matter:

- **The name** must match `[A-Za-z0-9_-]+` — letters, digits, underscore and
  hyphen. No spaces, slashes, or dots. This name is how every other part of Seal
  refers to the secret, so pick something you will recognise, like `github-pat`.
- **The value is write-only.** Seal stores it and never displays it again. The
  Secrets list shows key *names* only, and there is no "reveal" button — not in
  the UI, and not in the API. If you lose the token, rotate it and paste the new
  one.

Seal never writes the token to disk in plaintext and never puts it in the
transcript.

## 5. Register the repo that uses that token

Now tell Seal about the repo, and which credential reaches it.

1. Open **Repos**.
2. Fill in **Id** — a stable name for this repo, `[A-Za-z0-9_-]+`.
3. Fill in **URL** — the clone URL, HTTPS or SSH.
4. Pick **VCS kind** — `git` or `github`.
5. Pick **Credential** — how Seal authenticates:
   - **PAT** — a personal access token. Use this if the agent needs to do
     GitHub *operations*, such as opening a pull request.
   - **Deploy key** — an SSH key scoped to this one repo. Use this if the agent
     only needs to clone and push.
   - **Machine user** — a token plus a bot account's username, for a dedicated
     automation account.

For the token you created in step 4, choose **PAT**. The form offers two ways to
connect it:

- **Paste the token** — Seal stores it under a key it derives for you, named
  `seal-pat-<id>` (so a repo with id `myrepo` gets `seal-pat-myrepo`). You do not
  type the key name.
- **Reuse an existing secret** — a dropdown of the key names already in your
  vault. This is how you point the repo at the `github-pat` secret from step 4
  without pasting the token again.

Either way, what gets saved in `repos.toml` is the **key name**, never the token.

> **Why `gh auth login` will not work.** Seal injects the token from the vault as
> the `GH_TOKEN` environment variable for `git` and `gh` commands inside a
> session, so `gh pr create` and `gh repo clone` authenticate on their own.
> `gh auth login` and `gh auth token` are **refused by design** — the first would
> write your token to disk on the execution machine, and the second would print
> it into the transcript. You do not need them.

## 6. Add a chat channel

You can drive sessions from the web UI, but a chat channel lets you reach the
same agents from your phone. Seal supports two:

- **Signal**
- **Telegram**

Create a channel and fill in its fields:

| Field | What it is |
|---|---|
| **Kind** | `signal` or `telegram`. Cannot be changed after creation. |
| **Id** | A unique name, letters/digits/hyphens/underscores. |
| **Label** | A human-readable name (optional). |
| **Account** | Signal phone number or UUID. |
| **Token** | Telegram bot token. Stored in the vault, never displayed. |
| **Text chunk limit** | Max characters per message chunk (optional). |
| **Allow from** | Comma-separated allowed sender ids. **Leave blank to allow all.** |

**`Allow from` is the access-control boundary, and it is the field to think
about.** Your channel is a route to an agent that can run commands as you.
Leaving `Allow from` blank means *anyone who can message that bot* is treated as
you. Fill it in with your own sender id unless you have a specific reason not to.

Since a chat channel is a view onto the same transcript as the web UI, you can
start a conversation on your phone and continue it at your desk.

## 7. Start a session

1. Click **New Tab** in the sidebar to create a session.
2. Attach the repo from step 5. If the composer offers a repo field, that is the
   one to use.

Registering a repo does **not** clone it. The clone happens per session: the repo
is copied into *that session's* working directory, either from the composer
before the first turn or through the session's setup-repo action afterwards. This
is why two sessions on the same repo never fight over a checkout — a point the
next page explains.

3. Send a message. Try something concrete: *"What does the README say this
   project does?"*

The agent's reply, and every tool call behind it, appears in the transcript.

## 8. Look at the session's files

Every session has its own working directory, and you can browse it.

Click **Open session workdir in Files** in the chat header. That opens the file
explorer at this session's workdir, where you can read, download, and inspect
what the agent produced — the files it wrote, the repo it cloned, the scratch
output it left behind.

This is the fastest way to check that an agent did what it claimed: the workdir
is the actual filesystem state, not a summary.

## 9. Where to go next

- **[Sessions and working directories](sessions-and-workdirs.md)** — the model
  behind the workdir link you just clicked, and why branching starts empty.
- **[Web access control](https://github.com/seal-harness/seal-harness/blob/main/docs/web-access-control.md)**
  — passkeys, TLS, and reaching the gateway from another machine.
- **[README](https://github.com/seal-harness/seal-harness#readme)** — the full
  feature surface and the opcode catalog.
