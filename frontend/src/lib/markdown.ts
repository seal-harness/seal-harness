/**
 * A small, dependency-free Markdown parser for transcript message bodies.
 *
 * The transcript can show a message's text either as the raw source the model
 * emitted or as formatted HTML. This module is the data half of that: it turns
 * markdown text into a block/inline tree that `MarkdownView` renders purely as
 * React elements, so model output can never inject HTML.
 *
 * Supported syntax:
 *   - ATX headings (h1–h6), fenced code blocks (``` and ~~~), horizontal rules
 *   - paragraphs with soft wrapping and hard breaks (two trailing spaces / \)
 *   - unordered + ordered lists, nested by indentation, with lazy continuation
 *   - blockquotes (nested blocks)
 *   - GFM tables with per-column alignment (`:---`, `:---:`, `---:`) and `\|`
 *   - inline bold, italic, strikethrough, code spans, and links
 *
 * Deliberate omissions: raw HTML is never interpreted (it renders as text),
 * images are rendered as links rather than `<img>` (a transcript must not fire
 * off network requests to hosts the model picks), and unsupported syntax falls
 * through to plain text rather than being dropped.
 */

export type MdAlign = 'left' | 'center' | 'right'

export type MdInline =
  | { kind: 'text'; text: string }
  | { kind: 'break' }
  | { kind: 'bold'; inline: MdInline[] }
  | { kind: 'italic'; inline: MdInline[] }
  | { kind: 'strike'; inline: MdInline[] }
  | { kind: 'code'; code: string }
  | { kind: 'link'; href: string; inline: MdInline[] }

export interface MdListItem {
  inline: MdInline[]
  /** Nested blocks belonging to this item (nested lists today). */
  blocks: MdBlock[]
}

export type MdBlock =
  | { kind: 'heading'; level: number; inline: MdInline[] }
  | { kind: 'code'; lang: string; code: string }
  | { kind: 'para'; inline: MdInline[] }
  | { kind: 'list'; ordered: boolean; start: number; items: MdListItem[] }
  | { kind: 'quote'; blocks: MdBlock[] }
  | { kind: 'hr' }
  | { kind: 'table'; align: MdAlign[]; header: MdInline[][]; rows: MdInline[][][] }

// ── URL safety ────────────────────────────────────────────────────────────

/** Only these schemes may become a clickable href. Everything else (notably
 *  `javascript:`, `data:`, `vbscript:`) returns null, and the caller renders
 *  the original markdown source as text instead. */
const ALLOWED_SCHEMES = new Set(['http', 'https', 'mailto'])

/** Validate a URL taken from model output before it reaches an href.
 *  Returns the trimmed URL when it is safe, null when it is not.
 *
 *  Browsers ignore embedded whitespace and control characters when resolving
 *  a scheme, so `java\nscript:` is a working `javascript:` URL. The probe below
 *  strips them before looking for the scheme — that is what makes the check
 *  sound rather than cosmetic. */
export function sanitizeHref(href: string): string | null {
  const trimmed = href.trim()
  if (trimmed === '') return null
  const probe = trimmed.replace(/[\u0000-\u0020\u007f]/g, '').toLowerCase()
  // Block /api/files/download* — an agent-authored markdown link to a
  // download endpoint is same-site (session cookie sent), so a single
  // human click exfiltrates file bytes with no opcode, no SafePath, no audit.
  // The download UI uses fetch(), never an <a href>, so blocking these
  // hrefs cannot break the legitimate download path. (§6.0a, T-LINK-BLOCKED)
  if (probe.startsWith('/api/files/download')) return null
  if (probe.startsWith('/') || probe.startsWith('#')) return trimmed
  const scheme = /^([a-z][a-z0-9+.-]*):/.exec(probe)
  if (scheme === null) return trimmed
  return ALLOWED_SCHEMES.has(scheme[1]!) ? trimmed : null
}

// ── Line helpers ──────────────────────────────────────────────────────────

