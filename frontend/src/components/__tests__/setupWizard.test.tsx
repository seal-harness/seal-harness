import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react'
import { SetupWizard } from '../setup/SetupWizard'
import type { ParsedSetupState, SetupStep } from '../../lib/setupSteps'

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

function parsed(overrides: Partial<ParsedSetupState> = {}): ParsedSetupState {
  return {
    required_complete: false,
    steps: [
      step(),
      step({ id: 'provider', detail: 'Add an LLM provider.', actions: ['configure'] }),
    ],
    providers: [],
    unknownStatuses: [],
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

describe('SetupWizard', () => {
  it('renders the rail from state', () => {
    render(<SetupWizard state={parsed()} refresh={() => {}} onComplete={() => {}} />)
    const rail = screen.getByRole('navigation', { name: /setup steps/i })
    expect(rail).toHaveTextContent('Create your vault')
    expect(rail).toHaveTextContent('Choose an LLM provider')
  })

  it('auto-advances when the current step becomes ready', () => {
    const first = parsed()
    const { rerender } = render(<SetupWizard state={first} refresh={() => {}} onComplete={() => {}} />)
    expect(screen.getByRole('heading', { level: 2 })).toHaveTextContent('Create your vault')
    const advanced = parsed({
      steps: [step({ status: 'ready' }), step({ id: 'provider', actions: ['configure'] })],
    })
    rerender(<SetupWizard state={advanced} refresh={() => {}} onComplete={() => {}} />)
    expect(screen.getByRole('heading', { level: 2 })).toHaveTextContent('Choose an LLM provider')
  })

  it('renders the action bar and dispatches resume/reopen/recheck', async () => {
    const refresh = vi.fn()
    fetchMock.mockResolvedValue(jsonResponse(201, { recipient: 'age1x', key_type: 'x25519' }))
    const { rerender } = render(
      <SetupWizard
        state={parsed({ steps: [step({ status: 'pending', actions: ['resume'] }), step({ id: 'provider' })] })}
        refresh={refresh}
        onComplete={() => {}}
      />,
    )
    fireEvent.click(screen.getByRole('button', { name: /finish creating the vault/i }))
    await waitFor(() => expect(refresh).toHaveBeenCalled())
    expect(fetchMock).toHaveBeenCalledWith('/api/setup/vault', expect.objectContaining({ method: 'POST' }))

    // reopen: a 200 refreshes
    refresh.mockReset()
    rerender(
      <SetupWizard
        state={parsed({ steps: [step({ status: 'blocked', actions: ['reopen', 'recheck'] }), step({ id: 'provider' })] })}
        refresh={refresh}
        onComplete={() => {}}
      />,
    )
    fetchMock.mockResolvedValue(jsonResponse(200, { opened: true, locked: false }))
    fireEvent.click(screen.getByRole('button', { name: /reopen the vault/i }))
    await waitFor(() => expect(refresh).toHaveBeenCalled())

    // recheck: no request, just a re-probe
    refresh.mockReset()
    fetchMock.mockClear()
    fireEvent.click(screen.getByRole('button', { name: /re-check/i }))
    expect(refresh).toHaveBeenCalled()
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('shows a blocked detail with its actions', () => {
    render(
      <SetupWizard
        state={parsed({
          steps: [
            step({
              status: 'blocked',
              detail: 'The vault is configured but not open in this process.',
              actions: ['reopen'],
            }),
            step({ id: 'provider' }),
          ],
        })}
        refresh={() => {}}
        onComplete={() => {}}
      />,
    )
    expect(screen.getByText(/configured but not open/i)).toBeInTheDocument()
    expect(screen.getByRole('alert')).toHaveTextContent(/needs attention/i)
    expect(screen.getByRole('button', { name: /reopen the vault/i })).toBeInTheDocument()
  })

  it('a failed reopen terminates with recovery instructions', async () => {
    fetchMock.mockResolvedValue(jsonResponse(422, {
      error: 'the vault file cannot be opened with the recorded key',
      hint: 'restore the matching identity file',
    }))
    render(
      <SetupWizard
        state={parsed({
          steps: [
            step({ status: 'blocked', actions: ['reopen'] }),
            step({ id: 'provider' }),
          ],
        })}
        refresh={() => {}}
        onComplete={() => {}}
      />,
    )
    fireEvent.click(screen.getByRole('button', { name: /reopen the vault/i }))
    await waitFor(() => expect(screen.getAllByText(/cannot be opened with the recorded key/i).length).toBeGreaterThan(0))
    expect(screen.getByText(/vault\.age\.bak/)).toBeInTheDocument()
    expect(screen.getByText(/restore the matching identity file/i)).toBeInTheDocument()
  })

  it('the completion screen gates onComplete behind Start chatting', async () => {
    const onComplete = vi.fn()
    render(
      <SetupWizard
        state={parsed({
          required_complete: true,
          steps: [step({ status: 'ready' }), step({ id: 'provider', status: 'ready' })],
        })}
        refresh={() => {}}
        onComplete={onComplete}
      />,
    )
    expect(onComplete).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: /start chatting/i }))
    expect(onComplete).toHaveBeenCalledTimes(1)
  })

  it('there is no skip or close control', () => {
    render(<SetupWizard state={parsed()} refresh={() => {}} onComplete={() => {}} />)
    for (const name of [/skip/i, /close/i, /later/i, /dismiss/i, /cancel/i]) {
      expect(screen.queryByRole('button', { name })).toBeNull()
    }
  })

  it('an unknown required step renders a generic card, never a silent block', () => {
    const state = parsed({
      steps: [
        step({ status: 'ready' }),
        step({ id: 'provider', status: 'ready' }),
        step({ id: 'chat_channels', required: true, detail: 'Connect Telegram.', actions: [] }),
      ],
    })
    render(<SetupWizard state={state} refresh={() => {}} onComplete={() => {}} />)
    // The unknown step is current (nothing else is left) and says so.
    expect(screen.getByRole('heading', { level: 2 })).toHaveTextContent('Chat channels')
    expect(screen.getByText(/does not know how to render/i)).toBeInTheDocument()
  })

  it('focus moves to the step heading on advance', () => {
    const { rerender } = render(<SetupWizard state={parsed()} refresh={() => {}} onComplete={() => {}} />)
    rerender(
      <SetupWizard
        state={parsed({
          steps: [step({ status: 'ready' }), step({ id: 'provider' })],
        })}
        refresh={() => {}}
        onComplete={() => {}}
      />,
    )
    expect(document.activeElement).toBe(screen.getByRole('heading', { level: 2 }))
  })

  it('the rail exposes aria-current and errors are role=alert', () => {
    render(
      <SetupWizard
        state={parsed({
          steps: [
            step({ status: 'blocked', actions: ['reopen'] }),
            step({ id: 'provider' }),
          ],
        })}
        refresh={() => {}}
        onComplete={() => {}}
      />,
    )
    const current = screen.getByRole('button', { name: /create your vault/i })
    expect(current).toHaveAttribute('aria-current', 'step')
    expect(screen.getByRole('alert')).toBeInTheDocument()
  })
})
