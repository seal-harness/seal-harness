/**
 * FileTree — the Files page's directory-tree rail.
 *
 * Fully controlled and presentational: every value it renders (expansion,
 * selection, loading/error status, children) arrives via props, and every
 * intent leaves via a callback. It performs **no** fetching and holds **no**
 * state, which is what lets it be tested in isolation and what keeps the
 * listing cache in one place (`FilesView`).
 *
 * Visual shape mirrors the app's existing collapsible-group idiom
 * (`SkillsView.SkillGroupSection` / `AgentsView.AgentGroupSection`): rows use
 * the shared `agent-row` classes and a `▸`/`▾` glyph indicates expansion.
 * Each row is a real `<button>` — the app's established affordance — so
 * keyboard activation (Enter/Space) comes for free and there is no bespoke
 * ARIA tree to diverge from the rest of the frontend.
 */

/** One node in the rail. `children` is absent while collapsed or unloaded. */
export interface FileTreeNode {
  path: string
  name: string
  isDir: boolean
  isSymlink: boolean
  expanded: boolean
  selected: boolean
  status: 'idle' | 'loading' | 'error'
  children?: FileTreeNode[]
}

export interface FileTreeProps {
  nodes: FileTreeNode[]
  onToggle: (path: string) => void
  onSelect: (path: string) => void
  onRetry: (path: string) => void
}

/** A symlink is a leaf: the backend reports `isDir = false` for every symlink,
 *  so it is never expandable and carries a badge instead. */
function isExpandable(node: FileTreeNode): boolean {
  return node.isDir && !node.isSymlink
}

/** The disclosure chevron, matching the app's inline-SVG idiom
 *  (`viewBox="0 0 16 16"`, `stroke="currentColor"`, `strokeWidth="1.6"`). */
function Chevron({ expanded }: { expanded: boolean }) {
  return (
    <svg
      width="11"
      height="11"
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      style={{ transform: expanded ? 'rotate(90deg)' : 'none', transition: 'transform 120ms ease' }}
    >
      <path d="M6 3 L11 8 L6 13" />
    </svg>
  )
}

/** A symlink is a leaf: it carries a badge rather than a disclosure chevron. */
function SymlinkBadge() {
  return (
    <svg
      width="11"
      height="11"
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M6 10 L10 6" />
      <path d="M7 4 h5 v5" />
      <path d="M9 12 H4 a1 1 0 0 1 -1 -1 V6" />
    </svg>
  )
}

function NodeGlyph({ node }: { node: FileTreeNode }) {
  if (!isExpandable(node)) {
    return (
      <span
        data-testid={`rail-badge-${node.path}`}
        aria-label="symlink"
        style={{ color: 'var(--text-faint)', width: 12, flexShrink: 0, display: 'inline-flex' }}
      >
        {node.isSymlink ? <SymlinkBadge /> : null}
      </span>
    )
  }
  return (
    <span
      data-testid={`rail-glyph-${node.path}`}
      aria-hidden="true"
      style={{ color: 'var(--text-faint)', width: 12, flexShrink: 0, display: 'inline-flex' }}
    >
      <Chevron expanded={node.expanded} />
    </span>
  )
}

function RailNode({
  node,
  onToggle,
  onSelect,
  onRetry,
}: {
  node: FileTreeNode
  onToggle: (path: string) => void
  onSelect: (path: string) => void
  onRetry: (path: string) => void
}) {
  const expandable = isExpandable(node)
  const showChildren = expandable && node.expanded

  const handleClick = () => {
    if (expandable) onToggle(node.path)
    onSelect(node.path)
  }

  return (
    <div>
      <button
        type="button"
        data-testid={`rail-node-${node.path}`}
        className={`agent-row w-full text-left flex items-center gap-1.5 px-3 py-1.5${
          node.selected ? ' selected' : ''
        }`}
        style={{
          background: 'none',
          border: 'none',
          borderLeft: '2px solid transparent',
          color: 'var(--text-primary)',
          cursor: 'pointer',
          font: 'inherit',
        }}
        aria-current={node.selected ? 'true' : undefined}
        aria-expanded={expandable ? node.expanded : undefined}
        onClick={handleClick}
      >
        <NodeGlyph node={node} />
        <span
          data-testid={`rail-label-${node.path}`}
          className="text-sm truncate"
          title={node.name}
          style={{ color: 'var(--text-primary)', letterSpacing: 'var(--tracking-tight)' }}
        >
          {node.name}
        </span>
      </button>

      {showChildren && node.status === 'loading' && (
        <div
          data-testid={`rail-loading-${node.path}`}
          className="px-3 py-1 text-xs"
          style={{ color: 'var(--text-faint)', paddingLeft: 28 }}
        >
          Loading…
        </div>
      )}

      {showChildren && node.status === 'error' && (
        <div
          data-testid={`rail-error-${node.path}`}
          className="px-3 py-1 text-xs flex items-center gap-2"
          style={{ color: 'var(--needs-input)', paddingLeft: 28 }}
        >
          <span>Could not load</span>
          <button
            type="button"
            data-testid={`rail-retry-${node.path}`}
            className="btn btn-ghost"
            style={{ fontSize: 11, padding: '1px 6px', lineHeight: 1.4 }}
            onClick={() => onRetry(node.path)}
          >
            Retry
          </button>
        </div>
      )}

      {showChildren && node.status === 'idle' && node.children && node.children.length === 0 && (
        <div
          data-testid={`rail-empty-${node.path}`}
          className="px-3 py-1 text-xs"
          style={{ color: 'var(--text-faint)', paddingLeft: 28 }}
        >
          empty
        </div>
      )}

      {showChildren && node.children && node.children.length > 0 && (
        <div style={{ paddingLeft: 12 }}>
          {node.children.map((child) => (
            <RailNode
              key={child.path}
              node={child}
              onToggle={onToggle}
              onSelect={onSelect}
              onRetry={onRetry}
            />
          ))}
        </div>
      )}
    </div>
  )
}

export function FileTree({ nodes, onToggle, onSelect, onRetry }: FileTreeProps) {
  return (
    <div data-testid="file-tree">
      {nodes.map((node) => (
        <RailNode
          key={node.path}
          node={node}
          onToggle={onToggle}
          onSelect={onSelect}
          onRetry={onRetry}
        />
      ))}
    </div>
  )
}
