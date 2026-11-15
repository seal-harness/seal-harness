import { useState, useCallback, useRef, useEffect } from 'react'
import { fetchFileManifest, fetchFileChunk } from './useApi'
import type { FileManifest } from '../types'

// ── Types ─────────────────────────────────────────────────────────────

export type DownloadState =
  | 'idle'
  | 'fetching'
  | 'verifying'
  | 'interrupted'
  | 'cancelled'
  | 'partial-stop'
  | 'done'
  | 'error'

export interface DownloadProgress {
  state: DownloadState
  /** Percentage 0–100 (rounded). */
  percent: number
  /** Bytes downloaded so far. */
  bytesDone: number
  /** Total bytes to download. */
  bytesTotal: number
  /** Estimated seconds remaining, or null if not yet computable. */
  etaSeconds: number | null
  /** Download speed in bytes/second, or null if not yet computable. */
  bytesPerSecond: number | null
  error: string | null
}

export interface UseFileDownloadResult {
  progress: DownloadProgress | null
  cancel: () => void
  retry: () => void
  start: (path: string, partialLimit?: number) => Promise<void>
}

// ── SHA256 helper ──────────────────────────────────────────────────────

async function sha256(data: ArrayBuffer): Promise<string | null> {
  try {
    if (typeof crypto === 'undefined' || !crypto.subtle) return null
    const hash = await crypto.subtle.digest('SHA-256', data)
    return Array.from(new Uint8Array(hash))
      .map(b => b.toString(16).padStart(2, '0'))
      .join('')
  } catch {
    return null
  }
}

// ── Format helper ───────────────────────────────────────────────────────

function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KiB`
  if (n < 1024 * 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(1)} MiB`
  return `${(n / (1024 * 1024 * 1024)).toFixed(2)} GiB`
}

// ── ETA helper ─────────────────────────────────────────────────────────

function computeEta(bytesDone: number, bytesTotal: number, elapsedMs: number): {
  etaSeconds: number | null
  bytesPerSecond: number | null
} {
  if (bytesDone <= 0 || elapsedMs <= 0) return { etaSeconds: null, bytesPerSecond: null }
  const bytesPerSecond = bytesDone / (elapsedMs / 1000)
  if (bytesPerSecond <= 0) return { etaSeconds: null, bytesPerSecond: null }
  const remaining = bytesTotal - bytesDone
  if (remaining <= 0) return { etaSeconds: 0, bytesPerSecond }
  return { etaSeconds: remaining / bytesPerSecond, bytesPerSecond }
}

// ── Hook ───────────────────────────────────────────────────────────────

