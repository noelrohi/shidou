# Continuous integration

`.github/workflows/test.yml` selects jobs from changed paths. Pull requests use
GitHub's changed-file list; pushes to `master` use the previous push SHA.
Deleted and renamed files count. A manual run selects every job.

| Change | Main checks |
| --- | --- |
| Desktop or Rust crate code | Rust tests on macOS, Linux and Windows |
| Tooling scripts or Change Notes | Bun tooling tests and note validation |
| Shared TypeScript client | Client and Browser typechecks and tests |
| Browser code | Browser typecheck and tests |
| iOS code | ShidouKit package tests on macOS |
| Protocol definitions or generated bindings | Protocol drift, client, Browser and Swift checks |
| Dependency manifests, locks or license reports | Relevant language checks and license validation |
| Ordinary documentation | Selection and final status only |
| Workflow configuration | All checks |

The workflow contains the complete path rules, including shared dependencies.
Fast Bun jobs do not wait for the Rust matrix. Swift builds the demo daemon
without GPUI and sets `SHIDOU_DEMO_BIN` so its daemon integration tests execute
rather than skip. These are package tests, not iOS app, simulator or device QA.

`Tests passed` is the aggregate status for branch protection. It succeeds only
when selection succeeds and every selected job passes. Adding this workflow
does not configure repository branch protection or gate the separate automatic
Browser Deployment and Website Deployment workflows.

## Rust caches

Tests and Desktop Release builds cache compiled dependencies instead of whole
build directories. Workspace binaries, incremental state and bundled apps are
not retained. Pull requests restore caches but only `master` saves them, which
avoids creating a large cache for every PR merge ref.

Caches share the repository's storage allowance with Desktop Release builds.
An evicted cache makes the next build cold, and a PR cannot repopulate it. Run
the Tests workflow on `master` to warm shared caches without shipping anything.
Cache storage limits and Desktop Release triggers are unchanged.

### Measuring Rust checks

`Compile tests` runs `cargo test --locked --no-run --timings`; `Run tests` then
runs the same suite, including doctests. The execution step may still compile
doctests or anything Cargo decides is stale. Each platform uploads a
`rust-build-timings-<os>` HTML report retained for seven days. Step durations
separate compilation from test execution; cache restore/upload and runner queue
time must also count toward the user-facing wait.

Before changing cache policy, compare a cold run and a warm run of the same
commit, runner and toolchain. Confirm the cache restore in the logs, not just a
green cache step. Then measure a representative small Rust change. Compare
whole-job duration and compressed cache size for dependency-only versus fuller
build caching; a same-commit rerun alone is not representative of PR work.
Retaining more build output is only useful if it survives the shared storage
budget and saves more compilation time than it adds in transfer time.

## Focused allocation regression

The normal Cargo suite owns the markdown unit tests. CI separately checks the
allocation budget without building another GPUI-linked test executable:

```sh
rustc --edition=2024 --test scripts/check-markdown-allocations.rs -o /tmp/shidou-mend-tests
/tmp/shidou-mend-tests --exact marker_free_streaming_tails_do_not_allocate --nocapture
```

Keep `--exact`: the imported production module also contains unit tests that
Cargo already runs. This check measures allocation calls, not frame rate or
peak memory.
