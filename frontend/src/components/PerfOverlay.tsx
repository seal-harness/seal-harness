/**
 * On-screen performance overlay for the transcript hot paths.
 *
 * Toggle with Ctrl+Shift+P (or Cmd+Shift+P on macOS). The toggle writes the
 * `seal.perf` localStorage flag so the setting survives reloads and the
 * underlying `lib/perf.ts` instrumentation is enabled/disabled atomically.
 *
 * When enabled, the overlay:
 *   - subscribes to `perf.subscribe()` and re-renders on every sample,
 *   - shows the last N samples per operation (most-recent-first), with each
 *     sample's `durMs`, `count`, and `meta`,
 *   - groups operations by prefix (`transcript.*`, `server.*`, `render.*`,
 *     `reconcileEntries`, `entries.merge`) so the user can see at a glance
 *     where the time is going.
 *
 * The overlay is a fixed-position, bottom-right, semi-transparent panel with
 * a high z-index. It uses inline styles only (no CSS module dependency) so
 * it can be dropped into any component tree. It renders only when the perf
 * flag is on; otherwise it returns null and pays no cost.
 *
 * @module
 */

import { useEffect, useState } from 'react'
import * as perf from '../lib/perf'
import type { PerfSnapshot, PerfSample } from '../lib/perf'

function isToggleMatch(e: KeyboardEvent): boolean {
  // Accept either Ctrl (Win/Linux) or Cmd (Mac) + Shift + P. The key label
  // differs by platform; we check both modifiers explicitly so a Mac user
  // with a non-Apple keyboard can still use Ctrl.
  const mod = e.ctrlKey || e.metaKey
  return mod && e.shiftKey && (e.key === 'P' || e.key === 'p')
}

function groupOf(opName: string): string {
  if (opName.startsWith('server.')) return 'server'
  if (opName.startsWith('transcript.')) return 'transcript'
  if (opName.startsWith('render.')) return 'render'
  if (opName === 'reconcileEntries') return 'reconcile'
  if (opName === 'entries.merge') return 'merge'
  return 'other'
}

const GROUP_ORDER = ['transcript', 'server', 'render', 'reconcile', 'merge', 'other']
const GROUP_LABEL: Record<string, string> = {
  transcript: 'Transcript (frontend)',
  server: 'Transcript (server phases)',
  render: 'React render',
  reconcile: 'WS reconcile',
  merge: 'Entries merge',
  other: 'Other',
}

function formatSample(s: PerfSample): string {
  const parts = [`${s.durMs}ms`]
  if (s.count != null) parts.push(`n=${s.count}`)
  if (s.meta) {
    const metaStr = Object.entries(s.meta)
      .filter(([, v]) => v != null)
      .map(([k, v]) => `${k}=${v}`)
      .join(' ')
    if (metaStr) parts.push(metaStr)
  }
  return parts.join(' ')
}

function relTime(at: number, nowMs: number): string {
  const ago = Math.max(0, nowMs - at)
  if (ago < 1000) return `${Math.round(ago)}ms ago`
  if (ago < 60000) return `${(ago / 1000).toFixed(1)}s ago`
  return `${Math.round(ago / 1000)}s ago`
}

/** Build a compact text report of the current snapshot, suitable for pasting
 *  into a chat/issue. For each operation we emit min / median / max / count,
 *  plus the meta of the most-recent sample so the source (legacy / conv+entries
 *  / etc.) and entry count are visible. Operations are grouped by category
 *  in the same order the overlay renders. */
