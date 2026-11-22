// The HTML shell for every page: <head>, the sidebar nav, and the footer.
//
// Kept separate from build.mjs so the shell is one obvious place to change
// markup, and so the nav rendering can be reasoned about without reading the
// link checker.
//
// Every href this module emits is relative, because the site is served from a
// subpath on GitHub Pages (see build.mjs invariant 3).

/** Escape text for use in HTML body/attribute position. Markdown bodies are
 *  rendered by markdown-it (which escapes), but nav titles come straight from
 *  `_nav.json` and must not be trusted to be markup-free. */
export function esc(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}

/** The sidebar. Sections in `_nav.json` order; pages in section order; the
 *  page currently being rendered marked `aria-current="page"`. */
function sidebar(sections, pagePath) {
  const out = []
  for (const { section, pages } of sections) {
    if (pages.length === 0) continue
    out.push('<div class="nav-section">')
    if (section !== null && section !== undefined) {
      out.push(`<h2 class="nav-heading">${esc(section)}</h2>`)
    }
    out.push('<ul class="nav-list">')
    for (const page of pages) {
      const current = page.file === pagePath
      const href = relHref(pagePath, page.file.replace(/\.md$/, '.html'))
      const attrs = current ? ' class="nav-link" aria-current="page"' : ' class="nav-link"'
      out.push(`<li><a${attrs} href="${esc(href)}">${esc(page.title)}</a></li>`)
    }
    out.push('</ul>')
    out.push('</div>')
  }
  return out.join('\n')
}

/** Relative href from one content-relative page to another content-relative
 *  path. Both arguments are paths relative to the content root, so a sibling
 *  link from `docs/a.md` to `docs/b.html` correctly yields `b.html` (not
 *  `../b.html`).
 *
 *  Duplicated logic with build.mjs only because template.mjs must not import
 *  build.mjs (that would be a cycle). */
function relHref(fromPage, toPath) {
  const from = fromPage.split('/').slice(0, -1)
  const to = toPath.split('/')
  let common = 0
  while (common < from.length && common < to.length - 1 && from[common] === to[common]) {
    common += 1
  }
  const up = from.length - common
  return '../'.repeat(up) + to.slice(common).join('/')
}

/** Render a complete page document. */
export function renderPage({ pagePath, bodyHtml, sections, assetHref, homeHref }) {
  const title = titleFor(sections, pagePath)
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<link rel="stylesheet" href="${esc(assetHref)}">
</head>
<body>
<header class="topbar">
  <a class="brand" href="${esc(homeHref)}">Seal Harness <span class="brand-tag">Docs</span></a>
  <nav class="topnav">
    <a href="https://github.com/seal-harness/seal-harness">GitHub</a>
  </nav>
</header>
<div class="shell">
  <aside class="sidebar" aria-label="Documentation">
${sidebar(sections, pagePath)}
  </aside>
  <main class="content">
${bodyHtml}
  </main>
</div>
<footer class="footer">
  <p>Seal Harness — safer AND more productive.</p>
</footer>
</body>
</html>
`
}

/** The page title from the nav, falling back to the filename. */
function titleFor(sections, pagePath) {
  for (const { pages } of sections) {
    for (const page of pages) {
      if (page.file === pagePath) return page.title
    }
  }
  return pagePath.replace(/\.md$/, '')
}
