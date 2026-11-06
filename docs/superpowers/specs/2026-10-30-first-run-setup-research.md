# First-run setup: state-of-the-art research

**Status:** research (pre-design)
**Date:** 2026-10-30
**Question:** How should seal-harness's web frontend detect that required setup
is missing (vault, then provider) and guide a first-time user through it, in a
way that teaches the existing UI rather than duplicating it?

---

## 1. What the codebase does today

The web UI has no first-run path at all. A fresh install with no vault and no
provider is indistinguishable at the top level from a fully configured one:

| Surface | Today's behaviour when unconfigured |
|---|---|
| `GET /api/secrets` | `500 "vault not configured — run /vault setup"` |
| `SecretsView` | renders the list pane, shows "Failed to load — the vault may be locked or unconfigured." Nothing actionable. |
| `GET /api/providers/all` | `200` — every known provider with `authStatus: "none" \| "vault-locked"` |
| `ProvidersView` | CRUD form; saving an API key fails with a vault 500 |
| `NewTabComposer` provider `<select>` | `(no providers configured — set an API key or start Ollama)`, disabled. **Dead end.** |
| Vault creation | **CLI only.** `/vault setup` is `AvailabilityInteractiveOnly`, an interactive prompt flow (backend choice: local age key / age-plugin-yubikey / user-supplied; then passphrase/pin prompts). |

Two structural facts that constrain any design:

1. **There is no structured readiness signal.** "Is the vault configured?" is
   inferred today from a `500` status code. `vrHandleRef :: IORef (Maybe
   VaultHandle)` conflates *unconfigured* (no `vault_recipient`/`vault_identity`
   in `security.toml`) with *configured but unopenable* (identity file missing,
   YubiKey absent). A setup UI needs these as distinct states.
2. **Vault setup writes `~/.seal/`.** `vaultFilePath` = `~/.seal/config/vault/vault.age`,
   `securityFilePath` = `~/.seal/security.toml`, keys under `~/.seal/keys/`.
   AGENTS.md rule 3 reserves `~/.seal/` for *human-driven admin commands* and
   forbids wiring an opcode or agent-driven code path to it. Driving vault
   creation from a web endpoint is therefore a security-boundary decision, not
   a UI decision.

---

## 2. The three patterns, and which job each one does

The single most useful finding. These are not interchangeable; most bad
onboarding is a wizard doing a checklist's job.

| | Onboarding **wizard** | Onboarding **checklist** | **Product tour** |
|---|---|---|---|
| Shape | linear, blocking | non-linear, persistent | guided, contextual |
| Job | configure the product | drive a sequence of first wins | explain the interface in place |
| Timing | once, at signup | across first days/weeks | when the user reaches a feature |
| Failure mode | too long → abandon signup | ignored if items feel like chores | clicked through without reading |
| Right length | 2–4 steps | 3–6 items | 3–5 steps |

NN/g's canonical wizard guidance says the same thing from the other direction:
wizards suit "novice users or infrequent processes (e.g. configuration or
setup)", but they **may block access to other parts of the app** that are
needed to complete the process, and they are **not gracefully interruptible**.
Both are known costs to be paid only when the process is genuinely sequential
and self-sufficient.

**Implication for seal-harness:** the two required steps are dependent (an API
key needs a vault) but they are *not* completable inside a wizard pane — the
real work happens in `Secrets`/`Providers`, and vault creation today happens in
a terminal. That makes this a **guided setup checklist that deep-links into the
real UI**, not a modal wizard that re-implements the forms. Which is exactly
the tutorial property the task asks for: the user leaves onboarding having used
the actual Providers screen once.

### The rules that survived every source

1. **Every step must be blocking-necessary.** Test: "if this were missing,
   would the product be broken, or merely less personalised?" Only "broken"
   qualifies.
2. **Honest progress.** A "step 2 of 3" that later reveals a fourth step
   destroys trust at the worst moment.
3. **Skippable, or at least deferrable.** "A skippable step loses that step; an
   unskippable one loses the user." Skipped items move to the checklist rather
   than vanishing.
4. **End inside the product.** Never on "You're all set!" — land the user in a
   working state (here: a New Tab composer with a provider selected).
5. **Resumable.** "A meaningful share of abandonment is interruption, not
   rejection." Re-detection is free for us because readiness is derived from
   server state, not from a local step index.
6. **Checklists rot.** Every new feature adds an item until the list is twenty
   deep. Someone must prune.
7. **Auto-hide on completion.** Required-but-incomplete resurfaces; dismissals
   should not be permanent for *required* items.

---

## 3. Prior art in adjacent products

| Product | Pattern | Useful detail |
|---|---|---|
| **Linear** | task-driven checklist | Each task is one real action (`create an issue`, `use the command menu`); completing one unlocks the next. Learning happens by doing, with no overlay tour. |
| **Stripe / Vercel** | ordered finite checklist | Every item is a real setup step with a tangible outcome. |
| **Microsoft Dynamics 365 Business Central** | "Guided Experience Item" table | The checklist is a *typed index into the real app*: each item is `Assisted Setup` \| `Manual Setup` \| `Learn` \| `Tour` \| `Spotlight Tour` \| `Video`, and each points at an actual page. The checklist is a platform for surfacing the real UI — closest structural match to what we want. |
| **Jami Studio** | sidebar Setup panel | Only required steps are tracked; panel collapsible; "Hide setup" hides for the browser session; **required-but-incomplete resurfaces on next load**; auto-hides when all required items are done. |
| **Guildhall** | `GET /api/setup/providers` | A dedicated *setup status* endpoint that reports which provider paths are detected, so the wizard renders state rather than guessing. |
| **Hermes WebUI** | first screen reports runtime state | Checks agent importability, provider readiness, password status, config paths. Provider step groups providers by how much input they need (easy start / self-hosted / specialized). **Probes `<base-url>/models` before saving**; a failed probe blocks the step with an inline, specific error (DNS / refused / timeout / HTTP / bad shape). `HERMES_WEBUI_SKIP_ONBOARDING=1` bypass for managed images. |
| **Open WebUI / LibreChat** | no wizard at all | Both are "docs-first": user reads a guide, then uses Settings → Connections. Cheapest to build, worst first-run; this is the gap the task is asking us to close. |