const FENCE_RE = /^\s{0,3}(`{3,}|~{3,})\s*([^`\s]*)/
const HEADING_RE = /^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$/
const HR_RE = /^\s{0,3}(?:-{3,}|\*{3,}|_{3,})\s*$/
const QUOTE_RE = /^\s{0,3}>\s?(.*)$/
const LIST_RE = /^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$/

interface ListMarker {
  ordered: boolean
  number: number
  indent: number
  content: string
}

function leadingIndent(line: string): number {
  const m = /^[ \t]*/.exec(line)
  if (m === null) return 0
  return m[0].replace(/\t/g, '    ').length
}

function matchListMarker(line: string): ListMarker | null {
  const m = LIST_RE.exec(line)
  if (m === null) return null
  const marker = m[2]!
  const ordered = /^[0-9]/.test(marker)
  return {
    ordered,
    number: ordered ? parseInt(marker, 10) : 1,
    indent: m[1]!.replace(/\t/g, '    ').length,
    content: m[3]!,
  }
}

function nextNonBlank(lines: string[], from: number): number {
  for (let i = from; i < lines.length; i++) {
    if (lines[i]!.trim() !== '') return i
  }
  return -1
}

/** True when a line would start a block other than a paragraph — used to stop
 *  a paragraph from swallowing the block that follows it. */
function startsBlock(line: string): boolean {
  return (
    FENCE_RE.test(line) ||
    HEADING_RE.test(line) ||
    HR_RE.test(line) ||
    QUOTE_RE.test(line) ||
    matchListMarker(line) !== null
  )
}

// ── Tables ────────────────────────────────────────────────────────────────

const DELIM_CELL_RE = /^:?-+:?$/

/** Split a table row into trimmed cell sources. `\|` is an escaped pipe that
 *  belongs to the cell text; leading and trailing pipes are optional. */
function splitTableRow(line: string): string[] {
  let s = line.trim()
  if (s.startsWith('|')) s = s.slice(1)
  if (s.endsWith('|') && !s.endsWith('\\|')) s = s.slice(0, -1)
  const cells: string[] = []
  let current = ''
  for (let i = 0; i < s.length; i++) {
    const ch = s[i]!
    if (ch === '\\' && s[i + 1] === '|') {
      current += '|'
      i++
      continue
    }
    if (ch === '|') {
      cells.push(current)
      current = ''
      continue
    }
    current += ch
  }
  cells.push(current)
  return cells.map((c) => c.trim())
}

function parseAlign(cell: string): MdAlign | null {
  if (!DELIM_CELL_RE.test(cell)) return null
  const left = cell.startsWith(':')
  const right = cell.endsWith(':')
  if (left && right) return 'center'
  if (right) return 'right'
  return 'left'
}

/** A table starts at `lines[i]` when the next line is a delimiter row whose
 *  column count matches (the CommonMark/GFM rule). */
function tableAlignAt(lines: string[], i: number): MdAlign[] | null {
  const header = lines[i]
  const delim = lines[i + 1]
  if (header === undefined || delim === undefined) return null
  if (!header.includes('|') || !delim.includes('|')) return null
  const delimCells = splitTableRow(delim)
  if (delimCells.length === 0) return null
  const align: MdAlign[] = []
  for (const cell of delimCells) {
    const a = parseAlign(cell)
    if (a === null) return null
    align.push(a)
  }
  const headerCells = splitTableRow(header)
  if (headerCells.length !== align.length) return null
  return align
}

// ── Block parsing ─────────────────────────────────────────────────────────

export function parseMarkdown(text: string): MdBlock[] {
  // Normalise CRLF first: transcript payloads can arrive with Windows line
  // endings, and a stray \r inside a table cell or list item would otherwise
  // ride along into the rendered output.
  return parseBlocks(text.replace(/\r\n?/g, '\n').split('\n'))
}

