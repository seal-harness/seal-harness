/**
 * MarkdownView tests.
 *
 * The renderer must produce a *real* document structure (tables, lists, code
 * blocks, headings) with no HTML-injection surface: every node is a React
 * element, links are scheme-checked, and no raw HTML from the model ever
 * reaches the DOM.
 */

import { describe, it, expect, afterEach } from 'vitest'
import { render, cleanup } from '@testing-library/react'
import { MarkdownView } from '../MarkdownView'

afterEach(cleanup)

describe('MarkdownView', () => {
  it('renders a GFM table as a real <table> with th/td cells', () => {
    const md = [
      '| File | Status |',
      '| --- | --- |',
      '| a.txt | ok |',
      '| b.txt | missing |',
    ].join('\n')
    const { container } = render(<MarkdownView text={md} />)
    const table = container.querySelector('table')
    expect(table).toBeTruthy()
    expect(container.querySelectorAll('thead th')).toHaveLength(2)
    expect(container.querySelectorAll('tbody tr')).toHaveLength(2)
    expect(container.querySelector('tbody td')!.textContent).toBe('a.txt')
    // The raw delimiter syntax must be gone from the rendered output.
    expect(container.textContent).not.toContain('| --- |')
  })

  it('applies column alignment from the delimiter row', () => {
    const md = '| l | c | r |\n| :--- | :---: | ---: |\n| 1 | 2 | 3 |'
    const { container } = render(<MarkdownView text={md} />)
    const cells = Array.from(container.querySelectorAll('tbody td'))
    expect(cells.map((c) => (c as HTMLElement).style.textAlign)).toEqual([
      'left', 'center', 'right',
    ])
  })

  it('renders fenced code as a <pre> with the code text intact', () => {
    const { container } = render(<MarkdownView text={'```python\nprint("hi")\n```'} />)
    const pre = container.querySelector('pre')
    expect(pre).toBeTruthy()
    expect(pre!.textContent).toBe('print("hi")')
  })

  it('renders headings as h4/h5/h6 so they never outrank the page chrome', () => {
    const { container } = render(<MarkdownView text={'# one\n\n## two\n\n### three'} />)
    expect(container.querySelectorAll('h4')).toHaveLength(1)
    expect(container.querySelectorAll('h5')).toHaveLength(1)
    expect(container.querySelectorAll('h6')).toHaveLength(1)
  })

  it('renders lists, blockquotes and inline formatting structurally', () => {
    const { container } = render(
      <MarkdownView text={'- one\n- two\n\n> quoted\n\n**bold** and `code`'} />,
    )
    expect(container.querySelectorAll('ul > li')).toHaveLength(2)
    expect(container.querySelector('blockquote')).toBeTruthy()
    expect(container.querySelector('strong')!.textContent).toBe('bold')
    expect(container.querySelector('code')!.textContent).toBe('code')
  })

  it('renders nested list items inside their parent <li>', () => {
    const { container } = render(<MarkdownView text={'- parent\n  - child'} />)
    const outerLi = container.querySelector('ul > li')!
    expect(outerLi.querySelector('ul > li')!.textContent).toBe('child')
  })

  it('renders a safe link with rel/target hardening', () => {
    const { container } = render(
      <MarkdownView text={'see [docs](https://example.com/x)'} />,
    )
    const a = container.querySelector('a')!
    expect(a.getAttribute('href')).toBe('https://example.com/x')
    expect(a.getAttribute('rel')).toContain('noopener')
    expect(a.getAttribute('target')).toBe('_blank')
  })

  it('never renders a javascript: href', () => {
    const { container } = render(<MarkdownView text={'[x](javascript:alert(1))'} />)
    expect(container.querySelector('a')).toBeNull()
    expect(container.textContent).toContain('javascript:alert(1)')
  })

  it('escapes embedded HTML — a <script> tag is text, not an element', () => {
    const { container } = render(
      <MarkdownView text={'<script>alert(1)</script>\n\n<b>not bold</b>'} />,
    )
    expect(container.querySelector('script')).toBeNull()
    expect(container.querySelector('b')).toBeNull()
    expect(container.textContent).toContain('<script>alert(1)</script>')
    expect(container.textContent).toContain('<b>not bold</b>')
  })

  it('treats model-supplied <img> tags as text, never a network fetch', () => {
    const { container } = render(
      <MarkdownView text={'<img src="https://tracker.example/pixel.png">'} />,
    )
    expect(container.querySelector('img')).toBeNull()
    expect(container.textContent).toContain('<img')
  })

  it('passes the extra className through to the wrapper', () => {
    const { container } = render(<MarkdownView text="hi" className="show-human-message" />)
    const wrapper = container.firstElementChild!
    expect(wrapper.className).toContain('show-human-message')
    expect(wrapper.className).toContain('md-body')
  })

  it('renders nothing for empty input', () => {
    const { container } = render(<MarkdownView text="" />)
    expect(container.querySelector('.md-body')!.childElementCount).toBe(0)
  })
})
