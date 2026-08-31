# Shidou

A native client for coding-agent tasks: a macOS GPUI app, an iOS SwiftUI app,
and a browser client that connect to a per-user daemon owning the provider
processes.

## Language

### Connection

**Daemon**:
The per-user background process that owns provider sessions and serves them
over a WebSocket at `/v1`. Clients are viewers; the daemon is the source of
truth.
_Avoid_: server, backend

**Saved Daemon**:
A daemon the phone has paired with and persisted: its candidate addresses,
metadata, and a Keychain-held token. v1 keeps exactly one, stored as a
list-of-one.
_Avoid_: connection, account

**Candidate Address**:
One of the several addresses a daemon may be reachable at (LAN IP, `.local`
hostname, Tailscale IP or name). Pairing and reconnect try candidates in
order; the last-good candidate is tried first.
_Avoid_: endpoint list, fallback URL

**Pairing**:
Acquiring a daemon's candidate addresses and token on the phone, by scanning
the desktop's QR (a versioned `shidou://pair` URL) or by manual entry.
_Avoid_: login, sign-in

**Re-pair**:
Recovering from a rejected token: the Saved Daemon's addresses are kept, the
token is replaced by rescanning or editing. Distinct from forgetting the
daemon.

**Demo Daemon**:
The public fixture daemon at `demo.shidou.dev`, a separate `shidou-demo`
binary serving a scripted Demo Session. It is what an App Review reviewer
and a prospective user reach with "Try the demo"; its token is baked into
the app and is therefore public, which is safe only because the backend has
no side effects. Persisted as a Saved Daemon flagged `isDemo`, and evicted
when a real daemon is paired.
_Avoid_: demo mode, sandbox, staging

**Demo Session**:
The scripted session the Demo Daemon serves: streaming assistant text, a
tool call, a permission request, a diff, and a canned reply to anything the
composer sends. Nothing in it executes.
_Avoid_: sample, fixture data

**Insecure Remote**:
A cleartext `ws://` endpoint that is neither loopback nor trusted transport;
the token travels unencrypted. Warned once at pairing and badged in settings.

**Trusted Transport**:
An address whose path is encrypted below the WebSocket: `wss://`, loopback,
or a Tailscale address (`100.64.0.0/10`, `*.ts.net`). Never warned.

**Suspend**:
Cleanly pausing the connection when the app leaves the foreground — at the
end of the Grace Window, or immediately if none is granted — harvesting
replay cursors for the next reconnect. iOS denies background local-network
traffic, so nothing lingers past it.
_Avoid_: background mode, keep-alive

**Grace Window**:
The ~30 seconds of background execution iOS grants after the app is
backgrounded. The connection stays alive through it so Attention Events can
still fire local notifications; when it expires, Suspend runs. The only
locked-phone signal v1 has — after it, silence until the app reopens.

**Attention Event**:
An agent event worth interrupting the user for: a permission request, a
question for the user, or a finished turn. Fires a local notification during
the Grace Window; from a non-visible session in the foreground, the blocking
two (permission, question) show an in-app banner.
_Avoid_: alert, push

**Waiting Task**:
A Task blocked on the user — a pending permission or question. Marked in
the task list; reopening the app restores its pending prompt via replay.
_Avoid_: waiting session, blocked task

**App Reload**:
The desktop recovery command (debug builds): rebuilding the app's entire UI
state in place, inside the same process, window, and daemon connection. The
daemon, its runtimes, and other clients continue uninterrupted. Distinct from
a browser reload (the embedded webview only) and a daemon restart (Settings →
Daemon Apply, which replaces the daemon process).
_Avoid_: refresh, restart

**Replay Cursor**:
A client's high-water mark per session runtime (epoch + sequence), sent on
reconnect so the daemon replays only missed events. Held in memory across
reconnects; never persisted across launches.

**Replay Gap**:
The daemon telling a client that replay cannot make it whole: its Replay
Cursor fell behind the oldest event still in the per-runtime journal, so the
events between them are gone. The client refetches the session instead of
applying the surviving tail onto a projection with a hole in it. A phone
backgrounded through a long run is the ordinary way to get here.
_Avoid_: desync, missed events

### Task

**Task**:
One conversation with one coding agent in one project. It is the unit the
sidebar lists and the daemon owns.
_Avoid_: session, thread, chat, conversation

**Provider Session**:
The coding agent's own conversation record, owned and named by the provider —
Claude's session file, Codex's resume cursor. One Task drives one at a time,
and it is the only thing the word "session" may still name.
_Avoid_: task, agent session

**Archived Task**:
A Task the user has marked as finished with. It leaves the main sidebar list
for the Task Shelf, and the daemon clears the mark when the Task becomes
active again.
_Avoid_: settled, done, closed, hidden, deleted

**Task Shelf**:
The collapsed section at the foot of the sidebar that holds every Archived
Task, newest first, revealed in pages.
_Avoid_: archive folder, trash, history

**Projection**:
A session's reduced transcript — turns, messages, and activity — built by
folding the runtime's event stream. The daemon's projection is the record;
a client's is a live view of the same stream.
_Avoid_: transcript state, reduced state

**Reducer**:
The logic that folds runtime events into a Projection. The daemon runs the
canonical one; the apps run faithful ports of it for live rendering, and a
divergent port causes transcript flapping between clients.

**Accepted Turn**:
The daemon's canonical record of a submitted prompt — the turn and its
message identities. A client echoes the prompt optimistically with
temporary ids and adopts the Accepted Turn's ids when it arrives.
_Avoid_: optimistic turn, pending turn

**Session Store**:
The phone's whole client-side model of a daemon: projects, the session list,
the projection of every open session, drafts, and the workspace snapshots the
transcript header reads. It owns command dispatch, catalog invalidation, and
Replay Gap recovery, and lives in `ShidouKit` so it can be driven headlessly
against the Demo Daemon.
_Avoid_: view model, cache