function parseBlocks(lines: string[]): MdBlock[] {
  const blocks: MdBlock[] = []
  let i = 0
  while (i < lines.length) {
    const line = lines[i]!
    if (line.trim() === '') {
      i++
      continue
    }

    // Fenced code block — content is taken verbatim, no inline parsing.
    const fence = FENCE_RE.exec(line)
    if (fence !== null) {
      const fenceChar = fence[1]![0]!
      const lang = fence[2] ?? ''
      const codeLines: string[] = []
      i++
      while (i < lines.length) {
        const candidate = lines[i]!
        const trimmed = candidate.trim()
        if (trimmed.startsWith(fenceChar.repeat(3)) && trimmed === fenceChar.repeat(trimmed.length)) {
          i++
          break
        }
        codeLines.push(candidate)
        i++
      }
      blocks.push({ kind: 'code', lang, code: codeLines.join('\n') })
      continue
    }

    const heading = HEADING_RE.exec(line)
    if (heading !== null) {
      blocks.push({
        kind: 'heading',
        level: heading[1]!.length,
        inline: parseInline(heading[2]!),
      })
      i++
      continue
    }

    if (HR_RE.test(line)) {
      blocks.push({ kind: 'hr' })
      i++
      continue
    }

    const align = tableAlignAt(lines, i)
    if (align !== null) {
      const header = splitTableRow(line).map(parseInline)
      i += 2
      const rows: MdInline[][][] = []
      while (i < lines.length && lines[i]!.trim() !== '' && lines[i]!.includes('|')) {
        const cells = splitTableRow(lines[i]!)
        const row: MdInline[][] = []
        for (let c = 0; c < align.length; c++) {
          row.push(parseInline(cells[c] ?? ''))
        }
        rows.push(row)
        i++
      }
      blocks.push({ kind: 'table', align, header, rows })
      continue
    }

    const quote = QUOTE_RE.exec(line)
    if (quote !== null) {
      const inner: string[] = [quote[1]!]
      i++
      while (i < lines.length) {
        const next = QUOTE_RE.exec(lines[i]!)
        if (next !== null) {
          inner.push(next[1]!)
          i++
          continue
        }
        // A blank line inside a quote keeps the quote going when the quote
        // resumes right after it.
        if (lines[i]!.trim() === '' && QUOTE_RE.test(lines[i + 1] ?? '')) {
          inner.push('')
          i++
          continue
        }
        break
      }
      blocks.push({ kind: 'quote', blocks: parseBlocks(inner) })
      continue
    }

    const marker = matchListMarker(line)
    if (marker !== null) {
      const parsed = parseList(lines, i, marker)
      blocks.push(parsed.block)
      i = parsed.next
      continue
    }

    // Paragraph: consecutive lines up to a blank line or the start of another
    // block. Soft-wrapped lines are joined with a single space; a hard break
    // (two trailing spaces or a trailing backslash) survives as a `break`.
    const paraLines: string[] = [line]
    i++
    while (i < lines.length) {
      const next = lines[i]!
      if (next.trim() === '' || startsBlock(next) || tableAlignAt(lines, i) !== null) break
      paraLines.push(next)
      i++
    }
    blocks.push({ kind: 'para', inline: joinLines(paraLines) })
  }
  return blocks
}

/** Join paragraph source lines into inline nodes, preserving hard breaks. */
function joinLines(sourceLines: string[]): MdInline[] {
  const out: MdInline[] = []
  sourceLines.forEach((raw, idx) => {
    if (idx > 0) {
      const prev = sourceLines[idx - 1]!
      out.push(/ {2,}$|\\$/.test(prev) ? { kind: 'break' } : { kind: 'text', text: ' ' })
    }
    out.push(...parseInline(raw.trim()))
  })
  return out
}

