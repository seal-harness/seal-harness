import { useEffect, useState } from 'react'
import { fetchAllProviders } from './useApi'

/**
 * A shared, module-level cache of provider name → base URL, populated once
 * per page load (and refreshed when 'refreshProviderBaseUrls' is called).
 *
 * Multiple components calling 'useProviderBaseUrls' share this single map
 * — the fetch happens once, not per 'ProviderBadge' instance.
 */
let baseUrlsCache: Map<string, string> | null = null
let baseUrlsPromise: Promise<Map<string, string>> | null = null

/**
 * Fetch the provider name → base URL map (once, shared across all callers).
 * Returns the cached map if already fetched. Exposed for the icon resolver
 * so it can look up a provider's base URL without a React hook.
 */
export function getProviderBaseUrls(): Promise<Map<string, string>> {
  if (baseUrlsCache) return Promise.resolve(baseUrlsCache)
  if (baseUrlsPromise) return baseUrlsPromise
  baseUrlsPromise = (async () => {
    const providers = await fetchAllProviders()
    const map = new Map<string, string>()
    if (providers) {
      for (const p of providers) {
        if (p.baseUrl) map.set(p.name, p.baseUrl)
      }
    }
    baseUrlsCache = map
    baseUrlsPromise = null
    return map
  })()
  return baseUrlsPromise
}

/** Force a refresh of the provider base URL cache (e.g. after a provider mutation). */
export function refreshProviderBaseUrls(): void {
  baseUrlsCache = null
  baseUrlsPromise = null
}

/**
 * React hook: returns a map of provider name → base URL, fetched once on
 * mount. Multiple components share the same underlying fetch. Returns an
 * empty map while loading.
 */
export function useProviderBaseUrls(): Map<string, string> {
  const [map, setMap] = useState<Map<string, string>>(
    () => baseUrlsCache ?? new Map(),
  )
  useEffect(() => {
    let cancelled = false
    void getProviderBaseUrls().then((m) => {
      if (!cancelled) setMap(m)
    })
    return () => { cancelled = true }
  }, [])
  return map
}
