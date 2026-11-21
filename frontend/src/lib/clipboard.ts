/** Best-effort clipboard copy that survives non-secure contexts. Resolves
 *  `true` if either the modern Clipboard API or the legacy `execCommand`
 *  path succeeded, `false` if both failed (so the caller can offer a manual
 *  fallback instead of claiming success).
 *
 *  The Clipboard API rejects on insecure origins, in some Firefox contexts,
 *  and whenever the Permissions Policy withholds `clipboard-write` — all of
 *  which the server may well be served under — so the legacy path is not
 *  dead code. */
export async function copyTextToClipboard(text: string): Promise<boolean> {
  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(text)
      return true
    } catch {
      // Fall through to the execCommand fallback (permissions / non-secure
      // context / Firefox-on-some-pages all reject the same way).
    }
  }
  return execCommandCopy(text)
}

/** Last-resort copy: a temporary off-screen textarea plus `execCommand`.
 *  The node is always removed, so a failed copy leaves no scratch DOM. */
function execCommandCopy(text: string): boolean {
  const ta = document.createElement('textarea')
  ta.value = text
  // Off-screen but still focusable.
  ta.style.position = 'fixed'
  ta.style.top = '0'
  ta.style.left = '0'
  ta.style.opacity = '0'
  ta.style.pointerEvents = 'none'
  ta.setAttribute('readonly', '')
  document.body.appendChild(ta)
  ta.select()
  let ok = false
  try {
    ok = document.execCommand('copy')
  } catch {
    ok = false
  }
  document.body.removeChild(ta)
  return ok
}
