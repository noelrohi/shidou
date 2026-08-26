# Shidou

A native client for coding-agent sessions: a macOS GPUI app and an iOS SwiftUI
app that connect to a per-user daemon owning the provider processes.

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

**Waiting Session**:
A session blocked on the user — a pending permission or question. Marked in
the session list; reopening the app restores its pending prompt via replay.

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
