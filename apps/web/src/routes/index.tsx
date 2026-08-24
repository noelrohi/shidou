import { createFileRoute } from '@tanstack/react-router'
import { ShidouShell } from '@/components/shidou-shell'

export const Route = createFileRoute('/')({
  validateSearch: (search: Record<string, unknown>) => ({
    session: typeof search.session === 'string' ? search.session : undefined,
  }),
  component: IndexRoute,
})

function IndexRoute() {
  return <ShidouShell />
}
