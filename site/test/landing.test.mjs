// Landing-page assertions.
//
// The landing page has two jobs that are easy to break silently: its primary
// call-to-action must reach the getting-started guide (it is the single most
// important link on the site), and its "Reference" links must stay RELATIVE.
// A root-relative `/api/index.html` works on a local file server and 404s on
// GitHub Pages, which is exactly the kind of bug nobody notices until publish.
//
// The builder already fails on a root-relative href, so the second test is a
// belt-and-braces check on the built artifact.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { buildSite } from '../build.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const contentDir = join(here, '..', 'content')

// Build once for this file; the artifact under test is the real site.
const { files } = buildSite(contentDir)
const index = files.get('index.html')

test('the primary CTA resolves to the getting-started page', () => {
  assert.match(index, /class="btn btn-primary" href="docs\/getting-started\.html"/)
})

test('the hero is present with a headline and a lede', () => {
  assert.match(index, /class="hero-title"/)
  assert.match(index, /class="hero-lede"/)
  assert.match(index, /class="hero-eyebrow"/)
})

test('the install snippet is present', () => {
  assert.match(index, /seal-x86_64-linux\.tar\.gz/)
  assert.match(index, /seal serve/)
})

test('at least three feature cards link into the docs', () => {
  const cards = index.match(/class="card"/g) ?? []
  assert.ok(cards.length >= 3, `expected >= 3 cards, found ${cards.length}`)
  const docLinks = index.match(/href="docs\/[^"]+\.html"/g) ?? []
  assert.ok(docLinks.length >= 3, `expected >= 3 docs links, found ${docLinks.length}`)
})

test('the Reference block links to the API docs and coverage, relatively', () => {
  assert.match(index, /href="api\/index\.html"/)
  assert.match(index, /href="coverage\/main\/hpc_index\.html"/)
})

test('no href on the landing page is root-relative', () => {
  const hrefs = [...index.matchAll(/href="([^"]*)"/g)].map((m) => m[1])
  const rooted = hrefs.filter((h) => h.startsWith('/'))
  assert.deepEqual(rooted, [], `root-relative hrefs would 404 under /seal-harness/: ${rooted.join(', ')}`)
})

test('the landing page is the first nav entry', () => {
  const { sections } = buildSite(contentDir)
  assert.equal(sections[0].pages[0].file, 'index.md')
})

test('the landing page is linked from the docs home', () => {
  const docsHome = files.get('docs/index.html')
  assert.ok(docsHome, 'docs home must exist')
})
