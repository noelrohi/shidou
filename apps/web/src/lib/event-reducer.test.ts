import { describe, expect, test } from 'bun:test'
import type { ActivityItem, AgentSession, SequencedEvent } from '@shidou/client'
import { reduceRuntimeEvent, sessionHasActiveProviderTurn } from './event-reducer'
import { recordedEditsByTurn } from './recorded-edits'

const clock = {
  nowSeconds: () => 200,
  nowMillis: () => 200_000,
  randomUUID: (() => {
    let id = 0
    return () => `00000000-0000-4000-8000-${String(++id).padStart(12, '0')}`
  })(),
}

describe('reduceRuntimeEvent', () => {
  test('preserves event order across reasoning, tools, and assistant text', () => {
    let session = runningSession()
    session = apply(session, 'reasoningDelta', 'Thinking')
    session = apply(session, 'richActivity', {
      id: '10000000-0000-4000-8000-000000000001',
      source_id: 'tool-1',
      kind: 'fileRead',
      title: 'Read file',
      detail: 'src/app.rs',
      failed: false,
      complete: true,
    })
    session = apply(session, 'textDelta', 'Done')
    session = apply(session, 'textDelta', '.')

    expect(session.transcript_blocks[0]?.content).toMatchObject({
      kind: 'activities',
      data: [
        { reasoning: { content: 'Thinking' }, complete: true },
        { source_id: 'tool-1', title: 'Read file' },
      ],
    })
    expect(session.messages.at(-1)?.content).toBe('Done.')
  })

  test('reuses recorded-edit revisions across actual text-only reducer updates', () => {
    const activity: ActivityItem = {
      id: 'edit-row', source_id: 'provider-edit', kind: 'fileChange',
      title: 'Edit file', detail: null, complete: true, failed: false,
      file_changes: [{ path: 'task.ts', additions: 3, deletions: 1, diff: '@@\n-old\n+new' }],
    }
    const edited = apply(runningSession(), 'richActivity', activity)
    const summary = recordedEditsByTurn(edited)
    let streamed = edited
    for (const text of ['Done', ' with', ' edits.']) {
      const previous = streamed
      streamed = apply(previous, 'textDelta', text)
      expect(streamed.transcript_blocks).not.toBe(previous.transcript_blocks)
      expect(recordedEditsByTurn(streamed)).toBe(summary)
      expect(recordedEditsByTurn(streamed).get('turn')).toBe(summary.get('turn'))
    }
    expect(streamed.messages.at(-1)?.content).toBe('Done with edits.')

    const updated = apply(streamed, 'richActivity', {
      ...activity,
      file_changes: [{ path: 'task.ts', additions: 4, deletions: 2, diff: '@@\n-old\n+updated' }],
    })
    const updatedSummary = recordedEditsByTurn(updated)
    expect(updatedSummary).not.toBe(summary)
    expect(updatedSummary.get('turn')?.additions).toBe(4)
    expect(updatedSummary.get('turn')?.activities[0]?.file_changes?.[0]?.diff).toBe('@@\n-old\n+updated')
    expect(recordedEditsByTurn(apply(updated, 'textDelta', ' More.'))).toBe(updatedSummary)
    expect(summary.get('turn')?.additions).toBe(3)
  })

  test('shares a lazy edit revision before either text-stream snapshot is rendered', () => {
    const initial = runningSession()
    const streamed = apply(initial, 'textDelta', 'Working')
    expect(recordedEditsByTurn(streamed)).toBe(recordedEditsByTurn(initial))
    // A separately loaded snapshot must never inherit a previous revision.
    const reloaded = JSON.parse(JSON.stringify(streamed)) as AgentSession
    expect(recordedEditsByTurn(reloaded)).not.toBe(recordedEditsByTurn(streamed))
  })

  test('invalidates recorded-edit summaries when an existing activity completes or fails', () => {
    const activity: ActivityItem = {
      id: 'edit-row',
      source_id: 'provider-edit',
      kind: 'fileChange',
      title: 'Edit file',
      detail: null,
      failed: false,
      complete: false,
      file_changes: [{ path: 'task.ts', additions: 3, deletions: 1 }],
    }
    const pending = apply(runningSession(), 'richActivity', activity)
    const pendingEdits = recordedEditsByTurn(pending)
    expect(pendingEdits.size).toBe(0)
    expect(recordedEditsByTurn(pending)).toBe(pendingEdits)

    const completed = apply(pending, 'richActivity', {
      ...activity,
      id: 'completion-event',
      complete: true,
      file_changes: [],
    })
    const completedEdits = recordedEditsByTurn(completed)
    expect(completed.transcript_blocks).not.toBe(pending.transcript_blocks)
    expect(completed.transcript_blocks[0]).not.toBe(pending.transcript_blocks[0])
    expect(completedEdits).not.toBe(pendingEdits)
    expect(completedEdits.get('turn')?.files).toEqual([{ path: 'task.ts', additions: 3, deletions: 1 }])
    expect(completedEdits.get('turn')?.activities.map((item) => item.id)).toEqual(['edit-row'])
    expect(recordedEditsByTurn(completed)).toBe(completedEdits)
    expect(recordedEditsByTurn(pending).size).toBe(0)

    for (const update of [{ complete: true, failed: true }, { complete: false, failed: false }]) {
      const changed = apply(completed, 'richActivity', { ...activity, ...update })
      const changedEdits = recordedEditsByTurn(changed)
      expect(changed.transcript_blocks).not.toBe(completed.transcript_blocks)
      expect(changedEdits).not.toBe(completedEdits)
      expect(changedEdits.size).toBe(0)
      expect(recordedEditsByTurn(changed)).toBe(changedEdits)
      expect(recordedEditsByTurn(completed).get('turn')?.additions).toBe(3)
    }
  })

  test('invalidates recorded-edit attribution on canonical turn adoption and settlement', () => {
    const activity: ActivityItem = {
      id: 'edit-row', source_id: 'provider-edit', kind: 'fileChange',
      title: 'Edit file', detail: null, complete: false, failed: false,
      file_changes: [{ path: 'task.ts', additions: 3, deletions: 1 }],
    }
    const pending = apply(runningSession(), 'richActivity', activity)
    const pendingSummary = recordedEditsByTurn(pending)
    const settled = apply(pending, 'turnFinished', { success: true })
    expect(recordedEditsByTurn(settled)).not.toBe(pendingSummary)
    expect(recordedEditsByTurn(settled).get('turn')?.additions).toBe(3)
    expect(pendingSummary.size).toBe(0)

    const provisional = apply(runningSession(), 'richActivity', { ...activity, complete: true })
    const provisionalSummary = recordedEditsByTurn(provisional)
    const canonical = apply(provisional, 'turnAccepted', {
      submissionId: 'turn',
      turn: { ...provisional.turns[0], id: 'canonical-turn' },
      messages: [],
    })
    const canonicalSummary = recordedEditsByTurn(canonical)
    expect(canonicalSummary).not.toBe(provisionalSummary)
    expect(canonicalSummary.has('turn')).toBe(false)
    expect(canonicalSummary.get('canonical-turn')?.additions).toBe(3)
    expect(provisionalSummary.get('turn')?.additions).toBe(3)
  })

  test('adopts canonical ids for an optimistically echoed prompt', () => {
    const optimistic = runningSession()
    const optimisticTurnId = optimistic.turns[0]!.id
    const optimisticMessageId = optimistic.messages[0]!.id
    optimistic.messages[0]!.display_content = 'Go with context'
    optimistic.messages[0]!.attachments = [{
      name: 'context.txt',
      path: '/tmp/context.txt',
      mention: 'context.txt',
      is_dir: false,
      is_image: false,
    }]

    const session = apply(optimistic, 'turnAccepted', {
      submissionId: optimisticTurnId,
      turn: {
        ...optimistic.turns[0],
        id: 'canonical-turn',
        turn_count: 5,
      },
      messages: [{
        ...optimistic.messages[0],
        id: 'canonical-message',
        turn_id: 'canonical-turn',
        content: 'daemon prompt',
        display_content: null,
        attachments: [],
      }],
    })

    expect(optimisticTurnId).not.toBe('canonical-turn')
    expect(optimisticMessageId).not.toBe('canonical-message')
    expect(session.turns).toHaveLength(1)
    expect(session.turns[0]).toMatchObject({ id: 'canonical-turn', turn_count: 5 })
    expect(session.messages).toHaveLength(1)
    expect(session.messages[0]).toMatchObject({
      id: 'canonical-message',
      turn_id: 'canonical-turn',
      content: 'Go',
      display_content: 'Go with context',
      attachments: [{ mention: 'context.txt' }],
    })
  })

  test('incorporates a follow-up accepted by another client before its output', () => {
    let session = apply(runningSession(), 'turnFinished', { success: true, summary: null })
    const accepted = {
      submissionId: 'remote-submission',
      turn: {
        id: 'remote-turn',
        turn_count: 2,
        status: 'running',
        provider_turn_started: false,
        provider_resume_at: null,
        started_at: 201,
        completed_at: null,
        checkpoint: null,
      },
      messages: [{
        id: 'remote-message',
        turn_id: 'remote-turn',
        role: 'user',
        content: 'this works fine',
        display_content: null,
        attachments: [],
        created_at: 201,
        streaming: false,
      }],
    }
    session = apply(session, 'turnAccepted', accepted)
    session.status = 'idle'
    session = apply(session, 'turnAccepted', accepted)
    expect(session.status).toBe('connecting')
    session = apply(session, 'turnStarted', null)
    session = apply(session, 'textDelta', 'Great. What would you like to work on next?')

    expect(session.messages.at(-2)?.content).toBe('this works fine')
    expect(session.messages.at(-1)?.content).toBe('Great. What would you like to work on next?')
    expect(session.turns.at(-1)?.id).toBe('remote-turn')
  })

  test('settles the active turn and finalizes streaming output', () => {
    let session = runningSession()
    session = apply(session, 'textDelta', 'Ready')
    const result = reduceRuntimeEvent(
      session,
      event('turnFinished', { success: true, summary: null }),
      clock,
    )

    expect(result.settled).toBe(true)
    expect(result.session.status).toBe('idle')
    expect(result.session.turns[0]?.status).toBe('completed')
    expect(result.session.messages.at(-1)?.streaming).toBe(false)
  })

  test('does not turn a completed session into a failure when its process exits', () => {
    let session = runningSession()
    session = reduceRuntimeEvent(
      session,
      event('turnFinished', { success: true, summary: null }),
      clock,
    ).session
    const result = reduceRuntimeEvent(session, event('processExited', null), clock)

    expect(result.session.status).toBe('idle')
    expect(result.session.turns[0]?.status).toBe('completed')
    expect(result.settled).toBe(false)
    expect(result.removeRuntime).toBe(true)
  })

  test('stores the daemon sequence incorporated into the transcript', () => {
    const wire = { ...event('textDelta', 'hello'), sequence: 42 }
    const result = reduceRuntimeEvent(runningSession(), wire, clock)

    expect(result.session.runtime_event_cursor).toEqual({
      runtime_id: 'runtime',
      epoch: 'epoch',
      sequence: 42,
    })
  })

  test('records Claude resume position on the active turn', () => {
    const result = reduceRuntimeEvent(
      runningSession(),
      event('connected', {
        provider: 'claude',
        sessionId: 'provider-session',
        resumeAt: 'provider-message',
      }),
      clock,
    )

    expect(result.session.turns[0]?.provider_resume_at).toBe('provider-message')
  })

  test('ignores late turn output and permission events after a turn settles', () => {
    let session = reduceRuntimeEvent(
      runningSession(),
      event('turnFinished', { success: true, summary: null }),
      clock,
    ).session
    const messageCount = session.messages.length
    session = apply(session, 'textDelta', 'late output')
    session = apply(session, 'richActivity', {
      id: 'late-tool',
      source_id: 'late-tool',
      kind: 'tool',
      title: 'Late tool',
      failed: false,
      complete: true,
    })
    const permission = reduceRuntimeEvent(
      session,
      event('permission', { requestId: 'late', title: 'Late', detail: '', options: [] }),
      clock,
    )

    expect(permission.session.messages).toHaveLength(messageCount)
    expect(permission.session.transcript_blocks).toHaveLength(0)
    expect(permission.session.status).toBe('idle')
    expect(permission.permission).toBeUndefined()
  })

  test('surfaces structured provider questions and clears them when the turn settles', () => {
    const requested = reduceRuntimeEvent(
      runningSession(),
      event('userInputRequested', {
        requestId: 'question-request',
        questions: [{
          id: 'deployment',
          header: 'Environment',
          question: 'Where should this deploy?',
          options: [{ label: 'Preview', description: 'Create a preview deployment' }],
          multiSelect: false,
        }],
      }),
      clock,
    )

    expect(requested.session.status).toBe('waiting')
    expect(requested.userInput?.questions[0]).toMatchObject({
      id: 'deployment',
      options: [{ label: 'Preview' }],
    })

    const resolved = reduceRuntimeEvent(
      requested.session,
      event('interactionResolved', { requestId: 'question-request' }),
      clock,
    )
    expect(resolved.session.status).toBe('waiting')
    expect(resolved.resolvedInteractionId).toBe('question-request')
    expect(resolved.userInput).toBeUndefined()
    expect(resolved.permission).toBeUndefined()

    const settled = reduceRuntimeEvent(
      requested.session,
      event('turnFinished', { success: true, summary: null }),
      clock,
    )
    expect(settled.userInput).toBeNull()
  })

  test('keeps the provider error when a working runtime exits', () => {
    let session = apply(runningSession(), 'turnStarted', null)
    const errored = reduceRuntimeEvent(session, event('error', 'provider exploded'), clock)
    expect(errored.session.status).toBe('working')
    session = reduceRuntimeEvent(
      errored.session,
      event('processExited', null),
      clock,
      errored.error,
    ).session

    expect(session.status).toBe('failed')
    expect(session.messages.at(-1)?.content).toBe('provider exploded')
  })

  test('surfaces a startup error immediately without duplicating it on exit', () => {
    const errored = reduceRuntimeEvent(
      runningSession(),
      event('error', 'could not start provider'),
      clock,
    )
    expect(errored.session.status).toBe('failed')
    expect(errored.session.messages.at(-1)?.content).toBe('could not start provider')

    const exited = reduceRuntimeEvent(
      errored.session,
      event('processExited', null),
      clock,
      errored.error,
    )
    expect(exited.session.messages.filter((message) => message.role === 'assistant')).toHaveLength(1)
  })
})

