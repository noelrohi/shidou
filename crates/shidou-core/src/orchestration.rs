//! Agent-driven Task orchestration.
//!
//! A running Task's provider process receives a Task Credential in its
//! environment: the daemon's loopback address and a token scoped to that one
//! Task. The bundled `shidou` CLI reads the credential and lets the agent
//! create Child Tasks, prompt them, and read what they said — over the same
//! `/v1` WebSocket every client uses, with the daemon enforcing that a token
//! only reaches the Tasks it spawned.

use std::collections::HashMap;
use std::ffi::OsString;
use std::path::PathBuf;
use std::process::Command;

use serde_json::Value;

use parking_lot::Mutex;
use uuid::Uuid;

use crate::model::{AgentSession, MessageRole, RuntimeMode, TurnStatus};
use shidou_protocol::{
    DAEMON_ADDRESS_ENV, TASK_ID_ENV, TASK_TOKEN_ENV, TaskCredential, TaskSummary,
};

/// Where the provider process finds the CLI, independent of `PATH`.
pub const CLI_PATH_ENV: &str = "SHIDOU_CLI";

/// The executable name the agent types. Cargo builds it as `shidou-cli` so it
/// cannot collide with the desktop binary; the bundle renames it.
pub const CLI_COMMAND: &str = "shidou";

/// How many unfinished children one Task may have at once.
pub const MAX_ACTIVE_CHILDREN: usize = 8;

/// Tokens the daemon has handed to running provider processes, each bound to
/// the Task whose runtime carries it.
#[derive(Default)]
pub struct TaskCredentialRegistry {
    tokens: Mutex<HashMap<String, Uuid>>,
}

impl TaskCredentialRegistry {
    /// Mint a fresh token for `task_id`, replacing any earlier one so a
    /// restarted runtime never keeps two live credentials.
    pub fn mint(&self, task_id: Uuid, address: &str) -> TaskCredential {
        let token = format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());
        let mut tokens = self.tokens.lock();
        tokens.retain(|_, bound| *bound != task_id);
        tokens.insert(token.clone(), task_id);
        TaskCredential {
            address: address.to_owned(),
            token,
            task_id,
            subtasks_enabled: true,
        }
    }

    /// The Task a token is bound to, if it is still live.
    pub fn task_for_token(&self, token: &str) -> Option<Uuid> {
        self.tokens.lock().get(token).copied()
    }

    /// Drop every credential for `task_id`; its runtime is gone.
    pub fn revoke(&self, task_id: Uuid) {
        self.tokens.lock().retain(|_, bound| *bound != task_id);
    }
}

/// The bundled CLI, when this build ships one.
///
/// Release bundles carry it at `Contents/Resources/bin/shidou`. A development
/// daemon runs from `target/`, where Cargo leaves `shidou-cli` beside it.
pub fn cli_executable_path() -> Option<PathBuf> {
    let executable = std::env::var_os(crate::APP_EXECUTABLE_ENV)
        .filter(|path| !path.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::current_exe().ok())?;
    let macos = executable.parent()?;
    let bundled = macos
        .parent()
        .map(|contents| contents.join("Resources").join("bin").join(CLI_COMMAND));
    if let Some(bundled) = bundled.filter(|path| path.is_file()) {
        return Some(bundled);
    }
    let development = macos.join(format!("{CLI_COMMAND}-cli"));
    development.is_file().then_some(development)
}

/// The variables a provider process needs to act as an orchestrator.
pub fn credential_environment(credential: &TaskCredential) -> Vec<(String, String)> {
    let mut environment = vec![
        (DAEMON_ADDRESS_ENV.to_owned(), credential.address.clone()),
        (TASK_TOKEN_ENV.to_owned(), credential.token.clone()),
        (TASK_ID_ENV.to_owned(), credential.task_id.to_string()),
    ];
    if let Some(cli) = cli_executable_path() {
        environment.push((CLI_PATH_ENV.to_owned(), cli.display().to_string()));
    }
    environment
}