export function useFileDownload(): UseFileDownloadResult {
  const [progress, setProgress] = useState<DownloadProgress | null>(null)
  const abortRef = useRef<AbortController | null>(null)
  const chunkStoreRef = useRef<Map<number, ArrayBuffer>>(new Map())
  const manifestRef = useRef<FileManifest | null>(null)
  const pathRef = useRef<string>('')
  const partialLimitRef = useRef<number | undefined>(undefined)
  const retryFnRef = useRef<(() => Promise<void>) | null>(null)
  const startTimeRef = useRef<number>(0)

  const updateProgress = useCallback((p: Partial<DownloadProgress>) => {
    setProgress(prev => {
      const base = prev ?? {
        state: 'idle' as DownloadState,
        percent: 0,
        bytesDone: 0,
        bytesTotal: 0,
        etaSeconds: null,
        bytesPerSecond: null,
        error: null,
      }
      return { ...base, ...p }
    })
  }, [])

  const start = useCallback(async (path: string, partialLimit?: number) => {
    pathRef.current = path
    partialLimitRef.current = partialLimit
    retryFnRef.current = null

    const ac = new AbortController()
    abortRef.current = ac

    chunkStoreRef.current = new Map()
    manifestRef.current = null
    startTimeRef.current = Date.now()

    updateProgress({
      state: 'fetching', percent: 0,
      bytesDone: 0, bytesTotal: 0,
      etaSeconds: null, bytesPerSecond: null,
      error: null,
    })

    try {
      // 1. Fetch manifest
      const manifestRes = await fetchFileManifest(path)
      if (!manifestRes.ok) {
        updateProgress({ state: 'error', error: `Manifest fetch failed (HTTP ${manifestRes.status})` })
        return
      }
      const manifest = manifestRes.manifest
      manifestRef.current = manifest

      const { size, mtimeEpoch, chunkSize, chunkCount } = manifest
      const limit = partialLimit ?? Infinity
      const effectiveChunks = Math.min(chunkCount, Math.ceil(limit / chunkSize))
      const totalBytes = Math.min(size, limit)

      updateProgress({
        bytesTotal: totalBytes,
      })

      // 2. Sequential chunk fetching
      let restarted = false
      let bytesDone = 0

      for (let i = 0; i < effectiveChunks; i++) {
        if (ac.signal.aborted) {
          updateProgress({ state: 'cancelled' })
          return
        }

        // Resume: skip already-held chunks
        if (chunkStoreRef.current.has(i)) {
          bytesDone += chunkStoreRef.current.get(i)!.byteLength
          const elapsed = Date.now() - startTimeRef.current
          const { etaSeconds, bytesPerSecond } = computeEta(bytesDone, totalBytes, elapsed)
          updateProgress({
            percent: Math.round((bytesDone / totalBytes) * 100),
            bytesDone,
            etaSeconds,
            bytesPerSecond,
          })
          continue
        }

        updateProgress({ state: 'fetching', bytesDone })

        let chunkRes
        try {
          chunkRes = await fetchFileChunk(path, i, size, mtimeEpoch)
        } catch {
          chunkRes = { ok: false, status: 0 }
        }

        if (ac.signal.aborted) {
          updateProgress({ state: 'cancelled' })
          return
        }

        if (!chunkRes.ok) {
          if (chunkRes.status === 409) {
            // File changed — discard held chunks, restart once
            if (restarted) {
              updateProgress({ state: 'error', error: 'File is changing — try again later' })
              return
            }
            restarted = true
            chunkStoreRef.current.clear()
            bytesDone = 0
            i = -1 // restart loop from 0
            updateProgress({ percent: 0, bytesDone: 0, etaSeconds: null, bytesPerSecond: null })
            continue
          }
          if (chunkRes.status === 0) {
            // Network error — interrupted state
            retryFnRef.current = async () => {
              await start(path, partialLimit)
            }
            updateProgress({ state: 'interrupted', error: 'Network error' })
            return
          }
          if (chunkRes.status === 416) {
            updateProgress({ state: 'error', error: 'Chunk index out of range' })
            return
          }
          updateProgress({ state: 'error', error: `Chunk fetch failed (HTTP ${chunkRes.status})` })
          return
        }

        // 3. Verify SHA256
        updateProgress({ state: 'verifying', bytesDone })
        const expectedSha = chunkRes.sha256
        const actualSha = chunkRes.bytes ? await sha256(chunkRes.bytes) : null

        if (expectedSha && actualSha && expectedSha !== actualSha && chunkRes.bytes) {
          // Retry once on mismatch
          let retryRes
          try {
            retryRes = await fetchFileChunk(path, i, size, mtimeEpoch)
          } catch {
            retryRes = { ok: false, status: 0 }
          }
          if (!retryRes.ok || (retryRes.sha256 && retryRes.sha256 !== actualSha)) {
            updateProgress({ state: 'error', error: `Chunk ${i} integrity check failed` })
            return
          }
          if (retryRes.ok && retryRes.bytes) {
            chunkStoreRef.current.set(i, retryRes.bytes)
            bytesDone += retryRes.bytes.byteLength
          }
        } else if (chunkRes.bytes) {
          chunkStoreRef.current.set(i, chunkRes.bytes)
          bytesDone += chunkRes.bytes.byteLength
        }

        // Update progress with percentage + ETA
        const elapsed = Date.now() - startTimeRef.current
        const { etaSeconds, bytesPerSecond } = computeEta(bytesDone, totalBytes, elapsed)
        updateProgress({
          percent: Math.min(100, Math.round((bytesDone / totalBytes) * 100)),
          bytesDone,
          etaSeconds,
          bytesPerSecond,
        })
      }

      // 4. Length assertions
      const heldChunks = Array.from(chunkStoreRef.current.values())
      const totalHeld = heldChunks.reduce((s, c) => s + c.byteLength, 0)
      if (partialLimit === undefined && totalHeld !== size) {
        updateProgress({ state: 'error', error: `Length mismatch: expected ${size}, got ${totalHeld}` })
        return
      }

      // 5. Assemble and save
      const blob = new Blob(heldChunks)
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      const basename = path.split('/').pop() || 'download'
      if (partialLimit !== undefined && effectiveChunks < chunkCount) {
        const savedStr = formatBytes(Math.min(size, partialLimit))
        const totalStr = formatBytes(size)
        a.download = `${basename}.${savedStr}-of-${totalStr}.partial`
      } else {
        a.download = basename
      }
      document.body.appendChild(a)
      a.click()
      document.body.removeChild(a)
      URL.revokeObjectURL(url)

      // 6. Clear chunk store on complete download
      if (partialLimit === undefined) {
        chunkStoreRef.current.clear()
      }

      updateProgress({
        state: partialLimit !== undefined && effectiveChunks < chunkCount ? 'partial-stop' : 'done',
        percent: 100,
        bytesDone: totalHeld,
        etaSeconds: 0,
      })
    } catch (err) {
      updateProgress({ state: 'error', error: err instanceof Error ? err.message : String(err) })
    }
  }, [updateProgress])

  const cancel = useCallback(() => {
    abortRef.current?.abort()
  }, [])

  const retry = useCallback(async () => {
    if (retryFnRef.current) {
      const fn = retryFnRef.current
      retryFnRef.current = null
      await fn()
    }
  }, [])

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      abortRef.current?.abort()
    }
  }, [])

  return { progress, cancel, retry, start }
}