function parseList(
  lines: string[],
  start: number,
  first: ListMarker,
): { block: MdBlock; next: number } {
  const baseIndent = first.indent
  const ordered = first.ordered
  const startNumber = first.number
  const items: MdListItem[] = []
  let i = start

  while (i < lines.length) {
    const line = lines[i]!

    if (line.trim() === '') {
      const next = nextNonBlank(lines, i)
      if (next === -1) {
        i = lines.length
        break
      }
      const nextLine = lines[next]!
      const nextMarker = matchListMarker(nextLine)
      const continues =
        (nextMarker !== null && nextMarker.indent >= baseIndent) ||
        leadingIndent(nextLine) > baseIndent
      if (!continues) break
      i = next
      continue
    }

    const marker = matchListMarker(line)
    if (marker !== null && marker.indent < baseIndent) break
    if (marker !== null && marker.indent === baseIndent && marker.ordered !== ordered) break

    if (marker !== null && marker.indent === baseIndent) {
      // A sibling item: its own text, plus any nested blocks / continuation
      // lines that follow it.
      const contentLines: string[] = [marker.content]
      const nested: MdBlock[] = []
      i++
      while (i < lines.length) {
        const tail = lines[i]!
        if (tail.trim() === '') {
          const next = nextNonBlank(lines, i)
          if (next === -1) {
            i = lines.length
            break
          }
          if (leadingIndent(lines[next]!) > baseIndent) {
            i = next
            continue
          }
          break
        }
        const tailMarker = matchListMarker(tail)
        if (tailMarker !== null && tailMarker.indent > baseIndent) {
          const parsed = parseList(lines, i, tailMarker)
          nested.push(parsed.block)
          i = parsed.next
          continue
        }
        if (tailMarker !== null && tailMarker.indent <= baseIndent) break
        // Lazy continuation: a plain line indented under the item.
        contentLines.push(tail.trim())
        i++
      }
      items.push({ inline: parseInline(contentLines.join(' ')), blocks: nested })
      continue
    }

    if (marker !== null && marker.indent > baseIndent) {
      const parent = items[items.length - 1]
      if (parent === undefined) break
      const parsed = parseList(lines, i, marker)
      parent.blocks.push(parsed.block)
      i = parsed.next
      continue
    }

    // Not a marker and not a block start: continuation of the current item.
    const current = items[items.length - 1]
    if (current === undefined) break
    const extra = parseInline(line.trim())
    if (extra.length > 0) {
      current.inline.push({ kind: 'text', text: ' ' }, ...extra)
    }
    i++
  }

  return {
    block: { kind: 'list', ordered, start: startNumber, items },
    next: i,
  }
}

// ── Inline parsing ────────────────────────────────────────────────────────

interface InlineMatch {
  start: number
  length: number
  node: MdInline
  /** Set when the syntax matched but the target was rejected (e.g. an unsafe
   *  URL) — the raw source is emitted as text so nothing is silently lost. */
  literal?: string
}

export function parseInline(text: string): MdInline[] {
  const out: MdInline[] = []
  let rest = text
  while (rest.length > 0) {
    const match = nextInline(rest)
    if (match === null) {
      out.push({ kind: 'text', text: rest })
      break
    }
    if (match.start > 0) out.push({ kind: 'text', text: rest.slice(0, match.start) })
    if (match.literal !== undefined) {
      out.push({ kind: 'text', text: match.literal })
    } else {
      out.push(match.node)
    }
    rest = rest.slice(match.start + match.length)
  }
  return coalesceText(out)
}

/** Merge adjacent text nodes so the renderer emits as few spans as possible. */
function coalesceText(nodes: MdInline[]): MdInline[] {
  const out: MdInline[] = []
  for (const node of nodes) {
    const prev = out[out.length - 1]
    if (node.kind === 'text' && node.text === '') continue
    if (node.kind === 'text' && prev !== undefined && prev.kind === 'text') {
      out[out.length - 1] = { kind: 'text', text: prev.text + node.text }
      continue
    }
    out.push(node)
  }
  return out
}

const LINK_RE = /(!?)\[([^\]]*)\]\(([^)\s]*)\)/

function nextInline(s: string): InlineMatch | null {
  const candidates: InlineMatch[] = []

  const code = matchCodeSpan(s)
  if (code !== null) candidates.push(code)

  const link = matchLink(s)
  if (link !== null) candidates.push(link)

  const bold = matchEmphasis(s, '**', (inline) => ({ kind: 'bold', inline }))
  if (bold !== null) candidates.push(bold)

  const boldUnderscore = matchEmphasis(s, '__', (inline) => ({ kind: 'bold', inline }), true)
  if (boldUnderscore !== null) candidates.push(boldUnderscore)

  const strike = matchEmphasis(s, '~~', (inline) => ({ kind: 'strike', inline }))
  if (strike !== null) candidates.push(strike)

  const italic = matchEmphasis(s, '*', (inline) => ({ kind: 'italic', inline }))
  if (italic !== null) candidates.push(italic)

  const italicUnderscore = matchEmphasis(s, '_', (inline) => ({ kind: 'italic', inline }), true)
  if (italicUnderscore !== null) candidates.push(italicUnderscore)

  if (candidates.length === 0) return null
  // Earliest match wins; on a tie the longest delimiter (bold over italic).
  return candidates.reduce((best, c) =>
    c.start < best.start || (c.start === best.start && c.length > best.length) ? c : best,
  )
}

