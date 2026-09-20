import { describe, it, expect } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { StatusDot, ActivityDot } from '../StatusDot'
import { TopBar } from '../TopBar'
import { BottomBar } from '../BottomBar'
import { JsonTree } from '../JsonTree'

describe('StatusDot', () => {
  it('renders the right variant class per AgentStatus', () => {
    const { container: needsInput } = render(<StatusDot status="needs-input" />)
    expect(needsInput.querySelector('.dot-needs')).toBeTruthy()
    const { container: thinking } = render(<StatusDot status="thinking" />)
    expect(thinking.querySelector('.dot-thinking')).toBeTruthy()
    const { container: idle } = render(<StatusDot status="idle" />)
    expect(idle.querySelector('.dot-idle')).toBeTruthy()
    const { container: completed } = render(<StatusDot status="completed" />)
    expect(completed.querySelector('.dot-completed')).toBeTruthy()
  })

  it('applies the small class when small=true', () => {
    const { container } = render(<StatusDot status="idle" small />)
    expect(container.querySelector('.dot-sm')).toBeTruthy()
  })
})

describe('ActivityDot', () => {
  it('renders the right variant class per HarnessActivity', () => {
    const { container: thinking } = render(<ActivityDot activity="thinking" />)
    expect(thinking.querySelector('.dot-thinking')).toBeTruthy()
    const { container: stopped } = render(<ActivityDot activity="stopped" />)
    expect(stopped.querySelector('.dot-completed')).toBeTruthy()
  })
})

describe('TopBar', () => {
  it('renders the brand name "Seal Harness"', () => {
    render(<TopBar section="sessions" onSectionChange={() => {}} />)
    expect(screen.getByText('Seal Harness')).toBeTruthy()
  })

  it('does NOT render any reference product name', () => {
    const { container } = render(<TopBar section="sessions" onSectionChange={() => {}} />)
    expect(container.textContent).not.toMatch(/pureclaw/i)
  })

  it('renders a top-level menu button per section', () => {
    render(<TopBar section="sessions" onSectionChange={() => {}} />)
    expect(screen.getByTestId('section-sessions')).toBeTruthy()
    expect(screen.getByTestId('section-agents')).toBeTruthy()
    expect(screen.getByTestId('section-skills')).toBeTruthy()
  })

  it('marks the active section with aria-current=page', () => {
    render(<TopBar section="agents" onSectionChange={() => {}} />)
    const agents = screen.getByTestId('section-agents')
    expect(agents.getAttribute('aria-current')).toBe('page')
    expect(screen.getByTestId('section-sessions').getAttribute('aria-current')).toBeNull()
  })

  it('fires onSectionChange with the chosen section', () => {
    let picked: string | null = null
    render(
      <TopBar
        section="sessions"
        onSectionChange={(s) => { picked = s }}
      />,
    )
    fireEvent.click(screen.getByTestId('section-skills'))
    expect(picked).toBe('skills')
  })
})

describe('BottomBar', () => {
  it('renders the token count without a context window when contextWindow=0', () => {
    render(<BottomBar tokensUsed={1234} contextWindow={0} sessionStart={null} running={false} />)
    expect(screen.getByText('1.2k')).toBeTruthy()
  })

  it('renders the token count + percentage when contextWindow > 0', () => {
    render(<BottomBar tokensUsed={50000} contextWindow={200000} sessionStart={null} running={false} />)
    expect(screen.getByText(/50k/)).toBeTruthy()
    expect(screen.getByText(/200k/)).toBeTruthy()
    expect(screen.getByText(/25%/)).toBeTruthy()
  })

  it('shows Idle when not running, Running when running', () => {
    const { rerender } = render(<BottomBar tokensUsed={0} contextWindow={0} sessionStart={null} running={false} />)
    expect(screen.getByText('Idle')).toBeTruthy()
    rerender(<BottomBar tokensUsed={0} contextWindow={0} sessionStart={null} running={true} />)
    expect(screen.getByText('Running')).toBeTruthy()
  })

  it('shows --:-- when sessionStart is null', () => {
    render(<BottomBar tokensUsed={0} contextWindow={0} sessionStart={null} running={false} />)
    expect(screen.getByText('--:--')).toBeTruthy()
  })
})

