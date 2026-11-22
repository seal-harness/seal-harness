#!/usr/bin/env node
// Seal Harness docs-site builder.
//
// Reads `content/**.md`, renders each page through `template.mjs`, and writes
// the result to `dist/`. Deliberately small: a docs site for a handful of pages
// does not need a static-site framework, and a hand-rolled builder that FAILS
// on a broken internal link is worth more than one that silently publishes a
// 404.
//
// The whole build is pure-ish: `buildSite` takes a content directory and returns
// the rendered files in memory, so the failure branches are testable without
// touching the real tree or the filesystem beyond the input.
//
// Invariants this module enforces (each one is a bug that has shipped in real
// docs sites):
//
//   1. An internal link to a page that does not exist FAILS the build. A dead
//      link is a documentation bug, and the only reliable time to catch it is
//      before publish.
//   2. A nav entry naming a missing file FAILS, and so does unparseable or
//      empty `_nav.json`. A nav is the site's index; silently rendering an
//      empty sidebar is worse than not building.
//   3. Asset references are RELATIVE and depth-correct. The site is served from
//      a subpath (GitHub Pages project site, `/seal-harness/`), so a
//      root-relative `/styles.css` 404s in production while working perfectly
//      on a local file server. That class of bug is invisible without a rule.
//   4. Anchors are not supported and are REJECTED. Preserving a `#fragment`
//      whose target heading we never verified just launders a dead link.
//
// Orphan pages (a `.md` with no nav entry) only WARN: an unreachable draft
// should not block the build.

import { readFileSync, readdirSync, statSync, mkdirSync, writeFileSync,
         copyFileSync, rmSync, existsSync } from 'node:fs'
import { join, relative, dirname, posix, sep } from 'node:path'
import { fileURLToPath } from 'node:url'
import MarkdownIt from 'markdown-it'
import { renderPage } from './template.mjs'

// ── Errors ────────────────────────────────────────────────────────────────

/** A build failure carrying every problem found, not just the first — one
 *  build should report all the broken links an author just introduced. */
export class BuildError extends Error {
  constructor(problems) {
    super(problems.join('\n'))
    this.name = 'BuildError'
    this.problems = problems
  }
}

// ── Path helpers ──────────────────────────────────────────────────────────

/** Every `.md` file under `dir`, as POSIX-style paths relative to `dir`.
 *  Sorted so the build is deterministic (and so test expectations are stable). */
function listMarkdown(dir) {
  const out = []
  const walk = (abs) => {
    for (const name of readdirSync(abs).sort()) {
      const full = join(abs, name)
      if (statSync(full).isDirectory()) {
        walk(full)
      } else if (name.endsWith('.md')) {
        out.push(relative(dir, full).split(sep).join(posix.sep))
      }
    }
  }
  walk(dir)
  return out.sort()
}

/** `docs/getting-started.md` -> `docs/getting-started.html`. */
function mdToHtml(p) {
  return p.replace(/\.md$/, '.html')
}

/** The href a page at `fromPage` needs to reach `toPath` (both content-root
 *  relative). Always relative, so the site works under any base path. */
function relativeHref(fromPage, toPath) {
  const fromDir = posix.dirname(fromPage)
  const rel = posix.relative(fromDir === '.' ? '' : fromDir, toPath)
  // `posix.relative('', 'x')` gives 'x'; make sure we never emit a bare ''
  // or an absolute path.
  return rel === '' ? posix.basename(toPath) : rel
}

// ── Nav ───────────────────────────────────────────────────────────────────

/** Parse and validate `_nav.json`. Returns `[{section, pages:[{title,file}]}]`.
 *  Every failure mode is fatal: absent, unparseable, empty, or naming a file
 *  that does not exist. */
export function parseNav(contentDir, problems) {
  const navPath = join(contentDir, '_nav.json')
  let raw
  try {
    raw = readFileSync(navPath, 'utf8')
  } catch {
    problems.push(`_nav.json is missing (expected at ${navPath})`)
    return []
  }

  let parsed
  try {
    parsed = JSON.parse(raw)
  } catch (e) {
    problems.push(`_nav.json is not valid JSON: ${e.message}`)
    return []
  }

  if (!Array.isArray(parsed) || parsed.length === 0) {
    problems.push('_nav.json must be a non-empty array of {section, pages} objects')
    return []
  }

  const sections = []
  for (const [i, entry] of parsed.entries()) {
    if (entry === null || typeof entry !== 'object' || !Array.isArray(entry.pages)) {
      problems.push(`_nav.json[${i}] must be an object with a 'pages' array`)
      continue
    }
    const pages = []
    for (const [j, page] of entry.pages.entries()) {
      if (page === null || typeof page !== 'object'
          || typeof page.title !== 'string' || typeof page.file !== 'string') {
        problems.push(`_nav.json[${i}].pages[${j}] needs string 'title' and 'file'`)
        continue
      }
      pages.push({ title: page.title, file: page.file })
    }
    sections.push({ section: entry.section ?? null, pages })
  }
  return sections
}

// ── Link rewriting ───────────────────────────────────────────────────────

/** Rewrite internal `.md` links to `.html`, relative to the page doing the
 *  linking. Any target that is missing, any `#anchor`, and any root-relative
 *  href is recorded as a problem.
 *
 *  A `.html` link is treated as verbatim (it may point at something we do not
 *  build, e.g. `api/index.html`), so it is NOT checked. That is why the site's
 *  own cross-page references must be written as `.md`. */