/// Give `command` the credential and put the CLI's directory first on its
/// `PATH`, so `shidou task …` resolves inside the agent's shell tool.
pub fn apply_task_credential(command: &mut Command, credential: &TaskCredential) {
    for (name, value) in credential_environment(credential) {
        command.env(name, value);
    }
    let Some(cli_dir) = cli_executable_path().and_then(|path| path.parent().map(PathBuf::from))
    else {
        return;
    };
    let existing = command
        .get_envs()
        .find(|(name, _)| *name == "PATH")
        .and_then(|(_, value)| value.map(OsString::from))
        .or_else(|| std::env::var_os("PATH"));
    let mut directories = vec![cli_dir];
    if let Some(existing) = existing {
        directories.extend(std::env::split_paths(&existing));
    }
    if let Ok(joined) = std::env::join_paths(directories) {
        command.env("PATH", joined);
    }
}

/// Instructions that teach the agent the CLI. Claude receives them as a
/// system-prompt addition; every other provider gets them ahead of its first
/// prompt through [`FirstPromptPreamble`]. Written for the agent, not the user.
///
/// `inline_credential` is for providers whose process is shared across Tasks
/// (OpenCode, DeepSeek): their shell has no per-Task environment, so the agent
/// has to put the credential on each command line itself.
pub fn agent_instructions(credential: &TaskCredential, inline_credential: bool) -> String {
    let cli = cli_executable_path()
        .map(|path| path.display().to_string())
        .unwrap_or_else(|| CLI_COMMAND.to_owned());
    let invocation = if inline_credential {
        format!(
            "Your shell does not carry the connection details, so prefix every call exactly \
like this (all on one line, nothing else on the line):\n\
`{address_env}={address} {token_env}={token} {id_env}={task} {cli} task …`\n\
Below, `shidou task …` stands for that full form.",
            address_env = DAEMON_ADDRESS_ENV,
            address = credential.address,
            token_env = TASK_TOKEN_ENV,
            token = credential.token,
            id_env = TASK_ID_ENV,
            task = credential.task_id,
        )
    } else {
        format!("The `shidou` executable is at `{cli}` and on PATH.")
    };
    if !credential.subtasks_enabled {
        return format!(
            "You are running inside a Shidou task (id {task}). Creating child tasks is disabled. \
You can still manage your existing child tasks. {invocation}\n\
Commands:\n\
- `shidou task list` lists your existing child tasks.\n\
- `shidou task read <task-id>` prints the child's status and last message without waiting.\n\
- `shidou task wait <task-id> [--timeout <seconds>]` waits for the child's current turn \
to settle and prints its final message.\n\
- `shidou task send <task-id> \"<prompt>\" [--wait]` sends a follow-up to an existing child.\n\
Run each call as a single plain command: no `&&`, `;`, pipes, or redirection on the same \
line, or it will need the user's approval. If a child is waiting for user input or \
permission, tell the user rather than polling forever.",
            task = credential.task_id,
        );
    }
    format!(
        "You are running inside a Shidou task (id {task}). Shidou can run other coding-agent \
tasks for you in the same project; they appear in the user's sidebar under this task. Use \
this only for work that is genuinely separable and worth a fresh context. {invocation}\n\
Commands:\n\
- `shidou task new \"<prompt>\" [--provider <name>] [--model <id>] [--effort <level>] [--mode \
<mode>] [--plan] [--title \"<title>\"] [--wait]` creates a child task, sends the prompt, prints \
the task id. `--wait` blocks until the turn settles and prints the child's final message. \
Without `--model` the child uses your provider and model.\n\
- `shidou task models [--provider <name>]` lists the model ids and effort levels a provider \
offers. Run it before choosing `--model` or `--effort`; the daemon rejects ids it does not \
know.\n\
- `shidou task send <task-id> \"<prompt>\" [--wait]` sends a follow-up to a child.\n\
- `shidou task wait <task-id> [--timeout <seconds>]` blocks until the child's current turn \
settles, then prints its final message.\n\
- `shidou task read <task-id>` prints the child's status and last message without waiting.\n\
- `shidou task list` lists your child tasks.\n\
Run each call as a single plain command: no `&&`, `;`, pipes, or redirection on the same \
line, or it will need the user's approval. Children start with your permission level or \
lower, never higher. A child can stop to ask the user for permission; `wait` returns then \
with status `waiting`, so tell the user rather than polling forever. Children do not see \
this conversation: put everything they need in the prompt. Child tasks cannot create tasks \
of their own, and you may have at most {children} unfinished children at once.",
        task = credential.task_id,
        children = MAX_ACTIVE_CHILDREN,
    )
}

