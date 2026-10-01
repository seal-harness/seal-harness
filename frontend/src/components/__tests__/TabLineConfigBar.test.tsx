import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { TabLineConfigBar } from '../TabLineConfigBar'
import type { TabLineField } from '../../lib/tabLineConfig'

describe('TabLineConfigBar', () => {
  it('renders the gear button', () => {
    render(<TabLineConfigBar fields={['provider', 'model', 'repo']} onFieldsChange={() => {}} />)
    expect(screen.getByTestId('tab-line-config-button')).toBeTruthy()
    expect(screen.getByLabelText('Configure tab fields')).toBeTruthy()
  })

  it('shows the current field labels as a hint string', () => {
    render(<TabLineConfigBar fields={['provider', 'model', 'repo']} onFieldsChange={() => {}} />)
    expect(screen.getByText('Provider · Model · Repo')).toBeTruthy()
  })

  it('does not show the popover before clicking', () => {
    render(<TabLineConfigBar fields={['provider', 'model']} onFieldsChange={() => {}} />)
    expect(screen.queryByTestId('tab-line-config-popover')).toBeNull()
  })

  it('opens the popover on gear click', () => {
    render(<TabLineConfigBar fields={['provider', 'model']} onFieldsChange={() => {}} />)
    fireEvent.click(screen.getByTestId('tab-line-config-button'))
    expect(screen.getByTestId('tab-line-config-popover')).toBeTruthy()
  })

  it('renders a row per available field (all 5)', () => {
    render(<TabLineConfigBar fields={['provider', 'model']} onFieldsChange={() => {}} />)
    fireEvent.click(screen.getByTestId('tab-line-config-button'))
    expect(screen.getByTestId('tab-line-config-row-provider')).toBeTruthy()
    expect(screen.getByTestId('tab-line-config-row-model')).toBeTruthy()
    expect(screen.getByTestId('tab-line-config-row-repo')).toBeTruthy()
    expect(screen.getByTestId('tab-line-config-row-channel')).toBeTruthy()
    expect(screen.getByTestId('tab-line-config-row-agent')).toBeTruthy()
  })

  it('checkboxes reflect enabled state', () => {
    render(<TabLineConfigBar fields={['provider', 'model']} onFieldsChange={() => {}} />)
    fireEvent.click(screen.getByTestId('tab-line-config-button'))
    const providerCheckbox = screen.getByLabelText('Provider') as HTMLInputElement
    const repoCheckbox = screen.getByLabelText('Repo') as HTMLInputElement
    expect(providerCheckbox.checked).toBe(true)
    expect(repoCheckbox.checked).toBe(false)
  })

  it('calls onFieldsChange when toggling a checkbox', () => {
    const onChange = vi.fn()
    render(<TabLineConfigBar fields={['provider', 'model']} onFieldsChange={onChange} />)
    fireEvent.click(screen.getByTestId('tab-line-config-button'))
    fireEvent.click(screen.getByLabelText('Repo'))
    expect(onChange).toHaveBeenCalledOnce()
    const newFields = onChange.mock.calls[0]![0] as TabLineField[]
    expect(newFields).toEqual(['provider', 'model', 'repo'])
  })

  it('calls onFieldsChange when removing a field via checkbox', () => {
    const onChange = vi.fn()
    render(<TabLineConfigBar fields={['provider', 'model', 'repo']} onFieldsChange={onChange} />)
    fireEvent.click(screen.getByTestId('tab-line-config-button'))
    fireEvent.click(screen.getByLabelText('Model'))
    expect(onChange).toHaveBeenCalledOnce()
    const newFields = onChange.mock.calls[0]![0] as TabLineField[]
    expect(newFields).toEqual(['provider', 'repo'])
  })

  it('shows up/down arrows only for enabled fields', () => {
    render(<TabLineConfigBar fields={['provider', 'model']} onFieldsChange={() => {}} />)
    fireEvent.click(screen.getByTestId('tab-line-config-button'))
    expect(screen.getByTestId('tab-line-config-up-provider')).toBeTruthy()
    expect(screen.queryByTestId('tab-line-config-up-repo')).toBeNull()
  })

  it('disables up arrow for the first field', () => {
    render(<TabLineConfigBar fields={['provider', 'model']} onFieldsChange={() => {}} />)
    fireEvent.click(screen.getByTestId('tab-line-config-button'))
    const upBtn = screen.getByTestId('tab-line-config-up-provider') as HTMLButtonElement
    expect(upBtn.disabled).toBe(true)
  })

  it('disables down arrow for the last field', () => {
    render(<TabLineConfigBar fields={['provider', 'model']} onFieldsChange={() => {}} />)
    fireEvent.click(screen.getByTestId('tab-line-config-button'))
    const downBtn = screen.getByTestId('tab-line-config-down-model') as HTMLButtonElement
    expect(downBtn.disabled).toBe(true)
  })

  it('calls onFieldsChange when moving a field up', () => {
    const onChange = vi.fn()
    render(<TabLineConfigBar fields={['provider', 'model', 'repo']} onFieldsChange={onChange} />)
    fireEvent.click(screen.getByTestId('tab-line-config-button'))
    fireEvent.click(screen.getByTestId('tab-line-config-up-repo'))
    expect(onChange).toHaveBeenCalledOnce()
    const newFields = onChange.mock.calls[0]![0] as TabLineField[]
    expect(newFields).toEqual(['provider', 'repo', 'model'])
  })

  it('calls onFieldsChange when moving a field down', () => {
    const onChange = vi.fn()
    render(<TabLineConfigBar fields={['provider', 'model', 'repo']} onFieldsChange={onChange} />)
    fireEvent.click(screen.getByTestId('tab-line-config-button'))
    fireEvent.click(screen.getByTestId('tab-line-config-down-provider'))
    expect(onChange).toHaveBeenCalledOnce()
    const newFields = onChange.mock.calls[0]![0] as TabLineField[]
    expect(newFields).toEqual(['model', 'provider', 'repo'])
  })

  it('closes the popover on outside click', () => {
    render(
      <div>
        <TabLineConfigBar fields={['provider', 'model']} onFieldsChange={() => {}} />
        <div data-testid="outside">outside</div>
      </div>,
    )
    fireEvent.click(screen.getByTestId('tab-line-config-button'))
    expect(screen.getByTestId('tab-line-config-popover')).toBeTruthy()
    fireEvent.mouseDown(screen.getByTestId('outside'))
    expect(screen.queryByTestId('tab-line-config-popover')).toBeNull()
  })

  it('toggles the popover on repeated gear clicks', () => {
    render(<TabLineConfigBar fields={['provider']} onFieldsChange={() => {}} />)
    const btn = screen.getByTestId('tab-line-config-button')
    fireEvent.click(btn)
    expect(screen.getByTestId('tab-line-config-popover')).toBeTruthy()
    fireEvent.click(btn)
    expect(screen.queryByTestId('tab-line-config-popover')).toBeNull()
  })
})