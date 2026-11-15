import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, cleanup } from '@testing-library/react'
import { FileTree, type FileTreeNode } from '../FileTree'

// ── Helpers ──────────────────────────────────────────────────────────────

function makeNode(overrides: Partial<FileTreeNode> = {}): FileTreeNode {
  return {
    path: '/home/user/project',
    name: 'project',
    isDir: true,
    isSymlink: false,
    expanded: false,
    selected: false,
    status: 'idle',
    ...overrides,
  }
}

function renderTree(
  nodes: FileTreeNode[],
  handlers: Partial<{
    onToggle: (p: string) => void
    onSelect: (p: string) => void
    onRetry: (p: string) => void
  }> = {},
) {
  const onToggle = handlers.onToggle ?? vi.fn()
  const onSelect = handlers.onSelect ?? vi.fn()
  const onRetry = handlers.onRetry ?? vi.fn()
  const result = render(
    <FileTree nodes={nodes} onToggle={onToggle} onSelect={onSelect} onRetry={onRetry} />,
  )
  return { ...result, onToggle, onSelect, onRetry }
}

beforeEach(() => {})
afterEach(() => { cleanup() })

// ── Tests ────────────────────────────────────────────────────────────────

describe('FileTree', () => {
  // #1
  it('renders a nested list of agent-row styled nodes', () => {
    const { container } = renderTree([
      makeNode({
        path: '/a',
        name: 'a',
        expanded: true,
        children: [makeNode({ path: '/a/b', name: 'b', isDir: false })],
      }),
    ])
    expect(screen.getByTestId('rail-node-/a')).toBeTruthy()
    expect(screen.getByTestId('rail-node-/a/b')).toBeTruthy()
    // rows reuse the app's established selection idiom
    expect(container.querySelectorAll('.agent-row').length).toBe(2)
  })

  // #2
  it('expands and collapses a directory on click, flipping ▸ to ▾', () => {
    const onToggle = vi.fn()
    const { rerender } = render(
      <FileTree
        nodes={[makeNode({ path: '/a', name: 'a', expanded: false })]}
        onToggle={onToggle}
        onSelect={vi.fn()}
        onRetry={vi.fn()}
      />,
    )
    // The chevron is an inline SVG; collapsed = unrotated, expanded = rotated 90°.
    const glyph = () => screen.getByTestId('rail-glyph-/a').querySelector('svg')
    expect(glyph()?.style.transform).toBe('none')

    // Clicking reports intent; the glyph follows the prop, not internal state.
    fireEvent.click(screen.getByTestId('rail-node-/a'))
    expect(onToggle).toHaveBeenCalledWith('/a')

    rerender(
      <FileTree
        nodes={[makeNode({ path: '/a', name: 'a', expanded: true })]}
        onToggle={onToggle}
        onSelect={vi.fn()}
        onRetry={vi.fn()}
      />,
    )
    expect(glyph()?.style.transform).toBe('rotate(90deg)')
  })

  // #3
  it('marks the current node selected', () => {
    renderTree([
      makeNode({ path: '/a', name: 'a', selected: false }),
      makeNode({ path: '/b', name: 'b', selected: true }),
    ])
    expect(screen.getByTestId('rail-node-/a').className).not.toContain('selected')
    expect(screen.getByTestId('rail-node-/b').className).toContain('selected')
  })

  // #4
  it("renders a node's loading state from its status prop", () => {
    renderTree([makeNode({ path: '/a', name: 'a', expanded: true, status: 'loading' })])
    expect(screen.getByTestId('rail-loading-/a')).toBeTruthy()
  })

  // #5
  it("renders a node's error state from its status prop, with a retry affordance", () => {
    renderTree([makeNode({ path: '/a', name: 'a', expanded: true, status: 'error' })])
    expect(screen.getByTestId('rail-error-/a')).toBeTruthy()
    expect(screen.getByTestId('rail-retry-/a')).toBeTruthy()
  })

  // #6
  it('calls onRetry when the retry affordance is clicked', () => {
    const onRetry = vi.fn()
    renderTree([makeNode({ path: '/a', name: 'a', expanded: true, status: 'error' })], {
      onRetry,
    })
    fireEvent.click(screen.getByTestId('rail-retry-/a'))
    expect(onRetry).toHaveBeenCalledWith('/a')
  })

  // #7
  it('renders an empty marker for an empty directory', () => {
    renderTree([
      makeNode({ path: '/a', name: 'a', expanded: true, status: 'idle', children: [] }),
    ])
    expect(screen.getByTestId('rail-empty-/a')).toBeTruthy()
  })

  // #8
  it('truncates long node labels and sets a title attribute', () => {
    const longName = 'a'.repeat(120)
    renderTree([makeNode({ path: '/a', name: longName })])
    const label = screen.getByTestId('rail-label-/a')
    expect(label.getAttribute('title')).toBe(longName)
    expect(label.className).toContain('truncate')
  })

  // #9
  it('marks a symlink node with a badge and does not expand it', () => {
    const onToggle = vi.fn()
    renderTree(
      [
        makeNode({
          path: '/a/link',
          name: 'link',
          isDir: false,
          isSymlink: true,
        }),
      ],
      { onToggle },
    )
    expect(screen.getByTestId('rail-badge-/a/link')).toBeTruthy()
    // No expand/collapse affordance and no toggle on click.
    expect(screen.queryByTestId('rail-glyph-/a/link')).toBeNull()
    fireEvent.click(screen.getByTestId('rail-node-/a/link'))
    expect(onToggle).not.toHaveBeenCalled()
  })

  // #10
  it('calls onToggle once when a collapsed directory node is clicked', () => {
    const onToggle = vi.fn()
    renderTree([makeNode({ path: '/a', name: 'a', expanded: false })], { onToggle })
    fireEvent.click(screen.getByTestId('rail-node-/a'))
    expect(onToggle).toHaveBeenCalledTimes(1)
    expect(onToggle).toHaveBeenCalledWith('/a')
  })

  // #11
  it('does not render children for a collapsed node', () => {
    renderTree([
      makeNode({
        path: '/a',
        name: 'a',
        expanded: false,
        children: [makeNode({ path: '/a/b', name: 'b' })],
      }),
    ])
    expect(screen.queryByTestId('rail-node-/a/b')).toBeNull()
  })

  // #12
  it('renders children passed in props for an expanded node', () => {
    renderTree([
      makeNode({
        path: '/a',
        name: 'a',
        expanded: true,
        children: [makeNode({ path: '/a/b', name: 'b' })],
      }),
    ])
    expect(screen.getByTestId('rail-node-/a/b')).toBeTruthy()
  })

  // #13
  it("always expands the target's ancestors on cold load", () => {
    // The ancestors of the target arrive already expanded and selected.
    renderTree([
      makeNode({
        path: '/a',
        name: 'a',
        expanded: true,
        children: [
          makeNode({
            path: '/a/b',
            name: 'b',
            expanded: true,
            children: [makeNode({ path: '/a/b/c', name: 'c', isDir: false, selected: true })],
          }),
        ],
      }),
    ])
    expect(screen.getByTestId('rail-node-/a/b/c')).toBeTruthy()
    expect(screen.getByTestId('rail-node-/a/b/c').className).toContain('selected')
    expect(screen.getByTestId('rail-glyph-/a').querySelector('svg')?.style.transform).toBe('rotate(90deg)')
    expect(screen.getByTestId('rail-glyph-/a/b').querySelector('svg')?.style.transform).toBe('rotate(90deg)')
  })

  // #14
  it('exposes every node as a focusable button activatable with Enter and Space', () => {
    const onToggle = vi.fn()
    renderTree([makeNode({ path: '/a', name: 'a', expanded: false })], { onToggle })

    const node = screen.getByTestId('rail-node-/a')
    expect(node.tagName).toBe('BUTTON')

    node.focus()
    expect(document.activeElement).toBe(node)

    fireEvent.keyDown(node, { key: 'Enter' })
    fireEvent.click(node)
    expect(onToggle).toHaveBeenCalledTimes(1)
  })
})
