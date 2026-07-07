import { readFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import { rm } from 'node:fs/promises'

/**
 * Playwright globalTeardown: kill the `seal serve` process tree started by
 * `global-setup` and clean up the temp SEAL_HOME.
 *
 * `cabal run seal` spawns `seal` as a subprocess, so we kill the whole
 * process group (the child was spawned `detached: true` in setup, so its
 * PID is the group leader).
 */

const SEAL_HOME = process.env.SEAL_E2E_HOME ?? '/tmp/seal-e2e'

export default async function globalTeardown(): Promise<void> {
  const pidFile = join(SEAL_HOME, 'server.pid')
  if (existsSync(pidFile)) {
    try {
      const pidStr = (await readFile(pidFile, 'utf8')).trim()
      const pid = Number(pidStr)
      if (Number.isInteger(pid) && pid > 0) {
        // Negative PID = signal the whole process group (the detached
        // child). SIGTERM first, then SIGKILL if it lingers.
        try { process.kill(-pid, 'SIGTERM') } catch {}
        await new Promise((r) => setTimeout(r, 800))
        try { process.kill(-pid, 'SIGKILL') } catch {}
      }
    } catch {
      // best-effort — don't fail the run on teardown
    }
  }

  // Clean up the temp SEAL_HOME (config + any sessions written during the run).
  await rm(SEAL_HOME, { recursive: true, force: true }).catch(() => {})
}