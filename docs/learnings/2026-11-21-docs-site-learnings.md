# Docs site: a link checker is only worth what its failure branches are (2026-11-21)

## What shipped

A public docs site (`site/`) — Markdown content plus a hand-rolled Node builder —
with the getting-started guide as the centrepiece, and a landing page that points
at it. Verified on PRs, deployed by the existing `pages` job. PR #345.

## Symptoms → root causes that were caught before merge

The plan-review gate ran three adversarial rounds and returned FAIL every time.
That was unpleasant and it was correct. Five real defects, each of which would
have shipped:

### 1. The Pages job would have overwritten the landing page

`ci.yml` assembled `deploy/` with an **inline heredoc** writing
`deploy/index.html` (`ci.yml:165-187`). Adding a site meant copying
`site/dist/*` into `deploy/` — and whichever of those two ran *second* won.
The heredoc was below the copy, so the site index was silently replaced by a
"Seal Harness — Docs" stub on every deploy.

**Lesson:** when you introduce a second writer for a path, audit the *existing*
writer. Adding the new thing is the obvious half; finding the thing it collides
with is the half that bites. `grep` the destination path, not just the new source.

### 2. The deploy job had no toolchain

`pages` checked out **only** `gh-pages` (`ci.yml:107-112`), so `site/` did not
exist on the runner, and the job installed no Nix and no Node. "Build the site in
the pages job" was unimplementable as first written.

**Lesson:** "add a build step to job X" is a claim about job X's environment.
Verify the checkout, the toolchain, and the working directory before asserting the
step can run. `gate.yml` *did* have a checkout and Node-via-`nix develop`, which
is exactly why pre-merge verification belonged there and deployment's toolchain
had to be added explicitly (`setup-node@v4`, matching `flake.nix`'s `nodejs_22`).

### 3. The base path would have 404'd every asset in production

The site publishes to a **project** page at `/seal-harness/` (`ci.yml:116`). A
root-relative `/styles.css` or `/api/index.html` resolves fine on a local file
server and 404s under a subpath. This class of bug is invisible without a rule.

**Lesson:** a static site under a subpath must emit only *relative* hrefs, and
that has to be a build-time assertion — not a convention. The builder now fails
on any root-relative href in rendered output.

### 4. The guide described a UI that does not exist

The first draft said to connect a repo to a PAT by "naming the same vault key".
The vault key is **derived** (`seal-pat-<id>`, `ReposView.tsx:89-90`) and there is
no free-text field for it (`:104`); reuse happens through a dropdown of existing
secret names (`:519-546`). A guide written from the data model rather than the UI
would have sent every user looking for a field that isn't there.

**Lesson:** documenting a flow requires reading the *view*, not the API. The
backend said `cVaultKey :: Text` and a free-text field is the natural reading of
that; the UI had already made it derived.

### 5. Registering a repo is not cloning it

The guide conflated them. Registration records a URL and a credential; the clone
happens per session (`README.md:141`). Since the whole point of the companion
page is that every session gets a fresh workdir, getting this wrong would have
made the next page look self-contradictory.

## Durable lessons

1. **Test the failure branches of the tool that protects you.** The builder's
   value is entirely in its exit-1 paths: a broken link, a bad nav entry, a
   root-relative href. A link checker with untested failure branches is a link
   checker that will one day silently stop checking. 15 of the 44 tests exist
   only to prove each rule actually fails.

2. **Pin the facts a reader will act on with tests, not prose.** The wizard's
   step count, the derived key, the `GH_TOKEN` mechanism, the two channel kinds,
   the branch-has-no-files rule — 21 assertions hold these. Prose drifts when
   someone edits a paragraph; a test fails loudly. For a *getting-started* page,
   a wrong fact is worse than a missing one.

3. **Run the site build in CI under the same wrapper as locally.** Node exists
   only in the Nix dev shell here. Local instructions that omit `nix develop`
   diverge from CI on the first contributor who follows them. Same for `python3`
   for the preview server — not in the dev shell, so it is invoked via
   `nix shell nixpkgs#python3`.

4. **Two CI jobs answer two different questions.** "Does the site build?" belongs
   where PRs run and a checkout exists (`gate.yml`). "Publish it" belongs where
   the deploy lives (`pages`). Putting verification only in the deploy job means
   the failures it exists to catch surface *after* merge — which is the one moment
   they are expensive.

5. **A docs change must not be able to break the code gate.** The Makefile is
   untouched, so `make check` never runs site tests; the site has its own CI
   step. Deliberate asymmetry, documented in `site/README.md` so it reads as a
   decision rather than an oversight.

6. **Anchor support you cannot verify is worse than no anchor support.** The first
   draft round-tripped `#fragment`s without ever checking that the target heading
   exists. Preserving an unverified fragment just launders a dead link. Cut
   entirely; the builder now *rejects* an anchor link.

## Process note

The plan-review gate exhausted its three iterations without consensus; per its
own protocol I escalated to the operator rather than self-certifying. The
operator approved, and two reviewers' remaining objections were about test
*volume*, which I partly accepted (dropped anchors, dropped CI-internals tests
that asserted on workflow YAML text) and partly rebutted (kept the link-integrity
suite).

The valuable finding is that **two reviewers contradicted each other** — one
demanded `styles.css` be asserted present in `dist/`, the other called that class
of assertion creep. When reviewers disagree, the disagreement itself is
information: it means the criterion is a judgment call, and the human should
make it. Escalating was the right move, not a failure of the gate.
