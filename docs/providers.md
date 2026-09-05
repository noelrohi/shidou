# Provider integrations

How Shidou talks to each coding agent: the process it launches, the wire protocol
it speaks, how long that process lives, and what has to be emulated because the
CLI does not offer it.

How each of them names a session — which are read from the provider, which are
polled off disk, and the one Shidou generates itself — is in
[titles.md](titles.md).

Every provider is reached through the same driver abstraction in
[driver/mod.rs](../crates/shidou-core/src/driver/mod.rs). There are seven
transport implementations behind eleven providers, and **every one of them holds a
session that spans the whole conversation**:

| Transport | File | Providers |
| --- | --- | --- |
| Codex app-server (JSON-RPC over stdio) | [driver/codex.rs](../crates/shidou-core/src/driver/codex.rs) | Codex CLI |
| Agent Client Protocol (JSON-RPC over stdio) | [driver/acp.rs](../crates/shidou-core/src/driver/acp.rs) | Cursor CLI, Fx, Grok Build, Kimi Code |
| OpenCode server (HTTP + server-sent events) | [driver/opencode.rs](../crates/shidou-core/src/driver/opencode.rs) | OpenCode |
| Pi RPC mode (NDJSON request/response over stdio) | [driver/pi.rs](../crates/shidou-core/src/driver/pi.rs) | Pi, Oh My Pi |
| Claude streaming-input session (NDJSON over stdio) | [driver/claude.rs](../crates/shidou-core/src/driver/claude.rs) | Claude Code |
| Amp streaming-JSON session (NDJSON over stdio) | [driver/amp.rs](../crates/shidou-core/src/driver/amp.rs) | Amp |
| Harness client API (typed HTTP + downlink streams) | [driver/deepseek.rs](../crates/shidou-core/src/driver/deepseek.rs) | DeepSeek Harness |

This guide describes the checked-in adapters, not a guarantee about every CLI
version. Older live probes informed these implementations; rerun the ignored
provider integration tests against the installed CLI when changing wire behavior.

## The driver contract

Provider processes belong to **shidou-daemon**, not the desktop UI:

1. Desktop's `start_driver` / `attach_driver` in
   [src/app/runtime.rs](../src/app/runtime.rs) constructs a remote handle through
   `start_remote` / `attach_remote` in [src/driver/mod.rs](../src/driver/mod.rs).
2. `RemoteDriverControl` sends daemon protocol commands through
   [shidou-client](../crates/shidou-client/src/client.rs). A desktop attachment
   subscribes to a particular session/runtime; it is not the process owner.
3. The daemon's command handler in [daemon.rs](../crates/shidou-core/src/daemon.rs)
   calls `driver::start_local(provider, options, events)`. That dispatcher in
   [driver/mod.rs](../crates/shidou-core/src/driver/mod.rs) selects the local
   transport and returns a `DriverHandle` backed by `DriverControl`.
4. Local drivers emit `DriverEvent`s through `DriverEventSender`. The daemon
   reduces and publishes sequenced wire events; desktop converts its subscription
   back into local events. Crossbeam queues carry events and bounded wake channels
   notify the consumer; this is not a provider process polled by the frame loop.

`DriverStartOptions` carries the binary, cwd, access/interaction modes, model,
reasoning effort, service tier, context window, agent preset, Computer Use flag,
resume cursor, and optional task credential for Child Task orchestration. See the
struct itself in [driver/mod.rs](../crates/shidou-core/src/driver/mod.rs).

The complete event contract is `DriverEvent` in
[model.rs](../crates/shidou-protocol/src/model.rs). Besides connection, turn,
text/reasoning, activity, permission, steering, error and exit events, it includes
user-input requests, usage, titles, background work and provider projections.

A transport that can inject a user message into the *running* turn advertises
it through `DriverControl::supports_steer` and delivers it with `steer`; the
outcome comes back asynchronously as `SteerAccepted` or `SteerRejected`. When
steering is unsupported, refused, or the session is still connecting, the app
falls back to its own follow-up queue — the message stays visible above the
composer and starts a fresh turn once the current one settles.

Every driver normalizes its tool events into one `ActivityItem`
(including reasoning, command, file change/read/search/list, search, plan and tool
kinds) via
[driver/activity.rs](../crates/shidou-core/src/driver/activity.rs), so the transcript renders
provider-agnostic rows. Tool titles prefer a `title` argument when the tool
supplies one, then fall back to the command, the query, or a de-camel-cased
tool name.

### Runtime lifetime in the app

`Shidou::runtimes` holds desktop attachments keyed by session id. Switching views
does not stop a session. Dropping a `RemoteDriverControl` only removes that
subscription; it does not stop daemon work that another desktop, browser or iOS
connection may observe.
Explicit `DriverHandle::close` sends `CloseSession`, whose daemon handler removes
the matching local runtime. See [src/driver/mod.rs](../src/driver/mod.rs) and
[daemon.rs](../crates/shidou-core/src/daemon.rs).

Desktop explicitly closes a runtime when a transport needs restarting, a session
is deleted, rewind leaves a stale provider session, or idle cleanup releases it.
A daemon-observed `ProcessExited` also removes the dead runtime. Finishing a turn
normally leaves it resident; a resumed conversation can span several runtime ids
and process lifetimes.

Desktop Stop first sends Cancel. `retain_runtime_after_cancel` normally retains
all providers except Codex and Amp; live detached background work is an override
that keeps the runtime attached and cancels Computer Use separately. Otherwise
Stop explicitly closes the runtime, and the next prompt resumes the provider's
native conversation (`thread/resume` for Codex, `threads continue` for Amp).
Amp's cancel itself terminates its process because its stream has no interrupt.
These are desktop policies in [src/app/sessions.rs](../src/app/sessions.rs), not
an assertion that every daemon client implements Cancel by closing a runtime.

Quitting desktop is likewise not a universal provider-shutdown command. The
supervisor owns and stops a daemon it launched, but does not stop an externally
managed or remote daemon. See `DaemonProcess` and `DaemonSupervisor` in
[process.rs](../crates/shidou-client/src/process.rs).

Option changes go through `DriverControl::apply_options`, which returns whether
the transport absorbed the change or wants to be restarted:

| Change | Codex | Pi | ACP | OpenCode | Claude | Amp |
| --- | --- | --- | --- | --- | --- | --- |
| Model and related options | model/effort/tier ride on `turn/start` | `set_model`, `set_thinking_level` | model change applies provider config or `session/set_model`; effort is applied with that change | model rides on prompts; generic effort/tier are not sent | model/context window use `set_model`; effort is launch-only and tier is not applied | restart — mode/effort/fast are launch arguments |
| Access mode, interaction mode | restart | restart | restart | restart — the agent is chosen when the session opens | restart | restart |
| Provider | restart | restart | restart | restart | restart | restart |

