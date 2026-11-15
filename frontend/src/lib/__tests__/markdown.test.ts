/**
 * Markdown parser tests.
 *
 * The transcript view renders assistant/user text either as raw source or as
 * formatted HTML. The parser is the data half of that: pure, XSS-free block
 * and inline trees the renderer turns into React elements. Tables are the
 * headline case — an LLM transcript is full of them and they read terribly as
 * raw pipes.
 */

import { describe, it, expect } from 'vitest'
import {
  parseMarkdown,
  parseInline,
  parseMarkdownCached,
  sanitizeHref,
  clearMarkdownCache,
  markdownCacheSize,
  type MdBlock,
  type MdInline,
} from '../markdown'

function blocks(text: string): MdBlock[] {
  return parseMarkdown(text)
}

function onlyBlock(text: string): MdBlock {
  const b = blocks(text)
  expect(b).toHaveLength(1)
  return b[0]!
}

function plain(inline: MdInline[]): string {
  return inline
    .map((n) => {
      switch (n.kind) {
        case 'text': return n.text
        case 'code': return n.code
        case 'break': return '\n'
        case 'link': return plain(n.inline)
        case 'bold':
        case 'italic':
        case 'strike': return plain(n.inline)
      }
    })
    .join('')
}

// ── Blocks ────────────────────────────────────────────────────────────────

describe('parseMarkdown — blocks', () => {
  it('splits paragraphs on blank lines and joins soft-wrapped lines', () => {
    const b = blocks('first line\nsecond line\n\nsecond paragraph')
    expect(b).toHaveLength(2)
    expect(b[0]).toMatchObject({ kind: 'para' })
    expect(plain((b[0] as { inline: MdInline[] }).inline)).toBe('first line second line')
    expect(plain((b[1] as { inline: MdInline[] }).inline)).toBe('second paragraph')
  })

  it('parses ATX headings of every level', () => {
    const b = blocks('# one\n\n## two\n\n### three\n\n#### four\n\n##### five\n\n###### six')
    expect(b.map((x) => (x.kind === 'heading' ? x.level : null))).toEqual([1, 2, 3, 4, 5, 6])
  })

  it('keeps a fenced code block verbatim — no inline parsing, no dropped lines', () => {
    const src = '```ts\nconst a = **not bold**\n  indented\n\nblank above\n```'
    const b = onlyBlock(src)
    expect(b).toMatchObject({ kind: 'code', lang: 'ts' })
    expect((b as { code: string }).code).toBe('const a = **not bold**\n  indented\n\nblank above')
  })

  it('parses an unclosed fenced code block to end of input', () => {
    const b = onlyBlock('```\nstill code')
    expect(b).toMatchObject({ kind: 'code', lang: '', code: 'still code' })
  })

  it('parses horizontal rules', () => {
    expect(onlyBlock('---')).toEqual({ kind: 'hr' })
    expect(onlyBlock('***')).toEqual({ kind: 'hr' })
  })

  it('parses an unordered list', () => {
    const b = onlyBlock('- alpha\n- beta\n* gamma')
    expect(b).toMatchObject({ kind: 'list', ordered: false })
    expect((b as { items: { blocks: MdBlock[] }[] }).items).toHaveLength(3)
  })

  it('parses an ordered list and honours its start number', () => {
    const b = onlyBlock('3. three\n4. four')
    expect(b).toMatchObject({ kind: 'list', ordered: true, start: 3 })
  })

  it('nests indented list items under their parent', () => {
    const b = onlyBlock('- parent\n  - child\n  - child 2\n- parent 2')
    const list = b as { items: { blocks: MdBlock[] }[] }
    expect(list.items).toHaveLength(2)
    const nested = list.items[0]!.blocks
    expect(nested).toHaveLength(1)
    expect(nested[0]).toMatchObject({ kind: 'list', ordered: false })
    expect((nested[0] as { items: unknown[] }).items).toHaveLength(2)
  })

  it('appends a lazy continuation line to the current list item', () => {
    const b = onlyBlock('- first part\n  continued here\n- second')
    const list = b as { items: { inline: MdInline[] }[] }
    expect(list.items).toHaveLength(2)
    expect(plain(list.items[0]!.inline)).toBe('first part continued here')
  })

  it('parses a blockquote, nesting its inner blocks', () => {
    const b = onlyBlock('> quoted **strong**\n> more')
    expect(b).toMatchObject({ kind: 'quote' })
    const inner = (b as { blocks: MdBlock[] }).blocks
    expect(inner).toHaveLength(1)
    expect(plain((inner[0] as { inline: MdInline[] }).inline)).toBe('quoted strong more')
  })

  it('normalises CRLF line endings (Windows payloads)', () => {
    const b = blocks('| a | b |\r\n| --- | --- |\r\n| 1 | 2 |\r\n\r\n# Title\r\n')
    expect(b.map((x) => x.kind)).toEqual(['table', 'heading'])
    const t = b[0] as { rows: MdInline[][][] }
    expect(t.rows[0]!.map(plain)).toEqual(['1', '2'])
  })
})

