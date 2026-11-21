# Landing page + docs site — implementation plan

<!-- branch: docs/landing-and-docs-site -->
<!-- base: main -->
<!-- status: rev 6 — round-3 findings addressed; build scope trimmed per the
     scope reviewer. Every citation below was read at the cited line. -->

## Goal

Ship a public **docs site**, with the **getting-started guide as the first and
most important page**, plus a landing page that points at it. Patterned on the
docs/landing split of `openclaw.ai` + `docs.openclaw.ai` and
`hermes-agent.nousresearch.com` (§Patterning).

Docs first: a landing page that oversells an undocumented product is worse than
no landing page.

## Facts this plan is built on (read at the cited line)

| Fact | Verified at |
|---|---|
| Wizard has **exactly two required steps**: `vault`, `provider` | `src/Seal/Setup/State.hs:158` — `steps = [vault, provider]` |
| Completion gates the app | `State.hs:160` — `ssRequiredComplete = all isSatisfied steps` |
| Deliberately **no `StepSkipped`** | `State.hs:52-54` |
| Vault actions: `create`, `resume`, `reopen`, `recheck`, `configure` | `State.hs:65` |
| Six providers | `State.hs:350-356` |
| Repo vault key is **auto-derived** `seal-<kind>-<id>` | `frontend/src/components/ReposView.tsx:89-90`; comment `:104` |
| Create form can **reference an existing** vault secret | `ReposView.tsx:519-546`; `:104-108` |
| PAT stored as a **vault key name**, never token bytes | `src/Seal/SourceControl/Repo.hs:82` — `= CredPat { cVaultKey :: Text }` |
| PAT injected as `GH_TOKEN` at exec time | `src/Seal/ISA/Ops/Bin.hs:327` |
| `gh auth login`/`token` refused by design | `Bin.hs:145`; `src/Seal/ISA/Ops/Shell.hs:61` |
| Secrets list = **names only** | `frontend/src/components/SecretsView.tsx:55` |
| Secret value is **write-only** | `SecretsView.tsx:77` |
| Secret names match `[A-Za-z0-9_-]+` | `SecretsView.tsx:99-100` |
| Channel kinds are **`signal`, `telegram`** only | `src/Seal/Command/Channel.hs:208-211` |
| Channel `Allow from` — "Leave blank to allow all" | `frontend/src/components/ChannelsView.tsx:475` |
| Other channel fields | `ChannelsView.tsx:389,405,419,433,448,462` |
| Repo fields | `ReposView.tsx:409,422,434,446,482,576` |
| Workdir at `~/.seal/cache/workdirs/<sid>` | `src/Seal/Gateway/API.hs:457-459`; `docs/2026-07-23-per-session-workdir-design.md:100` |
| `mode=remote` → workdir on the execution machine | `Gateway/API.hs:457-458` |
| Workdir **persists** | `per-session-workdir-design.md:105,114` |
| Branch = transcript yes, **empty workdir** | `README.md:79-81` |
| "Open session workdir in Files" link in the chat header | `frontend/src/components/ChatArea.tsx:364-420` |
| The Files view | `frontend/src/App.tsx:1084` |
| CLI surface: `tui`, `serve`, `access-control`, `gen-openapi` | `src/Seal/Types/Command.hs:83-91`; `src/Seal/AppMain.hs:105` |
| Default bind loopback `:8080` | `README.md:128` |
| Access control: unconfigured / `none` / `passkey` | `docs/web-access-control.md:36-38` |
| Config at `~/.seal/config/config.toml` + `~/.seal/security.toml` | `README.md:294,298` |
| Registering a repo ≠ cloning it | `README.md:141` (`POST …/setup-repo`); `Gateway/API.hs:419-428` |
| Install snippet source | `README.md:231-235` |
| PR trigger for CI | `.github/workflows/ci.yml:5-6` |
| `gate.yml` runs on **PRs** and on **release tags** | `gate.yml:2-6`; `release.yml:32-45` |
| `gate.yml` **has** a repo checkout | `gate.yml:56-59` |
| `gate.yml` runs npm under `nix develop` (precedent) | `gate.yml:105-106` |
| `nix develop` provides node | `flake.nix:86` — `nodejs_22` |
| `pages` has **no repo checkout** — only `gh-pages` | `ci.yml:107-112` |
| `pages` has **no Nix and no setup-node** | `ci.yml:100-194` |
| `pages` tolerates missing coverage | `continue-on-error` `ci.yml:105`,`:112`; `2>/dev/null \|\| true` `:121`,`:124`; guarded copy `:129-132` |
| `pages` writes `deploy/index.html` from an **inline heredoc** | `ci.yml:165-187` — must be deleted or it overwrites the site |
| `pages` writes `deploy/api/index.html` (Swagger) | `ci.yml:138-163` — stays |
| Published base path `/seal-harness/` | `ci.yml:116` (`PAGES_BASE`); `README.md:14,16` |
| README links to `/api/index.html` + `/coverage/main/hpc_index.html` | `README.md:14,16` |
| `.gitignore` frontend block | `.gitignore:9-11` |
| `make check` = build + test + lint + frontend-test | `Makefile:39` |