This table covers Pi and Oh My Pi together. ACP uses provider config options for
Cursor and Fx where advertised, with `session/set_model` as the legacy path.
DeepSeek is the exception to the mode-restart rule: its `apply_options` sends
model selection and permission/Plan commands within the existing session. Not
all generic option fields have a meaning on every provider; consult each
transport's `apply_options` and command handler before adding a picker option.
A restart does not necessarily mean a fresh conversation: the resume cursor can
reattach the existing native history.

Desktop's idle sweep runs on a background timer every 5 minutes, not a frame tick.
`reap_idle_sessions` explicitly closes attachments idle for 30 minutes, skipping
active turns, non-idle/non-failed sessions and live background work. See
`session_is_reapable` in [src/app.rs](../src/app.rs) and
[reap_idle_sessions](../src/app/runtime.rs). This is desktop maintenance, not a
daemon-wide idle timeout guaranteed for sessions used only by other clients.

Note what is *not* on the teardown list: finishing a turn. `TurnFinished` leaves
the long-lived processes resident and idle, which is the point of them — until
the idle sweep decides otherwise.

### How the long-lived processes actually die

**The hand-written stdio drivers — Codex, Pi, Claude and Amp — normally shut
down by closing stdin** when the daemon drops the local driver:

1. The driver is dropped, which sends `CommandMessage::Shutdown` (and drops the
   command `Sender`, so a missed send has the same effect).
2. The writer thread breaks out of its loop and returns, dropping the
   `ChildStdin` it owns.
3. The provider sees EOF on stdin and exits.
4. Its stdout closes, ending the reader thread, and `ProcessExited` is emitted.

A provider that ignores stdin EOF can linger. These descriptors belong to the
daemon: desktop quitting alone does not close them on a remote daemon. Amp Cancel
is an explicit termination path, and Computer Use descendants have their own
cleanup; stdin EOF is not a guarantee that every descendant process exits.

Each of these drivers moves its `Child` into a dedicated thread that blocks on
`wait()`, so the process is reaped and a nonzero exit status becomes an `Error`
when stderr has not already explained itself. Pi and Oh My Pi both use this path.
Rust's `Child::drop` neither kills nor reaps.

**ACP uses the agent-client-protocol SDK**, not Shidou's own stdin writer/child
waiter. `AcpDriver` runs `run_sdk_connection` on a dedicated smol thread, using
`AcpAgent` and `Client::connect_with` to own the connection. Shutdown breaks its
command loop, cancels pending responders and returns from the connection scope;
the thread emits `ProcessExited` when that scope ends. SDK process cleanup is not
the hand-written four-thread sequence above. See
[driver/acp.rs](../crates/shidou-core/src/driver/acp.rs).

**HTTP hosts are pooled.** OpenCode normally shares a server per binary/workspace;
Computer Use needs a dedicated server with session-specific environment. DeepSeek
shares one Harness host per binary across workspaces. Dropping one driver releases
a lease, not necessarily the host. The final lease shuts down and reaps the server;
starts and final teardown are serialized by
[opencode_pool.rs](../crates/shidou-core/src/opencode_pool.rs) and
[deepseek_pool.rs](../crates/shidou-core/src/deepseek_pool.rs). Process termination
is implemented in [opencode_session.rs](../crates/shidou-core/src/opencode_session.rs)
and [deepseek_session.rs](../crates/shidou-core/src/deepseek_session.rs).
Short-lived discovery, title-generation and fork helpers also own and reap their
processes; they should not be confused with resident conversation drivers.

## At a glance

| | Codex CLI | Pi | Oh My Pi | Claude Code | Amp | Cursor CLI | Fx | OpenCode | Grok Build | Kimi Code |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Binary | `codex` | `pi` | `omp` | `claude` | `amp` | `cursor-agent` | `fx` | `opencode` | `grok` | `kimi` |
| Wire protocol | JSON-RPC over stdio | NDJSON RPC over stdio | NDJSON RPC over stdio | stream-json over stdio | stream-json over stdio | ACP over stdio | ACP over stdio | HTTP + SSE | ACP over stdio | ACP over stdio |
| Resident between turns | yes | yes | yes | yes | yes | yes | yes | yes (pooled) | yes | yes |
| Process spawned per turn | no | no | no | no | no | no | no | no | no | no |
| Bidirectional | yes | yes | yes | yes | yes | yes | yes | yes | yes | yes |
| Reasoning stream | yes | yes | yes | yes | yes | yes | yes | yes | yes | yes |
| Interactive approvals | yes | no | no (has them; Shidou runs `--yolo`) | yes | no | yes | yes | yes | yes | yes |
| Mid-turn steering | yes | yes | yes | yes | yes | yes | **no** | yes | yes | yes (transport) |
| Model discovery | yes | yes | yes | no (fixed) | no (modes) | yes | yes | yes | yes | yes |
| Computer Use | yes | yes | no (ships its own) | no | no | no | no | yes | yes | no |
| Restricted to Build + Full access | no | yes | yes | no | yes | no | no | no | no | no |
| Rewind and branch at a turn | yes | yes | yes | yes | yes | yes | **no** | yes | yes | **no** |

The table covers ten providers; DeepSeek's pooled Harness API is covered
in its section below. All retain conversation state across turns, but a session
need not have a dedicated process. Computer Use here means Shidou's integration
(macOS only), not a provider's separate built-in feature.

Kimi Code's steering is supported by the adapter but lacks the live-turn probe
coverage recorded for Cursor and Grok. Fx explicitly disables steering. Fork and
rollback capability predicates in
[ProviderKind](../crates/shidou-protocol/src/model.rs) exclude **Fx and Kimi**;
all other providers, including DeepSeek, expose both.

---

## Codex CLI

**Launch** — `codex app-server --stdio`
([CodexDriver::start](../crates/shidou-core/src/driver/codex.rs)), plus `-c` config
overrides when Computer Use is on.

**Protocol** — newline-delimited JSON-RPC over stdio, genuinely bidirectional:
Codex can send Shidou requests (approvals) and Shidou answers them by id. Three
threads: writer (owns stdin and the command queue), reader (parses stdout),
stderr collector; a fourth waits on the process and emits `ProcessExited`.

