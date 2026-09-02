# Agents orchestrate Tasks through a CLI, not an MCP server

A Task's agent should be able to open further Tasks, prompt them, and read
what they said, so a user can talk to one Task and let it farm out the rest.
T3 Code is building this as an MCP server injected into every provider
session; Waku only observes provider-native subagents. We chose a bundled
command-line client, `shidou`, that the agent runs from its ordinary shell
tool, backed by a Task Credential the daemon places in the provider process's
environment.

## Considered options

- **An MCP server per provider**: named tools and typed arguments, but every
  provider has its own configuration surface for MCP (Claude flags, Codex
  `-c` overrides, OpenCode and Grok config files, ACP SDK fields), each of
  which has to be wired and kept working. Rejected for cost, and because the
  user did not want another MCP surface.
- **Structured markers in the agent's text**: the driver scans the stream for
  a fenced request block and acts on it. No integration cost, but it depends
  on the model emitting the format faithfully and the markers would have to
  be stripped from the transcript. Rejected as fragile.
- **Provider-native subagents only**: Claude's `Task` tool and Codex's collab
  agents already fan out, but the workers live inside one transcript and are
  never Tasks the user can open, steer, or see in the sidebar. Not the
  feature.
- **A CLI on the agent's `PATH`** (chosen): one binary works for every
  provider that has a shell tool; the only per-provider work is passing four
  environment variables, which every driver already does for other reasons.
  Claude receives a short system-prompt note so it knows the command exists;
  every other provider gets the same note ahead of its first prompt, which the
  transcript never shows.

## Consequences

- The CLI speaks the same `/v1` WebSocket as the clients, with a **Task
  Credential** instead of the daemon token: a token minted per runtime start,
  bound to that Task, and revoked when its runtime ends. The server refuses
  every command outside a short allowlist and pins the parent of any created
  Task to the credential's Task, whatever the caller wrote. A child can only
  be created, started, prompted, cancelled, and read by its parent.
- Child Tasks are daemon-owned Tasks with a `parent_task_id`, persisted as a
  column so the list load carries it. All three clients see them through the
  ordinary Task catalog; the desktop nests them under the parent in the
  sidebar.
- A child never runs with more access than its parent. Only user-opened root
  Tasks receive a Task Credential or orchestration instructions, and the daemon
  refuses attempts to create a child beneath another Child Task. A root may
  have at most eight unfinished children.
- Because the agent reaches the daemon through a shell command, the parent's
  Supervised mode would ask about every `shidou task …` call. The Claude,
  Codex, ACP, and OpenCode drivers allow a plain `shidou task` line without
  asking, since the daemon itself bounds what the credential can do. The line
  must be a single command: any chaining, piping, redirection, or substitution
  falls back to asking. DeepSeek Harness does not report the command in its
  approval request, so it still asks. Pi and Amp have no permission requests.
- OpenCode and DeepSeek share one server process across Tasks, so the
  credential cannot ride in their environment. Their agents are told to put the
  three variables on each command line instead; the auto-approve matcher
  accepts that form.
- Renaming the CLI or its subcommands is a breaking change for any skill or
  prompt that teaches it.
