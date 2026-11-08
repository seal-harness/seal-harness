import { useEffect, useRef } from 'react'

/**
 * The final screen. It does not auto-continue: the operator clicks "Start
 * chatting", which asks the gate to re-probe and (if everything is ready)
 * reveal the app. Auto-continuing on mount would yank the completion
 * confirmation away before it could be read, and would fire an extra probe on
 * every render of a step that is already finished.
 */
export function SetupComplete({ onComplete }: { onComplete: () => void }) {
  const headingRef = useRef<HTMLHeadingElement | null>(null)
  useEffect(() => {
    headingRef.current?.focus()
  }, [])
  return (
    <main className="mx-auto max-w-2xl p-8">
      <h1 ref={headingRef} tabIndex={-1} className="text-xl font-semibold text-slate-100 outline-none">
        Setup complete
      </h1>
      <p className="mt-2 text-sm text-slate-300">
        Your vault and your LLM provider are configured. Everything else can be
        changed later from the terminal with <code>seal tui</code>.
      </p>
      <button
        type="button"
        onClick={onComplete}
        className="mt-6 rounded bg-emerald-700 px-4 py-2 text-sm text-white"
      >
        Start chatting
      </button>
    </main>
  )
}
