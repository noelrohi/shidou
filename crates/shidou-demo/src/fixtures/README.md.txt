# demo-api

The sample service the Shidou **Demo Session** works on.

This project does not exist on disk. It is served by `shidou-demo`, the public
fixture daemon behind "Try the demo", so the app has a believable workspace to
render — a file tree, readable files, a branch with uncommitted changes, and a
diff — without any agent running and without any file being read from the demo
host.

## Layout

| Path                | What it holds                          |
| ------------------- | -------------------------------------- |
| `src/main.rs`       | Process entry point and server wiring  |
| `src/routes.rs`     | Request routing for the public API     |
| `src/limiter.rs`    | Token-bucket rate limiting             |
| `docs/`             | Design notes                           |
| `assets/`           | Latency charts from the rollout        |

## The change in flight

`src/limiter.rs` refilled its buckets in whole-second steps, which handed every
client a full burst once a second regardless of how fast they were calling. The
branch `demo/rate-limiter` replaces that with continuous refill and adds idle
bucket eviction.
