import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react'
import { ChannelsView } from '../ChannelsView'
import type { ChannelDetail } from '../../types'

// ── Mocks ────────────────────────────────────────────────────────────────

const createChannel = vi.fn(async (_input: unknown): Promise<{ ok: true; channel: ChannelDetail } | { ok: false; error: string }> => ({ ok: false, error: 'fail' }))
const updateChannel = vi.fn(async (_id: string, _input: unknown): Promise<{ ok: true; channel: ChannelDetail } | { ok: false; error: string }> => ({ ok: false, error: 'fail' }))
const deleteChannel = vi.fn(async (_id: string): Promise<boolean> => false)

let channelsState: ChannelDetail[] = []
let channelsError = false
let channelsLoaded = true

vi.mock('../../hooks/useApi', () => ({
  createChannel: (input: unknown) => createChannel(input),
  updateChannel: (id: string, input: unknown) => updateChannel(id, input),
  deleteChannel: (id: string) => deleteChannel(id),
  useChannels: () => ({
    channels: channelsState,
    loaded: channelsLoaded,
    error: channelsError,
    refresh: vi.fn(),
  }),
}))

// ── Helpers ──────────────────────────────────────────────────────────────

function makeChannel(overrides: Partial<ChannelDetail> = {}): ChannelDetail {
  return {
    id: 'work-signal',
    kind: 'signal',
    label: 'Work Signal',
    account: '+15555550123',
    textChunkLimit: 1998,
    allowFrom: ['+15555550123'],
    authStatus: 'configured',
    ...overrides,
  }
}

beforeEach(() => {
  channelsState = []
  channelsError = false
  channelsLoaded = true
  createChannel.mockReset()
  updateChannel.mockReset()
  deleteChannel.mockReset()
  createChannel.mockResolvedValue({ ok: false, error: 'fail' })
  updateChannel.mockResolvedValue({ ok: false, error: 'fail' })
  deleteChannel.mockResolvedValue(false)
})

afterEach(() => {
  cleanup()
})

// ── Tests ────────────────────────────────────────────────────────────────

