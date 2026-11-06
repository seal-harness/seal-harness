/**
 * MarkdownView — renders a message body as formatted HTML.
 *
 * Every node is a React element built from the tree produced by
 * `lib/markdown`. There is no `dangerouslySetInnerHTML` on this path, so
 * model-written HTML stays text. Links are scheme-checked in the parser and
 * get `rel="noopener noreferrer nofollow"`. Images never render as images —
 * the parser turns them into links so a transcript can't beacon out to a host
 * the model chose.
 *
 * Styling lives in App.css under `.md-body` (one place, so the transcript and
 * the SHOW_HUMAN box share the same typography).
 */

import { type MdBlock, type MdInline, type MdAlign, parseMarkdownCached } from '../lib/markdown'

const HEADING_TAGS = ['h4', 'h5', 'h6', 'h6', 'h6', 'h6'] as const

function alignStyle(align: MdAlign): { textAlign: MdAlign } {
  return { textAlign: align }
}

function renderInline(node: MdInline, key: number): React.ReactNode {
  switch (node.kind) {
    case 'text':
      return node.text
    case 'break':
      return <br key={key} />
    case 'code':
      return <code key={key} className="inline-code">{node.code}</code>
    case 'bold':
      return <strong key={key}>{node.inline.map(renderInline)}</strong>
    case 'italic':
      return <em key={key}>{node.inline.map(renderInline)}</em>
    case 'strike':
      return <del key={key}>{node.inline.map(renderInline)}</del>
    case 'link':
      return (
        <a
          key={key}
          href={node.href}
          target="_blank"
          rel="noopener noreferrer nofollow"
        >
          {node.inline.map(renderInline)}
        </a>
      )
  }
}

function renderInlineList(nodes: MdInline[]): React.ReactNode[] {
  return nodes.map(renderInline)
}

function renderListBlock(
  block: Extract<MdBlock, { kind: 'list' }>,
  key: number,
): React.ReactNode {
  const items = block.items.map((item, i) => (
    <li key={i}>
      {renderInlineList(item.inline)}
      {item.blocks.map(renderBlock)}
    </li>
  ))
  if (block.ordered) {
    return (
      <ol key={key} className="md-list" start={block.start === 1 ? undefined : block.start}>
        {items}
      </ol>
    )
  }
  return <ul key={key} className="md-list">{items}</ul>
}

function renderTable(
  block: Extract<MdBlock, { kind: 'table' }>,
  key: number,
): React.ReactNode {
  return (
    <div key={key} className="md-table-wrap">
      <table className="md-table">
        <thead>
          <tr>
            {block.header.map((cell, c) => (
              <th key={c} style={alignStyle(block.align[c] ?? 'left')}>
                {renderInlineList(cell)}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {block.rows.map((row, r) => (
            <tr key={r}>
              {row.map((cell, c) => (
                <td key={c} style={alignStyle(block.align[c] ?? 'left')}>
                  {renderInlineList(cell)}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function renderBlock(block: MdBlock, key: number): React.ReactNode {
  switch (block.kind) {
    case 'heading': {
      const Tag = HEADING_TAGS[Math.min(block.level, 6) - 1] ?? 'h6'
      return <Tag key={key}>{renderInlineList(block.inline)}</Tag>
    }
    case 'code':
      return <pre key={key} className="code-block md-code">{block.code}</pre>
    case 'para':
      return <p key={key}>{renderInlineList(block.inline)}</p>
    case 'list':
      return renderListBlock(block, key)
    case 'quote':
      return <blockquote key={key}>{block.blocks.map(renderBlock)}</blockquote>
    case 'hr':
      return <hr key={key} />
    case 'table':
      return renderTable(block, key)
  }
}

export function MarkdownView({ text, className }: { text: string; className?: string }) {
  const blocks = parseMarkdownCached(text)
  return (
    <div className={className === undefined ? 'md-body' : `md-body ${className}`}>
      {blocks.map(renderBlock)}
    </div>
  )
}
