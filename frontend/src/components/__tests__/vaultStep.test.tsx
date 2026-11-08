import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react'
import { VaultStep } from '../setup/VaultStep'
import type { SetupStep } from '../../lib/setupSteps'

function step(overrides: Partial<SetupStep> = {}): SetupStep {
  return {
    id: 'vault',
    required: true,
    status: 'pending',
    detail: 'Create an encrypted vault for API keys and tokens.',
    actions: ['create'],
    ...overrides,
  }
}

const fetchMock = vi.fn()

beforeEach(() => {
  fetchMock.mockReset()
  vi.stubGlobal('fetch', fetchMock)
})

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

function jsonResponse(status: number, body: unknown) {
  return { status, ok: status >= 200 && status < 300, json: async () => body } as Response
}

describe('VaultStep', () => {
  it('shows the backend cards only for create', () => {
    const { rerender } = render(<VaultStep step={step()} onDone={() => {}} />)
    expect(screen.getByRole('button', { name: /local age key/i })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /yubikey/i })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /my own key/i })).toBeInTheDocument()
    rerender(<VaultStep step={step({ status: 'blocked', actions: ['reopen'] })} onDone={() => {}} />)
    expect(screen.queryByRole('button', { name: /local age key/i })).toBeNull()
  })

  it('shows the YubiKey waiting state and policy in the hint', async () => {
    fetchMock.mockResolvedValue(jsonResponse(422, {
      error: 'this vault backend needs an interactive terminal',
      hint: "age-plugin-yubikey --generate --touch-policy always --pin-policy once > '~/.seal/keys/default.yubikey.txt'",
    }))
    render(<VaultStep step={step()} onDone={() => {}} />)
    fireEvent.click(screen.getByRole('button', { name: /yubikey/i }))
    // Policies are on by default, and the operator can turn them off.
    expect(screen.getByLabelText(/require a touch/i)).toBeChecked()
    expect(screen.getByLabelText(/require the pin/i)).toBeChecked()
    fireEvent.click(screen.getByRole('button', { name: /generate on the token/i }))
    await waitFor(() => expect(screen.getByText(/--touch-policy always/)).toBeInTheDocument())
    expect(screen.getByText(/--pin-policy once/)).toBeInTheDocument()
    expect(screen.getByText(/run that command in a terminal/i)).toBeInTheDocument()
    expect(fetchMock).toHaveBeenCalledWith('/api/setup/vault', expect.objectContaining({
      body: JSON.stringify({ backend: 'yubikey', touch: true, pin: true }),
    }))
  })

  it('sends recipient and identity_path for the user backend', async () => {
    fetchMock.mockResolvedValue(jsonResponse(201, { recipient: 'age1x', key_type: 'user' }))
    render(<VaultStep step={step()} onDone={() => {}} />)
    fireEvent.click(screen.getByRole('button', { name: /my own key/i }))
    fireEvent.change(screen.getByLabelText(/recipient/i), { target: { value: 'age1qqq' } })
    fireEvent.change(screen.getByLabelText(/identity file path/i), { target: { value: '/home/me/keys.txt' } })
    fireEvent.click(screen.getByRole('button', { name: /use my key/i }))
    await waitFor(() => expect(fetchMock).toHaveBeenCalled())
    expect(fetchMock).toHaveBeenCalledWith('/api/setup/vault', expect.objectContaining({
      body: JSON.stringify({
        backend: 'user',
        recipient: 'age1qqq',
        identity_path: '/home/me/keys.txt',
      }),
    }))
  })

  it('attributes a 400 to the offending field', async () => {
    fetchMock.mockResolvedValue(jsonResponse(400, {
      error: 'identity_path: identity file does not exist: /nope.txt',
    }))
    render(<VaultStep step={step()} onDone={() => {}} />)
    fireEvent.click(screen.getByRole('button', { name: /my own key/i }))
    fireEvent.change(screen.getByLabelText(/recipient/i), { target: { value: 'age1qqq' } })
    fireEvent.change(screen.getByLabelText(/identity file path/i), { target: { value: '/nope.txt' } })
    fireEvent.click(screen.getByRole('button', { name: /use my key/i }))
    const alerts = await screen.findAllByRole('alert')
    // One is the whole-request reason, one sits under the identity field.
    expect(alerts.some((el) => /identity file does not exist/i.test(el.textContent ?? ''))).toBe(true)
    const field = screen.getByLabelText(/identity file path/i).closest('label')
    expect(field?.textContent).toMatch(/identity file does not exist/i)
  })

  it('renders 409 and 422 copy and 413/415 as a bug with the code', async () => {
    fetchMock.mockResolvedValue(jsonResponse(409, {
      error: 'a vault key is already recorded; nothing was changed',
      hint: 'use the "resume" backend',
    }))
    const { rerender } = render(<VaultStep step={step()} onDone={() => {}} />)
    fireEvent.click(screen.getByRole('button', { name: /local age key/i }))
    fireEvent.click(screen.getByRole('button', { name: /create the vault/i }))
    await waitFor(() => expect(screen.getByText(/already recorded/i)).toBeInTheDocument())
    expect(screen.getByText(/use the "resume" backend/i)).toBeInTheDocument()

    fetchMock.mockResolvedValue(jsonResponse(415, {}))
    rerender(<VaultStep step={step()} onDone={() => {}} />)
    fireEvent.click(screen.getByRole('button', { name: /local age key/i }))
    fireEvent.click(screen.getByRole('button', { name: /create the vault/i }))
    await waitFor(() => expect(screen.getByText(/unexpected response \(415\)/i)).toBeInTheDocument())
    expect(screen.getByText(/looks like a bug/i)).toBeInTheDocument()
  })

  it('never pre-fills a key field', () => {
    render(<VaultStep step={step()} onDone={() => {}} />)
    fireEvent.click(screen.getByRole('button', { name: /my own key/i }))
    expect(screen.getByLabelText(/recipient/i)).toHaveValue('')
    expect(screen.getByLabelText(/identity file path/i)).toHaveValue('')
  })
})