export function rewriteLinks(html, pagePath, knownPages, problems) {
  return html.replace(/href="([^"]*)"/g, (whole, href) => {
    // Leave protocol/scheme links, mailto, and pure fragments alone.
    if (/^[a-z][a-z0-9+.-]*:/i.test(href) || href.startsWith('//')) return whole
    if (href.startsWith('#')) {
      problems.push(`${pagePath}: anchor-only link "${href}" is not supported`)
      return whole
    }
    if (href.startsWith('/')) {
      problems.push(
        `${pagePath}: root-relative link "${href}" — the site is served from a `
        + `subpath, so this would 404. Use a relative link.`)
      return whole
    }

    const hashAt = href.indexOf('#')
    if (hashAt !== -1) {
      problems.push(
        `${pagePath}: link "${href}" carries an anchor, which this builder does `
        + `not verify. Link to the page instead.`)
      return whole
    }

    // Split off a query, which we pass through untouched.
    const qAt = href.indexOf('?')
    const pathPart = qAt === -1 ? href : href.slice(0, qAt)
    const query = qAt === -1 ? '' : href.slice(qAt)

    if (pathPart === '' ) return whole

    // Resolve the target relative to the linking page, then back to a
    // content-root-relative path.
    const fromDir = posix.dirname(pagePath)
    const target = posix.normalize(posix.join(fromDir === '.' ? '' : fromDir, pathPart))

    if (!target.endsWith('.md')) {
      // A non-.md relative target is treated as a static asset and left alone
      // (e.g. an image). Only .md pages participate in link checking.
      return whole
    }
    if (!knownPages.has(target)) {
      problems.push(`${pagePath}: link "${href}" points at a missing page (${target})`)
      return whole
    }
    return `href="${relativeHref(pagePath, mdToHtml(target))}${query}"`
  })
}

// ── Rendering ─────────────────────────────────────────────────────────────

/** Render one page's body HTML to a full document. */
function renderBody(bodyHtml, pagePath, knownPages, problems) {
  const checked = rewriteLinks(bodyHtml, pagePath, knownPages, problems)
  return checked
}

/** Build the whole site in memory.
 *
 *  Returns `{ files: Map<relPath, contents> }` on success and throws
 *  `BuildError` when any problem was found. `contentDir` defaults to
 *  `site/content` relative to this module, and `outDirName` is only used for
 *  message text. */
export function buildSite(contentDir, { nav: overrideNav } = {}) {
  const problems = []

  const sections = overrideNav ?? parseNav(contentDir, problems)
  const pages = listMarkdown(contentDir)
  const knownPages = new Set(pages)

  // Nav entries naming a file we do not have.
  const navFiles = new Set()
  for (const { pages: navPages } of sections) {
    for (const { file } of navPages) {
      navFiles.add(file)
      if (!knownPages.has(file)) {
        problems.push(`_nav.json names "${file}", which does not exist`)
      }
    }
  }

  // Orphan pages only warn — see the module header.
  for (const page of pages) {
    if (!navFiles.has(page)) {
      process.stderr.write(`warning: ${page} is not in _nav.json (unreachable from the sidebar)\n`)
    }
  }

  // `html: true`: pages carry a little inline markup (the landing page's hero
  // and its CTA class names). Content is authored in this repo and reviewed
  // like any other code, so raw HTML is not an injection surface here — and
  // note that `rewriteLinks` runs over the rendered HTML either way, so a raw
  // `<a href="docs/x.md">` is link-checked exactly like a Markdown one.
  const md = new MarkdownIt({ html: true, linkify: false, typographer: false })

  const files = new Map()
  for (const page of pages) {
    const source = readFileSync(join(contentDir, page), 'utf8')
    const bodyHtml = renderBody(md.render(source), page, knownPages, problems)
    files.set(mdToHtml(page), renderPage({
      pagePath: page,
      bodyHtml,
      sections,
      assetHref: relativeHref(page, 'styles.css'),
      homeHref: relativeHref(page, 'index.html'),
    }))
  }

  if (problems.length > 0) throw new BuildError(problems)
  return { files, pages, sections }
}

// ── CLI ───────────────────────────────────────────────────────────────────
//
// Only reached when this file is executed directly (not when a test imports
// it). All the interesting logic is above and pure; this section does the
// filesystem side effects and owns the exit code.

const invokedDirectly = process.argv[1]
  && fileURLToPath(import.meta.url) === process.argv[1]

if (invokedDirectly) {
  const here = dirname(fileURLToPath(import.meta.url))
  const contentDir = join(here, 'content')
  const distDir = join(here, 'dist')

  let result
  try {
    result = buildSite(contentDir)
  } catch (e) {
    if (e instanceof BuildError) {
      process.stderr.write('docs site build failed:\n')
      for (const problem of e.problems) process.stderr.write(`  - ${problem}\n`)
      process.exit(1)
    }
    throw e
  }

  // Success: replace dist/ wholesale. A failed build has already exited above,
  // so a half-written tree can never be published.
  if (existsSync(distDir)) rmSync(distDir, { recursive: true, force: true })
  mkdirSync(distDir, { recursive: true })

  for (const [rel, contents] of result.files) {
    const out = join(distDir, rel)
    mkdirSync(dirname(out), { recursive: true })
    writeFileSync(out, contents, 'utf8')
  }

  copyFileSync(join(here, 'styles.css'), join(distDir, 'styles.css'))

  process.stdout.write(
    `built ${result.files.size} page(s) + styles.css into dist/\n`)
}
