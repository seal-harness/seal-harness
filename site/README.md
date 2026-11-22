# Site build

The Seal Harness landing page and documentation site.

## Why this exists

The docs are more useful than a marketing page: a landing page that oversells an
undocumented product is worse than no landing page. So the getting-started guide
is the centrepiece, and the landing page points at it.

## Layout

```
site/
  content/                # the source of truth — Markdown only
    index.md              # landing page
    _nav.json             # sidebar order, section titles, page titles
    docs/
      index.md            # docs home
      getting-started.md
      sessions-and-workdirs.md
  build.mjs               # content/**.md -> dist/  (also the CLI entry point)
  template.mjs            # the HTML shell: head, sidebar, footer
  styles.css              # hand-written, matches the app's design tokens
  test/build.test.mjs     # node:test — the build's failure branches
```

Pages are Markdown so a docs change is a prose diff a human can review.

## Build and preview

The build runs inside the Nix dev shell, which is where `node` lives
(`flake.nix`, `nodejs_22`). Do not assume a host Node install:

```bash
nix develop --command bash -c 'cd site && npm ci && npm test && npm run build'
```

Preview the result (port 8090 — **not** 8080, which `seal serve` owns):

```bash
nix shell nixpkgs#python3 -c 'python3 -m http.server -d site/dist 8090'
```

`python3` is not in the dev shell either, hence the `nix shell` wrapper.

## The build fails on purpose

`build.mjs` refuses to publish a site with a broken internal link, a nav entry
naming a missing file, or a root-relative href. Those rules exist because each
one is a bug that has shipped in real docs sites:

- **A dead link fails the build.** The only reliable moment to catch one is
  before publish.
- **A bad `_nav.json` fails the build** (absent, unparseable, empty, or naming a
  missing file). Silently rendering an empty sidebar is worse than not building.
- **A root-relative href (`/styles.css`) fails the build.** The site is published
  to a GitHub Pages *project* site at `/seal-harness/`, so a root-relative path
  works on a local file server and 404s in production.
- **Anchors are rejected.** This builder does not verify that a `#fragment`
  target heading exists, and preserving an unverified fragment just launders a
  dead link. Link to the page instead.

A page with no `_nav.json` entry only *warns*: an unreachable draft should not
block the build.

**Write internal links as relative `.md` paths** (`docs/getting-started.md`,
`../index.md`). The builder rewrites them to `.html`. A `.html` link is treated
as verbatim and is not checked — that is deliberate, so the landing page can
point at artifacts built by other CI jobs (`api/index.html`,
`coverage/main/hpc_index.html`).

## Where it is verified and deployed

- **Before merge:** the `gate.yml` workflow builds and tests the site on every
  PR, so a broken link fails a pull request.
- **After merge:** the `pages` job in `ci.yml` assembles `deploy/` and publishes
  it. That job owns the site's `index.html` and `docs/`; the old inline
  `deploy/index.html` heredoc is gone, and the coverage report and Swagger UI
  still publish alongside at their existing paths.

**Rollback:** the deploy uses `force_orphan: true`, so each publish replaces the
`gh-pages` tree — but the tree is fully derived from `main`, so nothing is lost.
Revert the change and **push to `main`**; the `pages` job is gated on a push, so a
manual `workflow_dispatch` re-run would skip it.

## Note on `make check`

`make check` does not run the site tests: the Makefile is deliberately untouched
so a docs change cannot affect the Haskell gate. The site is verified by the
`gate.yml` step above instead.
