// Tests for the docs-site builder.
//
// The failure branches are the point: a link checker that silently stops
// checking is worse than none, so each rule in build.mjs's header has a test
// that proves it actually fails. Fixtures are synthesised in a temp directory
// per test, so these never touch (or depend on) the real content tree.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { tmpdir } from 'node:os'
import { buildSite, BuildError } from '../build.mjs'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

// ── Fixture helper ───────────────────────────────────────────────────────

/** Create a throwaway content tree. `files` maps a relative path to contents;
 *  `_nav.json` is written from `nav` unless `nav` is `undefined`. */
function fixture(files, nav) {
  const dir = mkdtempSync(join(tmpdir(), 'seal-site-'))
  for (const [rel, contents] of Object.entries(files)) {
    const out = join(dir, rel)
    mkdirSync(dirname(out), { recursive: true })
    writeFileSync(out, contents, 'utf8')
  }
  if (nav !== undefined) {
    writeFileSync(join(dir, '_nav.json'), JSON.stringify(nav), 'utf8')
  }
  return dir
}

/** Run `fn(dir)` and clean the fixture up afterwards. Returns fn's result. */
function withFixture(files, nav, fn) {
  const dir = fixture(files, nav)
  try {
    return fn(dir)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

/** Run buildSite expecting a BuildError; return the joined problem text. */
function expectFailure(files, nav) {
  return withFixture(files, nav, (dir) => {
    try {
      buildSite(dir)
    } catch (e) {
      assert.ok(e instanceof BuildError, `expected BuildError, got ${e?.name}: ${e?.message}`)
      return e.problems.join('\n')
    }
    assert.fail('expected the build to fail, but it succeeded')
  })
}

const NAV = [
  { section: null, pages: [{ title: 'Home', file: 'index.md' }] },
]

// ── Happy path ───────────────────────────────────────────────────────────

test('builds a page and a nested page', () => {
  withFixture({
    'index.md': '# Home\n',
    'docs/index.md': '# Docs\n',
  }, [
    { section: null, pages: [{ title: 'Home', file: 'index.md' }] },
    { section: 'Get started', pages: [{ title: 'Docs', file: 'docs/index.md' }] },
  ], (dir) => {
    const { files } = buildSite(dir)
    assert.ok(files.has('index.html'), 'root page rendered')
    assert.ok(files.has('docs/index.html'), 'nested page rendered')
    assert.match(files.get('index.html'), /<h1>Home<\/h1>/)
  })
})

// ── Rule 1: internal .md links resolve ───────────────────────────────────

test('internal .md link renders as .html', () => {
  withFixture({
    'index.md': '[guide](docs/getting-started.md)\n',
    'docs/getting-started.md': '# Guide\n',
  }, [
    { section: null, pages: [
      { title: 'Home', file: 'index.md' },
      { title: 'Guide', file: 'docs/getting-started.md' },
    ] },
  ], (dir) => {
    const { files } = buildSite(dir)
    assert.match(files.get('index.html'), /href="docs\/getting-started.html"/)
  })
})

test('a link to a missing page fails the build and names the target', () => {
  const text = expectFailure({
    'index.md': '[gone](missing.md)\n',
  }, NAV)
  assert.match(text, /missing\.md/)
})

test('a link between sibling docs pages is relative to the sibling', () => {
  withFixture({
    'index.md': '# Home\n',
    'docs/index.md': '[next](getting-started.md)\n',
    'docs/getting-started.md': '# Guide\n',
  }, [
    { section: null, pages: [
      { title: 'Home', file: 'index.md' },
      { title: 'Docs', file: 'docs/index.md' },
      { title: 'Guide', file: 'docs/getting-started.md' },
    ] },
  ], (dir) => {
    const { files } = buildSite(dir)
    assert.match(files.get('docs/index.html'), /href="getting-started\.html"/,
      'sibling link must not gain a ../ prefix')
  })
})

test('a link from a nested page up to the root is ../', () => {
  withFixture({
    'index.md': '# Home\n',
    'docs/x.md': '[home](../index.md)\n',
  }, [
    { section: null, pages: [
      { title: 'Home', file: 'index.md' },
      { title: 'X', file: 'docs/x.md' },
    ] },
  ], (dir) => {
    const { files } = buildSite(dir)
    assert.match(files.get('docs/x.html'), /href="\.\.\/index\.html"/)
  })
})

// ── Rule 2: nav validity ─────────────────────────────────────────────────

test('a nav entry with no file fails the build', () => {
  const text = expectFailure({ 'index.md': '# Home\n' }, [
    { section: null, pages: [{ title: 'Ghost', file: 'ghost.md' }] },
  ])
  assert.match(text, /ghost\.md/)
})

test('absent _nav.json fails the build', () => {
  const text = expectFailure({ 'index.md': '# Home\n' }, undefined)
  assert.match(text, /_nav\.json/i)
})

test('empty _nav.json fails the build', () => {
  const text = expectFailure({ 'index.md': '# Home\n' }, [])
  assert.match(text, /_nav\.json/i)
})

test('malformed _nav.json fails the build', () => {
  const dir = mkdtempSync(join(tmpdir(), 'seal-site-'))
  try {
    writeFileSync(join(dir, 'index.md'), '# Home\n', 'utf8')
    writeFileSync(join(dir, '_nav.json'), '{ not json', 'utf8')
    assert.throws(() => buildSite(dir), (e) => {
      assert.ok(e instanceof BuildError)
      assert.match(e.problems.join('\n'), /not valid JSON/i)
      return true
    })
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

// ── Rule 3: relative asset/link hrefs only ───────────────────────────────

test('a root-relative href fails the build', () => {
  const text = expectFailure({
    'index.md': '[api](/api/index.html)\n',
  }, NAV)
  assert.match(text, /root-relative/i)
})

test('asset href is depth-correct', () => {
  withFixture({
    'index.md': '# Home\n',
    'docs/index.md': '# Docs\n',
  }, [
    { section: null, pages: [{ title: 'Home', file: 'index.md' }] },
    { section: 'Docs', pages: [{ title: 'Docs', file: 'docs/index.md' }] },
  ], (dir) => {
    const { files } = buildSite(dir)
    assert.match(files.get('index.html'), /href="styles\.css"/)
    assert.match(files.get('docs/index.html'), /href="\.\.\/styles\.css"/)
  })
})

// ── Rule 4: anchors rejected ─────────────────────────────────────────────

test('an internal link carrying an anchor fails the build', () => {
  const text = expectFailure({
    'index.md': '[vault](docs/getting-started.md#vault)\n',
    'docs/getting-started.md': '# Guide\n',
  }, [
    { section: null, pages: [
      { title: 'Home', file: 'index.md' },
      { title: 'Guide', file: 'docs/getting-started.md' },
    ] },
  ])
  assert.match(text, /anchor/i)
})

// ── Nav rendering ────────────────────────────────────────────────────────

test('sidebar lists nav pages in order with aria-current on the current page', () => {
  withFixture({
    'index.md': '# Home\n',
    'docs/a.md': '# A\n',
    'docs/b.md': '# B\n',
  }, [
    { section: null, pages: [{ title: 'Home', file: 'index.md' }] },
    { section: 'Get started', pages: [
      { title: 'A', file: 'docs/a.md' },
      { title: 'B', file: 'docs/b.md' },
    ] },
  ], (dir) => {
    const { files } = buildSite(dir)
    const aHtml = files.get('docs/a.html')

    // Section headings render.
    assert.match(aHtml, /Get started/)

    // Order: A before B.
    const aAt = aHtml.indexOf('>A</a>')
    const bAt = aHtml.indexOf('>B</a>')
    assert.ok(aAt !== -1 && bAt !== -1, 'both nav links present')
    assert.ok(aAt < bAt, 'nav preserves _nav.json order')

    // Exactly the current page carries aria-current.
    const currentCount = (aHtml.match(/aria-current="page"/g) ?? []).length
    assert.equal(currentCount, 1, 'exactly one aria-current')
    assert.match(aHtml, /<a class="nav-link" aria-current="page" href="a\.html">A<\/a>/)
  })
})

test('nav titles are HTML-escaped', () => {
  withFixture({
    'index.md': '# Home\n',
  }, [
    { section: null, pages: [{ title: '<script>x</script>', file: 'index.md' }] },
  ], (dir) => {
    const { files } = buildSite(dir)
    const html = files.get('index.html')
    assert.ok(!html.includes('<script>x</script>'), 'title must not be injected raw')
    assert.match(html, /&lt;script&gt;/)
  })
})

// ── Orphans warn, they do not fail ───────────────────────────────────────

test('a page with no nav entry builds but warns', () => {
  const warnings = []
  const original = process.stderr.write.bind(process.stderr)
  process.stderr.write = (chunk, ...rest) => {
    warnings.push(String(chunk))
    return original(chunk, ...rest)
  }
  try {
    withFixture({
      'index.md': '# Home\n',
      'docs/draft.md': '# Draft\n',
    }, [
      { section: null, pages: [{ title: 'Home', file: 'index.md' }] },
    ], (dir) => {
      const { files } = buildSite(dir)
      assert.ok(files.has('docs/draft.html'), 'orphan still renders')
    })
  } finally {
    process.stderr.write = original
  }
  assert.match(warnings.join(''), /not in _nav\.json/)
})
