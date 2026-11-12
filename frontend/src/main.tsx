import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App'
import { AccessGate } from './components/AccessGate'
import { SetupGate } from './components/setup/SetupGate'
import { installUnauthorizedInterceptor } from './lib/unauthorized'
import './App.css'

installUnauthorizedInterceptor()

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <AccessGate>
      <SetupGate>
        <App />
      </SetupGate>
    </AccessGate>
  </StrictMode>,
)