/// Delivers [`agent_instructions`] to a provider that has no system-prompt
/// hook: the text rides ahead of the runtime's first prompt, once. The
/// transcript keeps the user's own words; only the provider sees the preamble.
#[derive(Default)]
pub struct FirstPromptPreamble {
    pending: Mutex<Option<String>>,
}

impl FirstPromptPreamble {
    pub fn new(credential: Option<&TaskCredential>, inline_credential: bool) -> Self {
        Self {
            pending: Mutex::new(
                credential.map(|credential| agent_instructions(credential, inline_credential)),
            ),
        }
    }

    /// The prompt to hand the provider: the first call carries the
    /// instructions, every later one passes through unchanged.
    pub fn apply(&self, prompt: String) -> String {
        match self.pending.lock().take() {
            Some(instructions) => format!(
                "<shidou-orchestration>\n{instructions}\n</shidou-orchestration>\n\n{prompt}"
            ),
            None => prompt,
        }
    }
}

/// Whether a shell command the agent wants to run is the CLI talking to the
/// daemon, and nothing else. Such commands never need the user's permission:
/// the daemon itself bounds what the token can do.
///
/// "Nothing else" matters. A line that starts with the CLI but goes on to
/// chain, pipe, redirect, or substitute would let anything ride on the
/// approval, so any unquoted shell operator disqualifies the command, as does
/// `$` or a backtick anywhere outside single quotes.
pub fn is_cli_invocation(command: &str) -> bool {
    let trimmed = strip_credential_assignments(command.trim());
    let starts_with_cli = trimmed.starts_with(&format!("{CLI_COMMAND} task "))
        || cli_executable_path().is_some_and(|cli| {
            let cli = cli.display().to_string();
            [
                format!("{cli} task "),
                format!("\"{cli}\" task "),
                format!("'{cli}' task "),
            ]
            .iter()
            .any(|candidate| trimmed.starts_with(candidate))
        });
    starts_with_cli && is_single_simple_command(trimmed)
}

/// A command the provider reports as an argument list rather than a shell
/// line (Codex does both). Without a shell there is nothing to smuggle, so
/// only the program and its first word matter.
pub fn is_cli_invocation_value(command: &Value) -> bool {
    match command {
        Value::String(line) => is_cli_invocation(line),
        Value::Array(words) => {
            let words = words
                .iter()
                .filter_map(Value::as_str)
                .skip_while(|word| is_credential_assignment(word))
                .collect::<Vec<_>>();
            let Some((program, rest)) = words.split_first() else {
                return false;
            };
            let is_cli = *program == CLI_COMMAND
                || cli_executable_path().is_some_and(|cli| cli.display().to_string() == *program);
            is_cli && rest.first() == Some(&"task")
        }
        _ => false,
    }
}

/// Leading `SHIDOU_…=value` words, as the inline-credential form uses.
fn strip_credential_assignments(mut command: &str) -> &str {
    loop {
        let word_end = command.find(char::is_whitespace).unwrap_or(command.len());
        let (word, rest) = command.split_at(word_end);
        if !is_credential_assignment(word) {
            return command;
        }
        command = rest.trim_start();
    }
}

fn is_credential_assignment(word: &str) -> bool {
    word.split_once('=').is_some_and(|(name, value)| {
        name.starts_with("SHIDOU_")
            && name
                .bytes()
                .all(|byte| byte.is_ascii_uppercase() || byte == b'_')
            && !value.is_empty()
            && !value.contains(['`', '$', '"', '\''])
    })
}

fn is_single_simple_command(command: &str) -> bool {
    let mut in_single = false;
    let mut in_double = false;
    let mut escaped = false;
    for character in command.chars() {
        if escaped {
            escaped = false;
            continue;
        }
        match character {
            '\\' if !in_single => escaped = true,
            '\'' if !in_double => in_single = !in_single,
            '"' if !in_single => in_double = !in_double,
            '$' | '`' if !in_single => return false,
            ';' | '|' | '&' | '<' | '>' | '(' | ')' | '\n' | '\r' if !in_single && !in_double => {
                return false;
            }
            _ => {}
        }
    }
    !in_single && !in_double && !escaped
}

