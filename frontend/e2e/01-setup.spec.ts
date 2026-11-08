import { test, expect } from '@playwright/test'

/**
 * First-run setup wizard, driven for real against the `seal serve` instance
 * started by `global-setup`.
 *
 * This spec runs **before** `02-capstone.spec.ts` (Playwright orders files
 * alphabetically and `workers: 1` / `fullyParallel: false` serialise them), so
 * it is the spec that provisions the shared `SEAL_HOME`: the capstone then
 * finds a configured vault and provider instead of a wizard.
 *
 * Dependencies: `age-keygen` and `age` on the gateway's PATH. `global-setup`
 * writes `[access_control] mode = "none"`, which is the explicit operator
 * waiver the wizard's API requires — without it the setup routes answer 403 by
 * design and this spec cannot pass.
 */

test('first-run setup wizard — vault then provider', async ({ page }) => {
  await page.goto('/')

  // The wizard, not the app. It says what it is before it asks anything.
  await expect(
    page.getByRole('heading', { level: 1, name: 'Seal Harness Setup Wizard' }),
  ).toBeVisible({ timeout: 20_000 })

  // The vault step is current.
  await expect(page.getByRole('heading', { name: 'Create your vault' })).toBeVisible({
    timeout: 20_000,
  })
  await expect(page.getByRole('navigation', { name: 'Setup steps' })).toBeVisible()

  // ── Vault: local age key ──────────────────────────────────────────────
  await page.getByRole('button', { name: /local key/i }).click()
  await page.getByRole('button', { name: /^create vault$/i }).click()

  // The step flips to ready and the wizard advances to the provider step.
  await expect(page.getByRole('heading', { name: 'Choose an LLM provider' })).toBeVisible({
    timeout: 30_000,
  })

  // ── Provider: anthropic with a placeholder credential ────────────────
  await page.getByRole('radio', { name: /anthropic/i }).check()
  await page.getByLabel(/api key/i).fill('e2e-placeholder-key')
  await page.getByRole('button', { name: 'Save' }).click()

  // Both steps ready → the completion screen, which does not auto-continue.
  await expect(page.getByRole('heading', { name: 'Setup complete' })).toBeVisible({
    timeout: 20_000,
  })

  // The gate only leaves the wizard when the operator says so.
  await page.getByRole('button', { name: 'Start chatting' }).click()

  // ...and the app shell is what is left.
  await expect(page.getByText('Active Tabs').first()).toBeVisible({ timeout: 15_000 })
  await expect(page.getByRole('navigation', { name: 'Setup steps' })).toHaveCount(0)
})
