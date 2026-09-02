//! `shidou`: the command-line client a running Task's agent uses to orchestrate
//! Child Tasks.
//!
//! The daemon places a Task Credential in every provider process it starts
//! (`SHIDOU_DAEMON_ADDRESS`, `SHIDOU_TASK_TOKEN`, `SHIDOU_TASK_ID`). This
//! binary reads it, connects over the same `/v1` WebSocket the clients use, and
//! issues the ordinary commands — create, start, prompt, read — that the daemon
//! scopes to the calling Task's children. Nothing here knows about providers or
//! the filesystem; the daemon resolves all of that.

use std::io::{IsTerminal as _, Write as _};
use std::time::{Duration, Instant};

use anyhow::{Context as _, anyhow, bail};
use shidou_client::{
    Command, DAEMON_ADDRESS_ENV, DaemonClient, ResponsePayload, TASK_ID_ENV, TASK_TOKEN_ENV,
    TaskSummary, WireDriverStartOptions,
};
use shidou_protocol::model::{
    AgentSession, InteractionMode, ProviderKind, ProviderModel, RuntimeMode, SessionStatus,
};
use uuid::Uuid;

const POLL_INTERVAL: Duration = Duration::from_millis(750);
const DEFAULT_WAIT_TIMEOUT: Duration = Duration::from_secs(30 * 60);

const USAGE: &str = "\
shidou — orchestrate Shidou tasks from inside a task

Usage:
  shidou task new <prompt> [--provider <name>] [--model <id>] [--effort <level>]
                           [--mode <mode>] [--plan] [--title <title>]
                           [--wait] [--timeout <seconds>]
  shidou task send <task-id> <prompt> [--wait] [--timeout <seconds>]
  shidou task wait <task-id> [--timeout <seconds>]
  shidou task read <task-id>
  shidou task list
  shidou task models [--provider <name>]

