import { spawn } from 'node:child_process'
import { mkdir, writeFile, rm } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { join } from 'node:path'

/**
 * Playwright globalSetup: boot a real `seal serve` Haskell gateway against
 * a temp SEAL_HOME, wait for `/api/health` to go 200, and expose the URL +
 * the spawned PID for `global-teardown` to clean up.
 *
 * The frontend must already be built (`frontend/dist/` present); the
 * `test:e2e` npm script runs `npm run build` before `playwright test`, so
 * we don't rebuild here.
 */

const PORT = 18080
const WS_PORT = 18081
const BASE_URL = process.env.SEAL_E2E_BASE_URL ?? `http://127.0.0.1:${PORT}`

// Fixed path under /tmp so global-teardown can find the PID + SEAL_HOME
// without having to thread module-level state (Playwright runs setup +
// teardown in separate module instances).
const SEAL_HOME = process.env.SEAL_E2E_HOME ?? '/tmp/seal-e2e'

// The workspace root (parent of `frontend/`). Resolve from the cwd at setup
// time — Playwright runs globalSetup with cwd = the config dir
// (`frontend/`), so `..` lands on the workspace root.
const WORKSPACE = process.env.SEAL_E2E_WORKSPACE ?? join(process.cwd(), '..')
const STATIC_DIR = join(WORKSPACE, 'frontend', 'dist')

const HEALTH_URL = `${BASE_URL}/api/health`
const HEALTH_TIMEOUT_MS = Number(process.env.SEAL_E2E_HEALTH_TIMEOUT ?? 60_000)

async function pollHealth(): Promise<void> {
  const deadline = Date.now() + HEALTH_TIMEOUT_MS
  let lastErr: unknown
  while (Date.now() < deadline) {
    try {
      const res = await fetch(HEALTH_URL)
      if (res.ok) return
      lastErr = new Error(`health ${res.status}`)
    } catch (e) {
      lastErr = e
    }
    await new Promise((r) => setTimeout(r, 500))
  }
  throw new Error(
    `seal serve did not become healthy within ${HEALTH_TIMEOUT_MS}ms at ${HEALTH_URL}: ${String(lastErr)}`,
  )
}

export default async function globalSetup(): Promise<void> {
  // Sanity: the frontend must have been built.
  if (!existsSync(join(STATIC_DIR, 'index.html'))) {
    throw new Error(
      `frontend/dist/index.html not found at ${STATIC_DIR}. Run \`npm run build\` in frontend/ before \`playwright test\`.`,
    )
  }

  // (Re)create a fresh SEAL_HOME with the gateway config.
  await rm(SEAL_HOME, { recursive: true, force: true })
  await mkdir(join(SEAL_HOME, 'config'), { recursive: true })

  const configToml = [
    '[gateway]',
    `port = ${PORT}`,
    'host = "127.0.0.1"',
    `ws_port = ${WS_PORT}`,
    `static_dir = "${STATIC_DIR}"`,
    `allowed_origins = ["http://127.0.0.1:${PORT}"]`,
    '',
  ].join('\n')
  await writeFile(join(SEAL_HOME, 'config', 'config.toml'), configToml)

  // Spawn `nix develop --command cabal run seal -- serve`. The `--` after
  // `seal` separates cabal's run-target args from the program's own args.
  const child = spawn(
    'nix',
    ['develop', '--command', 'cabal', 'run', 'seal', '--', 'serve'],
    {
      cwd: WORKSPACE,
      env: { ...process.env, SEAL_HOME },
      stdio: 'pipe',
      detached: true, // create a new process group so teardown can kill the tree
    },
  )

  // Surface stderr lines for debugging (visible in the Playwright output
  // when globalSetup throws).
  child.stderr?.on('data', (d: Buffer) => {
    process.stderr.write(`[seal serve] ${d.toString()}`)
  })
  child.on('error', (e) => {
    throw new Error(`failed to spawn seal serve: ${e.message}`)
  })

  // Persist the child's PID + the SEAL_HOME so teardown can find them.
  await writeFile(join(SEAL_HOME, 'server.pid'), String(child.pid))

  // Expose the base URL to the tests via an env var (Playwright picks up
  // env vars set in globalSetup for the test workers).
  process.env.SEAL_E2E_BASE_URL = BASE_URL

  try {
    await pollHealth()
  } catch (e) {
    // Kill the half-booted server so we don't leak a process.
    try { process.kill(-child.pid!, 'SIGTERM') } catch {}
    throw e
  }
}