**Lifetime** — long-lived: one app-server serves the whole session, staying
resident and idle between turns. Dropping the daemon's local driver closes its
stdin; dropping a desktop attachment does not. Desktop Stop has a detached-work
exception, and remote daemon lifetime is independent of desktop quit. See
[Runtime lifetime in the app](#runtime-lifetime-in-the-app).

**Handshake**

1. `initialize` (id `0`) with `clientInfo` and `capabilities.experimentalApi`.
2. `initialized`.
3. `skills/extraRoots/set` when Computer Use is on, so Shidou's bundled skill is
   discovered like Codex's own skills rather than injected as instructions.
4. `thread/start` or `thread/resume` (id `1`) with `cwd`, `approvalPolicy`,
   `sandbox`, `approvalsReviewer`, and optional `model` / `serviceTier`.

The reply to id `1` carries `result.thread.id` (→ `Connected` with a
`ProviderResumeCursor::Codex`) and `result.thread.turns[]`, whose ids are
retained because `thread/fork` needs a `lastTurnId`.

**Per turn** — `turn/start` with `threadId`, `input: [{type: "text", …}]`,
`approvalPolicy`, `approvalsReviewer`, `sandboxPolicy`, and optional `model`,
`effort`, `serviceTier`.

**Inbound stream** ([handle_codex_message](../crates/shidou-core/src/driver/codex.rs)):

| Method | Becomes |
| --- | --- |
| `turn/started` | `TurnStarted` (records the turn id) |
| `item/agentMessage/delta` | `TextDelta` |
| `item/reasoning/summaryTextDelta`, `item/reasoning/textDelta` | `ReasoningDelta` |
| `item/started`, `item/completed` | `RichActivity` (command, patch, web search, plan, MCP tool) |
| `turn/completed` | `TurnFinished { success: status == "completed" }` |
| `error`, `mcpServer/startupStatus/updated` (failed) | `Error` |
| `*requestApproval*` (a request, has an `id`) | `Permission` |

**Approvals** — an app-server approval request becomes a `Permission` event with
`accept` / `acceptForSession` / `decline`, and the answer is written back as a JSON-RPC *response*:
`{"id": <original>, "result": {"decision": …}}`. Because JSON-RPC ids are
per-peer, the reader only treats method-less messages as replies to Shidou's own
requests ([handle_codex_message](../crates/shidou-core/src/driver/codex.rs)).

**Cancel** — `turn/interrupt {threadId, turnId}`.

**Steer** — `turn/steer {threadId, expectedTurnId, input}`. The RPC response
resolves the pending steer to `SteerAccepted`, or to `SteerRejected` with the
CLI's reason when the expected turn no longer matches. The expected id lets the
server reject a steer aimed at an already-settled turn.

**Rewind** — `thread/rollback {threadId, numTurns}`, in place; the cursor is
unchanged. **Branch** — `thread/fork {threadId, lastTurnId}` returns a new
thread id. The local driver's response-channel wait is bounded at 15 s; desktop
runs blocking rewind/fork work off the UI thread and reaches it through the daemon.

**Citations** — Codex marks web citations with private-use characters
(`U+E200`/`U+E201`/`U+E202`). They are buffered across deltas and rewritten into
markdown links against the `webSearch` results captured earlier in the turn;
unknown markers are dropped. Private control markers never reach the transcript
([driver/codex.rs](../crates/shidou-core/src/driver/codex.rs)).

**Models** — a throwaway app-server, `model/list` paged via `nextCursor`, up to
32 pages ([model_catalog.rs](../crates/shidou-core/src/model_catalog.rs)).

**Computer Use** — `-c mcp_servers.shidou_js_repl.command=…` registers Shidou's
QuickJS MCP server, with several `-c` flags disabling Codex's own external
computer-use plugin/MCP/skill so only Shidou's `js` / `js_reset` surface is
visible.

---

## Pi and Oh My Pi

Oh My Pi is a fork of Pi that kept the RPC transport and renamed part of its
surface, so one driver serves both. `PiFlavor`
([pi.rs](../crates/shidou-core/src/driver/pi.rs)) carries every divergence,
which is what keeps the two from drifting into near-copies:

| | Pi | Oh My Pi |
| --- | --- | --- |
| Binary | `pi` | `omp` |
| Full-access flag | `--approve` | `--yolo` |
| Update check | Shidou sets `PI_SKIP_VERSION_CHECK=1` | Shidou sets no update-check environment override |
| Oversized frames | whole | chunked, once `negotiate_protocol {protocolVersion: 2}` is accepted |
| Run settles on | `agent_settled` | `agent_end` |
| Title event / field | `session_info_changed` / `name` | `session_info_update` / `title` |
| Branch commands | `get_fork_messages`, `fork` | `get_branch_messages`, `branch` |
| Whole-session copy | in place | only at launch, so Shidou shells out (see below) |
| Computer Use | Shidou's Pi extension | none — Oh My Pi ships its own `/computer` |
| Catalog probe's context-files flag | `--no-context-files` | `--no-rules` |

Everything below is shared unless noted.

**Launch** — `pi --mode rpc --approve` with `PI_SKIP_VERSION_CHECK=1`;
`omp --mode rpc --yolo`
([PiDriver::start](../crates/shidou-core/src/driver/pi.rs)). Oh My Pi negotiates
protocol v2 first, before `get_state`, to enable chunked responses. The adapter
handles chunk assembly rather than assuming every response fits one frame.

The recorded Oh My Pi **17.3.8** probe accepted `--yolo` and `--fork` even though
its help omitted them. Its ready frame advertised protocol versions 1 and 2,
1 MiB frames and 64 MiB reassembled responses. These are version-scoped probe
results, not fixed limits for future releases; verify the installed version's
handshake and flag handling before changing the adapter.

**Protocol** — NDJSON over stdio, but request/response rather than JSON-RPC:
Shidou stamps each request with a string id (`shidou-<n>`) and Pi answers with
`{"type": "response", "id", "success", "data"}`. Everything else on the stream
is an unsolicited event. Requests are issued synchronously by the writer thread
with a 10 s timeout ([pi.rs](../crates/shidou-core/src/driver/pi.rs));
events keep flowing on the reader thread meanwhile.

**Lifetime** — long-lived, and unlike Codex it survives Stop: cancelling sends
`abort` over the existing connection. It ends when the runtime is dropped, by
stdin EOF. The `shidou-pi-process` thread calls `child.wait()`, joins the stdout
and stderr readers, reports an unexplained nonzero exit, and emits `ProcessExited`.

**Handshake** — `get_state` → Oh My Pi only: `set_host_tools` for Shidou's
host-owned `ask` → optional `switch_session {sessionPath}` when resuming →
`set_model {provider, modelId}` → `set_thinking_level {level}` → `get_state`.
The final state supplies `/data/sessionId` and `/data/sessionFile`; both go into
the cursor, and resume needs the **file path**, not just the id. OMP omits its
TUI-owned `ask` in RPC mode, so the host tool exposes the same batched
`questions[]` surface without switching to the sequential `rpc-ui` dialogs. If
a user extension already owns `ask`, OMP rejects the registration and Shidou
leaves that tool untouched.

**Per turn** — `{"type": "prompt", "message": …}`.

**Inbound stream** ([pi.rs](../crates/shidou-core/src/driver/pi.rs)):

| Event | Becomes |
| --- | --- |
| `agent_start`, `turn_start` | `TurnStarted` (once per run) |
| `message_update` → `text_delta` / `thinking_delta` | `TextDelta` / `ReasoningDelta` |
| `message_end` | fallback text/thinking when no delta was streamed |
| `tool_execution_start` / `_update` / `_end` | `RichActivity` |
| `auto_retry_end` | clears or sets the failure flag |
| `agent_settled` (Pi) / `agent_end` (Oh My Pi) | `TurnFinished`, then resets stream state |
| `extension_ui_request` | blocking dialogs become `UserInputRequested`; Shidou returns the user's answer |
| `host_tool_call` for Oh My Pi's host-owned `ask` | the whole `questions[]` batch becomes one `UserInputRequested`; answers return as `host_tool_result` |

**Access modes** — Build + Full access only, enforced at driver start rather
than degraded silently: any other combination fails with "currently supports
Build with Full access only" ([PiDriver::start](../crates/shidou-core/src/driver/pi.rs)).
Pi has no permission system at all, so `--approve` is the whole story. Oh My Pi
*does* have one, which Shidou's `--yolo` then bypasses — the restriction is Shidou's
here, not the CLI's, and lifting it is a matter of wiring Oh My Pi's permission
requests to a `Permission` event.

**Cancel** — `{"type": "abort"}`.

**Steer** — `{"type": "steer", "message": …}`; the request acknowledgment
resolves to `SteerAccepted` or `SteerRejected`.

**Rewind and branch** — both go through `get_fork_messages` → `fork {entryId}`
(`get_branch_messages` → `branch` on Oh My Pi), or `clone` when nothing is
removed, then `get_state`
([pi.rs](../crates/shidou-core/src/driver/pi.rs)). Rewind adopts the fork
as the session's new cursor. Branch additionally `switch_session`es back to the
source file and verifies it landed on the right session; if that restore fails
the runtime is dropped, because the RPC process may still be sitting on the fork
([runtime.rs](../src/app/runtime.rs)).

**Copying a whole session differs.** Removing no turns is a plain copy, which Pi
performs in place. Oh My Pi only copies at launch, so Shidou shells out to a
throwaway `omp --mode rpc --yolo --fork <session file>` and reads the new cursor
off it ([pi.rs](../crates/shidou-core/src/driver/pi.rs)). That is the
better shape anyway: the out-of-process copy never moves the live session, so
unlike the in-place path it needs no restore afterwards and cannot strand the
RPC process on the fork.

**Models** — a separate `pi --mode rpc --no-session --no-skills
--no-prompt-templates --no-context-files` process answering
`get_available_models` and `get_state`. Extensions stay enabled because they can
register model providers. Ids are `provider/model` slugs and are validated as
such before launch.

Oh My Pi rejects unknown flags outright, so its probe is its own list —
`--no-session --no-skills --no-rules --no-extensions` — and the two describe
thinking differently. Pi maps levels through a per-model `thinkingLevelMap`; Oh
My Pi advertises the levels a model actually honors under `thinking.efforts`.
`off` never appears in that list because it bypasses provider mapping entirely,
yet it is always accepted, so it is added back
([model_catalog.rs](../crates/shidou-core/src/model_catalog.rs)).

**Computer Use** — Pi only: `--extension <shidou pi extension>` and
`--skill <SKILL.md>`, with the REPL and helper paths passed through the
environment. Shidou's bridge is written against Pi's extension API, and Oh My Pi
ships its own `/computer` instead, so the flag is never passed to it.

---

## Claude Code

**Launch** — `claude -p --input-format stream-json --output-format stream-json
--verbose --include-partial-messages --thinking-display summarized
--replay-user-messages --permission-prompt-tool stdio --permission-mode <mode>`
([driver/claude.rs](../crates/shidou-core/src/driver/claude.rs)), plus `--model`, `--effort`,
and `--session-id` or `--resume`.

Shidou speaks the streaming CLI protocol directly, without the Claude Agent SDK.
`--thinking-display summarized` requests readable reasoning summaries; private raw
reasoning is not transcript content.
`--permission-prompt-tool stdio` routes approval requests back to the host; do not
remove it merely because a CLI version's help omits it. Verify permission traffic
against that installed version before changing these flags.

**Lifetime** — long-lived. One process serves the conversation, with turns fed
as newline-delimited user messages on stdin.

**Per turn** — write `{"type":"user","message":{"role":"user","content":[…]},
"parent_tool_use_id":null}`; the turn ends with a `result` message carrying
`is_error`, `stop_reason`, usage, and `permission_denials`.

**Inbound stream**

| Message | Becomes |
| --- | --- |
| `system` / `init` | the session id and advertised slash commands |
| `stream_event` → `text_delta`, `thinking_delta` | `TextDelta`, `ReasoningDelta` |
| `assistant` content blocks | `tool_use` → `RichActivity`; text and thinking only as a fallback when no delta of that kind streamed |
| `user` with `tool_result` | completes the matching activity |
| `user` with `isReplay: true` | ignored — Shidou's own prompt echoed by `--replay-user-messages` |
| `result` | `TurnFinished` |
| `system` status/thinking-token notices, `rate_limit_event` | ignored |

**Approvals** — `control_request` / `subtype: "can_use_tool"` carries the tool
name, input, `tool_use_id`, the `blocked_path` that tripped the check, and
`permission_suggestions`. Shidou answers with a `control_response` whose result is
`{"behavior":"allow"}` or `{"behavior":"deny","message":…}`. Outside Supervised it
answers allow itself. `AskUserQuestion` is handled first as `UserInputRequested`,
not automatically treated as tool permission. Native task lifecycle messages also
update background-work state; they are not assistant text.

**Cancel** — a `control_request` with `subtype: "interrupt"`.

**Steer** — the same user-message write as a prompt, sent while a turn is
running and without arming a new turn. The CLI holds the message and folds it
into the running turn at its next model call — one `result` still settles the
whole exchange, and the `isReplay` echo arrives at the moment of absorption
rather than at write time. Verified against the real CLI by injecting an
instruction while a Bash `sleep` ran: the same turn's reply honored it. Amp
was probed the same way and behaves differently — see its section.

**Model changes** — a `control_request` with `subtype: "set_model"`, so switching
models keeps the session. Context-window choice is encoded in the wire model id
(`wire_model`). The Options handler does not send an effort setter: `--effort`
is a launch argument. Access/interaction mode changes request a restart.

**Native checkpoints** — after each turn Shidou reads Claude's own transcript at
`$CLAUDE_CONFIG_DIR/projects/**/<session>.jsonl`, walks the `parentUuid` chain to
find the active branch, and records the latest message uuid as the turn's
`provider_resume_at` ([claude_session.rs](../crates/shidou-core/src/claude_session.rs)). That
per-turn checkpoint is what makes rewind and branch possible. Because Claude
accepts a caller-chosen `--session-id`, the cursor exists before the first turn
does.

**Rewind and branch** — `claude_session::fork_session_at` rewrites the JSONL
transcript into a *new* session file, truncated at the checkpoint and re-keyed
with fresh uuids; the returned id map is applied to Shidou's retained turns.
Rewinding to turn zero clears the cursor and starts clean. The implementation
uses checkpoint-aware JSONL rewriting, not the CLI's `--fork-session` option.

**Models** — Shidou does not probe Claude's model catalog; it uses a curated list
([model_catalog.rs](../crates/shidou-core/src/model_catalog.rs)).

---

## Amp

**Launch** — `amp [threads continue <thread-id>] --execute --stream-json-thinking
--stream-json-input --dangerously-allow-all [--mode M] [--effort E] [--fast]`
([driver/amp.rs](../crates/shidou-core/src/driver/amp.rs)). `--stream-json-thinking` implies
`--stream-json`, which `--stream-json-input` requires.

**Protocol** — newline-delimited JSON in both directions. Amp keeps the process
alive until *both* the assistant is done and stdin closes, which is what makes
one process serve the conversation.

**Lifetime** — long-lived. Turns are written as
`{"type":"user","message":{"role":"user","content":[…]}}`.

**Turn completion is not a `result` message.** Amp emits none; the turn is over
when an `assistant` message carries `stop_reason: "end_turn"`. A `tool_use` stop
reason is mid-turn. This was found by probing — a driver waiting for `result`
hangs forever.

**Inbound stream** — Anthropic-shaped: `system`/`init` carries the thread id;
`assistant` blocks carry text, thinking and `tool_use`; `user` blocks carry
`tool_result`. Redacted thinking is ignored rather than displayed. Text arrives
as whole blocks — Amp has no partial-message deltas.

**Access modes** — Build with Full access only; the driver refuses to start
otherwise. Amp's "models" are agent modes, and the fast service tier is `--fast`.
All three are launch arguments, so changing any of them restarts.

**Approvals** — none in this integration. Shidou selects Full access at launch
with `--dangerously-allow-all`; Pi and Oh My Pi likewise do not expose interactive
approvals through Shidou.

**Cancel** — no stream interrupt exists, so Stop ends the process. The thread
survives on Amp's side and the next prompt resumes it with `threads continue`,
which is why Amp's runtime is not retained after a cancel.

**Steer** — the user message with a documented top-level `"steer": true`
attribute. A plain mid-turn message is held until the current turn's
`end_turn` and then runs as a turn of its own; the attribute marks it for
handling at the next interruption point instead, so the running turn absorbs
it and one `end_turn` settles everything. Both behaviors probed against the
real CLI — the plain-message probe is why an unmarked write must never be
used as a steer.

**Branch** — `amp threads export <id>` dumps the thread, Shidou keeps the retained
prefix, `amp threads new` creates an empty thread, and the retained history is
replayed as a length-delimited envelope prepended to the first prompt
(`SHIDOU_AMP_BRANCH_CONTEXT_V1`). Forking a thread that was itself seeded this way
re-expands the nested envelope first, so branches of branches stay flat
([amp_session.rs](../crates/shidou-core/src/amp_session.rs)).

---

## OpenCode server

**Launch** — `opencode serve --hostname 127.0.0.1 --port <ephemeral>`
([driver/opencode.rs](../crates/shidou-core/src/driver/opencode.rs)). Shidou already started this
server to fork a session; it now runs the conversation too.

**Protocol** — OpenCode's own HTTP API plus a server-sent event stream. Routes
and payloads here were read off a live server's OpenAPI document, not guessed.

**Lifetime** — long-lived: a pooled server per binary/workspace, shared by sessions.
Computer Use sessions instead hold dedicated servers; see
[opencode_pool.rs](../crates/shidou-core/src/opencode_pool.rs).

**Handshake** — `POST /session` with `{agent: "plan" | "build"}` for a fresh
session, or reuse the resume cursor's id. `PATCH /session/{id}` installs
session-local permission rules for the selected access mode on both fresh and
resumed sessions. The agent is also included in every prompt; there is no
`POST /session/{id}/agent` call.

**Per turn** — `POST /session/{id}/prompt_async` with
`{agent, parts: [{type: "text", …}], model?: {providerID, modelID}}`, which acknowledges with `204 No Content` as
soon as the prompt is accepted; the turn's completion arrives as
`session.idle` on the event stream. The blocking `message` route holds its
response until the turn ends — longer than any sane read timeout — so it is
not used for prompting.

**Steer** — the same `prompt_async` post while the session is busy: the
server folds the message into the running turn and one `session.idle` still
settles everything. OpenCode's own UI labels this "queued", but it is the
live turn absorbing the message, not a follow-up turn. The `204`
acknowledgment resolves to `SteerAccepted`; a failed post resolves to
`SteerRejected` and leaves the running turn untouched. Verified against a
real server by injecting an instruction while a bash `sleep` ran: one idle,
one reply, honoring both messages.

**Inbound stream** — `GET /event`, server-wide. Each driver filters events by
session id, including ids nested in message/part payloads. This is essential
because the pooled server hosts several Shidou sessions.

| Event | Becomes |
| --- | --- |
| `message.part.delta`, `field: "text"` on a text or unknown part | `TextDelta` |
| `message.part.delta`, `field: "reasoning"` / `field: "thinking"`, or `field: "text"` on a native reasoning part | `ReasoningDelta` |
| `message.part.updated` with a `reasoning` / `thinking` part | records its `partID`, since OpenCode streams the part's content as the generic `text` field |
| `message.part.updated` with a `tool` part | `RichActivity`, read off `/state/status`, `/state/input`, `/state/output` |
| `message.updated` with assistant token counters | `UsageUpdated`, paired with `/api/model`'s context limit for the reported provider/model |
| `session.idle` | `TurnFinished` |
| `session.error` | `Error` |
| `session.updated` | `AutoTitleUpdated` from trimmed `/info/title`; empty titles and `New session - ` placeholders are filtered |
| `permission.replied` | clears the matching pending/responding permission |
| Other `permission.*` | permission handling; surfaces `Permission` when user approval is needed |
| `question.asked` | `UserInputRequested` |
| `question.replied`, `question.rejected` | ignored |
| `session.created`, `session.diff`, plugin/catalog chatter | ignored |

**Approvals** — `POST /permission/{requestID}/reply` with provider replies
`once` or `reject`. The UI's “Always allow” is remembered in session-local driver
state and translated into one-shot replies, including matching pending requests.
Shidou deliberately never sends provider `always`: that would populate a
process-wide cache and let one pooled session suppress another's approvals.
Automatic approvals also send `once`. See `permission_responses` and
`request_permission` in [driver/opencode.rs](../crates/shidou-core/src/driver/opencode.rs).

**Cancel** — `POST /session/{id}/abort`.

**Rewind and branch** — `POST /session/{id}/fork`. A live task uses its resident
server; the cold helper also acquires from the workspace pool rather than always
spawning another server. See `fork_session_at_turn` in
[opencode_session.rs](../crates/shidou-core/src/opencode_session.rs).

**Computer Use** — `OPENCODE_CONFIG_CONTENT` and the helper paths are handed to
the resident server through its environment, exactly as the one-shot invocation
received them.

---

## Agent Client Protocol

**Launch** — `cursor-agent acp`, `fx acp`, `grok agent stdio`, `kimi acp`
([driver/acp.rs](../crates/shidou-core/src/driver/acp.rs)).

**Protocol** — newline-delimited JSON-RPC over stdio, bidirectional. One agent
process serves the whole conversation, streams `session/update` notifications,
and asks the client for tool permission with a request it expects an answer to.
Codex, Claude, OpenCode and DeepSeek also have interactive approval paths.

**Lifetime** — long-lived, like Codex and Pi. Cursor and Grok previously spawned
a process per turn; Fx and Kimi Code arrived on this transport directly.

**Handshake** — `initialize` (advertising **no** `fs` or `terminal` client
capability, since Shidou does not proxy the agent's file or terminal access — an
advertised capability the client cannot honor strands the agent mid-tool-call;
Cursor alone receives its `_meta.parameterizedModelPicker` opt-in) →
`session/resume` when resuming and the agent advertises it (so history is not
replayed), otherwise a replay-suppressed `session/load` when it reports
`loadSession`, else `session/new` → optional `session/set_mode`. A restore the
agent no longer recognizes falls back to a fresh session rather than stranding
the task. Mode selection is applied after both new and restored sessions. Kimi
Code advertises both, so it takes the first rung — `session/resume`, verified
against a session left by an earlier process.

Cursor's picker opt-in makes `session/new`, `session/load`, and
`session/resume` return provider-owned `configOptions`. Shidou resolves the CLI's
flat model alias to the advertised `model` value, then applies any dynamic
`thought_level`, `thinking`, and `fast` options returned by that selection. If
an older Cursor agent advertises no model option, Shidou retains the legacy
`session/set_model` request.

Fx also returns provider-owned config options, but its first model-category
option selects an account provider while the option whose id is `model` selects
the model. AI Gateway IDs such as `openai/gpt-5.6-luna-fast` are absent until
Shidou first selects Fx's `gateway` provider option and reads the refreshed model
option from that response. Shidou then targets the exact `model` id with
`session/set_config_option`; falling back to the older `session/set_model`
extension would not change Fx's model.

**Per turn** — `session/prompt`, whose response stays open until the turn ends.
The SDK request runs concurrently with the command loop, so Cancel can still be
sent. `PendingPrompts` tracks outstanding prompts separately; the last prompt's
reply emits `TurnFinished`, keyed off `stopReason`.

**When `stopReason` lies.** Kimi Code answers a turn its model provider
rejected — an inactive plan, a spent quota — with a clean `end_turn` carrying no
content at all: no error, no JSON-RPC failure, nothing on stderr. Trusting the
protocol there shows the user an empty answer reported as a success, with no
cause to act on. The cause is recoverable, just not from the wire: Kimi appends
a `turn.ended` record with the real message to its own per-session log at
`<KIMI_CODE_HOME>/sessions/<workspace>/<session>/agents/main/wire.jsonl`.

[kimi_session.rs](../crates/shidou-core/src/kimi_session.rs) reads it, and
`finish_prompt` lets a recovered failure override the protocol's verdict —
emitting `Error` with the provider's own wording and settling the turn
unsuccessfully. Three details make it safe:

- **It is scoped to a turn that produced nothing.** `AcpStreamState` tracks
  whether any message, thought, tool call, or plan arrived. A turn that streamed
  anything is settled by `stopReason` alone and does no I/O.
- **It waits.** The record can land after the ACP response. The lookup polls,
  bounded at one second; an immediate read alone could miss the failure.
- **It ignores earlier turns.** The log's byte length is captured before the
  prompt is sent, and only what is appended past that offset is scanned, so a
  previous turn's failure can never be reported as this one's.

All of it runs on the driver thread, never a frame. The invariant it protects is
covered by `kimi_never_reports_an_empty_turn_as_a_success`, which passes whether
or not the account can currently serve a request.

**Inbound stream** — `session/update` notifications:

| `sessionUpdate` | Becomes |
| --- | --- |
| `agent_message_chunk` | `TextDelta` |
| `agent_thought_chunk` | `ReasoningDelta` |
| `tool_call`, `tool_call_update` | `RichActivity`, correlated by `toolCallId` |
| `plan` | a plan activity |
| `usage_update` | `UsageUpdated` — the context gauge, not transcript content |
| `available_commands_update` | `AvailableCommands` — the composer's slash-command list |
| `session_info_update` | `AutoTitleUpdated` when it carries a `title` |
| `user_message_chunk` | ignored — Shidou's own prompt echoed back |

Unrecognized provider-private notifications (including Grok's `_x.ai/*` traffic)
are not rendered. RPC responses and `session/request_permission` are handled
separately; they are not transcript chunks. Provider-specific question requests
(`cursor/ask_question`, `_x.ai/ask_user_question` and `x.ai/ask_user_question`)
become `UserInputRequested`
and are answered through the SDK responder, rather than shown as control markers.

Fx emits its context-limit and skill-discovery diagnostics as ordinary
`agent_message_chunk` updates before the model starts. Their reserved
`[context]` and `skill discovery warning:` prefixes are provider notices rather
than assistant content, so Shidou filters that prelude from the transcript.

**Approvals** — `session/request_permission` becomes a `Permission` event whose
options come straight from the agent, with `kind` (`allow_once`, `allow_always`,
`reject_once`, `reject_always`) deciding which read as allow. The detail line is
the agent's own explanation from `toolCall.content` ("Not in allowlist: cat,
pwd") rather than a sentence synthesized from the tool kind — that reason is the
whole basis for the user's decision. Outside Supervised, Shidou answers for the
user and prefers the durable allow so the agent stops asking about the same tool.

**Why the client advertises no `fs` or `terminal` capability.** Those declare
services *Shidou offers the agent*, not permissions the agent needs. `fs` exists so
an editor can serve unsaved buffer contents in place of what is on disk, and
`terminal` lets the agent run commands through the client's own terminal. Shidou
provides neither, so the agent uses its own read and shell tools and reaches the
filesystem exactly as before — verified against `cursor-agent acp` with both
declined: it read a file, ran a shell command, and ended the turn normally.
Advertising a capability Shidou cannot service would invite file/tool requests
the host cannot fulfill.

Shidou's file editor tracks unsaved buffers
([src/app/right_panel.rs](../src/app/right_panel.rs)), but ACP does not serve
those buffers: an agent using its own file tools reads the disk copy.

**Modes** — Plan maps to the agent's own `plan` mode via `session/set_mode` when
it advertises one; Cursor offers `agent`, `plan` and `ask`, Kimi Code offers
`default`, `plan`, `auto` and `yolo`. Fx offers only `ask` and `code`, so Shidou
disables Plan for Fx, maps Supervised to `ask`, and maps the auto modes to
`code`. Every other access mode is Shidou's to
enforce: the agent stays in the mode that asks, and `auto_approve` decides
whether Shidou answers `session/request_permission` on the user's behalf. That is
why Kimi is left in `default` rather than being switched to `auto` or `yolo`.
Cursor's Supervised mode uses `agent`, not its read-only `ask` mode; Fx's own
`ask` mode has different semantics and is selected for Supervised. ACP mode names
are provider-specific, not a portable permission vocabulary.

**Model and reasoning effort** — provider config options for Cursor/Fx as above,
or `session/set_model`, then the effort as a session config option. **The config id is the agent's to
name**, and the two disagree: Shidou sends `mode` by default, but Kimi's `mode` is
its permission mode (`default`/`plan`/`auto`/`yolo`) and its effort lives on
`thinking`. `reasoning_effort_config_id` resolves that per provider — sending
the default id to Kimi would silently set nothing, or worse, move the permission
mode. The call is non-fatal either way, since an agent may expose no effort at
all.

Kimi's catalog comes from `kimi provider list --json`, which covers both the
managed plan and any registry the user imported with `kimi provider add`.
Reasoning choices come from reported `supportEfforts`, not a hardcoded model
family assumption. The plain-text listing supplies the configured default
field — hence two probes
([model_catalog.rs](../crates/shidou-core/src/model_catalog.rs)).

**Cancel** — `session/cancel`, a notification; the open `session/prompt` reports
the cancellation.

**Steer** — a second `session/prompt` while one is open. The agent continues
the same conversation under the newer request; the superseded request
resolves early — Cursor answers it `cancelled` the moment the steer lands and
re-plans with the message in context, Grok finishes the current work first
and answers the message before settling — and only the last open prompt's
response settles the merged turn. These behaviors were observed in earlier live
probes; the adapter implements last-prompt-settles bookkeeping. Kimi Code takes
the same path by virtue of the transport, but its superseded-prompt
policy has not been probed against a live turn.

Fx allows only one active prompt per connection, so its driver does not
advertise steering. Follow-ups remain in Shidou's queue and start after the
current prompt settles.

**Rewind and branch** — unchanged and still out of band: Grok forks through its
own ACP server plus on-disk truncation
([grok_session.rs](../crates/shidou-core/src/grok_session.rs)), Cursor re-seeds a
fresh session ([cursor_session.rs](../crates/shidou-core/src/cursor_session.rs)).

**Kimi Code and Fx have neither, deliberately.** Kimi advertises a `fork` session
capability, but `session/fork` takes only `{sessionId, cwd}` and copies the
whole conversation — there is no turn count, so "drop the last N turns" cannot
be expressed. Fx exposes no turn-aware fork or truncation method.
`ProviderKind::supports_conversation_fork` and
`supports_conversation_rollback` are therefore false for both, which hides the
rewind and branch affordances rather than offering a control that would silently
keep history the user asked to discard. The daemon and desktop match arms for it
exist only to keep the matches exhaustive; reaching them means the UI gate was
bypassed. Restoring these depends on Kimi accepting a truncation point.

**Computer Use** — Grok's isolated `GROK_HOME` and `--rules` setup uses
`HeadlessComputerUseRuntime` and the environment builders in
[driver/support.rs](../crates/shidou-core/src/driver/support.rs). The helper's
historical name does not imply a headless conversation transport.

**What moving to ACP gained.** Grok's Supervised mode no longer means "deny"
(`--permission-mode dontAsk` existed because the one-shot stream had no response
channel), Cursor's no longer means `--force`, and **Cursor streams reasoning**,
which its `--print` transport did not emit at all.

---

## Access modes across providers

Shidou's `InteractionMode` (Build / Plan) and `RuntimeMode` (Supervised /
Auto-accept edits / Auto / Full access) collapse into each CLI's own vocabulary.
Where supported, Plan selects the provider's planning behavior. Amp, Pi, Oh My Pi
and Fx do not support Shidou Plan; DeepSeek support depends on the selected preset.

| Shidou | Codex (`approvalPolicy` / `sandbox` / reviewer) | Claude `--permission-mode` | Cursor | Fx | OpenCode | Grok | Kimi Code |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Plan | `never` / `read-only` / `user` | `plan` | `session/set_mode` → `plan` | unsupported; control disabled | `agent: plan` | `session/set_mode` → `plan` | `session/set_mode` → `plan` |
| Supervised | `untrusted` / `read-only` / `user` | `default` + `can_use_tool` reaches the user | `session/request_permission` reaches the user | `session/set_mode` → `ask` | permission requests reach the user | `session/request_permission` reaches the user | `session/request_permission` reaches the user |
| Auto-accept edits | `on-request` / `workspace-write` / `user` | `acceptEdits` | auto-answered | `session/set_mode` → `code` | edits allowed; bash asks the user | auto-answered | auto-answered |
| Auto | `on-request` / `workspace-write` / `auto_review` | `auto` | auto-answered | `session/set_mode` → `code` | auto-answered (`once`) | auto-answered | auto-answered |
| Full access | `never` / `danger-full-access` / `user` | `bypassPermissions` + `--dangerously-skip-permissions` | auto-answered | `session/set_mode` → `code` | auto-answered (`once`) | auto-answered | auto-answered |

Amp, Pi, and Oh My Pi accept Build + Full access only and always run wide open
(`--dangerously-allow-all`, `--approve`, `--yolo`).

Unsupported access/interaction combinations for these three are rejected at
driver startup, not silently degraded. Other adapters route Supervised requests
to the user. OpenCode also asks for bash approval in Auto-accept edits; its Auto
and Full access modes automatically answer residual requests with `once`.
DeepSeek uses Harness permission and Plan commands in-session; its exact mapping
is described below.

## DeepSeek Harness

**Launch and ownership** — `dsh web --host 127.0.0.1 --port 0`, through
[deepseek_session.rs](../crates/shidou-core/src/deepseek_session.rs). The daemon-wide
[pool](../crates/shidou-core/src/deepseek_pool.rs) shares a Harness host per binary;
each session supplies its own cwd. No Shidou Computer Use bridge is installed.

**Protocol and handshake** — typed HTTP RPC envelopes and ordered downlink streams.
The driver subscribes before `session.create` to avoid losing initial state, then
loads `session.history` and commands. `session.create` also reopens a saved session
id. Agent presets are supplied when creating fresh sessions, not when resuming.
See [driver/deepseek.rs](../crates/shidou-core/src/driver/deepseek.rs).

**Turns and interaction** — `session.prompt` carries prompt or steer mode;
`session.cancel` interrupts. Native tool views, projections, questions, approvals,
usage and background jobs are mapped to provider-neutral events. Supervised
approval requests reach the user; other modes answer `allowed-once`. Batched
questions remain user-input requests rather than permission decisions.

**Options** — `session.selectModel` carries model and optional reasoning effort.
`/permission workspace-write` is used outside Full access, which selects
`danger-full-access`. `/plan` and `/plan off` update Plan in-session; a preset
without Plan support rejects a Plan request. These mode changes do not require a
restart. The current option handler does not apply service tier or context window.
Catalog discovery calls `llm.models` and `agentPreset.list` through the same host
([model_catalog.rs](../crates/shidou-core/src/model_catalog.rs)); option resolution
can also query the current selection with `session.models`.

**Rewind and branch** — completed turn sequence numbers define checkpoints.
`session.fork {sessionId, atSeq}` forks at the last retained turn; retaining no turns
creates a fresh session. Rollback adopts the resulting cursor rather than
truncating the source in place. The cursor carries `session_id`.

## Resume cursors

`ProviderResumeCursor` ([model.rs](../crates/shidou-protocol/src/model.rs)) is
persisted with the session and is what makes a Shidou task outlive its process:

| Provider | Cursor fields | Why |
| --- | --- | --- |
| Codex | `thread_id` | `thread/resume` |
| Pi | `session_id`, `session_file` | `switch_session` needs the path |
| Oh My Pi | `session_id`, `session_file` | same, plus `--fork <file>` for a whole-session copy |
| Claude | `session_id`, `resume_at` | `resume_at` is the transcript message uuid used for forking |
| Amp | `thread_id`, `fork_context` | `fork_context` is the seeded history for a branch |
| Cursor | `session_id`, `fork_context` | id is empty until a seeded branch streams one |
| Fx | `session_id` | `session/resume`; no fork or rewind, see above |
| DeepSeek | `session_id` | `session.create` reopens the id; `session.fork` branches at a sequence |
| OpenCode | `session_id` | reuse the id with the HTTP session API |
| Grok | `session_id` | ACP session restore / fork |
| Kimi Code | `session_id` | `session/resume`; no fork, see above |

A cursor from the wrong provider is rejected at driver start rather than
silently ignored.

## Reference comparisons

[T3 Code](https://github.com/pingdotgg/t3code) is a useful source for workflow and
transport precedent, but its provider roster and adapter API evolve independently.
Consult a pinned upstream revision for comparisons rather than treating an
unversioned capability matrix as Shidou's contract. The local capability table,
`ProviderKind` predicates, transport implementations and daemon handlers above are
the reference for this checkout.

## Adding a provider

1. Add the variant to `ProviderKind`
   ([model.rs](../crates/shidou-protocol/src/model.rs)) with `id`,
   `display_name`, `short_name`, `command`, and the capability predicates. The
   compiler's non-exhaustive-match errors are the reliable to-do list for
   everything that follows.
2. Add a `ProviderResumeCursor` variant carrying whatever resume actually needs
   (an id is often not enough — see Pi's session file and Claude's message uuid).
3. Pick a transport, and look hard before settling for the one-shot path. Ask
   whether the CLI speaks ACP (`acp` / `agent stdio` — [driver/acp.rs](../crates/shidou-core/src/driver/acp.rs)
   already covers it), serves an HTTP API, or has a persistent RPC mode. Reuse an
   existing transport or add a driver implementing `DriverControl` under
   `crates/shidou-core/src/driver/`. Route it in `driver::start_local`; there is
   no generic headless dispatcher. Keep process ownership in the daemon and wire
   any new commands/events through the protocol and client adapters.
4. Map its stream onto `DriverEvent` and its tools onto `ActivityKind`. **Read
   the payloads off a live provider** and record the CLI version alongside the
   probe. A dead event subscription or discarded permission reason can escape
   parser unit tests. Preserve ordering,
   and never leak private control markers into the transcript. If the transport
   accepts user messages mid-turn, probe *which* behavior it has before wiring
   `supports_steer`: inject an instruction while a slow tool runs and count the
   turn completions. Claude and OpenCode fold a plain message into the running
   turn; Amp queues it unless it carries the CLI's `"steer": true` attribute;
   steering-capable ACP agents take a second `session/prompt` whose superseded
   predecessor must not settle the turn; Fx deliberately does not take that path.
5. Map the access and interaction modes. If the transport can ask the user, route
   Supervised to a real `Permission` event; otherwise disable/reject the mode,
   as Amp/Pi/Oh My Pi do, rather than silently granting access.
6. Add an `#[ignore]`d integration test that drives the real provider through the
   driver, as `acp.rs` and `opencode.rs` do. Exercise the real subscription,
   permission reply and turn completion paths, not just parser fixtures.
7. Implement rewind and branch, or emulate them the way Claude, Amp, Cursor,
   OpenCode and Grok do. Native truncation is preferable; seeding a fresh session
   with retained history is the fallback. If the provider offers neither — Kimi's
   fork takes no turn count — answer the capability predicates with false and let
   the UI hide the affordance. A control that silently keeps history the user
   asked to discard is worse than one that is not there.
8. **Do not trust a clean stop reason.** Probe what the provider does when the
   turn cannot run at all: an expired plan, a spent quota, a rejected key. Kimi
   reports `end_turn` with no content and no error, and the real message is only
   in its own session log — a client that believes the protocol shows an empty
   answer and calls it a success. Where the cause is recoverable, recover it;
   where it is not, at least do not report success for a turn that produced
   nothing.
9. Wire model discovery in `model_catalog.rs` and define the missing-binary/failure
   behavior. Use a curated fallback only where valid; account-specific catalogs
   such as Fx and DeepSeek deliberately have no fallback models. Some transports hand you a better
   catalog than the CLI's `models` output — Cursor and Grok both return one in
   their ACP handshake.
