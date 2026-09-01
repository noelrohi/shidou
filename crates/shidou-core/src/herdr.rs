//! Adapter for Herdr's local newline-delimited JSON socket.
//!
//! The daemon is the seam: desktop, browser, and phone callers use the same
//! Shidou commands, while socket discovery and Herdr protocol details remain
//! on the host that owns the terminals.

use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context as _, anyhow, bail};
use serde::Deserialize;
use serde_json::{Value, json};
use shidou_protocol::herdr::{
    HerdrAgent, HerdrAgentOutput, HerdrAgentSession, HerdrAgentStatus, HerdrState, HerdrWorkspace,
    HerdrWorktree,
};
use uuid::Uuid;

const SOCKET_TIMEOUT: Duration = Duration::from_secs(10);

pub fn load_state() -> HerdrState {
    match load_state_result() {
        Ok(state) => state,
        Err(error) => HerdrState {
            available: false,
            unavailable_reason: Some(error.to_string()),
            ..HerdrState::default()
        },
    }
}

fn load_state_result() -> anyhow::Result<HerdrState> {
    let snapshot = snapshot()?;
    Ok(HerdrState {
        available: true,
        version: Some(snapshot.version),
        protocol: Some(snapshot.protocol),
        workspaces: snapshot.workspaces.into_iter().map(Into::into).collect(),
        agents: snapshot.agents.into_iter().map(Into::into).collect(),
        unavailable_reason: None,
    })
}

pub fn read_agent(terminal_id: &str, lines: u32) -> anyhow::Result<HerdrAgentOutput> {
    let target = resolve_terminal(terminal_id)?;
    let result = request(
        "agent.read",
        json!({
            "target": target,
            "source": "recent-unwrapped",
            "format": "text",
            "strip_ansi": true,
            "lines": lines.clamp(1, 2_000),
        }),
    )?;
    let read: ReadResult = serde_json::from_value(
        result
            .get("read")
            .cloned()
            .ok_or_else(|| anyhow!("Herdr returned no agent output"))?,
    )
    .context("could not decode Herdr agent output")?;
    Ok(HerdrAgentOutput {
        pane_id: read.pane_id,
        text: read.text,
        revision: read.revision,
        truncated: read.truncated,
    })
}

pub fn prompt_agent(terminal_id: &str, prompt: &str) -> anyhow::Result<HerdrAgent> {
    let target = resolve_terminal(terminal_id)?;
    let result = request("agent.prompt", json!({ "target": target, "text": prompt }))?;
    decode_agent(&result)
}

pub fn send_agent_keys(terminal_id: &str, keys: &[String]) -> anyhow::Result<()> {
    if keys.is_empty() {
        bail!("at least one key is required");
    }
    let target = resolve_terminal(terminal_id)?;
    request("agent.send_keys", json!({ "target": target, "keys": keys }))?;
    Ok(())
}

pub fn start_agent(
    cwd: &Path,
    label: &str,
    agent_kind: &str,
    agent_name: &str,
    args: &[String],
) -> anyhow::Result<HerdrAgent> {
    if !cwd.is_absolute() {
        bail!("Herdr workspace path must be absolute");
    }
    let created = request(
        "workspace.create",
        json!({
            "cwd": cwd,
            "label": nonempty(label),
            "focus": false,
            "env": {},
        }),
    )?;
    let pane_id = created
        .pointer("/root_pane/pane_id")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("Herdr returned no root pane for the workspace"))?;
    let started = request(
        "agent.start",
        json!({
            "name": agent_name,
            "kind": agent_kind,
            "pane_id": pane_id,
            "args": args,
            "timeout_ms": 30_000,
        }),
    )?;
    decode_agent(&started)
}

fn snapshot() -> anyhow::Result<Snapshot> {
    let result = request("session.snapshot", json!({}))?;
    serde_json::from_value(
        result
            .get("snapshot")
            .cloned()
            .ok_or_else(|| anyhow!("Herdr returned no session snapshot"))?,
    )
    .context("could not decode Herdr's session snapshot")
}