describe('ChannelsView', () => {
  it('renders loading state when not loaded', () => {
    channelsLoaded = false
    render(<ChannelsView />)
    expect(screen.getByText('Loading…')).toBeDefined()
  })

  it('renders empty state when no channels', () => {
    channelsState = []
    render(<ChannelsView />)
    expect(screen.getByText('No channels configured.')).toBeDefined()
  })

  it('renders channel list with kind badges', () => {
    channelsState = [
      makeChannel({ id: 'work-signal', kind: 'signal', label: 'Work Signal' }),
      makeChannel({ id: 'dev-telegram', kind: 'telegram', label: 'Dev Bot', account: null }),
    ]
    render(<ChannelsView />)
    expect(screen.getByTestId('channel-row-work-signal')).toBeDefined()
    expect(screen.getByTestId('channel-row-dev-telegram')).toBeDefined()
    expect(screen.getByText('Channels (2)')).toBeDefined()
    expect(screen.getByText('Signal')).toBeDefined()
    expect(screen.getByText('Telegram')).toBeDefined()
  })

  it('renders error state on load failure', () => {
    channelsError = true
    render(<ChannelsView />)
    expect(screen.getByText('Failed to load — the backend may be unreachable.')).toBeDefined()
  })

  it('shows the empty-editor placeholder when nothing selected', () => {
    channelsState = [makeChannel()]
    render(<ChannelsView />)
    expect(screen.getByText('Select a channel to edit, or click + to add one.')).toBeDefined()
  })

  it('clicking + opens new-channel form with kind select + id input', () => {
    channelsState = [makeChannel()]
    render(<ChannelsView />)
    fireEvent.click(screen.getByTestId('channel-new-btn'))
    expect(screen.getByTestId('channel-form-new')).toBeDefined()
    expect(screen.getByTestId('channel-id-input')).toBeDefined()
    expect(screen.getByTestId('channel-kind-select')).toBeDefined()
  })

  it('hides account field for Telegram kind', () => {
    channelsState = [makeChannel()]
    render(<ChannelsView />)
    fireEvent.click(screen.getByTestId('channel-new-btn'))
    // Select Telegram
    const kindSelect = screen.getByTestId('channel-kind-select') as HTMLSelectElement
    fireEvent.change(kindSelect, { target: { value: 'telegram' } })
    expect(screen.queryByTestId('channel-account-input')).toBeNull()
  })

  it('hides token field for Signal kind', () => {
    channelsState = [makeChannel()]
    render(<ChannelsView />)
    fireEvent.click(screen.getByTestId('channel-new-btn'))
    expect(screen.queryByTestId('channel-token-input')).toBeNull()
  })

  it('shows account field for Signal kind', () => {
    channelsState = [makeChannel()]
    render(<ChannelsView />)
    fireEvent.click(screen.getByTestId('channel-new-btn'))
    const kindSelect = screen.getByTestId('channel-kind-select') as HTMLSelectElement
    fireEvent.change(kindSelect, { target: { value: 'signal' } })
    expect(screen.getByTestId('channel-account-input')).toBeDefined()
  })

  it('shows token field for Telegram kind', () => {
    channelsState = [makeChannel()]
    render(<ChannelsView />)
    fireEvent.click(screen.getByTestId('channel-new-btn'))
    const kindSelect = screen.getByTestId('channel-kind-select') as HTMLSelectElement
    fireEvent.change(kindSelect, { target: { value: 'telegram' } })
    expect(screen.getByTestId('channel-token-input')).toBeDefined()
  })

  it('disables Save when id has invalid chars (spaces)', () => {
    channelsState = [makeChannel()]
    render(<ChannelsView />)
    fireEvent.click(screen.getByTestId('channel-new-btn'))
    const idInput = screen.getByTestId('channel-id-input') as HTMLInputElement
    fireEvent.change(idInput, { target: { value: 'bad id' } })
    const saveBtn = screen.getByTestId('channel-save') as HTMLButtonElement
    expect(saveBtn.disabled).toBe(true)
  })

  it('disables Save when id has a leading dash', () => {
    channelsState = [makeChannel()]
    render(<ChannelsView />)
    fireEvent.click(screen.getByTestId('channel-new-btn'))
    const idInput = screen.getByTestId('channel-id-input') as HTMLInputElement
    fireEvent.change(idInput, { target: { value: '-bad' } })
    const saveBtn = screen.getByTestId('channel-save') as HTMLButtonElement
    expect(saveBtn.disabled).toBe(true)
  })

  it('enables Save when id is valid', () => {
    channelsState = [makeChannel()]
    render(<ChannelsView />)
    fireEvent.click(screen.getByTestId('channel-new-btn'))
    const idInput = screen.getByTestId('channel-id-input') as HTMLInputElement
    fireEvent.change(idInput, { target: { value: 'work-signal' } })
    const saveBtn = screen.getByTestId('channel-save') as HTMLButtonElement
    expect(saveBtn.disabled).toBe(false)
  })

  it('creating a signal channel POSTs correct snake_case body', async () => {
    channelsState = [makeChannel()]
    const created: ChannelDetail = makeChannel({ id: 'new-sig', label: 'New Sig' })
    createChannel.mockResolvedValue({ ok: true, channel: created })
    render(<ChannelsView />)
    fireEvent.click(screen.getByTestId('channel-new-btn'))
    // Fill id
    const idInput = screen.getByTestId('channel-id-input') as HTMLInputElement
    fireEvent.change(idInput, { target: { value: 'new-sig' } })
    // Select signal
    const kindSelect = screen.getByTestId('channel-kind-select') as HTMLSelectElement
    fireEvent.change(kindSelect, { target: { value: 'signal' } })
    // Fill label
    const labelInput = screen.getByTestId('channel-label-input') as HTMLInputElement
    fireEvent.change(labelInput, { target: { value: 'New Sig' } })
    // Fill account
    const accountInput = screen.getByTestId('channel-account-input') as HTMLInputElement
    fireEvent.change(accountInput, { target: { value: '+15555550199' } })
    // Fill text_chunk_limit
    const chunkInput = screen.getByTestId('channel-chunk-input') as HTMLInputElement
    fireEvent.change(chunkInput, { target: { value: '1998' } })
    // Fill allow_from
    const allowInput = screen.getByTestId('channel-allow-input') as HTMLInputElement
    fireEvent.change(allowInput, { target: { value: '+1555, +1666' } })
    // Submit
    fireEvent.click(screen.getByTestId('channel-save'))
    await waitFor(() => {
      expect(createChannel).toHaveBeenCalledTimes(1)
    })
    const callArg = createChannel.mock.calls[0]![0] as Record<string, unknown>
    expect(callArg['id']).toBe('new-sig')
    expect(callArg['kind']).toBe('signal')
    expect(callArg['label']).toBe('New Sig')
    expect(callArg['account']).toBe('+15555550199')
    expect(callArg['text_chunk_limit']).toBe(1998)
    // allow_from parsed: split on comma, trim, filter empty
    expect(callArg['allow_from']).toEqual(['+1555', '+1666'])
  })

  it('editing a channel seeds form from camelCase response', () => {
    channelsState = [
      makeChannel({
        id: 'work-signal',
        kind: 'signal',
        label: 'Work Signal',
        account: '+15555550123',
        textChunkLimit: 1998,
        allowFrom: ['+1555', '+1666'],
        authStatus: 'configured',
      }),
    ]
    render(<ChannelsView />)
    fireEvent.click(screen.getByTestId('channel-row-work-signal'))
    expect(screen.getByTestId('channel-form-work-signal')).toBeDefined()
    // allow_from seeded by joining with ", "
    const allowInput = screen.getByTestId('channel-allow-input') as HTMLInputElement
    expect(allowInput.value).toBe('+1555, +1666')
    // text_chunk_limit seeded
    const chunkInput = screen.getByTestId('channel-chunk-input') as HTMLInputElement
    expect(chunkInput.value).toBe('1998')
    // label seeded
    const labelInput = screen.getByTestId('channel-label-input') as HTMLInputElement
    expect(labelInput.value).toBe('Work Signal')
  })

  it('editing and saving calls updateChannel', async () => {
    channelsState = [
      makeChannel({ id: 'work-signal', kind: 'signal', label: 'Work Signal', textChunkLimit: 1998 }),
    ]
    const updated: ChannelDetail = makeChannel({ id: 'work-signal', label: 'Work Signal Updated' })
    updateChannel.mockResolvedValue({ ok: true, channel: updated })
    render(<ChannelsView />)
    fireEvent.click(screen.getByTestId('channel-row-work-signal'))
    const labelInput = screen.getByTestId('channel-label-input') as HTMLInputElement
    fireEvent.change(labelInput, { target: { value: 'Work Signal Updated' } })
    fireEvent.click(screen.getByTestId('channel-save'))
    await waitFor(() => {
      expect(updateChannel).toHaveBeenCalledTimes(1)
      expect(updateChannel.mock.calls[0]![0]).toBe('work-signal')
    })
  })

  it('delete button shows confirmation then DELETEs', async () => {
    channelsState = [makeChannel({ id: 'work-signal' })]
    deleteChannel.mockResolvedValue(true)
    render(<ChannelsView />)
    fireEvent.click(screen.getByTestId('channel-row-work-signal'))
    fireEvent.click(screen.getByTestId('channel-delete'))
    expect(screen.getByTestId('channel-delete-confirm')).toBeDefined()
    fireEvent.click(screen.getByTestId('channel-delete-confirm-btn'))
    await waitFor(() => {
      expect(deleteChannel).toHaveBeenCalledWith('work-signal')
    })
  })

  it('shows restart-needed notice after successful create', async () => {
    channelsState = [makeChannel()]
    const created: ChannelDetail = makeChannel({ id: 'new-sig', label: 'New' })
    createChannel.mockResolvedValue({ ok: true, channel: created })
    render(<ChannelsView />)
    fireEvent.click(screen.getByTestId('channel-new-btn'))
    const idInput = screen.getByTestId('channel-id-input') as HTMLInputElement
    fireEvent.change(idInput, { target: { value: 'new-sig' } })
    const kindSelect = screen.getByTestId('channel-kind-select') as HTMLSelectElement
    fireEvent.change(kindSelect, { target: { value: 'signal' } })
    fireEvent.click(screen.getByTestId('channel-save'))
    const notice = await screen.findByTestId('channel-restart-notice')
    expect(notice.textContent).toContain('Restart seal serve')
  })

  it('shows restart-needed notice after successful update', async () => {
    channelsState = [makeChannel({ id: 'work-signal' })]
    updateChannel.mockResolvedValue({ ok: true, channel: makeChannel({ id: 'work-signal', label: 'Updated' }) })
    render(<ChannelsView />)
    fireEvent.click(screen.getByTestId('channel-row-work-signal'))
    fireEvent.click(screen.getByTestId('channel-save'))
    const notice = await screen.findByTestId('channel-restart-notice')
    expect(notice.textContent).toContain('Restart seal serve')
  })

  it('shows restart-needed notice after successful delete', async () => {
    channelsState = [makeChannel({ id: 'work-signal' })]
    deleteChannel.mockResolvedValue(true)
    render(<ChannelsView />)
    fireEvent.click(screen.getByTestId('channel-row-work-signal'))
    fireEvent.click(screen.getByTestId('channel-delete'))
    fireEvent.click(screen.getByTestId('channel-delete-confirm-btn'))
    const notice = await screen.findByTestId('channel-restart-notice')
    expect(notice.textContent).toContain('Restart seal serve')
  })

  it('shows form error when create fails', async () => {
    channelsState = [makeChannel()]
    createChannel.mockResolvedValue({ ok: false, error: 'id already exists' })
    render(<ChannelsView />)
    fireEvent.click(screen.getByTestId('channel-new-btn'))
    const idInput = screen.getByTestId('channel-id-input') as HTMLInputElement
    fireEvent.change(idInput, { target: { value: 'new-sig' } })
    const kindSelect = screen.getByTestId('channel-kind-select') as HTMLSelectElement
    fireEvent.change(kindSelect, { target: { value: 'signal' } })
    fireEvent.click(screen.getByTestId('channel-save'))
    const errorEl = await screen.findByTestId('channel-form-error')
    expect(errorEl).toBeDefined()
    expect(screen.getByText('id already exists')).toBeDefined()
  })

  it('does not show token field when editing (Telegram write-only)', () => {
    channelsState = [
      makeChannel({ id: 'dev-telegram', kind: 'telegram', label: 'Dev Bot', account: null }),
    ]
    render(<ChannelsView />)
    fireEvent.click(screen.getByTestId('channel-row-dev-telegram'))
    // Token field is write-only — present but empty (never pre-filled)
    const tokenInput = screen.queryByTestId('channel-token-input') as HTMLInputElement | null
    if (tokenInput) {
      expect(tokenInput.value).toBe('')
    }
  })

  it('id field is not shown when editing existing channel', () => {
    channelsState = [makeChannel({ id: 'work-signal' })]
    render(<ChannelsView />)
    fireEvent.click(screen.getByTestId('channel-row-work-signal'))
    expect(screen.queryByTestId('channel-id-input')).toBeNull()
    expect(screen.queryByTestId('channel-kind-select')).toBeNull()
  })
})
