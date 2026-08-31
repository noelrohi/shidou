# Daemon-owned turn persistence

Two data-loss events in one night (issue #28) showed that client-owned
persistence lets turns vanish: the daemon executed prompts to completion but
recorded nothing, so a client dying between `prompt` and its `saveTaskState`
lost the turns everywhere except the provider's own files. We decided the
daemon authors and persists the transcript itself: it writes the user message
and running turn when a prompt arrives, reduces the event stream with the
canonical Reducer (shared with the desktop app), and saves at turn
boundaries, stamping its projection with the event cursor it has reduced up
to.

## Considered options

- **Client-owned saves plus a journal safety net** (persist the event journal
  before runtime teardown): less work, but recovery stays a manual rebuild
  and the daemon remains a bystander to work it executed. Rejected.
- **Hard "daemon wins during a run" merge rule**: rejected in favor of
  reusing the existing cursor-ordering merge, which demotes stale client
  saves to metadata-only with no new special cases.

## Consequences

- The apps (desktop, web, iOS) stop persisting transcripts; `saveTaskState`
  remains for session creation and metadata (title, model, drafts, queued
  messages), and stale transcript content in a save is ignored by cursor
  ordering.
- Old installed builds that still persist-then-prompt keep working: the
  daemon reuses an already-persisted running turn and synthesizes one only
  when absent.
- Clients echo a sent prompt optimistically with temporary ids and adopt the
  Accepted Turn's canonical ids.
- The daemon saves at turn boundaries (prompt accepted, turn finished,
  provider resume position reported); a daemon crash mid-turn loses only that
  turn's partial output, still recoverable from the provider's native
  transcript.
- The provider's native session id is tracked mid-runtime (Claude `/clear`
  forks it), so the resume cursor follows the fork instead of silently
  pointing at the pre-`/clear` conversation.