fn resolve_terminal(terminal_id: &str) -> anyhow::Result<String> {
    snapshot()?
        .agents
        .into_iter()
        .find(|agent| agent.terminal_id == terminal_id)
        .map(|agent| agent.pane_id)
        .ok_or_else(|| anyhow!("Herdr terminal {terminal_id} is no longer available"))
}

fn nonempty(value: &str) -> Option<&str> {
    (!value.trim().is_empty()).then_some(value)
}

fn decode_agent(result: &Value) -> anyhow::Result<HerdrAgent> {
    let agent: WireAgent = serde_json::from_value(
        result
            .get("agent")
            .cloned()
            .ok_or_else(|| anyhow!("Herdr returned no agent"))?,
    )
    .context("could not decode Herdr agent")?;
    Ok(agent.into())
}

#[cfg(unix)]
fn request(method: &str, params: Value) -> anyhow::Result<Value> {
    use std::io::{BufRead as _, BufReader, Write as _};
    use std::os::unix::net::UnixStream;

    let path = socket_path().ok_or_else(|| anyhow!("could not locate Herdr's socket"))?;
    let mut stream = UnixStream::connect(&path)
        .with_context(|| format!("could not connect to Herdr at {}", path.display()))?;
    stream.set_read_timeout(Some(SOCKET_TIMEOUT))?;
    stream.set_write_timeout(Some(SOCKET_TIMEOUT))?;

    let id = format!("shidou_{}", Uuid::new_v4().simple());
    serde_json::to_writer(
        &mut stream,
        &json!({ "id": id, "method": method, "params": params }),
    )?;
    stream.write_all(b"\n")?;
    stream.flush()?;

    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line)?;
    if line.is_empty() {
        bail!("Herdr closed the socket without replying to {method}");
    }
    let response: RpcResponse =
        serde_json::from_str(&line).context("Herdr returned invalid JSON")?;
    if response.id != id {
        bail!("Herdr returned a response for a different request");
    }
    match (response.result, response.error) {
        (Some(result), None) => Ok(result),
        (_, Some(error)) => bail!("{}: {}", error.code, error.message),
        _ => bail!("Herdr returned an empty response"),
    }
}

#[cfg(not(unix))]
fn request(_method: &str, _params: Value) -> anyhow::Result<Value> {
    bail!("Herdr socket support is not available on this platform")
}

fn socket_path() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("HERDR_SOCKET_PATH").filter(|path| !path.is_empty()) {
        return Some(path.into());
    }
    let root = std::env::var_os("HERDR_CONFIG_PATH")
        .map(PathBuf::from)
        .and_then(|path| path.parent().map(Path::to_path_buf))
        .or_else(|| dirs::config_dir().map(|path| path.join("herdr")))?;
    match std::env::var("HERDR_SESSION")
        .ok()
        .filter(|name| !name.is_empty())
    {
        Some(name) => Some(root.join("sessions").join(name).join("herdr.sock")),
        None => Some(root.join("herdr.sock")),
    }
}

#[derive(Deserialize)]
struct RpcResponse {
    id: String,
    result: Option<Value>,
    error: Option<RpcError>,
}

#[derive(Deserialize)]
struct RpcError {
    code: String,
    message: String,
}

#[derive(Deserialize)]
struct Snapshot {
    version: String,
    protocol: u32,
    workspaces: Vec<WireWorkspace>,
    agents: Vec<WireAgent>,
}

#[derive(Deserialize)]
struct WireWorkspace {
    workspace_id: String,
    label: String,
    focused: bool,
    pane_count: usize,
    tab_count: usize,
    agent_status: HerdrAgentStatus,
    worktree: Option<WireWorktree>,
}

impl From<WireWorkspace> for HerdrWorkspace {
    fn from(value: WireWorkspace) -> Self {
        Self {
            id: value.workspace_id,
            label: value.label,
            focused: value.focused,
            pane_count: value.pane_count,
            tab_count: value.tab_count,
            status: value.agent_status,
            worktree: value.worktree.map(Into::into),
        }
    }
}