Options:
  --provider   claude | codex | amp | pi | cursor | grok | kimi | ohmypi | fx | deepseek | opencode
               (default: the calling task's provider)
  --model      model id from `shidou task models` (default: the parent's model)
  --effort     reasoning effort id listed for that model (default: the model's default)
  --mode       ask | auto-accept-edits | auto | full-access (never above the parent's)
  --plan       start the child in plan mode instead of build mode
  --title      sidebar title for the new task (default: derived from the prompt)
  --wait       block until the turn settles and print the task's final message
  --timeout    seconds to wait before giving up (default: 1800)
  --json       print machine-readable JSON instead of text

Only works inside a Shidou task: the daemon provides the connection details.";

fn main() {
    let arguments = std::env::args().skip(1).collect::<Vec<_>>();
    match run(arguments) {
        Ok(code) => std::process::exit(code),
        Err(error) => {
            eprintln!("shidou: {error:#}");
            std::process::exit(1);
        }
    }
}

struct Options {
    positional: Vec<String>,
    provider: Option<String>,
    model: Option<String>,
    mode: Option<String>,
    effort: Option<String>,
    plan: bool,
    title: Option<String>,
    wait: bool,
    timeout: Duration,
    json: bool,
}

fn parse(arguments: Vec<String>) -> anyhow::Result<Options> {
    let mut options = Options {
        positional: Vec::new(),
        provider: None,
        model: None,
        mode: None,
        effort: None,
        plan: false,
        title: None,
        wait: false,
        timeout: DEFAULT_WAIT_TIMEOUT,
        json: false,
    };
    let mut arguments = arguments.into_iter();
    while let Some(argument) = arguments.next() {
        let mut value_for = |flag: &str| {
            arguments
                .next()
                .ok_or_else(|| anyhow!("{flag} needs a value"))
        };
        match argument.as_str() {
            "--provider" => options.provider = Some(value_for("--provider")?),
            "--model" => options.model = Some(value_for("--model")?),
            "--mode" => options.mode = Some(value_for("--mode")?),
            "--effort" => options.effort = Some(value_for("--effort")?),
            "--plan" => options.plan = true,
            "--title" => options.title = Some(value_for("--title")?),
            "--timeout" => {
                let seconds = value_for("--timeout")?
                    .parse::<u64>()
                    .context("--timeout must be a whole number of seconds")?;
                options.timeout = Duration::from_secs(seconds);
            }
            "--wait" => options.wait = true,
            "--json" => options.json = true,
            "-h" | "--help" | "help" => {
                println!("{USAGE}");
                std::process::exit(0);
            }
            flag if flag.starts_with("--") => bail!("unknown option {flag}\n\n{USAGE}"),
            _ => options.positional.push(argument),
        }
    }
    Ok(options)
}

fn run(arguments: Vec<String>) -> anyhow::Result<i32> {
    let options = parse(arguments)?;
    let mut words = options.positional.iter().map(String::as_str);
    let (Some("task"), Some(verb)) = (words.next(), words.next()) else {
        eprintln!("{USAGE}");
        return Ok(2);
    };
    let rest = words.collect::<Vec<_>>();
    let connection = Connection::from_environment()?;
    match verb {
        "new" => {
            let prompt = join_prompt(&rest, "shidou task new needs a prompt")?;
            let provider = options
                .provider
                .as_deref()
                .map(parse_provider)
                .transpose()?;
            let mode = options.mode.as_deref().map(parse_mode).transpose()?;
            let session = connection.create_child(ChildTask {
                provider,
                model: options.model.clone(),
                mode,
                reasoning_effort: options.effort.clone(),
                interaction_mode: options.plan.then_some(InteractionMode::Plan),
                title: options.title.clone(),
            })?;
            connection.prompt(session.id, &prompt)?;
            if options.wait {
                let summary = connection.wait(session.id, options.timeout)?;
                print_summary(&summary, options.json, true);
            } else if options.json {
                print_json(
                    &serde_json::json!({ "taskId": session.id, "title": session.display_title() }),
                );
            } else {
                println!("{}", session.id);
            }
            Ok(0)
        }
        "send" => {
            let task_id = parse_task_id(rest.first().copied())?;
            let prompt = join_prompt(
                &rest[1.min(rest.len())..],
                "shidou task send needs a prompt",
            )?;
            connection.ensure_running(task_id)?;
            connection.prompt(task_id, &prompt)?;
            if options.wait {
                let summary = connection.wait(task_id, options.timeout)?;
                print_summary(&summary, options.json, true);
            } else if options.json {
                print_json(&serde_json::json!({ "taskId": task_id, "accepted": true }));
            } else {
                println!("sent");
            }
            Ok(0)
        }
        "wait" => {
            let task_id = parse_task_id(rest.first().copied())?;
            let summary = connection.wait(task_id, options.timeout)?;
            print_summary(&summary, options.json, true);
            Ok(0)
        }
        "read" => {
            let task_id = parse_task_id(rest.first().copied())?;
            let summary = connection.read(task_id)?;
            print_summary(&summary, options.json, true);
            Ok(0)
        }
        "models" => {
            let provider = options
                .provider
                .as_deref()
                .map(parse_provider)
                .transpose()?;
            let (provider, models) = connection.provider_models(provider)?;
            if options.json {
                print_json(&serde_json::json!({ "provider": provider, "models": models }));
            } else if models.is_empty() {
                println!(
                    "{} reports no model list; omit --model to use its default",
                    provider.display_name()
                );
            } else {
                for model in &models {
                    let default = if model.is_default { "  (default)" } else { "" };
                    println!("{}  {}{}", model.id, model.name, default);
                    if !model.reasoning_efforts.is_empty() {
                        let efforts = model
                            .reasoning_efforts
                            .iter()
                            .map(|effort| effort.id.as_str())
                            .collect::<Vec<_>>()
                            .join(", ");
                        println!("    effort: {efforts}");
                    }
                }
            }
            Ok(0)
        }
        "list" => {
            let summaries = connection.list_children()?;
            if options.json {
                print_json(&serde_json::to_value(&summaries)?);
            } else if summaries.is_empty() {
                println!("no child tasks");
            } else {
                for summary in &summaries {
                    println!(
                        "{}  {:<9} {}",
                        summary.id,
                        status_label(summary),
                        summary.title
                    );
                }
            }
            Ok(0)
        }
        other => bail!("unknown task command {other:?}\n\n{USAGE}"),
    }
}

fn join_prompt(words: &[&str], missing: &str) -> anyhow::Result<String> {
    let prompt = words.join(" ").trim().to_owned();
    if prompt.is_empty() {
        bail!("{missing}");
    }
    Ok(prompt)
}

fn parse_task_id(value: Option<&str>) -> anyhow::Result<Uuid> {
    let value = value.ok_or_else(|| anyhow!("a task id is required"))?;
    Uuid::parse_str(value).with_context(|| format!("{value:?} is not a task id"))
}

fn parse_provider(value: &str) -> anyhow::Result<ProviderKind> {
    serde_json::from_value(serde_json::Value::String(value.to_ascii_lowercase()))
        .with_context(|| format!("unknown provider {value:?}"))
}

fn parse_mode(value: &str) -> anyhow::Result<RuntimeMode> {
    Ok(
        match value.to_ascii_lowercase().replace('_', "-").as_str() {
            "ask" | "supervised" => RuntimeMode::Ask,
            "auto-accept-edits" | "accept-edits" => RuntimeMode::AutoAcceptEdits,
            "auto" => RuntimeMode::Auto,
            "full-access" | "full" | "bypass" => RuntimeMode::FullAccess,
            _ => bail!("unknown mode {value:?}; use ask, auto-accept-edits, auto, or full-access"),
        },
    )
}

fn status_label(summary: &TaskSummary) -> &'static str {
    match summary.status {
        SessionStatus::Idle if summary.turn_count == 0 => "new",
        SessionStatus::Idle => "done",
        SessionStatus::Connecting | SessionStatus::Working => "working",
        SessionStatus::Waiting => "waiting",
        SessionStatus::Failed => "failed",
    }
}

fn print_json(value: &serde_json::Value) {
    let mut stdout = std::io::stdout().lock();
    let _ = serde_json::to_writer(&mut stdout, value);
    let _ = stdout.write_all(b"\n");
}

fn print_summary(summary: &TaskSummary, json: bool, with_message: bool) {
    if json {
        print_json(&serde_json::to_value(summary).unwrap_or_default());
        return;
    }
    println!(
        "task {}  {}  {}",
        summary.id,
        status_label(summary),
        summary.title
    );
    if summary.status == SessionStatus::Waiting {
        println!("the task is waiting for the user to answer a permission request or question");
    }
    if with_message {
        match &summary.last_assistant_message {
            Some(message) => {
                println!();
                println!("{message}");
            }
            None if summary.last_turn_finished && summary.turn_count > 0 => {
                println!("(the task finished without a final message)");
            }
            None => {}
        }
    }
}

/// What `shidou task new` asks the daemon for.
struct ChildTask {
    provider: Option<ProviderKind>,
    model: Option<String>,
    mode: Option<RuntimeMode>,
    reasoning_effort: Option<String>,
    interaction_mode: Option<InteractionMode>,
    title: Option<String>,
}

struct Connection {
    client: DaemonClient,
    task_id: Uuid,
}

impl Connection {
    fn from_environment() -> anyhow::Result<Self> {
        let address = std::env::var(DAEMON_ADDRESS_ENV);
        let token = std::env::var(TASK_TOKEN_ENV);
        let task_id = std::env::var(TASK_ID_ENV);
        let (Ok(address), Ok(token), Ok(task_id)) = (address, token, task_id) else {
            bail!(
                "not running inside a Shidou task: {DAEMON_ADDRESS_ENV}, {TASK_TOKEN_ENV} and {TASK_ID_ENV} are unset"
            );
        };
        let task_id =
            Uuid::parse_str(task_id.trim()).context("the task id in the environment is invalid")?;
        let client = DaemonClient::connect(address.trim(), token.trim().to_owned())
            .context("could not reach the Shidou daemon")?;
        Ok(Self { client, task_id })
    }

    fn create_child(&self, child: ChildTask) -> anyhow::Result<AgentSession> {
        let response = self.client.request(
            self.task_id,
            Uuid::nil(),
            Command::CreateChildTask {
                parent_task_id: self.task_id,
                provider: child.provider,
                model: child.model,
                mode: child.mode,
                reasoning_effort: child.reasoning_effort,
                interaction_mode: child.interaction_mode,
                title: child.title,
            },
        )?;
        let ResponsePayload::ChildTaskCreated {
            session,
            start_options,
        } = response
        else {
            bail!("the daemon returned an unexpected reply to task creation");
        };
        self.start(session.id, start_options)?;
        Ok(session)
    }

    fn start(&self, task_id: Uuid, options: WireDriverStartOptions) -> anyhow::Result<()> {
        let runtime_id = Uuid::new_v4();
        match self
            .client
            .request(task_id, runtime_id, Command::Start { options })?
        {
            ResponsePayload::Started { .. } => Ok(()),
            _ => bail!("the daemon returned an unexpected reply to task start"),
        }
    }

    /// The runtime a child is running on, if any.
    fn runtime(&self, task_id: Uuid) -> anyhow::Result<Option<Uuid>> {
        match self
            .client
            .request(task_id, Uuid::nil(), Command::AttachSession)?
        {
            ResponsePayload::SessionRuntime { runtime_id, .. } => Ok(runtime_id),
            _ => bail!("the daemon returned an unexpected reply"),
        }
    }

    /// A follow-up needs a live provider process. The daemon keeps a child
    /// running between turns, so this only fails once the child was stopped.
    fn ensure_running(&self, task_id: Uuid) -> anyhow::Result<()> {
        if self.runtime(task_id)?.is_some() {
            return Ok(());
        }
        bail!("task {task_id} is not running any more; create a new task for follow-up work")
    }

    fn prompt(&self, task_id: Uuid, prompt: &str) -> anyhow::Result<()> {
        let runtime_id = self
            .runtime(task_id)?
            .ok_or_else(|| anyhow!("task {task_id} is not running"))?;
        self.client.request(
            task_id,
            runtime_id,
            Command::Prompt {
                prompt: prompt.to_owned(),
                submission_id: Uuid::new_v4(),
            },
        )?;
        Ok(())
    }

    fn provider_models(
        &self,
        provider: Option<ProviderKind>,
    ) -> anyhow::Result<(ProviderKind, Vec<ProviderModel>)> {
        match self.client.request(
            self.task_id,
            Uuid::nil(),
            Command::ListProviderModels { provider },
        )? {
            ResponsePayload::ProviderModels { provider, models } => Ok((provider, models)),
            _ => bail!("the daemon returned an unexpected reply"),
        }
    }

    fn read(&self, task_id: Uuid) -> anyhow::Result<TaskSummary> {
        match self
            .client
            .request(task_id, Uuid::nil(), Command::ReadTaskSummary)?
        {
            ResponsePayload::TaskSummary { summary } => Ok(summary),
            _ => bail!("the daemon returned an unexpected reply"),
        }
    }

    fn list_children(&self) -> anyhow::Result<Vec<TaskSummary>> {
        match self
            .client
            .request(self.task_id, Uuid::nil(), Command::ListChildTasks)?
        {
            ResponsePayload::TaskSummaries { summaries } => Ok(summaries),
            _ => bail!("the daemon returned an unexpected reply"),
        }
    }

    /// Poll until the child's newest turn settles or the child stops to ask
    /// the user something. Returns the summary either way.
    fn wait(&self, task_id: Uuid, timeout: Duration) -> anyhow::Result<TaskSummary> {
        let started = Instant::now();
        let interactive = std::io::stderr().is_terminal();
        loop {
            let summary = self.read(task_id)?;
            let settled = summary.turn_count > 0
                && summary.last_turn_finished
                && !matches!(
                    summary.status,
                    SessionStatus::Connecting | SessionStatus::Working
                );
            if settled || summary.status == SessionStatus::Waiting {
                return Ok(summary);
            }
            if started.elapsed() >= timeout {
                bail!(
                    "task {task_id} is still {} after {} seconds",
                    status_label(&summary),
                    timeout.as_secs()
                );
            }
            if interactive {
                eprint!(".");
            }
            std::thread::sleep(POLL_INTERVAL);
        }
    }
}
