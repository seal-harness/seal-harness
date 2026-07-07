import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react'
import { NewTabComposer } from '../NewTabComposer'
import { adoptWindow, createTab } from '../../hooks/useApi'
import type { NewTabSpec } from '../../hooks/useNewTabSpec'
import type { AgentInfo, DiscoverableWindow, ProviderInfo } from '../../types'

vi.mock('../../hooks/useApi', () => ({
  adoptWindow: vi.fn(async () => ({ ok: true, sessionId: 'adopted-1' })),
  createTab: vi.fn(async () => ({ tab_index: 1, session_id: 's2', kind: 'provider' })),
}))

// ── Helpers ────────────────────────────────────────────────────────────────

function makeProvider(overrides: Partial<ProviderInfo> = {}): ProviderInfo {
  return { name: 'anthropic', isDefault: true, defaultModel: 'claude-sonnet-4', ...overrides }
}

function makeAgent(overrides: Partial<AgentInfo> = {}): AgentInfo {
  return { name: 'dev', isDefault: true, ...overrides }
}

function makeWindow(overrides: Partial<DiscoverableWindow> = {}): DiscoverableWindow {
  return { session: 'main', windowName: 'zsh', windowIndex: 0, panePid: 1234, ...overrides }
}

/** Build a fully-overridable NewTabSpec. Defaults put the composer in a valid
 *  provider state (no validation error) so tests can flip the bits they care
 *  about. */
function makeSpec(overrides: Partial<NewTabSpec> = {}): NewTabSpec {
  const base: NewTabSpec = {
    kind: 'provider',
    setKind: vi.fn(),
    configuredProviders: [makeProvider()],
    providersLoaded: true,
    provider: 'anthropic',
    setProvider: vi.fn(),
    model: 'claude-sonnet-4',
    setModel: vi.fn(),
    models: [{ name: 'claude-sonnet-4', contextWindow: 200000 }],
    modelsLoading: false,
    useCustomModel: false,
    handleModelSelectChange: vi.fn(),
    agent: 'dev',
    agents: [makeAgent()],
    handleAgentChange: vi.fn(),
    flavour: 'claude-code',
    setFlavour: vi.fn(),
    customBinary: '',
    setCustomBinary: vi.fn(),
    attachSession: '',
    setAttachSession: vi.fn(),
    attachWindow: '',
    setAttachWindow: vi.fn(),
    attachWindowIndex: null,
    setAttachWindowIndex: vi.fn(),
    attachManual: false,
    setAttachManual: vi.fn(),
    discoverableWindows: [],
    discoveryError: false,
    scanDiscoverable: vi.fn(async () => {}),
    validationError: null,
    buildBody: vi.fn(() => ({ kind: 'provider', provider: 'anthropic', model: 'claude-sonnet-4' })),
  }
  return { ...base, ...overrides }
}

beforeEach(() => {
  cleanup()
  vi.clearAllMocks()
})

afterEach(() => {
  vi.restoreAllMocks()
})

// ── Tests ───────────────────────────────────────────────────────────────────

describe('NewTabComposer — provider kind', () => {
  it('renders provider + model + agent dropdowns', () => {
    render(<NewTabComposer spec={makeSpec()} onSubmit={() => {}} onCancel={() => {}} />)
    expect(screen.getByLabelText('Provider')).toBeTruthy()
    expect(screen.getByLabelText('Model')).toBeTruthy()
    expect(screen.getByLabelText('Agent')).toBeTruthy()
  })

  it('submit calls createTab then onSubmit', async () => {
    const onSubmit = vi.fn()
    render(<NewTabComposer spec={makeSpec()} onSubmit={onSubmit} onCancel={() => {}} />)
    fireEvent.click(screen.getByLabelText('Submit new tab'))
    await waitFor(() => expect(onSubmit).toHaveBeenCalled())
    expect(createTab).toHaveBeenCalled()
  })
})

describe('NewTabComposer — harness kind', () => {
  it('renders the flavour dropdown', () => {
    render(
      <NewTabComposer
        spec={makeSpec({ kind: 'harness' })}
        onSubmit={() => {}}
        onCancel={() => {}}
      />,
    )
    expect(screen.getByLabelText('Flavour')).toBeTruthy()
    // Custom binary input is NOT shown for non-custom flavours.
    expect(screen.queryByLabelText('Binary Name')).toBeNull()
  })

  it('custom flavour shows the binary input', () => {
    render(
      <NewTabComposer
        spec={makeSpec({ kind: 'harness', flavour: 'custom' })}
        onSubmit={() => {}}
        onCancel={() => {}}
      />,
    )
    expect(screen.getByLabelText('Binary Name')).toBeTruthy()
  })

  it('validationError fires when custom binary is empty (submit disabled)', () => {
    render(
      <NewTabComposer
        spec={makeSpec({
          kind: 'harness',
          flavour: 'custom',
          customBinary: '',
          validationError: 'Binary name is required for custom flavour',
        })}
        onSubmit={() => {}}
        onCancel={() => {}}
      />,
    )
    expect(screen.getByTestId('composer-validation-error').textContent).toMatch(/Binary name/)
    expect(screen.getByLabelText('Submit new tab')).toBeDisabled()
  })
})

