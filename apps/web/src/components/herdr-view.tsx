import { useQuery, useQueryClient } from '@tanstack/react-query'
import type { HerdrAgent, HerdrAgentStatus } from '@shidou/client'
import { useEffect, useMemo, useState } from 'react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { Dialog, DialogContent, DialogTitle } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { ShidouIcon } from '@/components/shidou-icon'
import { useHerdrState } from '@/hooks/use-daemon-data'
import {
  daemonKeys,
  promptHerdrAgent,
  readHerdrAgent,
  sendHerdrAgentKeys,
  startHerdrAgent,
} from '@/lib/daemon-api'
import { useDaemon } from '@/lib/daemon-context'
import { cn } from '@/lib/utils'

export function HerdrView({ open, onOpenChange }: {
  open: boolean
  onOpenChange: (open: boolean) => void
}) {
  const { client, config } = useDaemon()
  const queryClient = useQueryClient()
  const state = useHerdrState(open)
  const [selectedTerminal, setSelectedTerminal] = useState<string | null>(null)
  const [creating, setCreating] = useState(false)

  const agents = state.data?.agents ?? []
  const selected = agents.find((agent) => agent.terminal_id === selectedTerminal) ?? agents[0]

  useEffect(() => {
    if (!open || selectedTerminal || !agents[0]) return
    setSelectedTerminal(agents[0].terminal_id)
  }, [agents, open, selectedTerminal])

  if (!open) return null

  async function refresh() {
    if (!config) return
    await queryClient.invalidateQueries({ queryKey: daemonKeys.herdr(config.address) })
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="flex size-full max-h-[900px] max-w-[1280px] overflow-hidden rounded-none bg-background p-0 sm:rounded-xl">
        <DialogTitle className="sr-only">Herdr agents</DialogTitle>
        <aside className="flex w-[280px] shrink-0 flex-col border-r border-border bg-sidebar max-md:w-[210px]">
          <header className="flex h-12 items-center gap-2 border-b border-border px-3">
            <strong className="text-sm">Herdr</strong>
            <span className="text-xs text-muted-foreground">
              {state.data?.version ? `v${state.data.version}` : ''}
            </span>
            <div className="flex-1" />
            <Button aria-label="Refresh Herdr" size="icon-sm" variant="ghost" onClick={() => void refresh()}>
              <ShidouIcon name="rotateCw" />
            </Button>
          </header>
          <div className="min-h-0 flex-1 overflow-y-auto p-2">
            {!state.data?.available ? (
              <p className="p-3 text-sm text-muted-foreground">
                {state.data?.unavailable_reason ?? state.error?.message ?? 'Connecting to Herdr…'}
              </p>
            ) : state.data.workspaces.map((workspace) => {
              const workspaceAgents = agents.filter((agent) => agent.workspace_id === workspace.id)
              return (
                <section className="mb-3" key={workspace.id}>
                  <h2 className="px-2 py-1 text-xs font-medium text-muted-foreground">{workspace.label}</h2>
                  {workspaceAgents.length ? workspaceAgents.map((agent) => (
                    <AgentButton
                      agent={agent}
                      key={agent.terminal_id}
                      selected={selected?.terminal_id === agent.terminal_id}
                      onSelect={() => setSelectedTerminal(agent.terminal_id)}
                    />
                  )) : <p className="px-2 py-1 text-xs text-muted-foreground">No active agents</p>}
                </section>
              )
            })}
          </div>
          <div className="border-t border-border p-2">
            <Button className="w-full justify-start" variant="ghost" onClick={() => setCreating(true)}>
              <ShidouIcon name="plus" /> New Herdr agent
            </Button>
          </div>
        </aside>

        <main className="min-w-0 flex-1">
          {creating ? (
            <NewHerdrAgent
              onCancel={() => setCreating(false)}
              onCreated={async (agent) => {
                setCreating(false)
                setSelectedTerminal(agent.terminal_id)
                await refresh()
              }}
            />
          ) : selected ? (
            <AgentTerminal agent={selected} />
          ) : (
            <div className="grid size-full place-items-center text-sm text-muted-foreground">
              Select an agent or start one.
            </div>
          )}
        </main>
      </DialogContent>
    </Dialog>
  )
}

function AgentButton({ agent, selected, onSelect }: {
  agent: HerdrAgent
  selected: boolean
  onSelect: () => void
}) {
  return (
    <button
      aria-current={selected ? 'page' : undefined}
      className={cn(
        'flex w-full items-center gap-2 rounded-md px-2 py-2 text-left outline-none hover:bg-accent focus-visible:ring-1 focus-visible:ring-ring',
        selected && 'bg-accent',
      )}
      type="button"
      onClick={onSelect}
    >
      <StatusDot status={agent.status} />
      <span className="min-w-0">
        <span className="block truncate text-sm">{agent.title ?? agent.name ?? agent.agent}</span>
        <span className="block truncate text-xs text-muted-foreground">{agent.agent} · {agent.status}</span>
      </span>
    </button>
  )
}