describe('JsonTree', () => {
  it('renders a primitive object with keys', () => {
    render(<JsonTree value={{ a: 1, b: 'two', c: true }} />)
    // Top-level object is expanded; primitive fields are shown inline.
    expect(screen.getByText('"a"')).toBeTruthy()
    expect(screen.getByText('1')).toBeTruthy()
    expect(screen.getByText('"two"')).toBeTruthy()
    expect(screen.getByText('true')).toBeTruthy()
  })

  it('renders null', () => {
    render(<JsonTree value={null} />)
    expect(screen.getByText('null')).toBeTruthy()
  })

  it('renders an empty object as {}', () => {
    render(<JsonTree value={{}} />)
    expect(screen.getByText('{}')).toBeTruthy()
  })

  it('renders an empty array as []', () => {
    render(<JsonTree value={[]} />)
    expect(screen.getByText('[]')).toBeTruthy()
  })

  it('toggles the top-level object open/closed via the toggle button', () => {
    render(<JsonTree value={{ a: 1, b: 2 }} />)
    // Top-level is expanded; primitive keys are visible inline.
    expect(screen.getByText('"a"')).toBeTruthy()
    // Collapse the top-level object.
    const toggle = screen.getAllByLabelText('Collapse')[0]!
    fireEvent.click(toggle)
    expect(screen.queryByText('"a"')).toBeNull()
    // The collapsed preview shows "2 keys".
    expect(screen.getByText(/2 keys/)).toBeTruthy()
    // Re-expand.
    fireEvent.click(screen.getByLabelText('Expand'))
    expect(screen.getByText('"a"')).toBeTruthy()
  })

  it('toggles the top-level array open/closed', () => {
    render(<JsonTree value={[1, 2, 3]} />)
    // Top-level is expanded; primitive items are visible.
    expect(screen.getByText('1')).toBeTruthy()
    const toggle = screen.getAllByLabelText('Collapse')[0]!
    fireEvent.click(toggle)
    expect(screen.getByText(/3 items/)).toBeTruthy()
    fireEvent.click(screen.getByLabelText('Expand'))
    expect(screen.getByText('1')).toBeTruthy()
  })

  it('collapses nested object fields by default', () => {
    render(<JsonTree value={{ outer: { inner: 1 } }} />)
    // Top-level is expanded; "outer" key is visible.
    expect(screen.getByText('"outer"')).toBeTruthy()
    // The nested object is collapsed by default — "inner" key is NOT visible.
    expect(screen.queryByText('"inner"')).toBeNull()
    // A collapsed preview is shown for the nested object.
    expect(screen.getByText(/1 key/)).toBeTruthy()
    // Expand the nested field.
    const expandBtn = screen.getAllByLabelText('Expand')[0]!
    fireEvent.click(expandBtn)
    // Now the inner key is visible.
    expect(screen.getByText('"inner"')).toBeTruthy()
  })

  it('collapses nested array fields by default', () => {
    render(<JsonTree value={{ items: [1, 2] }} />)
    // Top-level is expanded; "items" key is visible.
    expect(screen.getByText('"items"')).toBeTruthy()
    // The nested array is collapsed by default — items are NOT visible.
    expect(screen.queryByText('1')).toBeNull()
    // A collapsed preview is shown.
    expect(screen.getByText(/2 items/)).toBeTruthy()
    // Expand the nested field.
    const expandBtn = screen.getAllByLabelText('Expand')[0]!
    fireEvent.click(expandBtn)
    expect(screen.getByText('1')).toBeTruthy()
  })

  it('hides toggle for primitive fields and shows them inline', () => {
    render(<JsonTree value={{ a: 1, b: 'hi', c: true, d: null }} />)
    // All primitive fields should be visible without needing to expand.
    expect(screen.getByText('"a"')).toBeTruthy()
    expect(screen.getByText('1')).toBeTruthy()
    expect(screen.getByText('"b"')).toBeTruthy()
    expect(screen.getByText('"hi"')).toBeTruthy()
    expect(screen.getByText('"c"')).toBeTruthy()
    expect(screen.getByText('true')).toBeTruthy()
    expect(screen.getByText('"d"')).toBeTruthy()
    expect(screen.getByText('null')).toBeTruthy()
    // There should be exactly one toggle button (for the top-level object).
    expect(screen.getAllByRole('button').filter((b) => b.getAttribute('aria-label') === 'Collapse')).toHaveLength(1)
  })

  it('shows a one-line preview when a multi-line string field is collapsed', () => {
    const multiline = 'line one\nline two\nline three'
    render(<JsonTree value={{ text: multiline }} />)
    // Top-level expanded; "text" key visible.
    expect(screen.getByText('"text"')).toBeTruthy()
    // The multi-line string is collapsed by default — full content NOT visible.
    expect(screen.queryByText('line two')).toBeNull()
    // A preview is shown.
    expect(screen.getByText(/line one/)).toBeTruthy()
    // Expand it.
    const expandBtn = screen.getAllByLabelText('Expand')[0]!
    fireEvent.click(expandBtn)
    // Now the full content is visible.
    // The full content is inside a <pre> block.
    expect(screen.getByText(/line two/)).toBeTruthy()
  })
})
