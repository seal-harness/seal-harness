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

  it('toggles an object open/closed via the toggle button', () => {
    render(<JsonTree value={{ a: 1, b: 2 }} />)
    // Initially expanded — both keys visible.
    expect(screen.getByText('"a"')).toBeTruthy()
    // Collapse via the toggle button (the first toggle button).
    const toggle = screen.getAllByLabelText('Collapse')[0]!
    fireEvent.click(toggle)
    expect(screen.queryByText('"a"')).toBeNull()
    // The collapsed summary shows "2 keys".
    expect(screen.getByText(/2 keys/)).toBeTruthy()
    // Re-expand.
    fireEvent.click(screen.getByLabelText('Expand'))
    expect(screen.getByText('"a"')).toBeTruthy()
  })

  it('toggles an array open/closed', () => {
    render(<JsonTree value={[1, 2, 3]} />)
    const toggle = screen.getAllByLabelText('Collapse')[0]!
    fireEvent.click(toggle)
    expect(screen.getByText(/3 items/)).toBeTruthy()
    fireEvent.click(screen.getByLabelText('Expand'))
    expect(screen.getByText('1')).toBeTruthy()
  })
})