function apply(session: AgentSession, kind: string, payload: unknown) {
  return reduceRuntimeEvent(session, event(kind, payload), clock).session
}

function event(kind: string, payload: unknown): SequencedEvent {
  return {
    sessionId: 'session',
    runtimeId: 'runtime',
    epoch: 'epoch',
    sequence: 1,
    event: { kind, payload: payload as never },
  }
}

describe('steering readiness', () => {
  test('a busy turn the provider has not started yet has nothing to steer', () => {
    const session = runningSession()
    expect(session.turns.at(-1)?.provider_turn_started).toBe(false)
    expect(sessionHasActiveProviderTurn(session)).toBe(false)
  })

  test('turnStarted opens steering', () => {
    const session = apply(runningSession(), 'turnStarted', null)
    expect(sessionHasActiveProviderTurn(session)).toBe(true)
  })

  test('foreground output repairs a runtime that missed turnStarted', () => {
    // Otherwise the chord stays stuck on the follow-up queue while output is
    // visibly streaming in.
    const session = apply(runningSession(), 'textDelta', 'Working')
    expect(session.status).toBe('working')
    expect(sessionHasActiveProviderTurn(session)).toBe(true)
  })

  test('a settled turn closes steering again', () => {
    let session = apply(runningSession(), 'turnStarted', null)
    session = apply(session, 'turnFinished', { success: true, summary: null })
    expect(sessionHasActiveProviderTurn(session)).toBe(false)
  })
})

function runningSession(): AgentSession {
  return {
    id: 'session',
    title: 'New task',
    project_id: 'project',
    workspace: { kind: 'local' },
    provider: 'codex',
    runtime_mode: 'fullAccess',
    interaction_mode: 'build',
    status: 'connecting',
    created_at: 100,
    updated_at: 100,
    provider_cursor: null,
    messages: [
      {
        id: 'message',
        turn_id: 'turn',
        role: 'user',
        content: 'Go',
        created_at: 100,
        streaming: false,
      },
    ],
    transcript_blocks: [],
    turns: [
      {
        id: 'turn',
        turn_count: 1,
        status: 'running',
        provider_turn_started: false,
        started_at: 100,
        completed_at: null,
        checkpoint: null,
      },
    ],
  }
}