function matchCodeSpan(s: string): InlineMatch | null {
  const open = s.indexOf('`')
  if (open === -1) return null
  let runEnd = open
  while (s[runEnd] === '`') runEnd++
  const runLength = runEnd - open
  // The closing run must be exactly as long as the opening one (CommonMark),
  // so a lone backtick never closes a ``double`` span.
  let close = -1
  let probe = runEnd
  while (probe < s.length) {
    const next = s.indexOf('`', probe)
    if (next === -1) break
    let end = next
    while (s[end] === '`') end++
    if (end - next === runLength) {
      close = next
      break
    }
    probe = end
  }
  if (close === -1) return null
  let code = s.slice(runEnd, close)
  // CommonMark: strip one leading and trailing space when both are present.
  if (code.startsWith(' ') && code.endsWith(' ') && code.trim() !== '') {
    code = code.slice(1, -1)
  }
  return {
    start: open,
    length: close + runLength - open,
    node: { kind: 'code', code },
  }
}

function matchLink(s: string): InlineMatch | null {
  const m = LINK_RE.exec(s)
  if (m === null) return null
  const start = m.index
  const length = m[0].length
  const href = sanitizeHref(m[3]!)
  if (href === null) {
    // Unsafe target: keep the original markdown as literal text.
    return { start, length, literal: m[0], node: { kind: 'text', text: m[0] } }
  }
  return {
    start,
    length,
    node: { kind: 'link', href, inline: parseInline(m[2]!) },
  }
}

/** Match `**bold**`-style emphasis. `intraWordGuard` rejects delimiters that
 *  are surrounded by word characters, so `snake_case_name` stays literal. */
function matchEmphasis(
  s: string,
  delimiter: string,
  wrap: (inline: MdInline[]) => MdInline,
  intraWordGuard = false,
): InlineMatch | null {
  let from = 0
  for (;;) {
    const open = s.indexOf(delimiter, from)
    if (open === -1) return null
    if (intraWordGuard && open > 0 && /\w/.test(s[open - 1]!)) {
      from = open + 1
      continue
    }
    const contentStart = open + delimiter.length
    const close = s.indexOf(delimiter, contentStart)
    if (close === -1) return null
    const content = s.slice(contentStart, close)
    if (content === '' || /^\s/.test(content) || /\s$/.test(content)) {
      from = open + 1
      continue
    }
    if (intraWordGuard && /\w/.test(s[close + delimiter.length] ?? '')) {
      from = open + 1
      continue
    }
    return {
      start: open,
      length: close + delimiter.length - open,
      node: wrap(parseInline(content)),
    }
  }
}

// ── Parse cache ───────────────────────────────────────────────────────────

/** Bounded LRU-ish cache: transcript rows re-render on every streamed token,
 *  and a session can hold hundreds of messages. Parsing each body once keeps
 *  the rendered view as cheap as the raw one. */
const CACHE_LIMIT = 256
const cache = new Map<string, MdBlock[]>()

export function parseMarkdownCached(text: string): MdBlock[] {
  const hit = cache.get(text)
  if (hit !== undefined) {
    cache.delete(text)
    cache.set(text, hit)
    return hit
  }
  const parsed = parseMarkdown(text)
  cache.set(text, parsed)
  if (cache.size > CACHE_LIMIT) {
    const oldest = cache.keys().next()
    if (!oldest.done) cache.delete(oldest.value)
  }
  return parsed
}

export function clearMarkdownCache(): void {
  cache.clear()
}

export function markdownCacheSize(): number {
  return cache.size
}