function StatusDot({ status }: { status: HerdrAgentStatus }) {
  return (
    <span
      aria-label={status}
      className={cn(
        'size-2 shrink-0 rounded-full border',
        status === 'working' && 'border-blue-500 bg-blue-500',
        status === 'blocked' && 'border-orange-500 bg-orange-500',
        status === 'done' && 'border-green-500 bg-green-500',
        (status === 'idle' || status === 'unknown') && 'border-muted-foreground',
      )}
      role="img"
    />
  )
}

function AgentTerminal({ agent }: { agent: HerdrAgent }) {
  const { client, config } = useDaemon()
  const [prompt, setPrompt] = useState('')
  const [sending, setSending] = useState(false)
  const output = useQuery({
    queryKey: daemonKeys.herdrOutput(config?.address ?? 'disconnected', agent.terminal_id),
    queryFn: () => readHerdrAgent(client!, agent.terminal_id),
    enabled: Boolean(client && config),
    refetchInterval: 1_500,
  })

  async function sendPrompt() {
    const text = prompt.trim()
    if (!client || !text || sending) return
    setPrompt('')
    setSending(true)
    try {
      await promptHerdrAgent(client, agent.terminal_id, text)
      await output.refetch()
    } catch (error) {
      setPrompt(text)
      toast.error(error instanceof Error ? error.message : String(error))
    } finally {
      setSending(false)
    }
  }

  async function sendKeys(keys: string[]) {
    if (!client) return
    try {
      await sendHerdrAgentKeys(client, agent.terminal_id, keys)
      await output.refetch()
    } catch (error) {
      toast.error(error instanceof Error ? error.message : String(error))
    }
  }

  return (
    <div className="flex size-full flex-col">
      <header className="flex h-12 shrink-0 items-center gap-2 border-b border-border px-4 pr-12">
        <StatusDot status={agent.status} />
        <strong className="truncate text-sm">{agent.title ?? agent.name ?? agent.agent}</strong>
        <span className="truncate text-xs text-muted-foreground">{agent.cwd}</span>
        <div className="flex-1" />
        <Button size="sm" variant="ghost" onClick={() => void sendKeys(['esc'])}>Esc</Button>
        <Button size="sm" variant="ghost" onClick={() => void sendKeys(['ctrl+c'])}>Interrupt</Button>
      </header>
      <pre className="min-h-0 flex-1 overflow-auto whitespace-pre-wrap break-words bg-[#111] p-4 font-mono text-xs leading-relaxed text-[#e7e7e7]">
        {output.data?.text ?? (output.isPending ? 'Loading terminal output…' : 'No terminal output')}
      </pre>
      <form
        className="flex shrink-0 gap-2 border-t border-border p-3"
        onSubmit={(event) => { event.preventDefault(); void sendPrompt() }}
      >
        <Input
          aria-label="Prompt agent"
          placeholder="Prompt agent"
          value={prompt}
          onChange={(event) => setPrompt(event.target.value)}
        />
        <Button disabled={sending || !prompt.trim()} type="submit">Send</Button>
      </form>
    </div>
  )
}

function NewHerdrAgent({ onCancel, onCreated }: {
  onCancel: () => void
  onCreated: (agent: HerdrAgent) => void | Promise<void>
}) {
  const { client } = useDaemon()
  const [cwd, setCwd] = useState('')
  const [label, setLabel] = useState('')
  const [kind, setKind] = useState('codex')
  const [name, setName] = useState('agent')
  const [starting, setStarting] = useState(false)
  const valid = useMemo(() => cwd.startsWith('/') && Boolean(kind.trim() && name.trim()), [cwd, kind, name])

  async function submit() {
    if (!client || !valid || starting) return
    setStarting(true)
    try {
      const agent = await startHerdrAgent(client, {
        cwd,
        label: label || cwd.split('/').filter(Boolean).at(-1) || 'workspace',
        agentKind: kind,
        agentName: name,
      })
      await onCreated(agent)
    } catch (error) {
      toast.error(error instanceof Error ? error.message : String(error))
    } finally {
      setStarting(false)
    }
  }

  return (
    <form
      className="mx-auto flex h-full w-full max-w-lg flex-col justify-center gap-4 p-6"
      onSubmit={(event) => { event.preventDefault(); void submit() }}
    >
      <div>
        <h2 className="text-lg font-semibold">New Herdr agent</h2>
        <p className="text-sm text-muted-foreground">Create a durable Herdr workspace and start an agent in its root pane.</p>
      </div>
      <label className="grid gap-1 text-sm">Workspace path<Input required value={cwd} onChange={(event) => setCwd(event.target.value)} /></label>
      <label className="grid gap-1 text-sm">Workspace label<Input value={label} onChange={(event) => setLabel(event.target.value)} /></label>
      <label className="grid gap-1 text-sm">Agent kind<Input required value={kind} onChange={(event) => setKind(event.target.value)} /></label>
      <label className="grid gap-1 text-sm">Agent name<Input required value={name} onChange={(event) => setName(event.target.value)} /></label>
      <div className="flex justify-end gap-2">
        <Button type="button" variant="ghost" onClick={onCancel}>Cancel</Button>
        <Button disabled={!valid || starting} type="submit">{starting ? 'Starting…' : 'Start agent'}</Button>
      </div>
    </form>
  )
}
