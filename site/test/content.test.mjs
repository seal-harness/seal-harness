// Content assertions for the two real docs pages.
//
// These are deliberately narrow: they check that the facts a reader will act on
// are actually ON the page, because those facts are easy to lose in an edit and
// expensive to get wrong. They are not a substitute for review — they assert
// presence, not correctness of prose.
//
// Each assertion maps to a line in the plan's Definition of Done for the
// getting-started work unit. The source files are read directly so a failure
// names the claim, not an HTML fragment.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const docs = join(here, '..', 'content', 'docs')

const gettingStarted = readFileSync(join(docs, 'getting-started.md'), 'utf8')
const workdirs = readFileSync(join(docs, 'sessions-and-workdirs.md'), 'utf8')

/** Collapse whitespace so a phrase that wraps across lines still matches. */
function flat(s) {
  return s.replace(/\s+/g, ' ')
}

/** Assert `page` contains `phrase`, ignoring line wrapping. */
function contains(page, phrase, why) {
  assert.ok(flat(page).includes(flat(phrase)),
    `expected the page to contain "${phrase}"${why ? ` (${why})` : ''}`)
}

// ── Getting started ─────────────────────────────────────────────────────

test('states the wizard has exactly two steps', () => {
  contains(gettingStarted, 'first-run setup wizard has exactly two steps')
})

test('states that secrets, repos and channels are set up after the wizard', () => {
  contains(gettingStarted, 'set up *after* the wizard')
})

test('secret names must match [A-Za-z0-9_-]+', () => {
  contains(gettingStarted, '[A-Za-z0-9_-]+')
})

test('states the secret value is write-only and never redisplayed', () => {
  contains(gettingStarted, 'The value is write-only')
  contains(gettingStarted, 'never displays it again')
})

test('names the derived vault key seal-pat-<id>', () => {
  contains(gettingStarted, 'seal-pat-<id>')
})

test('names the reuse-an-existing-secret dropdown path', () => {
  contains(gettingStarted, 'Reuse an existing secret')
})

test('names GH_TOKEN injection', () => {
  contains(gettingStarted, 'GH_TOKEN')
})

test('states gh auth login is refused by design', () => {
  contains(gettingStarted, 'refused by design')
})

test('names exactly the two channel kinds', () => {
  contains(gettingStarted, '**Signal**')
  contains(gettingStarted, '**Telegram**')
  // A channel kind we do not support must not be presented as available.
  for (const unsupported of ['Discord', 'Slack', 'WhatsApp']) {
    assert.ok(!gettingStarted.includes(unsupported),
      `${unsupported} is not a supported channel kind and must not be listed`)
  }
})

test('states Allow from is the access-control boundary', () => {
  contains(gettingStarted, 'access-control boundary')
  contains(gettingStarted, 'Leave blank to allow all')
})

test('states that registering a repo does not clone it', () => {
  contains(gettingStarted, 'does **not** clone it')
})

test('names the workdir link and the file explorer', () => {
  contains(gettingStarted, 'Open session workdir in Files')
  contains(gettingStarted, 'file explorer')
})

// ── Sessions and working directories ────────────────────────────────────

test('names the literal per-session workdir path', () => {
  contains(workdirs, '~/.seal/cache/workdirs/<session-id>')
})

test('states the workdir persists after the session ends', () => {
  contains(workdirs, 'not** deleted when you stop')
})

test('states a new session starts empty', () => {
  contains(workdirs, 'A new session starts empty')
})

test('states the branch rule: transcript yes, files no', () => {
  contains(workdirs, 'It does **not** inherit the files')
  contains(workdirs, 'transcript yes, files no')
})

test('states repos are cloned into the workdir', () => {
  contains(workdirs, 'cloned into')
})

test('describes the remote workdir location', () => {
  contains(workdirs, '<remote-workspace>/workdirs/<session-id>')
})

// ── Cross-links (the plan requires both directions) ─────────────────────

test('getting-started links to the workdir page', () => {
  contains(gettingStarted, 'sessions-and-workdirs.md')
})

test('the workdir page links back to getting started', () => {
  contains(workdirs, 'getting-started.md')
})

// ── No placeholder text anywhere ────────────────────────────────────────

test('the docs pages contain no placeholder text', () => {
  for (const [name, page] of [
    ['getting-started.md', gettingStarted],
    ['sessions-and-workdirs.md', workdirs],
  ]) {
    for (const marker of ['TODO', 'TBD', 'lorem', 'FIXME', 'XXX']) {
      assert.ok(!page.includes(marker), `${name} must not contain "${marker}"`)
    }
  }
})
