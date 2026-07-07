import { defineConfig, devices } from '@playwright/test'

/**
 * Playwright config for the Phase 7b capstone E2E.
 *
 * The `seal serve` Haskell gateway (which serves the built SPA + the REST
 * API + the WS stream) needs the Nix dev shell + a `cabal run` build, so we
 * can't use Playwright's built-in `webServer` (it has no notion of nix).
 * Instead `globalSetup` spawns `nix develop --command cabal run seal -- serve`
 * as a child process and waits for `/api/health` to go 200; `globalTeardown`
 * kills the process tree.
 */
export default defineConfig({
  testDir: './e2e',
  fullyParallel: false, // one seal-serve instance per run
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 0 : 0,
  workers: 1, // serialize; the shared server can't handle concurrent runs
  reporter: process.env.CI ? 'line' : 'list',
  globalSetup: './e2e/global-setup.ts',
  globalTeardown: './e2e/global-teardown.ts',
  use: {
    baseURL: process.env.SEAL_E2E_BASE_URL ?? 'http://127.0.0.1:18080',
    headless: true,
    trace: 'on-first-retry',
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
})