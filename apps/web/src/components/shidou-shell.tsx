import { lazy, Suspense, useEffect } from 'react'
import { ConnectionPanel } from '@/components/connection-panel'
import { StartupScreen } from '@/components/startup-screen'
import { useDaemon } from '@/lib/daemon-context'

const loadConnectedApp = () => import('@/components/shidou-app')
const ConnectedShidouApp = lazy(() => loadConnectedApp().then((module) => ({
  default: module.ShidouApp,
})))

export function ShidouShell() {
  const { config, phase } = useDaemon()

  useEffect(() => {
    if (phase === 'connecting' && config) void loadConnectedApp()
  }, [config, phase])

  if (phase !== 'connected') return <ConnectionPanel />
  return (
    <Suspense fallback={<StartupScreen />}>
      <ConnectedShidouApp />
    </Suspense>
  )
}
