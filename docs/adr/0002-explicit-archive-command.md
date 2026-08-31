# An explicit archive command, not a snapshot field

The Task Shelf needs one persisted mark per task, and `SaveTaskState` already
carries the whole `Vec<AgentSession>` snapshot, so adding `archivedAt` to
`AgentSession` looks like the free option. We rejected it and added an explicit
`ArchiveSession` command next to `RemoveSession`, because snapshot saves are
merge-only by design — a stale client's snapshot must never undo a write
another client just made — and because the daemon has to be able to *refuse*
the mark while a task is Working or Waiting, which a merge has no way to
express.

## Considered options

- **`archivedAt` on the `AgentSession` snapshot**: no new wire surface, but a
  client that saves a snapshot taken before another client archived a task
  would clear the mark, exactly the class of bug `RemoveSession` and
  `RemoveProject` already exist to prevent. Rejected.
- **A client-side rule over existing fields** (treat "quiet for N days" as
  archived, store nothing): no schema and no wire change, but the rule would
  have to be ported three times — `src/app/sidebar.rs`,
  `SessionListPresentation.swift`, `apps/web/src/lib/sidebar-presentation.ts` —
  and a divergent port shows the user a different sidebar per device.
  Rejected; the mark is a user decision, not a derivation.

## Consequences

- The mark is daemon state, so all three clients agree with no shared rule.
  Clients read the field and render; they never decide.
- `ArchiveSession` can fail. Clients must handle a refusal, which is the
  Working/Waiting guard surfacing.
- Clearing is also daemon-side: a user prompt, a turn start, a permission
  request, a question, or a failure clears the mark. A rename, an automatic
  title, or an open does not.
- Change propagates through the existing `TaskStateChanged { revision }`
  broadcast; no new invalidation path.