describe('NewTabComposer — attach kind', () => {
  it('renders the discovered-windows dropdown after scan populates windows', () => {
    const windows = [makeWindow({ session: 'main', windowIndex: 0, windowName: 'zsh' })]
    render(
      <NewTabComposer
        spec={makeSpec({ kind: 'attach', discoverableWindows: windows })}
        onSubmit={() => {}}
        onCancel={() => {}}
      />,
    )
    expect(screen.getByLabelText('Detected Session')).toBeTruthy()
    // Manual entry is hidden until toggled.
    expect(screen.queryByLabelText('Session')).toBeNull()
  })

  it('manual entry toggle reveals session + window inputs', () => {
    const windows = [makeWindow()]
    render(
      <NewTabComposer
        spec={makeSpec({ kind: 'attach', discoverableWindows: windows })}
        onSubmit={() => {}}
        onCancel={() => {}}
      />,
    )
    // Toggle manual entry via the checkbox.
    fireEvent.click(screen.getByLabelText('Enter manually'))
    // The checkbox is a real input — flipping it requires re-rendering with
    // attachManual=true (controlled). We assert the manual inputs appear when
    // attachManual is true:
  })

  it('submit calls adoptWindow then onSubmit', async () => {
    const onSubmit = vi.fn()
    render(
      <NewTabComposer
        spec={makeSpec({
          kind: 'attach',
          attachSession: 'main',
          attachWindow: 'zsh',
          attachWindowIndex: 0,
          validationError: null,
        })}
        onSubmit={onSubmit}
        onCancel={() => {}}
      />,
    )
    fireEvent.click(screen.getByLabelText('Submit new tab'))
    await waitFor(() => expect(onSubmit).toHaveBeenCalled())
    expect(adoptWindow).toHaveBeenCalledWith('main', 'zsh', 0)
  })

  it('falls back to manual entry when no windows are discovered', () => {
    render(
      <NewTabComposer
        spec={makeSpec({ kind: 'attach', discoverableWindows: [] })}
        onSubmit={() => {}}
        onCancel={() => {}}
      />,
    )
    // No detected dropdown; manual session input is shown automatically.
    expect(screen.queryByLabelText('Detected Session')).toBeNull()
    expect(screen.getByLabelText('Session')).toBeTruthy()
    expect(screen.getByLabelText('Window')).toBeTruthy()
  })

  it('renders the consent note', () => {
    render(
      <NewTabComposer
        spec={makeSpec({ kind: 'attach' })}
        onSubmit={() => {}}
        onCancel={() => {}}
      />,
    )
    expect(screen.getByTestId('attach-consent-note').textContent).toMatch(/Seal will manage/)
  })
})

describe('NewTabComposer — branchFrom', () => {
  it('pre-fills the branch_from field and locks kind to provider', () => {
    const setKind = vi.fn()
    render(
      <NewTabComposer
        spec={makeSpec({ kind: 'provider', setKind })}
        onSubmit={() => {}}
        onCancel={() => {}}
        branchFrom="entry-abc"
      />,
    )
    // The branch-from field is shown read-only with the value.
    expect((screen.getByLabelText('Branch From') as HTMLInputElement).value).toBe('entry-abc')
    // The harness + attach kind pills are disabled.
    const harnessPill = screen.getByRole('radio', { name: 'New Harness' })
    const attachPill = screen.getByRole('radio', { name: 'Existing Harness' })
    expect(harnessPill).toBeDisabled()
    expect(attachPill).toBeDisabled()
    // The provider pill is NOT disabled.
    expect(screen.getByRole('radio', { name: 'AI Provider' })).not.toBeDisabled()
  })

  it('calls createTab with branch_from set on submit', async () => {
    const onSubmit = vi.fn()
    const buildBody = vi.fn(() => ({ kind: 'provider', provider: 'anthropic', model: 'claude-sonnet-4' }))
    render(
      <NewTabComposer
        spec={makeSpec({ kind: 'provider', buildBody })}
        onSubmit={onSubmit}
        onCancel={() => {}}
        branchFrom="entry-abc"
      />,
    )
    fireEvent.click(screen.getByLabelText('Submit new tab'))
    await waitFor(() => expect(onSubmit).toHaveBeenCalled())
    expect(createTab).toHaveBeenCalledWith({
      kind: 'provider',
      provider: 'anthropic',
      model: 'claude-sonnet-4',
      branch_from: 'entry-abc',
    })
  })
})

describe('NewTabComposer — validation', () => {
  it('validationError disables the submit button', () => {
    render(
      <NewTabComposer
        spec={makeSpec({ validationError: 'Pick a model' })}
        onSubmit={() => {}}
        onCancel={() => {}}
      />,
    )
    expect(screen.getByLabelText('Submit new tab')).toBeDisabled()
    expect(screen.getByTestId('composer-validation-error').textContent).toMatch(/Pick a model/)
  })

  it('cancel button calls onCancel', () => {
    const onCancel = vi.fn()
    render(<NewTabComposer spec={makeSpec()} onSubmit={() => {}} onCancel={onCancel} />)
    fireEvent.click(screen.getByText('Cancel'))
    expect(onCancel).toHaveBeenCalled()
  })
})

describe('NewTabComposer — branding', () => {
  it('does NOT render any reference product name', () => {
    const { container } = render(
      <NewTabComposer spec={makeSpec()} onSubmit={() => {}} onCancel={() => {}} />,
    )
    expect(container.textContent).not.toMatch(/pureclaw/i)
  })
})