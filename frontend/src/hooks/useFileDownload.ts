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
  chunksDone: number
  chunksTotal: number
  bytesDone: number
  bytesTotal: number
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

// ── Hook ───────────────────────────────────────────────────────────────

export function useFileDownload(): UseFileDownloadResult {
  const [progress, setProgress] = useState<DownloadProgress | null>(null)
  const abortRef = useRef<AbortController | null>(null)
  const chunkStoreRef = useRef<Map<number, ArrayBuffer>>(new Map())
  const manifestRef = useRef<FileManifest | null>(null)
  const pathRef = useRef<string>('')
  const partialLimitRef = useRef<number | undefined>(undefined)
  const retryFnRef = useRef<(() => Promise<void>) | null>(null)

  const updateProgress = useCallback((p: Partial<DownloadProgress>) => {
    setProgress(prev => {
      const base = prev ?? {
        state: 'idle' as DownloadState,
        chunksDone: 0, chunksTotal: 0,
        bytesDone: 0, bytesTotal: 0,
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

    updateProgress({ state: 'fetching', chunksDone: 0, chunksTotal: 0, bytesDone: 0, bytesTotal: 0, error: null })

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

      updateProgress({
        chunksTotal: effectiveChunks,
        bytesTotal: Math.min(size, limit),
      })

      // Milestone live region
      const announceMilestone = (done: number, total: number) => {
        const pct = total > 0 ? Math.round((done / total) * 100) : 0
        if (pct === 0 || pct === 25 || pct === 50 || pct === 75 || pct === 100) {
          // Milestone announced via aria-live region in the component
        }
      }

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
          updateProgress({ chunksDone: i + 1, bytesDone })
          announceMilestone(i + 1, effectiveChunks)
          continue
        }

        updateProgress({ state: 'fetching', chunksDone: i, bytesDone })

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
            updateProgress({ chunksDone: 0, bytesDone: 0 })
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
        updateProgress({ state: 'verifying', chunksDone: i, bytesDone })
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
          }
        } else if (chunkRes.bytes) {
          chunkStoreRef.current.set(i, chunkRes.bytes)
          bytesDone += chunkRes.bytes.byteLength
        }

        updateProgress({ chunksDone: i + 1, bytesDone })
        announceMilestone(i + 1, effectiveChunks)
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
        chunksDone: effectiveChunks,
        bytesDone: totalHeld,
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
