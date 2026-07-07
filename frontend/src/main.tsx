// Minimal Seal Harness chat shell — React 18 + TypeScript + Vite + Tailwind.
// Deliberately minimal: transcript view, send box, live WS streaming, /help.
// The full UI is Phase 7b.
import React, { useState, useEffect, useRef } from 'react'
import { createRoot } from 'react-dom/client'

interface Entry { id: string; text: string; kind: string }

function App() {
  const [entries, setEntries] = useState<Entry[]>([])
  const [input, setInput] = useState('')
  const [sessionId] = useState('default')
  const wsRef = useRef<WebSocket | null>(null)

  useEffect(() => {
    const ws = new WebSocket(`ws://${window.location.hostname}:8081/`)
    wsRef.current = ws
    ws.onmessage = (e) => {
      try {
        const data = JSON.parse(e.data)
        setEntries((prev) => [...prev, { id: crypto.randomUUID(), text: JSON.stringify(data), kind: 'event' }])
      } catch { /* ignore non-JSON */ }
    }
    return () => ws.close()
  }, [])

  const send = async () => {
    if (!input.trim()) return
    await fetch(`/api/sessions/${sessionId}/send`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ message: input }),
    })
    setEntries((prev) => [...prev, { id: crypto.randomUUID(), text: input, kind: 'user' }])
    setInput('')
  }

  return (
    <div style={{ fontFamily: 'monospace', maxWidth: '800px', margin: '0 auto', padding: '1rem' }}>
      <h1>Seal Harness</h1>
      <div style={{ minHeight: '400px', border: '1px solid #ccc', padding: '1rem', marginBottom: '1rem' }}>
        {entries.map((e) => (
          <div key={e.id} style={{ color: e.kind === 'user' ? 'blue' : 'black' }}>{e.text}</div>
        ))}
      </div>
      <div style={{ display: 'flex', gap: '0.5rem' }}>
        <input
          style={{ flex: 1, padding: '0.5rem' }}
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={(e) => e.key === 'Enter' && send()}
          placeholder="Type a message or /help..."
        />
        <button onClick={send}>Send</button>
      </div>
    </div>
  )
}

createRoot(document.getElementById('root')!).render(<App />)