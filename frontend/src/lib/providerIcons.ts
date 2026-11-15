/**
 * Provider icon resolution — fetch the root page of an OpenAI-compatible
 * provider's base URL, find a @<link rel="icon">@ (or @apple-touch-icon@),
 * and return the absolute icon URL.
 *
 * This is a frontend-direct fetch: the browser calls the provider's website
 * directly. Results are cached per base URL (resolved + in-flight) so a
 * second render of the same provider does not refetch.
 *
 * Used by 'ProviderBadge' in 'ActiveTabs.tsx' for providers that are not in
 * the static 'PROVIDER_BADGE' map (i.e. custom OpenAI-compatible instances).
 */

// ── Pure helpers ────────────────────────────────────────────────────────

/**
 * Derive the root page URL (origin only) from a provider base URL.
 * Strips @/v1@ and any trailing path. Returns @null@ when the input is
 * empty or not a parseable URL.
 *
 *   "https://api.openai.com/v1"      → "https://api.openai.com"
 *   "http://localhost:8000/v1/"      → "http://localhost:8000"
 *   "https://api.example.com/api/v2" → "https://api.example.com"
 *   "https://api.example.com"        → "https://api.example.com"
 */
export function deriveRootUrl(baseUrl: string): string | null {
  const trimmed = baseUrl.trim()
  if (!trimmed) return null
  try {
    const u = new URL(trimmed)
    return `${u.protocol}//${u.host}`
  } catch {
    return null
  }
}

// Order of preference for @rel@ attribute values. @icon@ and @shortcut icon@
// are the standard favicon links; @apple-touch-icon@ is a higher-resolution
// fallback that most sites publish.
const ICON_REL_PATTERNS: readonly RegExp[] = [
  /rel\s*=\s*["'](?:shortcut\s+icon|icon)["']/i,
  /rel\s*=\s*["']apple-touch-icon["']/i,
]

/**
 * Extract the first icon @<link>@ tag's @href@ value from an HTML string.
 * Searches for @<link rel="icon">@, @<link rel="shortcut icon">@, and
 * @<link rel="apple-touch-icon">@ (case-insensitive), in that preference
 * order. Returns @null@ when no icon link is found.
 *
 * This is a lightweight regex scan, not a full HTML parse — we only need
 * the @href@ of a @<link>@ tag, and the HTML we fetch is a provider's
 * landing page (not adversarial input in this trust context).
 */
export function extractIconUrl(html: string, _rootUrl: string): string | null {
  for (const relPattern of ICON_REL_PATTERNS) {
    // Match a <link ...> tag containing the rel attribute, then extract href.
    // We scan for all <link> tags and check which ones match the rel pattern.
    const linkTagRe = /<link\b[^>]*>/gi
    let m: RegExpExecArray | null
    while ((m = linkTagRe.exec(html)) !== null) {
      const tag = m[0]
      if (relPattern.test(tag)) {
        const hrefMatch = tag.match(/href\s*=\s*["']([^"']+)["']/i)
        if (hrefMatch && hrefMatch[1]) {
          return hrefMatch[1]
        }
      }
    }
  }
  return null
}

/**
 * Resolve an icon @href@ (which may be absolute, protocol-relative, or
 * root-relative) to an absolute URL using the provider's root URL as the
 * base. Returns @null@ when the href is empty or the root URL is @null@.
 */
export function resolveIconUrl(href: string, rootUrl: string | null): string | null {
  const h = href.trim()
  if (!h || !rootUrl) return null
  try {
    return new URL(h, rootUrl).href
  } catch {
    return null
  }
}

// ── Fetch + cache ───────────────────────────────────────────────────────

/** The cache: base URL → resolved icon URL (or @null@ = no icon found). */
const iconCache = new Map<string, string | null>()

/** In-flight promises, so concurrent calls for the same base URL share one fetch. */
const inFlight = new Map<string, Promise<string | null>>()

/** Clear the icon cache (for tests). */
export function clearIconCache(): void {
  iconCache.clear()
  inFlight.clear()
}

/**
 * Fetch the root page at the provider's base URL origin, extract the icon
 * @<link>@ href, and return the absolute icon URL. Returns @null@ when:
 * - the base URL is empty/null
 * - the root page cannot be fetched (network error, non-200)
 * - the root page has no icon @<link>@ tag
 *
 * Results are cached per base URL. Concurrent calls for the same base URL
 * share a single in-flight fetch.
 */
export async function resolveProviderIcon(baseUrl: string | null): Promise<string | null> {
  if (!baseUrl) return null
  const trimmed = baseUrl.trim()
  if (!trimmed) return null

  // Cache hit (including null = "no icon found" — don't refetch).
  if (iconCache.has(trimmed)) {
    return iconCache.get(trimmed) ?? null
  }

  // In-flight dedup: a fetch for this base URL is already running.
  const existing = inFlight.get(trimmed)
  if (existing) return existing

  const promise = fetchProviderIcon(trimmed)
  inFlight.set(trimmed, promise)
  try {
    const result = await promise
    iconCache.set(trimmed, result)
    return result
  } finally {
    inFlight.delete(trimmed)
  }
}

/** The actual fetch + parse, factored out so the cache wrapper stays clean. */
async function fetchProviderIcon(baseUrl: string): Promise<string | null> {
  const rootUrl = deriveRootUrl(baseUrl)
  if (!rootUrl) return null

  try {
    const resp = await fetch(rootUrl, {
      // This is a best-effort icon lookup; don't send credentials.
      credentials: 'omit',
      // A short signal so a slow provider doesn't block the UI.
      signal: AbortSignal.timeout(5000),
    })
    if (!resp.ok) return null

    const html = await resp.text()
    const href = extractIconUrl(html, rootUrl)
    if (!href) return null

    return resolveIconUrl(href, rootUrl)
  } catch {
    return null
  }
}