**Scope consequence:** the wizard has two steps. Secrets, repos, and channels are
**post-setup** tasks done in the app. The guide must say so.

## Patterning (the "pattern it after OpenClaw/Hermes" requirement)

| Reference behaviour | What Seal does |
|---|---|
| Landing: hero (eyebrow, headline, one-line description), primary CTA **into the docs**, secondary GitHub | `index.md` hero; CTA → `docs/getting-started.md` |
| Landing: copyable **install snippet above the fold** | `index.md` uses the release-tarball command from `README.md:231-235` |
| Landing: feature grid of short honest claims | 4 cards from README claims, each linking into the docs |
| Docs: brand + "Docs" tag, persistent **left sidebar**, "Get started" group, grouped sections | sidebar from `_nav.json` |
| Docs: current page marked | `aria-current="page"` |
| Docs: dense prose, code blocks, no marketing voice | Markdown pages |

No logo/mark asset is used — the hero is type-only, because the non-goals forbid
fabricated assets and this PR ships none.

**DoD P-1:** landing has a hero, a primary CTA resolving to the rendered
getting-started page, an install snippet, and ≥3 feature cards each linking into
the docs. **DoD P-2:** every docs page renders a sidebar whose entries match
`_nav.json` in order **and grouped by section**, current page marked
`aria-current="page"`.

## Non-goals

- No versioned docs, no i18n, **no search**, **no anchor links** (see contract).
- No new dependency in the `seal` binary.
- No changes to `src/`, `test/`, or the frontend bundle.
- No fabricated screenshots or assets.

## Architecture

```
site/
  content/
    index.md                      # landing
    _nav.json                     # order + sections + titles
    docs/
      index.md                    # docs home (sidebar root)
      getting-started.md          # THE page
      sessions-and-workdirs.md    # workdir/repo model
  build.mjs                       # content/**.md -> dist/
  template.mjs                    # HTML shell (head, sidebar, footer)
  styles.css
  package.json
  package-lock.json               # REQUIRED — `npm ci` hard-fails without it
  test/build.test.mjs
  test/fixtures/
```

### Build contract (`build.mjs`) — deliberately minimal

1. Read `content/_nav.json`: an array of `{section, pages:[{title, file}]}`.
   Unparseable, empty, or naming a missing file ⇒ **fail**, message naming the
   offending path.
2. Render every `.md` under `content/`, preserving directory structure.
3. Internal links are **relative** and end in `.md` (`getting-started.md`,
   `../index.md`). Rewrite to `.html`. A link to a missing target ⇒ **fail**.
   A `.html` link is verbatim/unchecked. **An internal link carrying `#anchor`
   ⇒ fail** — anchors are out of scope, and shipping unchecked ones is worse
   than not offering them.
