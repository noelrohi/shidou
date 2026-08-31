# Task replaces Session as the domain word

The interface has always said "Task" (`sidebar.tasks`, `New task`) while the
code has always said `Session` (`AgentSession`, `session_id`), and the daemon's
own protocol comments call it the "project/task catalog" — three names for one
thing, with no entry in `CONTEXT.md` for any of them. We decided **Task** is
the single domain word, and staged the rename: `CONTEXT.md`, the interface
text, and the Rust types move now; the wire protocol keeps `sessionId`.

## Considered options

- **Session everywhere**: fewer code edits, but it would rename every
  user-visible string in four locales to a word the user never asked for.
  Rejected.
- **Two words, two meanings** (a Task is the work, a Session is the provider
  process): defensible — "Allow for task" and "Allow for session" in
  `locales/app.yml` really are different permissions — but it asks every reader
  to hold a distinction the codebase does not currently maintain anywhere.
  Rejected in favor of one word.
- **Rename the wire too**: the honest end state, but the daemon and all three
  clients would have to ship together and an old client would stop working.
  Deferred, not rejected.

## Consequences

- One exception survives, found while reading the strings: `session` still names
  a **Provider Session** — the coding agent's own conversation record, as in
  "Claude's native session file" and "Allow for session", which is a different
  permission from "Allow for task". Renaming those would make them false. Task
  is the unit; session names only the provider's own record.

- A reader will find `sessionId` on the wire and `Task` everywhere else. That
  split is deliberate and staged, not an oversight.
- Swift and TypeScript types keep `Session` until their own rename lands, so
  `Session Store` in `CONTEXT.md` still names a Swift type rather than a domain
  concept.
- Renaming the wire later is a breaking protocol change and needs its own ADR.