// ── Tables ────────────────────────────────────────────────────────────────

describe('parseMarkdown — GFM tables', () => {
  it('parses a table with a header, alignment row, and body rows', () => {
    const b = onlyBlock([
      '| Name | Status |',
      '| :--- | -----: |',
      '| build | ok |',
      '| test | failing |',
    ].join('\n'))
    expect(b).toMatchObject({ kind: 'table', align: ['left', 'right'] })
    const t = b as { header: MdInline[][]; rows: MdInline[][][] }
    expect(t.header.map(plain)).toEqual(['Name', 'Status'])
    expect(t.rows.map((r) => r.map(plain))).toEqual([['build', 'ok'], ['test', 'failing']])
  })

  it('parses a table without leading/trailing pipes and centres with :---:', () => {
    const b = onlyBlock('a | b\n:---: | ---\n1 | 2')
    expect(b).toMatchObject({ kind: 'table', align: ['center', 'left'] })
  })

  it('pads short body rows so every row has header width', () => {
    const b = onlyBlock('| a | b |\n| --- | --- |\n| 1 |')
    const t = b as { rows: MdInline[][][] }
    expect(t.rows).toHaveLength(1)
    expect(t.rows[0]!.map(plain)).toEqual(['1', ''])
  })

  it('parses inline formatting inside cells and escapes pipe via \\|', () => {
    const b = onlyBlock('| a |\n| --- |\n| **bold** `code` a \\| b |')
    const t = b as { rows: MdInline[][][] }
    expect(plain(t.rows[0]![0]!)).toBe('bold code a | b')
    expect(t.rows[0]![0]!.some((n) => n.kind === 'bold')).toBe(true)
  })

  it('does not treat a pipe line with no delimiter row as a table', () => {
    const b = blocks('a | b\nc | d')
    expect(b).toHaveLength(1)
    expect(b[0]!.kind).toBe('para')
  })

  it('ends the table at the first non-table line', () => {
    const b = blocks('| a |\n| --- |\n| 1 |\nafter')
    expect(b.map((x) => x.kind)).toEqual(['table', 'para'])
  })
})

// ── Inlines ───────────────────────────────────────────────────────────────