function formatReport(snap: PerfSnapshot, nowMs: number): string {
  if (!snap.enabled) return 'perf instrumentation is disabled'
  const ops = Object.entries(snap.operations)
  if (ops.length === 0) return 'perf enabled, no samples recorded yet'
  const lines: string[] = []
  lines.push(`# Perf report`)
  lines.push(`Captured: ${new Date(nowMs).toISOString()}`)
  lines.push('')
  const grouped: Record<string, Array<[string, PerfSample[]]>> = {}
  for (const [opName, samples] of ops) {
    const g = groupOf(opName)
    if (!grouped[g]) grouped[g] = []
    grouped[g]!.push([opName, samples])
  }
  for (const g of GROUP_ORDER) {
    const entries = grouped[g]
    if (!entries?.length) continue
    lines.push(`## ${GROUP_LABEL[g] ?? g}`)
    for (const [opName, samples] of entries) {
      const durs = samples.map((s) => s.durMs).sort((a, b) => a - b)
      const min = durs[0]!
      const max = durs[durs.length - 1]!
      const med = durs[Math.floor(durs.length / 2)]!
      const latest = samples[0]!
      const metaStr = latest.meta
        ? ' ' + Object.entries(latest.meta)
            .filter(([, v]) => v != null)
            .map(([k, v]) => `${k}=${v}`)
            .join(' ')
        : ''
      const countStr = latest.count != null ? ` n=${latest.count}` : ''
      lines.push(`  ${opName}: min=${min} med=${med} max=${max} (${samples.length} samples, latest:${countStr}${metaStr})`)
    }
    lines.push('')
  }
  return lines.join('\n').trim()
}

/** Result of a copy attempt — `ok` for the success banner, `text` so the
 *  caller can show a manual-copy textarea when every programmatic path
 *  failed (e.g. insecure context with no `execCommand` support). */
interface CopyResult {
  ok: boolean
  text: string
}

async function copyReport(snap: PerfSnapshot): Promise<CopyResult> {
  const text = formatReport(snap, Date.now())
  // Path 1: the async Clipboard API. Works on https/localhost only.
  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(text)
      return { ok: true, text }
    } catch {
      // Fall through to the execCommand path.
    }
  }
  // Path 2: the legacy execCommand path. Works in insecure contexts.
  const ta = document.createElement('textarea')
  ta.value = text
  ta.style.position = 'fixed'
  ta.style.top = '0'
  ta.style.left = '0'
  ta.style.opacity = '0'
  ta.style.pointerEvents = 'none'
  ta.setAttribute('readonly', '')
  document.body.appendChild(ta)
  ta.select()
  let ok = false
  try { ok = document.execCommand('copy') } catch { ok = false }
  document.body.removeChild(ta)
  return { ok, text }
}

