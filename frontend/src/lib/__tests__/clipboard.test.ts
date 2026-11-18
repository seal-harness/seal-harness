import { copyTextToClipboard } from '../clipboard'

describe('copyTextToClipboard', () => {
  const origClipboard = navigator.clipboard
  const origExec = document.execCommand

  afterEach(() => {
    Object.defineProperty(navigator, 'clipboard', {
      value: origClipboard,
      configurable: true,
      writable: true,
    })
    document.execCommand = origExec
  })

  function setClipboard(value: unknown) {
    Object.defineProperty(navigator, 'clipboard', {
      value,
      configurable: true,
      writable: true,
    })
  }

  it('uses the Clipboard API when it is available', async () => {
    const written: string[] = []
    setClipboard({ writeText: (t: string) => { written.push(t); return Promise.resolve() } })
    document.execCommand = (() => { throw new Error('execCommand must not be used') }) as typeof document.execCommand

    await expect(copyTextToClipboard('/home/user/a b.txt')).resolves.toBe(true)
    expect(written).toEqual(['/home/user/a b.txt'])
  })

  it('falls back to execCommand when the Clipboard API rejects', async () => {
    setClipboard({ writeText: () => Promise.reject(new Error('not allowed')) })
    const execSpy = vi.fn(() => true)
    document.execCommand = execSpy as unknown as typeof document.execCommand

    await expect(copyTextToClipboard('/etc/hosts')).resolves.toBe(true)
    expect(execSpy).toHaveBeenCalledWith('copy')
  })

  it('falls back to execCommand when there is no Clipboard API (insecure context)', async () => {
    setClipboard(undefined)
    const execSpy = vi.fn(() => true)
    document.execCommand = execSpy as unknown as typeof document.execCommand

    await expect(copyTextToClipboard('/etc/hosts')).resolves.toBe(true)
    expect(execSpy).toHaveBeenCalledWith('copy')
  })

  it('reports failure when both paths fail, and leaves no scratch nodes behind', async () => {
    setClipboard(undefined)
    document.execCommand = (() => false) as typeof document.execCommand

    await expect(copyTextToClipboard('/etc/hosts')).resolves.toBe(false)
    expect(document.querySelectorAll('textarea')).toHaveLength(0)
  })
})
