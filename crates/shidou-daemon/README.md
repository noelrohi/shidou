# shidou-daemon

`shidou-daemon` is the standalone process that hosts Shidou's provider sessions.
It defaults to a loopback-only listener, authenticates clients with
`SHIDOU_DAEMON_TOKEN`, and
prints one JSON readiness record to stdout containing its address, protocol
version, and process ID.

```text
SHIDOU_DAEMON_TOKEN=<secret> shidou-daemon --bind 127.0.0.1:0 [--parent-pid PID] [--allow-origin ORIGIN]...
```

Shidou Desktop supervises this process. Debug builds use the feature-gated
`shidou-debug-daemon` target at `target/debug/shidou-debug-daemon`, so rebuilding
provider code replaces only the daemon. Release distributions place the signed
`shidou-daemon` binary beside the desktop executable.

The token is a full-control capability for a trusted Shidou client, not a user or
workspace-scoped credential. Browser handshakes are rejected unless their exact
Origin was supplied with `--allow-origin`; native clients send no Origin. A
non-loopback bind is refused unless `--allow-non-loopback` is also present.
Shidou Desktop adds that flag only after the user enables exposure in Settings →
Daemon. The daemon does not terminate TLS itself. For access outside a private
network, put a trusted TLS proxy or tunnel in front of it and use `wss://`. Do
not give the daemon token to untrusted page JavaScript.