export function PerfOverlay() {
  const [snap, setSnap] = useState<PerfSnapshot>(() => perf.getSnapshot())
  const [now, setNow] = useState(() => Date.now())
  const [copied, setCopied] = useState(false)
  const [copyFailed, setCopyFailed] = useState<string | null>(null)

  // Subscribe to perf updates.
  useEffect(() => {
    const unsub = perf.subscribe(setSnap)
    return unsub
  }, [])

  // Tick `now` every 250ms so the "Xms ago" labels stay fresh.
  useEffect(() => {
    if (!perf.isEnabled()) return
    const id = window.setInterval(() => setNow(Date.now()), 250)
    return () => window.clearInterval(id)
  }, [snap.enabled])

  // Global keyboard toggle. Listens on `window` so the overlay need not be
  // focused.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (!isToggleMatch(e)) return
      e.preventDefault()
      perf.setEnabled(!perf.isEnabled())
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [])

  if (!snap.enabled) return null

  const onCopy = async () => {
    const res = await copyReport(snap)
    if (res.ok) {
      setCopied(true)
      setCopyFailed(null)
      window.setTimeout(() => setCopied(false), 1500)
    } else {
      // Clipboard write failed — surface the report so the user can
      // select+copy manually. Keep it open (no auto-dismiss) since the user
      // will need a moment to copy.
      setCopyFailed(res.text)
      setCopied(false)
    }
  }

  // Group operations by prefix for readability.
  const grouped: Record<string, Array<[string, PerfSample[]]>> = {}
  for (const opName of Object.keys(snap.operations)) {
    const g = groupOf(opName)
    if (!grouped[g]) grouped[g] = []
    grouped[g]!.push([opName, snap.operations[opName]!])
  }

  return (
    <div
      data-testid="perf-overlay"
      style={{
        position: 'fixed',
        bottom: 12,
        right: 12,
        width: 380,
        maxHeight: '60vh',
        overflow: 'auto',
        background: 'rgba(20, 20, 24, 0.92)',
        color: '#e5e5e5',
        border: '1px solid rgba(124, 108, 246, 0.5)',
        borderRadius: 8,
        padding: '8px 10px',
        fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
        fontSize: 11,
        lineHeight: 1.4,
        zIndex: 99999,
        boxShadow: '0 8px 24px rgba(0, 0, 0, 0.4)',
        pointerEvents: 'auto',
      }}
    >
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 6 }}>
        <span style={{ fontWeight: 600, color: '#a9a9f7' }}>Perf</span>
        <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
          <button
            type="button"
            onClick={() => { void onCopy() }}
            data-testid="perf-copy-report"
            style={{
              background: copied ? 'rgba(52,211,153,0.18)' : 'rgba(124,108,246,0.18)',
              color: copied ? '#34d399' : copyFailed ? '#ffb347' : '#cfcff8',
              border: `1px solid ${copied ? '#34d399' : copyFailed ? '#ffb347' : 'rgba(124,108,246,0.5)'}`,
              borderRadius: 4,
              padding: '1px 6px',
              fontSize: 10,
              cursor: 'pointer',
              fontFamily: 'inherit',
            }}
            title="Copy a text summary of all samples to the clipboard"
          >
            {copied ? 'Copied' : copyFailed ? 'Copy failed — show text' : 'Copy report'}
          </button>
          <span style={{ color: '#888', fontSize: 10 }}>Ctrl+Shift+P to hide</span>
        </div>
      </div>
      {copyFailed !== null && (
        <div data-testid="perf-copy-fallback" style={{ marginBottom: 8, borderTop: '1px solid rgba(255,179,71,0.4)', paddingTop: 6 }}>
          <div style={{ color: '#ffb347', fontSize: 10, marginBottom: 4 }}>
            Clipboard blocked. Select the text below and press Cmd/Ctrl+C:
          </div>
          <textarea
            data-testid="perf-copy-fallback-text"
            readOnly
            value={copyFailed}
            onClick={(e) => e.currentTarget.select()}
            style={{
              width: '100%',
              height: 120,
              background: 'rgba(0,0,0,0.3)',
              color: '#e5e5e5',
              border: '1px solid rgba(255,179,71,0.4)',
              borderRadius: 4,
              fontFamily: 'inherit',
              fontSize: 10,
              padding: 4,
              resize: 'vertical',
            }}
          />
          <button
            type="button"
            onClick={() => setCopyFailed(null)}
            style={{
              background: 'transparent',
              color: '#888',
              border: '1px solid #555',
              borderRadius: 4,
              padding: '1px 6px',
              fontSize: 10,
              cursor: 'pointer',
              fontFamily: 'inherit',
              marginTop: 4,
            }}
          >
            Dismiss
          </button>
        </div>
      )}
      {GROUP_ORDER.filter((g) => grouped[g]?.length).map((g) => (
        <div key={g} style={{ marginBottom: 8 }}>
          <div style={{ color: '#7c6cf6', fontWeight: 600, marginBottom: 2, borderBottom: '1px solid rgba(124,108,246,0.25)', paddingBottom: 1 }}>
            {GROUP_LABEL[g] ?? g}
          </div>
          {grouped[g]!.map(([opName, samples]) => (
            <div key={opName} style={{ marginBottom: 3 }}>
              <div style={{ color: '#cfcfcf' }}>{opName}</div>
              {samples.slice(0, 4).map((s, i) => (
                <div key={i} style={{ color: '#9a9a9a', paddingLeft: 8 }}>
                  <span style={{ color: '#b0b0b0' }}>{formatSample(s)}</span>
                  <span style={{ color: '#666', marginLeft: 6 }}>{relTime(s.at, now)}</span>
                </div>
              ))}
            </div>
          ))}
        </div>
      ))}
      {Object.keys(snap.operations).length === 0 && (
        <div style={{ color: '#888' }}>No samples yet. Click a tab to record.</div>
      )}
    </div>
  )
}