Two reusable ideas from Hermes worth stealing outright:

- **Probe before declaring success.** A provider that is *stored* is not a
  provider that *works*. `/api/providers/:p/models` exists today but returns a
  **static** list (the real `/v1/models` call is explicitly out of scope). So
  "working" needs a deliberate definition — see decision D3.
- **A skip switch.** `SEAL_SKIP_SETUP=1` (or equivalent) for managed/preconfigured
  deployments, so the gate can be bypassed without deleting state.

---

## 4. Recommended pattern

**A derived-state setup panel, not a step machine.**

- One new read-only endpoint `GET /api/setup/status` reports structured
  readiness: vault state (`unconfigured` \| `unconfigured-orphan` \|
  `unavailable` \| `locked` \| `unlocked`), provider state (derived from the
  existing `authStatus` machinery + default-provider config), and the one
  blocking-next-step answer.
- **Readiness is derived on every load, never stored as a step index.** The
  panel therefore cannot desync from reality, and resumability is free.
- The panel is a **persistent, non-blocking** "Get set up" card that appears in
  place of the empty chat/sidebar area when the app is not ready, plus a
  compact progress affordance in the top bar. It deep-links each step to the
  surface that owns it (`/secrets`, `/providers`) rather than embedding forms.
- The blocking-failure moments that already exist (`NewTabComposer`'s disabled
  provider select, `SecretsView`'s 500 banner, `ProvidersView`'s vault error)
  each gain a link to the step that fixes them. These are the real "tutorial"
  touchpoints — the user hits a wall once, is told exactly which wall it is,
  and is taken to the tool that fixes it.
- Only two steps are tracked as *required*, matching the dependency order:
  1. **Secrets vault** — prerequisite for any API-key provider.
  2. **Provider** — prerequisite for sending a message.
  Optional/deferred items stay out of v1 entirely (rule 6: prune before adding).

**Explicitly rejected:** a modal, blocking wizard. It would have to
re-implement the vault flow (security-sensitive) and the provider form
(duplication that drifts), and it would hide the very screens we want to teach.

---

## 5. Open decisions

- **D1 — Vault step: guide vs. build.** Guide (print `/vault setup`, detect
  completion) keeps `~/.seal/` human-admin-only and ships fast. Building a web
  vault-setup flow crosses the AGENTS.md rule-3 boundary and needs its own
  security design (it would be the first agent-adjacent code path that creates
  `security.toml` + keys). Recommendation: **guide in v1**, separate issue for
  a web flow.
- **D2 — Gate or nudge?** Recommendation: **nudge, never block.** Land on the
  setup panel, but every other surface stays reachable — the user may need
  `Repos` or `Agents` before a provider exists, and NN/g's "wizards may block
  access to other parts of the app" is a documented failure mode.
- **D3 — What counts as a "working provider"?** Options: (a) credentials stored
  or keyless (what `authStatus` already means), (b) credentials stored **and**
  the default provider/model resolves, (c) a live reachability probe. (c) needs
  a new outbound HTTP path from the gateway and is the only one that can
  distinguish "key is wrong". Recommendation: **(b) for v1**, with the live
  probe as an explicit follow-up.
- **D4 — Where does dismissal state live?** `UiState` (`ui_state.json`, already
  atomic-write, already frontend-owned, already served via `/api/ui/state`) is
  the obvious home for a "hide for this browser session" / "dismissed optional
  steps" flag. Required steps ignore dismissal.

---

## 6. Sources

- NN/g, *Wizards: Definition and Design Recommendations* — https://www.nngroup.com/articles/wizards/
- Kompassify, *Onboarding Wizard: when to use one, how to design it* — https://kompassify.com/blog/onboarding-wizard-guide
- Appcues, *Onboarding UX: 10 patterns* — https://www.appcues.com/blog/user-onboarding-ui-ux-patterns
- Appcues, *Product Tour UI/UX patterns* — https://www.appcues.com/blog/product-tours-ui-patterns
- Jimo, *Onboarding Checklist: definition, best practices* — https://jimo.ai/glossary/onboarding-checklist
- Microsoft Learn, *Get Users Started with the Checklist (Business Central)* — https://learn.microsoft.com/dynamics365/business-central/dev-itpro/administration/onboarding-checklist
- Jami Studio, *Onboarding & API Keys* — https://www.jami.studio/docs/onboarding
- Guildhall, *Setup wizard* — https://guildhall.cc/versions/0.6.0/web-ui/setup
- Hermes WebUI, *First-run onboarding guide* — https://github.com/nesquena/hermes-webui/blob/master/docs/onboarding.md
- Supademo, *Linear onboarding flow* — https://supademo.com/user-flow-examples/linear
- UX Patterns Guide, *Onboarding* — https://uxpatternsguide.com/agent/patterns/onboarding.md
