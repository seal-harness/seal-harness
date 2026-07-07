// Placeholder App — T0. The full component composition lands in T9.
// Imports App.css (the copied visual system) + renders the brand shell.
import { useState } from 'react'

export default function App() {
  const [input, setInput] = useState('')
  return (
    <div className="app-shell">
      <header className="app-header">
        <h1>Seal Harness</h1>
      </header>
      <main className="app-main">
        <p className="app-placeholder">Frontend under construction (Phase 7b).</p>
      </main>
      <footer className="app-footer">
        <input
          value={input}
          onChange={(e) => setInput(e.target.value)}
          placeholder="Type a message…"
        />
      </footer>
    </div>
  )
}