describe('parseInline', () => {
  it('parses bold, italic, strikethrough and code spans', () => {
    const nodes = parseInline('**b** *i* ~~s~~ `c`')
    expect(nodes.filter((n) => n.kind !== 'text').map((n) => n.kind))
      .toEqual(['bold', 'italic', 'strike', 'code'])
  })

  it('does not italicise arithmetic — * needs no inner space', () => {
    expect(plain(parseInline('2 * 3 * 4'))).toBe('2 * 3 * 4')
    expect(parseInline('2 * 3 * 4').every((n) => n.kind === 'text')).toBe(true)
  })

  it('does not treat intra-word underscores as emphasis', () => {
    expect(parseInline('snake_case_name').every((n) => n.kind === 'text')).toBe(true)
  })

  it('closes a code span only on a delimiter of the same length', () => {
    // A single backtick must not be closed by the first tick of a ``run``.
    const nodes = parseInline('`a` and ``b`c``')
    expect(nodes.filter((n) => n.kind === 'code').map((n) => (n as { code: string }).code))
      .toEqual(['a', 'b`c'])
  })

  it('parses links with text and href', () => {
    const nodes = parseInline('see [the docs](https://example.com/a?b=1)')
    const link = nodes.find((n) => n.kind === 'link')
    expect(link).toBeDefined()
    expect(link).toMatchObject({ kind: 'link', href: 'https://example.com/a?b=1' })
    expect(plain((link as { inline: MdInline[] }).inline)).toBe('the docs')
  })

  it('treats an image as a link (never emits an <img> to a remote host)', () => {
    const nodes = parseInline('![alt text](https://example.com/x.png)')
    // The image syntax becomes a link labelled with its alt text; the
    // renderer has no <img> path at all, so no remote fetch is possible.
    expect([...new Set(nodes.map((n) => n.kind))]).toEqual(['link'])
    const link = nodes[0] as { kind: 'link'; href: string; inline: MdInline[] }
    expect(link.href).toBe('https://example.com/x.png')
    expect(plain(link.inline)).toBe('alt text')
  })

  it('leaves javascript:/data: URLs as literal text', () => {
    const nodes = parseInline('[click](javascript:alert(1))')
    expect(nodes.some((n) => n.kind === 'link')).toBe(false)
    expect(plain(nodes)).toBe('[click](javascript:alert(1))')
  })

  it('keeps a hard line break for a trailing double space', () => {
    const b = onlyBlock('line one  \nline two')
    const nodes = (b as { inline: MdInline[] }).inline
    expect(nodes.some((n) => n.kind === 'break')).toBe(true)
  })

  it('handles an unterminated emphasis without dropping text', () => {
    expect(plain(parseInline('**unclosed bold'))).toBe('**unclosed bold')
  })
})

describe('sanitizeHref', () => {
  it('allows http, https, mailto and root-relative URLs', () => {
    expect(sanitizeHref('https://a.b/c')).toBe('https://a.b/c')
    expect(sanitizeHref('http://a.b')).toBe('http://a.b')
    expect(sanitizeHref('mailto:a@b.c')).toBe('mailto:a@b.c')
    expect(sanitizeHref('/session/1#msg-2')).toBe('/session/1#msg-2')
  })

  it('blocks /api/files/download* hrefs (agent exfiltration path)', () => {
    expect(sanitizeHref('/api/files/download?path=/etc/passwd')).toBeNull()
    expect(sanitizeHref('/api/files/download/chunk?path=/Users/x/.ssh/id_rsa&index=0&size=100&mtime=0')).toBeNull()
    expect(sanitizeHref('/api/files/download/manifest?path=/secret')).toBeNull()
    // Legitimate relative paths still pass
    expect(sanitizeHref('/session/1#msg-2')).toBe('/session/1#msg-2')
    expect(sanitizeHref('/files')).toBe('/files')
  })

  it('rejects javascript:, data:, vbscript: and control-character tricks', () => {
    expect(sanitizeHref('javascript:alert(1)')).toBeNull()
    expect(sanitizeHref('JaVaScRiPt:alert(1)')).toBeNull()
    expect(sanitizeHref('java\nscript:alert(1)')).toBeNull()
    expect(sanitizeHref('\u0001javascript:alert(1)')).toBeNull()
    expect(sanitizeHref('data:text/html,<script>')).toBeNull()
    expect(sanitizeHref('vbscript:x')).toBeNull()
  })
})

describe('parseMarkdownCached', () => {
  it('returns the identical array for the same input (parse once per text)', () => {
    clearMarkdownCache()
    const a = parseMarkdownCached('| a |\n| --- |\n| 1 |')
    const b = parseMarkdownCached('| a |\n| --- |\n| 1 |')
    expect(b).toBe(a)
  })

  it('keeps distinct entries for distinct input', () => {
    clearMarkdownCache()
    const a = parseMarkdownCached('alpha')
    const b = parseMarkdownCached('beta')
    expect(b).not.toBe(a)
  })

  it('stays bounded — the cache evicts instead of growing without limit', () => {
    clearMarkdownCache()
    for (let i = 0; i < 1000; i++) parseMarkdownCached(`message ${i}`)
    expect(markdownCacheSize()).toBeLessThanOrEqual(256)
  })
})