4. A page with no `_nav.json` entry ⇒ **warning** printed to stderr (not fatal;
   unreachable drafts shouldn't block a build).
5. Copy `styles.css` into `dist/`. Emitted asset hrefs are **relative and
   depth-correct** (`styles.css` from the root, `../styles.css` from `docs/`).
6. Any **root-relative** `/…` href in rendered output ⇒ **fail**: the site is
   served from `/seal-harness/` (`ci.yml:116`), so a root-relative path 404s.
7. Write `dist/` only on success.

Failure-branch tests use `site/test/fixtures/`, never real content.

## Work units

### WU-1 — Skeleton, build, template, tests

Creates the `site/` tree above with `content/index.md` and `content/docs/index.md`
as real pages, `_nav.json` listing exactly those two, and sidebar rendering
(grouped, `aria-current`) in `template.mjs`.

`content/docs/index.md` is a short docs home: one paragraph on what Seal is and a
link list to the two guide pages. (It is the sidebar root, so it must exist and
say something.)

Scripts: `build` → `node build.mjs`; `test` → `node --test test/`.
`package-lock.json` is generated and **committed in this WU**.

**DoD**
1. `cd site && npm ci && npm run build` produces `dist/index.html`,
   `dist/docs/index.html`, and `dist/styles.css`.
2. Fixture: a link to `missing.md` fails the build naming `missing.md`.
3. Fixture: a `_nav.json` entry with no file fails; malformed JSON fails.
4. Fixture: `docs/getting-started.md` renders as `href="getting-started.html"`;
   `../index.md` from `docs/` renders as `../index.html`.
5. Fixture: an internal `page.md#a` link fails (anchors unsupported).
6. Fixture: a root-relative `/api/index.html` href fails.
7. Asset depth: `dist/index.html` references `styles.css`,
   `dist/docs/index.html` references `../styles.css`.
8. Rendered pages contain one `<a>` per `_nav.json` page, in order, grouped under
   its section heading, current page carrying `aria-current="page"`.
9. `npm test` passes; `package-lock.json` is tracked.

### WU-2 — The docs content: getting-started + the workdir model

**Both prose pages land in one WU**, because they cross-link each other. Splitting
them would create a cycle: the build fails on a link to a not-yet-written page,
yet each page's DoD requires linking to the other. One WU, one commit, one
`_nav.json` update, no cycle.

`site/content/docs/getting-started.md`, in the operator's stated order:

1. **What you are setting up** — one paragraph. States the first-run wizard has
   **two steps** (vault, provider) and that secrets, repos, and channels are set
   up **after** it.
2. **Run the gateway** — `seal serve`, loopback `:8080`; an unconfigured install
   shows the setup screen.
3. **Wizard step 1 — the vault** — why; the three unlock modes; what
   `Create` / `Resume` / `Reopen` / `Re-check` mean.
4. **Wizard step 2 — the model provider** — the six providers; Ollama may report
   "not ready yet" without blocking completion.
5. **Add a GitHub PAT to the vault** — Secrets → new secret; the name must match
   `[A-Za-z0-9_-]+`; the value is **write-only** and is never displayed again.
6. **Register the repo that uses the PAT** — Id, URL, VCS kind, credential kind
   (PAT for `gh` operations, deploy key for pure git, machine-user for a bot
   account). Seal **derives** the vault key as `seal-pat-<id>`; the create form
   can instead **pick the existing secret from a dropdown** — that is how the
   step-5 secret is reused. `gh auth login` is refused because Seal injects
   `GH_TOKEN`.
7. **Add a chat channel** — `signal` or `telegram` only; each field; and that
   **`Allow from` is the access-control boundary** — leaving it blank allows
   everyone and is a deliberate decision, not a default to forget.
8. **Start a session** — create a session; registering a repo does *not* clone
   it, so the repo is cloned into the session's workdir via the composer or the
   session's setup-repo action; then send a message.
9. **See the session's files** — the "Open session workdir in Files" link in the
   chat header, which opens the file explorer at that session's workdir.
10. **Where to go next** — link to `sessions-and-workdirs.md`.

`site/content/docs/sessions-and-workdirs.md`:

- every session gets a **fresh, isolated** workdir at
  `~/.seal/cache/workdirs/<session-id>`; nothing is shared;
- the workdir **persists** after the session ends, for inspection;
- `mode=remote` places it on the execution machine;
- a repo is **cloned into** the workdir (not mounted, not symlinked);
- **branching** inherits the transcript but **not** the files — a past file state
  cannot be reconstructed, so the branch starts empty;
- consequences: sessions cannot clobber each other; a fresh session does not see
  yesterday's files unless it re-clones.

`_nav.json` is updated in this WU to add both pages under a "Get started" section.

**DoD**
1. Every UI label or command named appears verbatim in the cited source file.
2. No placeholder text (`TODO`, `TBD`, `<...>`, `lorem`).
3. States the wizard is exactly two steps.
4. Names `seal-<kind>-<id>` derivation *and* the reuse-existing-secret dropdown;
   names `GH_TOKEN`; states `gh auth login` is refused.
5. Names exactly `signal` and `telegram`.
6. States that registering a repo does not clone it.
7. The getting-started page contains the `[A-Za-z0-9_-]+` name rule and states
   the secret value is write-only / never redisplayed.
8. It states that `Allow from` is the access-control boundary and that blank
   allows everyone.
9. It names both the "Open session workdir in Files" link and the file explorer.
10. The workdir page names the literal path `~/.seal/cache/workdirs/<session-id>`,
    states that it persists **and** starts empty, and states the branch rule
    (transcript yes, files no).
11. The two pages link to each other in both directions.
12. Build passes; both pages appear in the sidebar under their section.

### WU-3 — Landing page

`site/content/index.md`: hero (eyebrow, headline, one-sentence what-it-is,
primary CTA `docs/getting-started.md`, secondary GitHub), install snippet from
`README.md:231-235`, then 4 capability cards from README claims (trust levels,
encrypted vault, repo credentials, multi-channel sessions), each linking into the
docs. A "Reference" block links **relatively** to `api/index.html` and
`coverage/main/hpc_index.html`.

**DoD**
1. Primary CTA source link is `docs/getting-started.md`; renders as
   `docs/getting-started.html`.
2. Every claim is traceable to `README.md` (a review criterion, stated as such —
   not an automated gate).
3. Satisfies P-1.
4. The Reference block contains both `api/index.html` and
   `coverage/main/hpc_index.html` as **relative** hrefs (asserted by test).
5. Build passes; the page is the first `_nav.json` entry.

### WU-4 — Verify before merge; deploy after merge

**4a — Pre-merge verification in `gate.yml`.** `gate.yml` has a repo checkout
(`:56-59`) and npm under `nix develop` (`:105-106`), and runs on PRs. Add one
step mirroring the frontend-test precedent:

```yaml
- name: Build and test the docs site
  run: nix develop --command bash -c 'cd site && npm ci --prefer-offline && npm test && npm run build'
```

`gate.yml` is also called by `release.yml:45`, so the site also gates releases —
correct, since a tag must not publish through a weaker check (`gate.yml:2-6`).

**4b — Deploy in `pages`.** The job has no repo checkout, no Nix, and no node
(`ci.yml:100-194`). So it must gain, in order:
1. `actions/checkout@v4` for the repo (it currently checks out only `gh-pages`,
   `ci.yml:107-112`);
2. `actions/setup-node@v4` with `node-version: 22` — matching `flake.nix:86`,
   and avoiding a Nix install in a job that has none. Then `npm ci && npm run
   build` in `site/`;
3. `cp -r site/dist/* deploy/` — **all** of `dist/`, so `styles.css` ships;
4. **delete the `deploy/index.html` heredoc** at `ci.yml:165-187`, or it
   overwrites the site landing page after the copy. The `deploy/api/index.html`
   heredoc at `:138-163` stays.

**Backward compatibility (must not regress):** `README.md:14,16` point at
`/api/index.html` and `/coverage/main/hpc_index.html` under `/seal-harness/`. The
site index links to both relatively, and the existing tolerance for a missing
coverage artifact (`continue-on-error` `:105`/`:112`, `2>/dev/null || true`
`:121`/`:124`, guarded copy `:129-132`) is **preserved** — the site build is
strict, the coverage copy stays tolerant.

**Rollback:** `peaceiris/actions-gh-pages` uses `force_orphan: true`
(`ci.yml:194`), so each deploy replaces the tree. Recovery is `git revert` of the
merge commit **pushed to `main`** — the `pages` job is gated on
`github.event_name == 'push'` (`ci.yml:95`), so a `workflow_dispatch` re-run would
skip it. The tree is fully derived from `main`; no data is lost.

**DoD** (verified by reviewing the workflow diff, not by tests that read YAML)
1. `gate.yml` gains the site build+test step; no `|| true`.
2. `pages` gains the repo checkout + `setup-node` 22 + `npm ci && npm run build`.
3. `cp -r site/dist/* deploy/` copies the whole build (incl. `styles.css`).
4. The `deploy/index.html` heredoc is deleted; `deploy/api/index.html` remains.
5. `.gitignore` gains `site/dist/` beside `frontend/dist/`.
6. `README.md` gains a "Documentation site" pointer beside the API/Coverage links.
7. The job's existing coverage tolerance is unchanged.

## Traps this plan resolves

1. **Do not document a five-step wizard.** Two steps (`State.hs:158`).
2. **Do not tell users to type a repo vault key.** Derived
   (`ReposView.tsx:89-90`); reuse via dropdown (`:519-546`).
3. **Do not expose secret values.** Names-only list; write-only value.
4. **Do not document `gh auth login`** — refused by design (`Bin.hs:145`).
5. **Do not list Discord/Slack/WhatsApp.** Only `signal`, `telegram`.
6. **Registering a repo ≠ cloning it** (`README.md:141`).
7. **Branch = empty workdir** — state it where branching first appears.
8. **The two docs pages must land together** (WU-2), or the strict link check
   deadlocks them.
9. **The `ci.yml:165` heredoc overwrites `deploy/index.html`** — delete it.
10. **Base path is `/seal-harness/`** — no root-relative hrefs.
11. **`pages` has no node** — `setup-node` is required (it has no Nix either).
12. **`site/dist/` must be gitignored.**
13. **The coverage copy stays tolerant** — do not convert it to a hard assert.

## File scope

**New**
- `site/package.json`, `site/package-lock.json`
- `site/build.mjs`, `site/template.mjs`, `site/styles.css`
- `site/content/index.md`, `site/content/_nav.json`
- `site/content/docs/{index,getting-started,sessions-and-workdirs}.md`
- `site/test/build.test.mjs`, `site/test/fixtures/**`
- `site/README.md` — **DoD:** documents
  `nix develop --command bash -c 'cd site && npm ci && npm test && npm run build'`,
  preview via `nix shell nixpkgs#python3 -c python3 -m http.server -d site/dist 8090`
  (`python3` is not in the dev shell — `flake.nix:74-87` — so it is invoked
  through `nix shell`), and the rollback note.

**Modified**
- `.github/workflows/gate.yml` — one added step (4a).
- `.github/workflows/ci.yml` — the `pages` job only (4b), incl. heredoc removal.
- `.gitignore` — add `site/dist/`.
- `README.md` — a "Documentation site" pointer.

**Explicitly untouched:** `src/`, `test/`, `frontend/`, `seal-harness.cabal`,
`flake.nix`, `Makefile`. Because `Makefile` is untouched, `make check` does not
run the site tests while `gate.yml` does — documented in `site/README.md`.

## Verification

```bash
nix develop --command bash -c 'cd site && npm ci && npm test && npm run build'
nix shell nixpkgs#python3 -c python3 -m http.server -d site/dist 8090   # not 8080
make check                                                             # nothing else moved
```

## Review history

**Round 1 — 3× FAIL.** Fixed: citations re-read; WU-1 given `docs/index.md`;
pre-merge work moved to `gate.yml`; coverage tolerance preserved; auto-derived
vault key and register≠clone corrected; `package-lock.json` committed in WU-1;
`.md`-only link form; `§Patterning` added; `.gitignore` added; the gold-plating
WU (404 + front-matter meta) **cut**, sidebar folded into WU-1's template.

**Round 2 — Scope PASS; Completeness FAIL.** Fixed: three citations corrected;
the `ci.yml:165` heredoc-overwrite hazard identified; the `/seal-harness/` base
path made a build rule with a test; DoDs added for the previously prose-only
requirements; build edge cases defined; `release.yml` propagation stated;
rollback documented; `nix develop` wrapper applied locally.

**Round 3 — 3× FAIL.** Fixed:
- `.gitignore:12-14` → **`:9-11`**; `Repo.hs:84-95` → **`:82`**;
  `SecretsView.tsx:78` → **`:77`** (with `:55` for names-only);
  `ci.yml:21-37` → **`:5-6`** for the PR trigger. Each re-read at the line.
- **The WU-2/WU-3 cycle is gone:** the two docs pages now land together in one
  WU. A forward link to an unwritten page can no longer fail the strict link
  check, and `_nav.json` is updated in the same commit.
- **`pages` toolchain specified:** repo checkout + `actions/setup-node@v4`
  (node 22, matching `flake.nix:86`). The job has no Nix, and the plan no longer
  pretends it does.
- **`styles.css` is emitted and asserted:** the build copies it to `dist/`, DoD 1
  and DoD 7 assert it, and 4b copies all of `dist/`.
- **Build scope trimmed** per the scope reviewer: orphan page downgraded from
  fail to warning; the three distinct `_nav.json` diagnostics collapsed to one
  rule; **anchor support dropped entirely** (and now actively rejected) rather
  than round-tripped unvalidated. WU-1 went from 10 DoDs to 9, six of them
  one-line fixture cases.
- **The CI-internals tests are gone:** no test greps `ci.yml` for heredoc
  markers, and no `dist/`-level assertion claims to prove what was deployed.
  4b's correctness is verified by reviewing the workflow diff, which is where an
  ordering bug actually lives.
- `content/docs/index.md` given a DoD; the hero "mark" dropped (it contradicted
  the no-fabricated-assets rule); `python3` invoked via `nix shell`; the rollback
  note corrected to "revert pushed to `main`", since `pages` is push-gated.

**Standing rebuttals.** (a) *Keep the failure-branch tests* — the build's exit-1
path is the only thing preventing a broken link from publishing; untested failure
branches are how a link checker silently stops checking. Kept, but trimmed to the
rules that earn their keep. (b) *3 of ~14 files are the requested prose; the rest
is one builder, one template, one stylesheet, one test file, and fixtures.*

## Open questions (resolved)

1. *Landing first?* No — docs first.
2. *Framework?* Markdown + a tiny Node build (operator decision).
3. *Where deploy?* `pages`; verified pre-merge in `gate.yml`.
4. *Does it gate code PRs?* Yes, via one `gate.yml` step that only fails on site
   errors.
