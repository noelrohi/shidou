# shidou-demo

`shidou-demo` is the **Demo Daemon**: the public fixture daemon behind
"Try the demo", serving the scripted **Demo Session**. It is
`shidou_core::serve` with a `DemoBackend` implementation of the `Backend`
trait, and nothing else.

It is a separate binary from [`shidou-daemon`](../shidou-daemon) on purpose.
The daemon users run owns provider processes, credentials, and a database, and
must carry no demo code path at all. This one owns none of those: it spawns no
subprocess, opens no file, makes no network call, and spends no provider
credit. Its bearer token is baked into the app and is therefore public, which
is safe only because there is nothing behind it to abuse.

## What it serves

| Module     | Surface                                                                          |
| ---------- | -------------------------------------------------------------------------------- |
| `sessions` | Projects and tasks, including the Demo Session and a Waiting Session              |
| `script`   | The scripted turn: streaming text and reasoning, a tool call with its result, a permission request, a unified diff, a multi-question form, background work |
| `tree`     | The workspace behind that diff: file tree, readable files, branch and commit state, review diff, and a browsable directory tree |
| `catalog`  | Settings, skills catalog, usage history, plan meters, provider probes            |
| `blobs`    | Images, rendered in memory so the visuals surface has real bytes                  |
| `log`      | The operational log — the only place a demo message is written                    |

Streaming runs at 120 tokens a second, the rate the streaming prototype used,
so the transcript's streaming path is genuinely exercised rather than filled in
one frame.

The first prompt in the Demo Session — or in any task a client just created —
plays the full showcase. Every prompt after that gets a canned reply that
quotes the message back, so a reviewer who types something always sees the
composer work.

## Replayability

The scripted turn is a pure list of beats, so it produces the same events in
the same order every time. The daemon's replay journal holds whatever the
player has emitted, which means a client that drops its connection mid-turn and
reconnects with a replay cursor receives exactly the tail it missed — no gap,
no duplicate. `tests/demo_daemon.rs` asserts this over a real socket.

Commands that would mutate the host — commit, push, checkout, write, open a
terminal — are refused with a message that says why, rather than quietly
succeeding.

## Data posture

`shidou.dev/privacy` commits this daemon to a narrow retention:

> Messages typed into the demo land in server logs alongside the requester's IP
> address and a timestamp. Those logs exist only to tell us whether the demo is
> up. They are deleted after 7 days. They are not sold, not shared, and not
> used to train anything.

This crate is built to that sentence exactly. A prompt reaches stderr and
nowhere else: no database, no transcript file, no crash payload. TLS terminates
at the reverse proxy, so the requester's IP is in *its* access log, correlated
by timestamp; deletion after seven days is log rotation on the host, because a
ceiling that only intent enforces is not a ceiling.

Widening what `log` records widens the published policy and the App Privacy
label — **Other User Content**, not linked to identity, used for App
Functionality — with it.

## Running it

```sh
cargo run -p shidou-demo -- --bind 127.0.0.1:8787
```

The token comes from `SHIDOU_DAEMON_TOKEN`, or defaults to the published demo
token in `lib.rs`. A non-loopback bind requires `--allow-non-loopback`, because
the token is public and `serve` has no TLS server of its own: in production
Caddy terminates TLS, rate-limits, and proxies to a loopback bind.