fn permissiveness(mode: RuntimeMode) -> u8 {
    match mode {
        RuntimeMode::Plan | RuntimeMode::Ask => 0,
        RuntimeMode::AutoAcceptEdits => 1,
        RuntimeMode::Auto => 2,
        RuntimeMode::FullAccess => 3,
    }
}

/// The access mode a child runs with: what the parent asked for, capped at
/// the parent's own. An agent must not grant itself more than the user gave.
pub fn child_runtime_mode(parent: RuntimeMode, requested: Option<RuntimeMode>) -> RuntimeMode {
    let parent = if parent == RuntimeMode::Plan {
        RuntimeMode::Ask
    } else {
        parent
    };
    match requested {
        Some(requested) if permissiveness(requested) < permissiveness(parent) => {
            if requested == RuntimeMode::Plan {
                RuntimeMode::Ask
            } else {
                requested
            }
        }
        _ => parent,
    }
}

/// The list-level view an orchestrating agent reads. `session` should be
/// hydrated; a skeleton yields no message text.
pub fn task_summary(session: &AgentSession) -> TaskSummary {
    let last_turn = session.turns.last();
    let last_turn_finished = last_turn.is_none_or(|turn| turn.status != TurnStatus::Running);
    let last_assistant_message = session
        .messages
        .iter()
        .rev()
        .filter(|message| last_turn.is_none_or(|turn| message.turn_id == Some(turn.id)))
        .find(|message| message.role == MessageRole::Assistant && !message.streaming)
        .map(|message| message.content.trim().to_owned())
        .filter(|content| !content.is_empty());
    TaskSummary {
        id: session.id,
        title: session.display_title().to_owned(),
        provider: session.provider,
        status: session.status,
        parent_task_id: session.parent_task_id,
        turn_count: session.turns.len(),
        last_turn_finished,
        last_assistant_message,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn child_mode_never_exceeds_the_parent() {
        assert_eq!(
            child_runtime_mode(RuntimeMode::Ask, Some(RuntimeMode::FullAccess)),
            RuntimeMode::Ask
        );
        assert_eq!(
            child_runtime_mode(RuntimeMode::FullAccess, Some(RuntimeMode::Ask)),
            RuntimeMode::Ask
        );
        assert_eq!(
            child_runtime_mode(RuntimeMode::Auto, None),
            RuntimeMode::Auto
        );
        assert_eq!(
            child_runtime_mode(RuntimeMode::Plan, Some(RuntimeMode::FullAccess)),
            RuntimeMode::Ask
        );
    }

    #[test]
    fn tokens_are_bound_to_one_task_and_replaced_on_remint() {
        let registry = TaskCredentialRegistry::default();
        let task = Uuid::new_v4();
        let first = registry.mint(task, "ws://127.0.0.1:1/v1");
        assert_eq!(registry.task_for_token(&first.token), Some(task));
        let second = registry.mint(task, "ws://127.0.0.1:1/v1");
        assert_eq!(registry.task_for_token(&first.token), None);
        assert_eq!(registry.task_for_token(&second.token), Some(task));
        registry.revoke(task);
        assert_eq!(registry.task_for_token(&second.token), None);
    }

    #[test]
    fn cli_invocations_are_recognized_by_command_name() {
        assert!(is_cli_invocation("shidou task new \"fix the tests\""));
        assert!(is_cli_invocation("  shidou task list"));
        assert!(is_cli_invocation(
            "shidou task new 'add a && b; keep $HOME literal' --title 'x | y'"
        ));
        assert!(is_cli_invocation(
            "shidou task send 1 \"say it's done\" --wait"
        ));
        assert!(!is_cli_invocation("rm -rf / && shidou task list"));
        assert!(!is_cli_invocation("shidoutask list"));
    }

    #[test]
    fn inline_credentials_are_part_of_the_invocation() {
        assert!(is_cli_invocation(
            "SHIDOU_DAEMON_ADDRESS=127.0.0.1:1 SHIDOU_TASK_TOKEN=abc SHIDOU_TASK_ID=x shidou task list"
        ));
        assert!(!is_cli_invocation(
            "SHIDOU_TASK_TOKEN=$(cat secret) shidou task list"
        ));
        assert!(!is_cli_invocation("PATH=/tmp shidou task list"));
        assert!(is_cli_invocation_value(&serde_json::json!([
            "shidou", "task", "list"
        ])));
        assert!(is_cli_invocation_value(&serde_json::json!([
            "SHIDOU_TASK_TOKEN=abc",
            "shidou",
            "task",
            "new",
            "do && this"
        ])));
        assert!(!is_cli_invocation_value(&serde_json::json!([
            "bash",
            "-c",
            "shidou task list"
        ])));
    }

    #[test]
    fn legacy_credentials_default_to_creation_instructions() {
        let credential: TaskCredential = serde_json::from_value(serde_json::json!({
            "address": "127.0.0.1:1", "token": "t", "task_id": Uuid::new_v4(),
        }))
        .unwrap();
        assert!(credential.subtasks_enabled);
        assert!(agent_instructions(&credential, false).contains("shidou task new"));
    }

    #[test]
    fn disabled_credentials_teach_only_existing_child_management() {
        let credential = TaskCredential {
            address: "127.0.0.1:1".into(),
            token: "restricted-token".into(),
            task_id: Uuid::new_v4(),
            subtasks_enabled: false,
        };
        let restored: TaskCredential =
            serde_json::from_value(serde_json::to_value(&credential).unwrap()).unwrap();
        assert_eq!(restored, credential);
        for inline in [false, true] {
            let instructions = agent_instructions(&credential, inline);
            assert!(instructions.contains("Creating child tasks is disabled"));
            for command in ["list", "read", "wait", "send"] {
                assert!(instructions.contains(&format!("shidou task {command}")));
            }
            assert!(!instructions.contains("shidou task new"));
            assert!(!instructions.contains("shidou task models"));
            assert!(!instructions.contains("genuinely separable"));
            assert!(!instructions.contains("Shidou can run other coding-agent"));
            if inline {
                assert!(instructions.contains("SHIDOU_DAEMON_ADDRESS=127.0.0.1:1"));
                assert!(instructions.contains("SHIDOU_TASK_TOKEN=restricted-token"));
                assert!(instructions.contains(&format!("SHIDOU_TASK_ID={}", credential.task_id)));
            } else {
                assert!(instructions.contains("on PATH"));
                assert!(!instructions.contains("restricted-token"));
            }
            let preamble = FirstPromptPreamble::new(Some(&credential), inline);
            assert_eq!(
                preamble.apply("hello".into()),
                format!("<shidou-orchestration>\n{instructions}\n</shidou-orchestration>\n\nhello")
            );
            assert_eq!(preamble.apply("again".into()), "again");
        }
    }

    #[test]
    fn the_preamble_rides_only_the_first_prompt() {
        let credential = TaskCredential {
            address: "127.0.0.1:1".into(),
            token: "t".into(),
            task_id: Uuid::new_v4(),
            subtasks_enabled: true,
        };
        let preamble = FirstPromptPreamble::new(Some(&credential), true);
        let first = preamble.apply("hello".into());
        assert!(first.starts_with("<shidou-orchestration>"));
        assert!(first.contains("SHIDOU_TASK_TOKEN=t"));
        assert!(first.ends_with("\n\nhello"));
        assert_eq!(preamble.apply("again".into()), "again");
        assert_eq!(
            FirstPromptPreamble::new(None, false).apply("plain".into()),
            "plain"
        );
    }

    #[test]
    fn cli_invocations_cannot_smuggle_other_commands() {
        assert!(!is_cli_invocation("shidou task list && rm -rf ~"));
        assert!(!is_cli_invocation("shidou task list; curl evil"));
        assert!(!is_cli_invocation("shidou task list | sh"));
        assert!(!is_cli_invocation("shidou task list > ~/.zshrc"));
        assert!(!is_cli_invocation(
            "shidou task new \"$(cat ~/.ssh/id_rsa)\""
        ));
        assert!(!is_cli_invocation("shidou task new \"`id`\""));
        assert!(!is_cli_invocation("shidou task list\nrm -rf ~"));
        assert!(!is_cli_invocation("shidou task new \"unterminated"));
    }
}