#[derive(Deserialize)]
struct WireWorktree {
    repo_name: String,
    repo_root: String,
    checkout_path: String,
    is_linked_worktree: bool,
}

impl From<WireWorktree> for HerdrWorktree {
    fn from(value: WireWorktree) -> Self {
        Self {
            repo_name: value.repo_name,
            repo_root: value.repo_root,
            checkout_path: value.checkout_path,
            is_linked_worktree: value.is_linked_worktree,
        }
    }
}

#[derive(Deserialize)]
struct WireAgent {
    pane_id: String,
    terminal_id: String,
    workspace_id: String,
    tab_id: String,
    agent: Option<String>,
    name: Option<String>,
    display_agent: Option<String>,
    title: Option<String>,
    terminal_title_stripped: Option<String>,
    cwd: Option<String>,
    foreground_cwd: Option<String>,
    agent_status: HerdrAgentStatus,
    focused: bool,
    revision: u64,
    agent_session: Option<HerdrAgentSession>,
}

impl From<WireAgent> for HerdrAgent {
    fn from(value: WireAgent) -> Self {
        let agent = value
            .display_agent
            .or(value.agent)
            .unwrap_or_else(|| "Agent".to_owned());
        let title = value
            .title
            .or(value.terminal_title_stripped)
            .filter(|title| !title.trim().is_empty());
        Self {
            pane_id: value.pane_id,
            terminal_id: value.terminal_id,
            workspace_id: value.workspace_id,
            tab_id: value.tab_id,
            agent,
            name: value.name,
            title,
            cwd: value.foreground_cwd.or(value.cwd),
            status: value.agent_status,
            focused: value.focused,
            revision: value.revision,
            provider_session: value.agent_session,
        }
    }
}

#[derive(Deserialize)]
struct ReadResult {
    pane_id: String,
    text: String,
    revision: u64,
    truncated: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_snapshot_without_leaking_herdr_shape() {
        let snapshot: Snapshot = serde_json::from_value(json!({
            "version": "0.8.2",
            "protocol": 20,
            "workspaces": [{
                "workspace_id": "w1", "label": "shidou", "focused": true,
                "pane_count": 2, "tab_count": 1, "agent_status": "working",
                "worktree": null
            }],
            "agents": [{
                "pane_id": "w1:p2", "terminal_id": "term_1", "workspace_id": "w1",
                "tab_id": "w1:t1", "agent": "codex", "name": "reviewer",
                "display_agent": null, "title": null, "terminal_title_stripped": "Review auth",
                "cwd": "/repo", "foreground_cwd": "/repo/worktree",
                "agent_status": "blocked", "focused": false, "revision": 7,
                "agent_session": {"source":"herdr:codex","agent":"codex","kind":"id","value":"abc"}
            }]
        }))
        .unwrap();

        let workspace: HerdrWorkspace = snapshot.workspaces.into_iter().next().unwrap().into();
        let agent: HerdrAgent = snapshot.agents.into_iter().next().unwrap().into();
        assert_eq!(workspace.status, HerdrAgentStatus::Working);
        assert_eq!(agent.title.as_deref(), Some("Review auth"));
        assert_eq!(agent.cwd.as_deref(), Some("/repo/worktree"));
        assert_eq!(agent.status, HerdrAgentStatus::Blocked);
        assert_eq!(agent.provider_session.unwrap().value, "abc");
    }

    #[test]
    fn default_socket_honors_named_sessions() {
        let root = std::env::temp_dir()
            .join("herdr-config-test")
            .join("config.toml");
        unsafe {
            std::env::set_var("HERDR_CONFIG_PATH", &root);
            std::env::set_var("HERDR_SESSION", "work");
            std::env::remove_var("HERDR_SOCKET_PATH");
        }
        assert_eq!(
            socket_path().unwrap(),
            root.parent().unwrap().join("sessions/work/herdr.sock")
        );
        unsafe {
            std::env::remove_var("HERDR_CONFIG_PATH");
            std::env::remove_var("HERDR_SESSION");
        }
    }
}
