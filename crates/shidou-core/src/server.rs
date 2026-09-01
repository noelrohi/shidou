use std::collections::{HashMap, HashSet, VecDeque};
use std::io;
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Weak};
use std::time::Duration;

use anyhow::{Context as _, bail};
use crossbeam_channel::{Receiver, Sender, unbounded};
use parking_lot::Mutex;
use subtle::ConstantTimeEq as _;
use tungstenite::handshake::server::{
    ErrorResponse, Request as HandshakeRequest, Response as HandshakeResponse,
};
use tungstenite::http::{StatusCode, header::ORIGIN};
use tungstenite::protocol::WebSocketConfig;
use tungstenite::{Message, WebSocket, accept_hdr_with_config};
use uuid::Uuid;

use crate::model::{AgentSession, Project, ProviderKind, SessionStatus};
use crate::protocol::MAX_WIRE_MESSAGE_BYTES;
use crate::protocol::{
    ClientMessage, Command, PROTOCOL_VERSION, ReplayCursor, Request, ResponseOutcome,
    ResponsePayload, RpcError, SequencedEvent, ServerMessage, WireDriverEvent,
};

const ACCEPT_POLL_INTERVAL: Duration = Duration::from_millis(25);
const SOCKET_POLL_INTERVAL: Duration = Duration::from_millis(25);
const MAX_HANDSHAKE_MESSAGE_BYTES: usize = 64 * 1024;
const MAX_CONNECTIONS: usize = 64;
/// Replayable events retained per session runtime. A client whose cursor
/// falls behind the oldest retained event gets a
/// [`ServerMessage::ReplayGap`] instead of a transcript with a hole in it.
pub const MAX_REPLAY_EVENTS_PER_SESSION: usize = 4096;
const MAX_CACHED_RESPONSES: usize = 2048;

#[derive(Clone, Debug, Default)]
pub struct ServerOptions {
    /// Browser WebSocket handshakes always carry an Origin header. Native
    /// clients do not. An empty set therefore permits native clients only.
    pub allowed_origins: HashSet<String>,
    /// Only a daemon owned by the desktop process should accept the global
    /// shutdown control message. Service-managed daemons keep running when an
    /// authenticated client disconnects.
    pub allow_shutdown: bool,
    /// How many replayable events one session runtime retains, overriding
    /// [`MAX_REPLAY_EVENTS_PER_SESSION`].
    ///
    /// Only a test harness has any business setting this: overflowing the
    /// real ring takes thousands of events, and a client's recovery from that
    /// overflow is exactly the path worth testing.
    pub max_replay_events_per_session: Option<usize>,
}

struct ConnectionPermit(Arc<AtomicUsize>);

impl Drop for ConnectionPermit {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}

/// What reducing one runtime event changed beyond the session projection each
/// client reduces for itself. A client learns the projection from the event it
/// is already receiving; catalog state it holds a snapshot of, so it has to be
/// told the snapshot is stale.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct RuntimeEventOutcome {
    /// The daemon changed the Task catalog while reducing — it cleared an
    /// archive mark because the Task became active again.
    pub task_catalog_changed: bool,
}

pub trait Backend: Send + Sync + 'static {
    fn handle(&self, request: Request, events: EventSink) -> anyhow::Result<ResponsePayload>;

    /// Fold one sequenced replayable event into backend-owned state. The
    /// default keeps lightweight test backends and non-session runtimes inert.
    fn handle_runtime_event(&self, _event: &SequencedEvent) -> anyhow::Result<RuntimeEventOutcome> {
        Ok(RuntimeEventOutcome::default())
    }

    fn runtime_ended(&self, _session_id: Uuid, _runtime_id: Uuid) {}

    /// Whether the persisted session state still has a turn marked running.
    /// Read when a runtime is being torn down: a turn that loses its runtime
    /// mid-flight otherwise never settles anywhere.
    fn session_has_active_turn(&self, _session_id: Uuid) -> bool {
        false
    }

    fn shutdown(&self) {}
}

#[derive(Clone)]
pub struct EventSink {
    session_id: Uuid,
    runtime_id: Uuid,
    hub: Arc<Hub>,
    backend: Option<Weak<dyn Backend>>,
}

impl EventSink {
    pub fn send(&self, event: WireDriverEvent) -> anyhow::Result<()> {
        self.hub.emit(
            self.session_id,
            self.runtime_id,
            event,
            true,
            self.backend.as_ref(),
        );
        Ok(())
    }

    /// Broadcast a live-only event without retaining it in the replay journal.
    /// High-volume PTY output is meaningful only to a terminal emulator that
    /// is currently attached; replaying raw chunks into a fresh emulator would
    /// also retain an unbounded terminal transcript in daemon memory.
    pub fn send_ephemeral(&self, event: WireDriverEvent) -> anyhow::Result<()> {
        self.hub
            .emit(self.session_id, self.runtime_id, event, false, None);
        Ok(())
    }
}

#[derive(Default)]
struct HubState {
    next_subscriber_id: u64,
    task_state_revision: u64,
    subscribers: HashMap<u64, Sender<ServerMessage>>,
    active_runtimes: HashMap<Uuid, Uuid>,
    event_locks: HashMap<(Uuid, Uuid), Arc<Mutex<()>>>,
    next_sequences: HashMap<(Uuid, Uuid), u64>,
    journal: HashMap<(Uuid, Uuid), VecDeque<SequencedEvent>>,
    responses: VecDeque<(Uuid, ResponseOutcome)>,
    catalog_projects: HashMap<Uuid, ProjectCatalogEntry>,
    catalog_sessions: HashMap<Uuid, SessionCatalogEntry>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ProjectCatalogEntry {
    name: String,
    path: std::path::PathBuf,
    created_at: u64,
}

impl From<&Project> for ProjectCatalogEntry {
    fn from(project: &Project) -> Self {
        Self {
            name: project.name.clone(),
            path: project.path.clone(),
            created_at: project.created_at,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct SessionCatalogEntry {
    title: String,
    auto_title: Option<String>,
    project_id: Uuid,
    provider: ProviderKind,
    model: Option<String>,
    status: SessionStatus,
    created_at: u64,
    last_reply_at: Option<u64>,
}

impl From<&AgentSession> for SessionCatalogEntry {
    fn from(session: &AgentSession) -> Self {
        Self {
            title: session.title.clone(),
            auto_title: session.auto_title.clone(),
            project_id: session.project_id,
            provider: session.provider,
            model: session.model.clone(),
            status: session.status,
            created_at: session.created_at,
            last_reply_at: session.last_reply_at,
        }
    }
}

struct Hub {
    epoch: Uuid,
    replay_limit: usize,
    state: Mutex<HubState>,
}

impl Default for Hub {
    fn default() -> Self {
        Self::new(MAX_REPLAY_EVENTS_PER_SESSION)
    }
}

struct DispatchedRequest {
    request: Request,
    outgoing: Sender<ServerMessage>,
    source_subscriber_id: u64,
}

struct RuntimeMailbox {
    id: Uuid,
    sender: Sender<DispatchedRequest>,
}

struct RequestDispatcher {
    backend: Arc<dyn Backend>,
    hub: Arc<Hub>,
    /// A live provider runtime is an actor owned by the daemon, not by any
    /// particular WebSocket connection. One mailbox per session preserves
    /// lifecycle order across desktop and web clients without serializing
    /// unrelated sessions or read-only requests.
    runtime_mailboxes: Arc<Mutex<HashMap<Uuid, RuntimeMailbox>>>,
}

impl Hub {
    fn new(replay_limit: usize) -> Self {
        Self {
            epoch: Uuid::new_v4(),
            replay_limit: replay_limit.max(1),
            state: Mutex::new(HubState::default()),
        }
    }

    #[cfg(test)]
    fn event_sink(self: &Arc<Self>, session_id: Uuid, runtime_id: Uuid) -> EventSink {
        EventSink {
            session_id,
            runtime_id,
            hub: self.clone(),
            backend: None,
        }
    }

    fn observed_event_sink(
        self: &Arc<Self>,
        session_id: Uuid,
        runtime_id: Uuid,
        backend: &Arc<dyn Backend>,
    ) -> EventSink {
        EventSink {
            session_id,
            runtime_id,
            hub: self.clone(),
            backend: Some(Arc::downgrade(backend)),
        }
    }

    fn begin_runtime(&self, session_id: Uuid, runtime_id: Uuid) {
        let current_event_lock = {
            let state = self.state.lock();
            state
                .active_runtimes
                .get(&session_id)
                .and_then(|active| state.event_locks.get(&(session_id, *active)))
                .cloned()
        };
        let _event_order = current_event_lock.as_ref().map(|lock| lock.lock());
        let mut state = self.state.lock();
        state.active_runtimes.insert(session_id, runtime_id);
        state
            .event_locks
            .retain(|(candidate, _), _| *candidate != session_id);
        state
            .next_sequences
            .retain(|(candidate, _), _| *candidate != session_id);
        state
            .journal
            .retain(|(candidate, _), _| *candidate != session_id);
    }

    fn end_runtime(&self, session_id: Uuid, runtime_id: Option<Uuid>) {
        let current_event_lock = {
            let state = self.state.lock();
            state
                .active_runtimes
                .get(&session_id)
                .and_then(|active| state.event_locks.get(&(session_id, *active)))
                .cloned()
        };
        let _event_order = current_event_lock.as_ref().map(|lock| lock.lock());
        let mut state = self.state.lock();
        let matches_active = runtime_id
            .is_none_or(|runtime_id| state.active_runtimes.get(&session_id) == Some(&runtime_id));
        if !matches_active {
            return;
        }
        state.active_runtimes.remove(&session_id);
        state
            .event_locks
            .retain(|(candidate, _), _| *candidate != session_id);
        state
            .next_sequences
            .retain(|(candidate, _), _| *candidate != session_id);
        state
            .journal
            .retain(|(candidate, _), _| *candidate != session_id);
    }

    fn emit(
        &self,
        session_id: Uuid,
        runtime_id: Uuid,
        event: WireDriverEvent,
        replayable: bool,
        backend: Option<&Weak<dyn Backend>>,
    ) {
        let event_lock = {
            let mut state = self.state.lock();
            if state.active_runtimes.get(&session_id) != Some(&runtime_id) {
                return;
            }
            state
                .event_locks
                .entry((session_id, runtime_id))
                .or_insert_with(|| Arc::new(Mutex::new(())))
                .clone()
        };
        let _event_order = event_lock.lock();
        let event = {
            let mut state = self.state.lock();
            if state.active_runtimes.get(&session_id) != Some(&runtime_id) {
                return;
            }
            let sequence = state
                .next_sequences
                .entry((session_id, runtime_id))
                .or_default();
            *sequence = sequence.saturating_add(1);
            let event = SequencedEvent {
                session_id,
                runtime_id,
                epoch: self.epoch,
                sequence: *sequence,
                event,
            };
            if replayable {
                let journal = state.journal.entry((session_id, runtime_id)).or_default();
                journal.push_back(event.clone());
                while journal.len() > self.replay_limit {
                    journal.pop_front();
                }
            }
            event
        };
        let mut task_catalog_changed = false;
        if replayable && let Some(backend) = backend.and_then(Weak::upgrade) {
            match backend.handle_runtime_event(&event) {
                Ok(outcome) => task_catalog_changed = outcome.task_catalog_changed,
                Err(error) => {
                    eprintln!("shidou-daemon could not reduce runtime event: {error:#}")
                }
            }
        }
        let message = ServerMessage::Event(event);
        let mut state = self.state.lock();
        state
            .subscribers
            .retain(|_, subscriber| subscriber.send(message.clone()).is_ok());
        if task_catalog_changed {
            // The daemon changed the catalog on its own, so no client already
            // knows: every one of them hears about it, including whichever is
            // prompting.
            Self::broadcast_task_state_changed(&mut state, None);
        }
    }

    fn subscribe(&self, resume_from: &[ReplayCursor], sender: Sender<ServerMessage>) -> u64 {
        let mut state = self.state.lock();
        for (&(session_id, runtime_id), events) in &state.journal {
            let sequence = resume_from
                .iter()
                .find(|cursor| {
                    cursor.session_id == session_id
                        && cursor.runtime_id == runtime_id
                        && cursor.epoch == self.epoch
                })
                .map(|cursor| cursor.sequence)
                .unwrap_or_default();
            // The journal is contiguous, so its front is the oldest sequence
            // still recoverable. A cursor more than one behind it is asking
            // for events that were evicted, and no amount of tail replay
            // makes that client whole again.
            if let Some(first_available) = events.front().map(|event| event.sequence)
                && first_available > sequence + 1
            {
                let _ = sender.send(ServerMessage::ReplayGap {
                    session_id,
                    runtime_id,
                    epoch: self.epoch,
                    first_available,
                });
            }
            for event in events.iter().filter(|event| event.sequence > sequence) {
                let _ = sender.send(ServerMessage::Event(event.clone()));
            }
        }
        let id = state.next_subscriber_id;
        state.next_subscriber_id = state.next_subscriber_id.saturating_add(1);
        state.subscribers.insert(id, sender);
        id
    }

    fn unsubscribe(&self, subscriber_id: u64) {
        self.state.lock().subscribers.remove(&subscriber_id);
    }

    fn task_state_changed(&self, source_subscriber_id: u64) {
        let mut state = self.state.lock();
        Self::broadcast_task_state_changed(&mut state, Some(source_subscriber_id));
    }

    fn replace_task_catalog(&self, projects: &[Project], sessions: &[AgentSession]) {
        let mut state = self.state.lock();
        state.catalog_projects = projects
            .iter()
            .map(|project| (project.id, ProjectCatalogEntry::from(project)))
            .collect();
        state.catalog_sessions = sessions
            .iter()
            .map(|session| (session.id, SessionCatalogEntry::from(session)))
            .collect();
    }

    fn task_state_saved(
        &self,
        source_subscriber_id: u64,
        projects: &[Project],
        sessions: &[AgentSession],
    ) {
        let mut state = self.state.lock();
        let mut changed = false;
        for project in projects {
            let next = ProjectCatalogEntry::from(project);
            changed |= state
                .catalog_projects
                .insert(project.id, next.clone())
                .is_none_or(|previous| previous != next);
        }
        for session in sessions {
            let next = SessionCatalogEntry::from(session);
            changed |= state
                .catalog_sessions
                .insert(session.id, next.clone())
                .is_none_or(|previous| previous != next);
        }
        if changed {
            Self::broadcast_task_state_changed(&mut state, Some(source_subscriber_id));
        }
    }

    /// Tells every client but the one that caused the change that its Task
    /// catalog snapshot is stale. `None` is a change the daemon made itself,
    /// which no client knows about yet.
    fn broadcast_task_state_changed(state: &mut HubState, source_subscriber_id: Option<u64>) {
        state.task_state_revision = state.task_state_revision.saturating_add(1);
        let message = ServerMessage::TaskStateChanged {
            revision: state.task_state_revision,
        };
        state.subscribers.retain(|subscriber_id, subscriber| {
            Some(*subscriber_id) == source_subscriber_id || subscriber.send(message.clone()).is_ok()
        });
    }

    fn cached_response(&self, request_id: Uuid) -> Option<ResponseOutcome> {
        self.state
            .lock()
            .responses
            .iter()
            .rev()
            .find_map(|(cached_id, outcome)| (*cached_id == request_id).then(|| outcome.clone()))
    }

    fn cache_response(&self, request_id: Uuid, outcome: ResponseOutcome) {
        let mut state = self.state.lock();
        state.responses.push_back((request_id, outcome));
        while state.responses.len() > MAX_CACHED_RESPONSES {
            state.responses.pop_front();
        }
    }
}

impl RequestDispatcher {
    fn new(backend: Arc<dyn Backend>, hub: Arc<Hub>) -> Self {
        Self {
            backend,
            hub,
            runtime_mailboxes: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    fn dispatch(
        &self,
        request: Request,
        outgoing: Sender<ServerMessage>,
        source_subscriber_id: u64,
    ) {
        if command_targets_runtime(&request.command) {
            self.dispatch_runtime(request, outgoing, source_subscriber_id);
        } else {
            self.dispatch_independent(request, outgoing, source_subscriber_id);
        }
    }

    fn dispatch_independent(
        &self,
        request: Request,
        outgoing: Sender<ServerMessage>,
        source_subscriber_id: u64,
    ) {
        let backend = self.backend.clone();
        let hub = self.hub.clone();
        let failed_request_id = request.request_id;
        let failed_outgoing = outgoing.clone();
        if let Err(error) = std::thread::Builder::new()
            .name("shidou-daemon-request".into())
            .spawn(move || {
                handle_request(request, outgoing, source_subscriber_id, backend, hub);
            })
        {
            send_dispatch_error(
                failed_request_id,
                failed_outgoing,
                &self.hub,
                format!("could not start daemon request worker: {error}"),
            );
        }
    }

    fn dispatch_runtime(
        &self,
        request: Request,
        outgoing: Sender<ServerMessage>,
        source_subscriber_id: u64,
    ) {
        let session_id = request.session_id;
        let failed_request_id = request.request_id;
        let failed_outgoing = outgoing.clone();
        let mut dispatched = DispatchedRequest {
            request,
            outgoing,
            source_subscriber_id,
        };
        loop {
            let mut mailboxes = self.runtime_mailboxes.lock();
            if let Some(mailbox) = mailboxes.get(&session_id) {
                match mailbox.sender.send(dispatched) {
                    Ok(()) => return,
                    Err(error) => {
                        dispatched = error.0;
                        mailboxes.remove(&session_id);
                        continue;
                    }
                }
            }

            let mailbox_id = Uuid::new_v4();
            let (sender, requests) = unbounded();
            sender
                .send(dispatched)
                .expect("a new runtime mailbox still has its receiver");
            mailboxes.insert(
                session_id,
                RuntimeMailbox {
                    id: mailbox_id,
                    sender,
                },
            );

            let backend = self.backend.clone();
            let hub = self.hub.clone();
            let mailbox_registry = Arc::downgrade(&self.runtime_mailboxes);
            let worker = std::thread::Builder::new()
                .name(format!("shidou-daemon-runtime-{session_id}"))
                .spawn(move || {
                    run_runtime_mailbox(
                        session_id,
                        mailbox_id,
                        requests,
                        mailbox_registry,
                        backend,
                        hub,
                    );
                });
            if let Err(error) = worker {
                if mailboxes
                    .get(&session_id)
                    .is_some_and(|mailbox| mailbox.id == mailbox_id)
                {
                    mailboxes.remove(&session_id);
                }
                drop(mailboxes);
                send_dispatch_error(
                    failed_request_id,
                    failed_outgoing,
                    &self.hub,
                    format!("could not start runtime worker: {error}"),
                );
            }
            return;
        }
    }
}

pub fn serve(
    listener: TcpListener,
    token: String,
    backend: Arc<dyn Backend>,
    shutdown: Arc<AtomicBool>,
    options: ServerOptions,
) -> anyhow::Result<()> {
    listener
        .set_nonblocking(true)
        .context("could not configure Shidou daemon listener")?;
    let hub = Arc::new(Hub::new(
        options
            .max_replay_events_per_session
            .unwrap_or(MAX_REPLAY_EVENTS_PER_SESSION),
    ));
    let dispatcher = Arc::new(RequestDispatcher::new(backend.clone(), hub.clone()));
    let options = Arc::new(options);
    let active_connections = Arc::new(AtomicUsize::new(0));
    while !shutdown.load(Ordering::Acquire) {
        match listener.accept() {
            Ok((stream, _)) => {
                if active_connections
                    .fetch_update(Ordering::AcqRel, Ordering::Acquire, |active| {
                        (active < MAX_CONNECTIONS).then_some(active + 1)
                    })
                    .is_err()
                {
                    continue;
                }
                let connection_permit = ConnectionPermit(active_connections.clone());
                let token = token.clone();
                let dispatcher = dispatcher.clone();
                let hub = hub.clone();
                let shutdown = shutdown.clone();
                let options = options.clone();
                std::thread::Builder::new()
                    .name("shidou-daemon-connection".into())
                    .spawn(move || {
                        let _connection_permit = connection_permit;
                        if let Err(error) =
                            handle_connection(stream, &token, dispatcher, hub, shutdown, &options)
                        {
                            eprintln!("shidou-daemon connection ended: {error:#}");
                        }
                    })
                    .context("could not start Shidou daemon connection thread")?;
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                std::thread::sleep(ACCEPT_POLL_INTERVAL);
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error).context("Shidou daemon listener failed"),
        }
    }
    backend.shutdown();
    Ok(())
}

fn handle_connection(
    stream: TcpStream,
    expected_token: &str,
    dispatcher: Arc<RequestDispatcher>,
    hub: Arc<Hub>,
    shutdown: Arc<AtomicBool>,
    options: &ServerOptions,
) -> anyhow::Result<()> {
    // Accepted sockets can inherit the listener's nonblocking flag on some
    // platforms. The handshake is deliberately blocking; steady-state reads
    // get their bounded polling behavior from SO_RCVTIMEO below.
    stream.set_nonblocking(false)?;
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    let config = WebSocketConfig::default()
        .max_message_size(Some(MAX_HANDSHAKE_MESSAGE_BYTES))
        .max_frame_size(Some(MAX_HANDSHAKE_MESSAGE_BYTES));
    let allowed_origins = options.allowed_origins.clone();
    let mut socket = accept_hdr_with_config(
        stream,
        move |request: &HandshakeRequest, response: HandshakeResponse| {
            validate_handshake(request, response, &allowed_origins)
        },
        Some(config),
    )
    .context("WebSocket handshake failed")?;
    let hello = read_client_message(&mut socket)?;
    let resume_from = match hello {
        ClientMessage::Hello {
            protocol_version,
            token,
            resume_from,
            ..
        } if protocol_version == PROTOCOL_VERSION && token_matches(expected_token, &token) => {
            resume_from
        }
        ClientMessage::Hello {
            protocol_version, ..
        } if protocol_version != PROTOCOL_VERSION => {
            write_json(
                &mut socket,
                &ServerMessage::Rejected {
                    message: format!(
                        "protocol {protocol_version} is unsupported; expected {PROTOCOL_VERSION}"
                    ),
                },
            )?;
            return Ok(());
        }
        ClientMessage::Hello { .. } => {
            write_json(
                &mut socket,
                &ServerMessage::Rejected {
                    message: "authentication failed".into(),
                },
            )?;
            return Ok(());
        }
        _ => bail!("first daemon message was not a hello"),
    };
    write_json(
        &mut socket,
        &ServerMessage::Hello {
            protocol_version: PROTOCOL_VERSION,
            daemon_version: env!("CARGO_PKG_VERSION").into(),
        },
    )?;
    socket.set_config(|config| {
        config.max_message_size = Some(MAX_WIRE_MESSAGE_BYTES);
        config.max_frame_size = Some(MAX_WIRE_MESSAGE_BYTES);
    });
    socket
        .get_mut()
        .set_read_timeout(Some(SOCKET_POLL_INTERVAL))?;

    let (outgoing, outgoing_rx) = unbounded();
    let subscriber_id = hub.subscribe(&resume_from, outgoing.clone());

    'connection: while !shutdown.load(Ordering::Acquire) {
        while let Ok(message) = outgoing_rx.try_recv() {
            if write_json(&mut socket, &message).is_err() {
                break 'connection;
            }
        }
        match socket.read() {
            Ok(Message::Text(text)) => match serde_json::from_str(text.as_ref()) {
                Ok(ClientMessage::Request(request)) => {
                    dispatcher.dispatch(request, outgoing.clone(), subscriber_id);
                }
                Ok(ClientMessage::Shutdown) => {
                    if options.allow_shutdown {
                        write_json(&mut socket, &ServerMessage::ShuttingDown)?;
                        shutdown.store(true, Ordering::Release);
                        break;
                    }
                    write_json(
                        &mut socket,
                        &ServerMessage::Rejected {
                            message: "daemon shutdown is managed by its service owner".into(),
                        },
                    )?;
                }
                Ok(ClientMessage::Hello { .. }) => {}
                Err(error) => {
                    eprintln!("shidou-daemon ignored invalid message: {error}");
                }
            },
            Ok(Message::Close(_)) => break,
            Ok(Message::Ping(_)) => {
                let _ = socket.flush();
            }
            Ok(_) => {}
            Err(tungstenite::Error::Io(error)) if retryable_io(&error) => {}
            Err(tungstenite::Error::ConnectionClosed | tungstenite::Error::AlreadyClosed) => break,
            Err(error) => return Err(error).context("Shidou daemon WebSocket failed"),
        }
    }
    hub.unsubscribe(subscriber_id);
    Ok(())
}

fn validate_handshake(
    request: &HandshakeRequest,
    response: HandshakeResponse,
    allowed_origins: &HashSet<String>,
) -> Result<HandshakeResponse, ErrorResponse> {
    if request.uri().path() != "/v1" {
        return Err(handshake_error(
            StatusCode::NOT_FOUND,
            "unknown daemon endpoint",
        ));
    }
    if let Some(origin) = request.headers().get(ORIGIN) {
        let allowed = origin
            .to_str()
            .ok()
            .is_some_and(|origin| allowed_origins.contains(origin));
        if !allowed {
            return Err(handshake_error(
                StatusCode::FORBIDDEN,
                "WebSocket origin is not allowed",
            ));
        }
    }
    Ok(response)
}

fn handshake_error(status: StatusCode, message: &str) -> ErrorResponse {
    tungstenite::http::Response::builder()
        .status(status)
        .body(Some(message.to_owned()))
        .expect("static WebSocket rejection is valid")
}

fn token_matches(expected: &str, candidate: &str) -> bool {
    expected.as_bytes().ct_eq(candidate.as_bytes()).into()
}

fn command_targets_runtime(command: &Command) -> bool {
    matches!(
        command,
        Command::AttachSession
            | Command::Start { .. }
            | Command::Prompt { .. }
            | Command::Steer { .. }
            | Command::Cancel
            | Command::CancelComputerUse
            | Command::RefreshBackgroundWork
            | Command::StopBackgroundWork { .. }
            | Command::Respond { .. }
            | Command::RespondUserInput { .. }
            | Command::RunComputerTool { .. }
            | Command::RejectComputerTool { .. }
            | Command::ApplyOptions { .. }
            | Command::Rollback { .. }
            | Command::Fork { .. }
            | Command::ForkSessionFromResponse { .. }
            | Command::RewindSessionToMessage { .. }
            | Command::OpenTerminal { .. }
            | Command::WriteTerminal { .. }
            | Command::ResizeTerminal { .. }
            | Command::CloseTerminal
            | Command::CloseSession
            | Command::RemoveSession
    )
}

fn run_runtime_mailbox(
    session_id: Uuid,
    mailbox_id: Uuid,
    requests: Receiver<DispatchedRequest>,
    mailbox_registry: Weak<Mutex<HashMap<Uuid, RuntimeMailbox>>>,
    backend: Arc<dyn Backend>,
    hub: Arc<Hub>,
) {
    let mut active_runtime_id = None;
    let mut pending = None;
    loop {
        let dispatched = match pending.take() {
            Some(request) => request,
            None => match requests.recv() {
                Ok(request) => request,
                Err(_) => return,
            },
        };
        let runtime_id = dispatched.request.runtime_id;
        let resolved_interaction = match &dispatched.request.command {
            Command::Respond { request_id, .. } | Command::RespondUserInput { request_id, .. } => {
                Some(request_id.clone())
            }
            _ => None,
        };
        let starts_runtime = matches!(
            &dispatched.request.command,
            Command::Start { .. } | Command::OpenTerminal { .. }
        );
        let closes_runtime = matches!(
            &dispatched.request.command,
            Command::CloseSession | Command::CloseTerminal | Command::RemoveSession
        );
        let removes_session = matches!(&dispatched.request.command, Command::RemoveSession);
        let handled = handle_request(
            dispatched.request,
            dispatched.outgoing,
            dispatched.source_subscriber_id,
            backend.clone(),
            hub.clone(),
        );

        if handled.executed {
            if let Some(request_id) = resolved_interaction
                && matches!(&handled.outcome, ResponseOutcome::Ok { .. })
            {
                hub.observed_event_sink(session_id, runtime_id, &backend)
                    .send(WireDriverEvent::new(
                        "interactionResolved",
                        serde_json::json!({ "requestId": request_id }),
                    ))
                    .ok();
            }
            if starts_runtime {
                active_runtime_id =
                    matches!(&handled.outcome, ResponseOutcome::Ok { .. }).then_some(runtime_id);
            } else if let ResponseOutcome::Ok {
                payload:
                    ResponsePayload::SessionRuntime {
                        runtime_id: Some(attached_runtime_id),
                        ..
                    },
            } = &handled.outcome
            {
                // A replacement mailbox can rediscover a provider runtime
                // that survived its previous actor worker.
                active_runtime_id = Some(*attached_runtime_id);
            } else if closes_runtime {
                if (removes_session || active_runtime_id == Some(runtime_id))
                    && matches!(&handled.outcome, ResponseOutcome::Ok { .. })
                {
                    settle_interrupted_turn(&hub, &backend, session_id, runtime_id);
                    hub.end_runtime(session_id, (!removes_session).then_some(runtime_id));
                    backend.runtime_ended(session_id, runtime_id);
                    active_runtime_id = None;
                }
            } else if active_runtime_id.is_none()
                && !matches!(
                    &handled.outcome,
                    ResponseOutcome::Ok {
                        payload: ResponsePayload::SessionRuntime { .. }
                    }
                )
                && matches!(&handled.outcome, ResponseOutcome::Ok { .. })
            {
                // Recover the supervisor state if a previous mailbox worker
                // exited unexpectedly while the backend runtime stayed alive.
                active_runtime_id = Some(runtime_id);
            }
        }

        if active_runtime_id.is_none() {
            pending =
                take_queued_request_or_retire(session_id, mailbox_id, &requests, &mailbox_registry);
            if pending.is_none() {
                return;
            }
        }
    }
}

fn take_queued_request_or_retire(
    session_id: Uuid,
    mailbox_id: Uuid,
    requests: &Receiver<DispatchedRequest>,
    mailbox_registry: &Weak<Mutex<HashMap<Uuid, RuntimeMailbox>>>,
) -> Option<DispatchedRequest> {
    let Some(mailbox_registry) = mailbox_registry.upgrade() else {
        return requests.try_recv().ok();
    };
    // Dispatchers send while holding this same lock. Therefore an empty
    // receiver followed by removal is atomic with respect to a new command:
    // it either joins this actor before retirement or creates its successor.
    let mut mailboxes = mailbox_registry.lock();
    match requests.try_recv() {
        Ok(request) => Some(request),
        Err(crossbeam_channel::TryRecvError::Empty) => {
            if mailboxes
                .get(&session_id)
                .is_some_and(|mailbox| mailbox.id == mailbox_id)
            {
                mailboxes.remove(&session_id);
            }
            None
        }
        Err(crossbeam_channel::TryRecvError::Disconnected) => None,
    }
}

struct HandledRequest {
    outcome: ResponseOutcome,
    executed: bool,
}

enum TaskCatalogAction {
    None,
    Load,
    Save { projects: Vec<Project> },
    Changed,
}

/// A runtime torn down while a turn is still running takes the only witness
/// of that turn's end with it: the hub drops later driver events once the
/// runtime is no longer active, so a phone left on the turn would spin
/// forever and the saved session would stay "working". Before the runtime
/// state is cleared, tell every client the turn failed — replayable, like
/// any driver event.
fn settle_interrupted_turn(
    hub: &Arc<Hub>,
    backend: &Arc<dyn Backend>,
    session_id: Uuid,
    runtime_id: Uuid,
) {
    if !backend.session_has_active_turn(session_id) {
        return;
    }
    let _ = hub
        .observed_event_sink(session_id, runtime_id, backend)
        .send(WireDriverEvent::new(
            "turnFinished",
            serde_json::json!({ "success": false }),
        ));
}

fn handle_request(
    request: Request,
    outgoing: Sender<ServerMessage>,
    source_subscriber_id: u64,
    backend: Arc<dyn Backend>,
    hub: Arc<Hub>,
) -> HandledRequest {
    let request_id = request.request_id;
    let notification = request_id.is_nil();
    let session_id = request.session_id;
    let runtime_id = request.runtime_id;
    let task_catalog_action = task_catalog_action(&request.command);
    let starts_runtime = matches!(
        &request.command,
        Command::Start { .. } | Command::OpenTerminal { .. }
    );
    let (outcome, executed) = if !notification && let Some(cached) = hub.cached_response(request_id)
    {
        (cached, false)
    } else {
        if starts_runtime {
            hub.begin_runtime(session_id, runtime_id);
        }
        let events = hub.observed_event_sink(session_id, runtime_id, &backend);
        let outcome = match backend.handle(request, events) {
            Ok(payload) => ResponseOutcome::Ok { payload },
            Err(error) => ResponseOutcome::Error {
                error: RpcError::from(error),
            },
        };
        if !notification {
            hub.cache_response(request_id, outcome.clone());
        }
        (outcome, true)
    };
    if executed && starts_runtime && matches!(&outcome, ResponseOutcome::Error { .. }) {
        hub.end_runtime(session_id, Some(runtime_id));
    }
    if executed {
        match (&task_catalog_action, &outcome) {
            (
                TaskCatalogAction::Load,
                ResponseOutcome::Ok {
                    payload:
                        ResponsePayload::TaskState {
                            projects, sessions, ..
                        },
                },
            ) => hub.replace_task_catalog(projects, sessions),
            (
                TaskCatalogAction::Save { projects },
                ResponseOutcome::Ok {
                    payload: ResponsePayload::TaskStateSaved { sessions },
                },
            ) => hub.task_state_saved(source_subscriber_id, projects, sessions),
            (TaskCatalogAction::Changed, ResponseOutcome::Ok { .. }) => {
                hub.task_state_changed(source_subscriber_id);
            }
            _ => {}
        }
    }
    if !notification {
        let _ = outgoing.send(ServerMessage::Response {
            request_id,
            outcome: outcome.clone(),
        });
    }
    HandledRequest { outcome, executed }
}

fn task_catalog_action(command: &Command) -> TaskCatalogAction {
    match command {
        Command::LoadTaskState => TaskCatalogAction::Load,
        Command::SaveTaskState { projects, .. } => TaskCatalogAction::Save {
            projects: projects.clone(),
        },
        Command::RemoveSession
        | Command::ArchiveSession { .. }
        | Command::RemoveProject { .. }
        | Command::ForkSessionFromResponse { .. }
        | Command::RewindSessionToMessage { .. } => TaskCatalogAction::Changed,
        _ => TaskCatalogAction::None,
    }
}

fn send_dispatch_error(
    request_id: Uuid,
    outgoing: Sender<ServerMessage>,
    hub: &Arc<Hub>,
    message: String,
) {
    if request_id.is_nil() {
        return;
    }
    let outcome = hub
        .cached_response(request_id)
        .unwrap_or_else(|| ResponseOutcome::Error {
            error: RpcError {
                message,
                kind: None,
            },
        });
    hub.cache_response(request_id, outcome.clone());
    let _ = outgoing.send(ServerMessage::Response {
        request_id,
        outcome,
    });
}

fn retryable_io(error: &io::Error) -> bool {
    retryable_error(error)
}

fn retryable_error(error: &(dyn std::error::Error + 'static)) -> bool {
    if let Some(error) = error.downcast_ref::<io::Error>() {
        if matches!(
            error.kind(),
            io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut | io::ErrorKind::Interrupted
        ) {
            return true;
        }
        #[cfg(unix)]
        if error.raw_os_error() == Some(libc::EAGAIN)
            || error.raw_os_error() == Some(libc::EWOULDBLOCK)
        {
            return true;
        }
    }
    error.source().is_some_and(retryable_error)
}

fn read_client_message(socket: &mut WebSocket<TcpStream>) -> anyhow::Result<ClientMessage> {
    loop {
        match socket.read()? {
            Message::Text(text) => return Ok(serde_json::from_str(text.as_ref())?),
            Message::Ping(_) => socket.flush()?,
            Message::Close(_) => bail!("client closed during daemon handshake"),
            _ => {}
        }
    }
}

fn write_json<S: io::Read + io::Write, T: serde::Serialize>(
    socket: &mut WebSocket<S>,
    value: &T,
) -> anyhow::Result<()> {
    socket.send(Message::Text(serde_json::to_string(value)?.into()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::WireDriverStartOptions;
    #[cfg(unix)]
    use crate::daemon::ShidouBackend;
    #[cfg(unix)]
    use crate::model::Project;
    use crate::model::{ActivityItem, ActivityKind, AgentSession, ProviderKind, TranscriptBlock};
    #[cfg(unix)]
    use crate::persistence::StateStore;
    #[cfg(unix)]
    use crate::settings::DaemonSettingsStore;
    #[cfg(unix)]
    use base64::Engine as _;
    use crossbeam_channel::bounded;
    use serde_json::json;
    use shidou_client::DaemonClient;
    use std::path::PathBuf;

    #[cfg(unix)]
    struct ShidouTestDaemon {
        root: PathBuf,
        address: std::net::SocketAddr,
        provider: Arc<ScriptedProvider>,
        shutdown_client: DaemonClient,
        server: Option<std::thread::JoinHandle<()>>,
    }

    #[cfg(unix)]
    impl ShidouTestDaemon {
        fn new(label: &str, configure: impl FnOnce(&ShidouBackend)) -> Self {
            let root = std::env::temp_dir().join(format!("shidou-{label}-{}", Uuid::new_v4()));
            std::fs::create_dir_all(&root).unwrap();
            let (address, provider, shutdown_client, server) = Self::start(&root, configure);
            Self {
                root,
                address,
                provider,
                shutdown_client,
                server: Some(server),
            }
        }

        fn start(
            root: &std::path::Path,
            configure: impl FnOnce(&ShidouBackend),
        ) -> (
            std::net::SocketAddr,
            Arc<ScriptedProvider>,
            DaemonClient,
            std::thread::JoinHandle<()>,
        ) {
            let backend = ShidouBackend::new(
                DaemonSettingsStore::open(root.join("settings.json")).unwrap(),
                StateStore::daemon(root.join("app.db")),
            )
            .unwrap();
            configure(&backend);
            let provider = Arc::new(ScriptedProvider {
                daemon: backend,
                sinks: Mutex::new(HashMap::new()),
            });
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let address = listener.local_addr().unwrap();
            let shutdown = Arc::new(AtomicBool::new(false));
            let server_shutdown = shutdown.clone();
            let server_provider = provider.clone();
            let server = std::thread::spawn(move || {
                serve(
                    listener,
                    "secret".into(),
                    server_provider,
                    server_shutdown,
                    ServerOptions {
                        allow_shutdown: true,
                        ..ServerOptions::default()
                    },
                )
                .unwrap()
            });
            let shutdown_client =
                DaemonClient::connect(&address.to_string(), "secret".into()).unwrap();
            (address, provider, shutdown_client, server)
        }

        /// Stops the daemon and starts a fresh one over the same state
        /// directory, so a test can assert what survives a restart rather than
        /// what a still-running process happens to hold in memory.
        fn restart(&mut self) {
            self.shutdown_client.shutdown();
            self.server.take().unwrap().join().unwrap();
            let (address, provider, shutdown_client, server) = Self::start(&self.root, |_| {});
            self.address = address;
            self.provider = provider;
            self.shutdown_client = shutdown_client;
            self.server = Some(server);
        }

        fn connect(&self) -> DaemonClient {
            DaemonClient::connect(&self.address.to_string(), "secret".into()).unwrap()
        }

        /// Attaches a runtime to the task the way a client does, and returns
        /// the runtime the test then speaks as.
        fn start_runtime(&self, client: &DaemonClient, session_id: Uuid) -> Uuid {
            let runtime_id = Uuid::new_v4();
            client
                .request(
                    session_id,
                    runtime_id,
                    Command::Start {
                        options: test_start_options(),
                    },
                )
                .unwrap();
            runtime_id
        }

        /// Emits one provider event on the task's runtime, exactly where its
        /// driver would, so the daemon reduces it through its own event pump.
        fn emit(&self, session_id: Uuid, event: WireDriverEvent) {
            let sink = self
                .provider
                .sinks
                .lock()
                .get(&session_id)
                .cloned()
                .expect("the task has a runtime");
            sink.send(event).unwrap();
        }
    }

    /// The real daemon with its provider process replaced by the test. Every
    /// command, reduction, and broadcast below is the daemon's own; only
    /// `Start` is intercepted, because a test cannot run a provider, and the
    /// events one would emit arrive through [`ShidouTestDaemon::emit`].
    #[cfg(unix)]
    struct ScriptedProvider {
        daemon: ShidouBackend,
        sinks: Mutex<HashMap<Uuid, EventSink>>,
    }

    #[cfg(unix)]
    impl Backend for ScriptedProvider {
        fn handle(&self, request: Request, events: EventSink) -> anyhow::Result<ResponsePayload> {
            if matches!(request.command, Command::Start { .. }) {
                self.daemon.set_running_driver_for_test(
                    request.session_id,
                    request.runtime_id,
                    crate::driver::DriverHandle::from_control(Arc::new(SilentProvider)),
                );
                self.sinks.lock().insert(request.session_id, events);
                return Ok(ResponsePayload::Started {
                    supports_steer: false,
                });
            }
            self.daemon.handle(request, events)
        }

        fn handle_runtime_event(
            &self,
            event: &SequencedEvent,
        ) -> anyhow::Result<RuntimeEventOutcome> {
            self.daemon.handle_runtime_event(event)
        }

        fn runtime_ended(&self, session_id: Uuid, runtime_id: Uuid) {
            self.daemon.runtime_ended(session_id, runtime_id);
        }

        fn session_has_active_turn(&self, session_id: Uuid) -> bool {
            self.daemon.session_has_active_turn(session_id)
        }

        fn shutdown(&self) {
            self.daemon.shutdown();
        }
    }

    /// A provider that accepts every instruction and volunteers nothing. What
    /// it would have said comes from the test instead.
    #[cfg(unix)]
    struct SilentProvider;

    #[cfg(unix)]
    impl crate::driver::DriverControl for SilentProvider {
        fn prompt(&self, _prompt: String) {}

        fn cancel(&self) {}

        fn respond(&self, _request_id: String, _option_id: String) {}

        fn rollback(
            &self,
            _turns: usize,
        ) -> anyhow::Result<Option<crate::model::ProviderResumeCursor>> {
            Ok(None)
        }
    }

    #[cfg(unix)]
    impl Drop for ShidouTestDaemon {
        fn drop(&mut self) {
            self.shutdown_client.shutdown();
            self.server.take().unwrap().join().unwrap();
            std::fs::remove_dir_all(&self.root).unwrap();
        }
    }

    #[derive(Default)]
    struct TestBackend {
        runtimes: Mutex<HashMap<Uuid, Uuid>>,
        active_turns: Mutex<HashSet<Uuid>>,
    }

    impl Backend for TestBackend {
        fn handle(&self, request: Request, events: EventSink) -> anyhow::Result<ResponsePayload> {
            let session_id = request.session_id;
            let runtime_id = request.runtime_id;
            match request.command {
                Command::Start { .. } => {
                    self.runtimes.lock().insert(session_id, runtime_id);
                    self.active_turns.lock().insert(session_id);
                    events.send(WireDriverEvent::new("connected", json!({})))?;
                    Ok(ResponsePayload::Started {
                        supports_steer: true,
                    })
                }
                Command::AttachSession => Ok(ResponsePayload::SessionRuntime {
                    runtime_id: self.runtimes.lock().get(&session_id).copied(),
                    supports_steer: true,
                }),
                Command::Prompt { prompt, .. } => {
                    if prompt == "__test_question__" {
                        events.send(WireDriverEvent::new(
                            "userInputRequested",
                            json!({
                                "requestId": "question-1",
                                "questions": [{
                                    "id": "direction",
                                    "header": "Direction",
                                    "question": "Which way?",
                                    "options": [{ "label": "Left" }],
                                    "multiSelect": false
                                }]
                            }),
                        ))?;
                    } else {
                        events.send(WireDriverEvent::new("textDelta", json!(prompt)))?;
                    }
                    Ok(ResponsePayload::Ack)
                }
                Command::CloseSession => {
                    self.runtimes.lock().remove(&session_id);
                    Ok(ResponsePayload::Ack)
                }
                _ => Ok(ResponsePayload::Ack),
            }
        }

        fn session_has_active_turn(&self, session_id: Uuid) -> bool {
            self.active_turns.lock().contains(&session_id)
        }
    }

    #[derive(Default)]
    struct TaskStateBackend {
        sessions: Mutex<Vec<AgentSession>>,
    }

    impl Backend for TaskStateBackend {
        fn handle(&self, request: Request, _events: EventSink) -> anyhow::Result<ResponsePayload> {
            match request.command {
                Command::SaveTaskState { sessions, .. } => {
                    let mut stored = self.sessions.lock();
                    for session in sessions {
                        if let Some(existing) =
                            stored.iter_mut().find(|existing| existing.id == session.id)
                        {
                            *existing = session;
                        } else {
                            stored.push(session);
                        }
                    }
                    Ok(ResponsePayload::TaskStateSaved {
                        sessions: stored.clone(),
                    })
                }
                Command::LoadTaskState => Ok(ResponsePayload::TaskState {
                    projects: Vec::new(),
                    sessions: self.sessions.lock().clone(),
                    default_cwd: PathBuf::from("/tmp"),
                    projectless_root: Some(PathBuf::from("/tmp/.shidou/projects")),
                }),
                _ => Ok(ResponsePayload::Ack),
            }
        }
    }

    #[test]
    fn task_state_revisions_notify_other_clients_only() {
        let hub = Hub::default();
        let (source_tx, source_rx) = unbounded();
        let source_id = hub.subscribe(&[], source_tx);
        let (observer_tx, observer_rx) = unbounded();
        hub.subscribe(&[], observer_tx);

        hub.task_state_changed(source_id);

        assert!(source_rx.try_recv().is_err());
        assert!(matches!(
            observer_rx.recv_timeout(Duration::from_secs(1)),
            Ok(ServerMessage::TaskStateChanged { revision: 1 })
        ));
    }

    #[test]
    fn websocket_task_state_changes_reach_another_client() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let shutdown = Arc::new(AtomicBool::new(false));
        let server_shutdown = shutdown.clone();
        let server = std::thread::spawn(move || {
            serve(
                listener,
                "secret".into(),
                Arc::new(TaskStateBackend::default()),
                server_shutdown,
                ServerOptions {
                    allow_shutdown: true,
                    ..ServerOptions::default()
                },
            )
            .unwrap()
        });

        let source = DaemonClient::connect(&address.to_string(), "secret".into()).unwrap();
        let observer = DaemonClient::connect(&address.to_string(), "secret".into()).unwrap();
        let source_revisions = source.subscribe_task_state();
        let observer_revisions = observer.subscribe_task_state();
        let session = AgentSession::new(Uuid::new_v4(), ProviderKind::Codex);
        let session_id = session.id;

        assert!(matches!(
            source
                .request(
                    Uuid::nil(),
                    Uuid::nil(),
                    Command::SaveTaskState {
                        projects: Vec::new(),
                        live_session_ids: vec![session_id],
                        sessions: vec![session],
                    },
                )
                .unwrap(),
            ResponsePayload::TaskStateSaved { .. }
        ));
        assert_eq!(
            observer_revisions.recv_timeout(Duration::from_secs(1)),
            Ok(1)
        );
        assert!(source_revisions.try_recv().is_err());
        let ResponsePayload::TaskState { sessions, .. } = observer
            .request(Uuid::nil(), Uuid::nil(), Command::LoadTaskState)
            .unwrap()
        else {
            panic!("expected daemon task state");
        };
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].id, session_id);

        // Streaming checkpoints update transcript detail and `updated_at`,
        // but do not change anything rendered in another client's task
        // catalog. They must not trigger a list reload for every stream save.
        let mut checkpoint = sessions[0].clone();
        checkpoint.updated_at = checkpoint.updated_at.saturating_add(1);
        source
            .request(
                Uuid::nil(),
                Uuid::nil(),
                Command::SaveTaskState {
                    projects: Vec::new(),
                    live_session_ids: vec![session_id],
                    sessions: vec![checkpoint],
                },
            )
            .unwrap();
        assert!(
            observer_revisions
                .recv_timeout(Duration::from_millis(100))
                .is_err()
        );

        // Desktop persistence uses fire-and-forget notifications, while Web
        // uses requests. Both directions must wake the other application's
        // catalog without echoing back to the source connection.
        let second = AgentSession::new(Uuid::new_v4(), ProviderKind::Claude);
        let second_id = second.id;
        observer
            .notify(
                Uuid::nil(),
                Uuid::nil(),
                Command::SaveTaskState {
                    projects: Vec::new(),
                    live_session_ids: vec![session_id, second_id],
                    sessions: vec![second],
                },
            )
            .unwrap();
        assert_eq!(source_revisions.recv_timeout(Duration::from_secs(1)), Ok(2));
        assert!(observer_revisions.try_recv().is_err());
        let ResponsePayload::TaskState { sessions, .. } = source
            .request(Uuid::nil(), Uuid::nil(), Command::LoadTaskState)
            .unwrap()
        else {
            panic!("expected daemon task state");
        };
        assert_eq!(sessions.len(), 2);
        assert!(sessions.iter().any(|session| session.id == second_id));

        source.shutdown();
        server.join().unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn stale_projection_cannot_resurrect_a_removed_session() {
        let daemon = ShidouTestDaemon::new("remove-race", |_| {});
        let stale_client = daemon.connect();
        let remover = daemon.connect();
        let project = Project::from_path(daemon.root.join("repo"));
        let mut session = AgentSession::new(project.id, ProviderKind::Codex);
        session.begin_turn("persist me");
        stale_client
            .request(
                Uuid::nil(),
                Uuid::nil(),
                Command::SaveTaskState {
                    projects: vec![project.clone()],
                    live_session_ids: vec![session.id],
                    sessions: vec![session.clone()],
                },
            )
            .unwrap();
        remover
            .request(session.id, Uuid::nil(), Command::RemoveSession)
            .unwrap();
        let ResponsePayload::TaskStateSaved { sessions } = stale_client
            .request(
                Uuid::nil(),
                Uuid::nil(),
                Command::SaveTaskState {
                    projects: vec![project],
                    live_session_ids: vec![session.id],
                    sessions: vec![session],
                },
            )
            .unwrap()
        else {
            panic!("expected task-state save response");
        };
        assert!(sessions.is_empty());
        let ResponsePayload::TaskState { sessions, .. } = stale_client
            .request(Uuid::nil(), Uuid::nil(), Command::LoadTaskState)
            .unwrap()
        else {
            panic!("expected task state");
        };
        assert!(sessions.is_empty());
    }

    /// Persists one started, quiet task through the wire, the way a client
    /// does before it can archive anything.
    #[cfg(unix)]
    fn persist_task(client: &DaemonClient, project: &Project) -> AgentSession {
        persist_task_with_status(client, project, SessionStatus::Idle)
    }

    #[cfg(unix)]
    fn try_archive(
        client: &DaemonClient,
        session_id: Uuid,
        archived: bool,
    ) -> anyhow::Result<ResponsePayload> {
        client.request(
            session_id,
            Uuid::nil(),
            Command::ArchiveSession { archived },
        )
    }

    #[cfg(unix)]
    fn archive(client: &DaemonClient, session_id: Uuid, archived: bool) {
        try_archive(client, session_id, archived).unwrap();
    }

    /// Persists one started task already in the given state, the way a client
    /// reports a runtime it is driving.
    #[cfg(unix)]
    fn persist_task_with_status(
        client: &DaemonClient,
        project: &Project,
        status: SessionStatus,
    ) -> AgentSession {
        let mut session = AgentSession::new(project.id, ProviderKind::Codex);
        session.begin_turn("shelve me");
        session.status = status;
        client
            .request(
                Uuid::nil(),
                Uuid::nil(),
                Command::SaveTaskState {
                    projects: vec![project.clone()],
                    live_session_ids: vec![session.id],
                    sessions: vec![session.clone()],
                },
            )
            .unwrap();
        session
    }

    #[cfg(unix)]
    fn archived_at(client: &DaemonClient, session_id: Uuid) -> Option<u64> {
        let ResponsePayload::TaskState { sessions, .. } = client
            .request(Uuid::nil(), Uuid::nil(), Command::LoadTaskState)
            .unwrap()
        else {
            panic!("expected task state");
        };
        sessions
            .into_iter()
            .find(|session| session.id == session_id)
            .expect("the task is listed")
            .archived_at
    }

    #[cfg(unix)]
    #[test]
    fn the_archive_command_marks_a_task_and_clears_it_again() {
        let daemon = ShidouTestDaemon::new("archive-mark", |_| {});
        let client = daemon.connect();
        let project = Project::from_path(daemon.root.join("repo"));
        let session = persist_task(&client, &project);

        assert_eq!(
            archived_at(&client, session.id),
            None,
            "an existing task starts unarchived"
        );

        archive(&client, session.id, true);
        assert!(archived_at(&client, session.id).is_some());

        archive(&client, session.id, false);
        assert_eq!(
            archived_at(&client, session.id),
            None,
            "unarchiving clears the mark rather than suppressing it"
        );
    }

    /// Only the command writes the mark. A snapshot save carrying one is not a
    /// second way in, not even for a task the daemon has never seen before.
    #[cfg(unix)]
    #[test]
    fn a_snapshot_save_cannot_set_the_archive_mark() {
        let daemon = ShidouTestDaemon::new("archive-claim", |_| {});
        let client = daemon.connect();
        let project = Project::from_path(daemon.root.join("repo"));
        let mut claiming = AgentSession::new(project.id, ProviderKind::Codex);
        claiming.begin_turn("already shelved");
        claiming.archived_at = Some(1);
        client
            .request(
                Uuid::nil(),
                Uuid::nil(),
                Command::SaveTaskState {
                    projects: vec![project],
                    live_session_ids: vec![claiming.id],
                    sessions: vec![claiming.clone()],
                },
            )
            .unwrap();
        assert_eq!(archived_at(&client, claiming.id), None);
    }

    #[cfg(unix)]
    #[test]
    fn a_stale_snapshot_cannot_clear_an_archive_mark() {
        let daemon = ShidouTestDaemon::new("archive-race", |_| {});
        let stale_client = daemon.connect();
        let archiver = daemon.connect();
        let project = Project::from_path(daemon.root.join("repo"));
        let session = persist_task(&stale_client, &project);

        archive(&archiver, session.id, true);
        let marked_at = archived_at(&stale_client, session.id).expect("the task is archived");

        // The snapshot the second client is still holding predates the mark,
        // and saving it advances the projection — the branch that replaces the
        // whole session.
        let mut stale = session.clone();
        stale.archived_at = None;
        stale.updated_at = stale.updated_at.saturating_add(1);
        let ResponsePayload::TaskStateSaved { sessions } = stale_client
            .request(
                Uuid::nil(),
                Uuid::nil(),
                Command::SaveTaskState {
                    projects: vec![project],
                    live_session_ids: vec![stale.id],
                    sessions: vec![stale],
                },
            )
            .unwrap()
        else {
            panic!("expected task-state save response");
        };
        assert_eq!(sessions[0].archived_at, Some(marked_at));
        assert_eq!(archived_at(&stale_client, session.id), Some(marked_at));
    }

    #[cfg(unix)]
    #[test]
    fn the_archive_mark_survives_a_daemon_restart() {
        let mut daemon = ShidouTestDaemon::new("archive-restart", |_| {});
        let session = {
            let client = daemon.connect();
            let project = Project::from_path(daemon.root.join("repo"));
            let session = persist_task(&client, &project);
            archive(&client, session.id, true);
            session
        };
        let marked_at = {
            let client = daemon.connect();
            archived_at(&client, session.id).expect("the task is archived")
        };

        daemon.restart();

        let reconnected = daemon.connect();
        assert_eq!(archived_at(&reconnected, session.id), Some(marked_at));
    }

    #[cfg(unix)]
    #[test]
    fn archiving_reaches_a_second_client() {
        let daemon = ShidouTestDaemon::new("archive-broadcast", |_| {});
        let archiver = daemon.connect();
        let observer = daemon.connect();
        let observed_revisions = observer.subscribe_task_state();
        let project = Project::from_path(daemon.root.join("repo"));
        let session = persist_task(&archiver, &project);
        let saved_revision = observed_revisions
            .recv_timeout(Duration::from_secs(1))
            .expect("the save reaches the observer");

        archive(&archiver, session.id, true);

        assert!(
            observed_revisions
                .recv_timeout(Duration::from_secs(1))
                .is_ok_and(|revision| revision > saved_revision),
            "archiving invalidates the observer's task catalog"
        );
        assert!(archived_at(&observer, session.id).is_some());
    }

    #[cfg(unix)]
    #[test]
    fn archiving_a_working_task_is_refused() {
        let daemon = ShidouTestDaemon::new("archive-working", |_| {});
        let client = daemon.connect();
        let project = Project::from_path(daemon.root.join("repo"));
        let session = persist_task_with_status(&client, &project, SessionStatus::Working);

        let error = try_archive(&client, session.id, true).expect_err("a Working task is refused");

        assert!(
            shidou_client::refusal(&error).is_some(),
            "a refusal is not a transport failure: {error}"
        );
        assert_eq!(archived_at(&client, session.id), None);
    }

    #[cfg(unix)]
    #[test]
    fn archiving_a_waiting_task_is_refused() {
        let daemon = ShidouTestDaemon::new("archive-waiting", |_| {});
        let client = daemon.connect();
        let project = Project::from_path(daemon.root.join("repo"));
        let session = persist_task_with_status(&client, &project, SessionStatus::Waiting);

        let error = try_archive(&client, session.id, true).expect_err("a Waiting task is refused");

        assert!(
            shidou_client::refusal(&error).is_some(),
            "a refusal is not a transport failure: {error}"
        );
        assert_eq!(archived_at(&client, session.id), None);
    }

    /// A refusal is the guard surfacing, so a client shows it and stops. A
    /// daemon it could not reach, and a daemon that simply failed, are both
    /// things a client may retry, so neither may look like a refusal.
    #[cfg(unix)]
    #[test]
    fn only_a_refusal_reads_as_a_refusal() {
        let client = {
            let daemon = ShidouTestDaemon::new("archive-refusal-kind", |_| {});
            let client = daemon.connect();
            let project = Project::from_path(daemon.root.join("repo"));
            let session = persist_task_with_status(&client, &project, SessionStatus::Working);

            let refused = try_archive(&client, session.id, true).expect_err("refused");
            assert!(shidou_client::refusal(&refused).is_some());

            // A task the daemon has never heard of fails, but not by refusal:
            // nothing about the request was declined on its merits.
            let missing =
                try_archive(&client, Uuid::new_v4(), true).expect_err("unknown task fails");
            assert!(
                shidou_client::refusal(&missing).is_none(),
                "an ordinary failure carries no refusal: {missing}"
            );
            client
        };

        // The daemon is gone now. Reaching a daemon that is not there is the
        // case a client retries, so it must not read as a refusal either.
        let unreachable =
            try_archive(&client, Uuid::new_v4(), true).expect_err("a stopped daemon fails");
        assert!(
            shidou_client::refusal(&unreachable).is_none(),
            "a transport failure carries no refusal: {unreachable}"
        );
    }

    /// Unarchiving can only bring a task back into view, so no state of the
    /// task is a reason to decline it.
    #[cfg(unix)]
    #[test]
    fn unarchiving_is_never_refused() {
        let daemon = ShidouTestDaemon::new("archive-unarchive-busy", |_| {});
        let client = daemon.connect();
        let project = Project::from_path(daemon.root.join("repo"));
        let session = persist_task(&client, &project);
        archive(&client, session.id, true);

        // The task starts working while it sits on the shelf.
        let mut working = session.clone();
        working.status = SessionStatus::Working;
        working.updated_at = working.updated_at.saturating_add(1);
        client
            .request(
                Uuid::nil(),
                Uuid::nil(),
                Command::SaveTaskState {
                    projects: vec![project],
                    live_session_ids: vec![working.id],
                    sessions: vec![working],
                },
            )
            .unwrap();

        try_archive(&client, session.id, false).expect("unarchiving a Working task is allowed");
        assert_eq!(archived_at(&client, session.id), None);
    }

    /// Reports the task as Working the way the client driving it does. An
    /// archived task reaches this state through the race the guard cannot
    /// prevent: the archive landed in the instant between another client
    /// starting a turn and the daemon hearing the runtime's first word.
    #[cfg(unix)]
    fn report_working(client: &DaemonClient, project: &Project, session: &AgentSession) {
        let mut working = session.clone();
        working.status = SessionStatus::Working;
        working.updated_at = working.updated_at.saturating_add(1);
        client
            .request(
                Uuid::nil(),
                Uuid::nil(),
                Command::SaveTaskState {
                    projects: vec![project.clone()],
                    live_session_ids: vec![working.id],
                    sessions: vec![working],
                },
            )
            .unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn a_user_prompt_returns_an_archived_task() {
        let daemon = ShidouTestDaemon::new("archive-prompt", |_| {});
        let client = daemon.connect();
        let project = Project::from_path(daemon.root.join("repo"));
        let session = persist_task(&client, &project);
        archive(&client, session.id, true);
        let runtime_id = daemon.start_runtime(&client, session.id);

        client
            .request(
                session.id,
                runtime_id,
                Command::Prompt {
                    prompt: "carry on".into(),
                    submission_id: Uuid::new_v4(),
                },
            )
            .unwrap();

        assert_eq!(
            archived_at(&client, session.id),
            None,
            "resuming work brings the task back with it"
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_turn_start_returns_an_archived_task() {
        let daemon = ShidouTestDaemon::new("archive-turn-start", |_| {});
        let client = daemon.connect();
        let project = Project::from_path(daemon.root.join("repo"));
        let session = persist_task(&client, &project);
        archive(&client, session.id, true);
        daemon.start_runtime(&client, session.id);

        daemon.emit(session.id, WireDriverEvent::new("turnStarted", json!(null)));

        assert_eq!(archived_at(&client, session.id), None);
    }

    #[cfg(unix)]
    #[test]
    fn a_permission_request_returns_an_archived_task() {
        let daemon = ShidouTestDaemon::new("archive-permission", |_| {});
        let client = daemon.connect();
        let project = Project::from_path(daemon.root.join("repo"));
        let session = persist_task(&client, &project);
        archive(&client, session.id, true);
        daemon.start_runtime(&client, session.id);
        report_working(&client, &project, &session);

        daemon.emit(
            session.id,
            WireDriverEvent::new(
                "permission",
                json!({
                    "requestId": "permission-1",
                    "title": "Run the tests",
                    "detail": "cargo test",
                    "options": [{ "id": "allow", "label": "Allow", "allow": true }]
                }),
            ),
        );

        assert_eq!(
            archived_at(&client, session.id),
            None,
            "blocked work can never sit unseen in the shelf"
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_question_returns_an_archived_task() {
        let daemon = ShidouTestDaemon::new("archive-question", |_| {});
        let client = daemon.connect();
        let project = Project::from_path(daemon.root.join("repo"));
        let session = persist_task(&client, &project);
        archive(&client, session.id, true);
        daemon.start_runtime(&client, session.id);
        report_working(&client, &project, &session);

        daemon.emit(
            session.id,
            WireDriverEvent::new(
                "userInputRequested",
                json!({
                    "requestId": "question-1",
                    "questions": [{
                        "id": "direction",
                        "header": "Direction",
                        "question": "Which way?",
                        "options": [{ "label": "Left" }],
                        "multiSelect": false
                    }]
                }),
            ),
        );

        assert_eq!(archived_at(&client, session.id), None);
    }

    #[cfg(unix)]
    #[test]
    fn a_runtime_failure_returns_an_archived_task() {
        let daemon = ShidouTestDaemon::new("archive-failure", |_| {});
        let client = daemon.connect();
        let project = Project::from_path(daemon.root.join("repo"));
        let session = persist_task(&client, &project);
        archive(&client, session.id, true);
        daemon.start_runtime(&client, session.id);

        daemon.emit(
            session.id,
            WireDriverEvent::new("error", json!("the provider gave up")),
        );

        assert_eq!(
            archived_at(&client, session.id),
            None,
            "a failure is never silent"
        );
    }

    /// Bookkeeping is not activity. A user renaming a shelved task is tidying
    /// it, not returning to it.
    #[cfg(unix)]
    #[test]
    fn a_rename_leaves_a_task_archived() {
        let daemon = ShidouTestDaemon::new("archive-rename", |_| {});
        let client = daemon.connect();
        let project = Project::from_path(daemon.root.join("repo"));
        let session = persist_task(&client, &project);
        archive(&client, session.id, true);
        let marked_at = archived_at(&client, session.id).expect("the task is archived");

        let mut renamed = session.clone();
        renamed.title = "Renamed on the shelf".into();
        renamed.updated_at = renamed.updated_at.saturating_add(1);
        client
            .request(
                Uuid::nil(),
                Uuid::nil(),
                Command::SaveTaskState {
                    projects: vec![project],
                    live_session_ids: vec![renamed.id],
                    sessions: vec![renamed],
                },
            )
            .unwrap();

        assert_eq!(archived_at(&client, session.id), Some(marked_at));
    }

    /// The provider retitling a shelved task is the same kind of background
    /// bookkeeping, and it must not drag old work back either.
    #[cfg(unix)]
    #[test]
    fn an_automatic_title_leaves_a_task_archived() {
        let daemon = ShidouTestDaemon::new("archive-auto-title", |_| {});
        let client = daemon.connect();
        let project = Project::from_path(daemon.root.join("repo"));
        let session = persist_task(&client, &project);
        archive(&client, session.id, true);
        let marked_at = archived_at(&client, session.id).expect("the task is archived");
        daemon.start_runtime(&client, session.id);

        daemon.emit(
            session.id,
            WireDriverEvent::new("autoTitleUpdated", json!("A better title")),
        );

        assert_eq!(archived_at(&client, session.id), Some(marked_at));
    }

    #[cfg(unix)]
    #[test]
    fn a_returning_task_reaches_a_second_client() {
        let daemon = ShidouTestDaemon::new("archive-return-broadcast", |_| {});
        let client = daemon.connect();
        let observer = daemon.connect();
        let observed_revisions = observer.subscribe_task_state();
        let project = Project::from_path(daemon.root.join("repo"));
        let session = persist_task(&client, &project);
        observed_revisions
            .recv_timeout(Duration::from_secs(1))
            .expect("the save reaches the observer");
        archive(&client, session.id, true);
        let archived_revision = observed_revisions
            .recv_timeout(Duration::from_secs(1))
            .expect("the archive reaches the observer");
        daemon.start_runtime(&client, session.id);

        daemon.emit(session.id, WireDriverEvent::new("turnStarted", json!(null)));

        assert!(
            observed_revisions
                .recv_timeout(Duration::from_secs(1))
                .is_ok_and(|revision| revision > archived_revision),
            "the clear invalidates the observer's task catalog"
        );
        assert_eq!(archived_at(&observer, session.id), None);
    }

    #[cfg(unix)]
    #[test]
    fn archiving_a_quiet_task_still_succeeds() {
        let daemon = ShidouTestDaemon::new("archive-quiet", |_| {});
        let client = daemon.connect();
        let project = Project::from_path(daemon.root.join("repo"));
        let session = persist_task_with_status(&client, &project, SessionStatus::Failed);

        try_archive(&client, session.id, true).expect("a task that is not busy can be archived");
        assert!(archived_at(&client, session.id).is_some());
    }

    #[cfg(unix)]
    #[test]
    fn generic_save_cannot_remove_canonical_transcript_blocks() {
        let daemon = ShidouTestDaemon::new("transcript-block-race", |_| {});
        let client = daemon.connect();
        let project = Project::from_path(daemon.root.join("repo"));
        let mut canonical = AgentSession::new(project.id, ProviderKind::Claude);
        let turn_id = canonical.begin_turn("inspect it");
        canonical.transcript_blocks.push(TranscriptBlock {
            after_message: 1,
            turn_id: Some(turn_id),
            activities: vec![ActivityItem::new(
                Some("tool-1".into()),
                ActivityKind::FileRead,
                "Read file",
                None,
                true,
            )],
        });
        canonical.finish_active_turn(crate::model::TurnStatus::Completed);
        client
            .request(
                Uuid::nil(),
                Uuid::nil(),
                Command::SaveTaskState {
                    projects: vec![project],
                    live_session_ids: vec![canonical.id],
                    sessions: vec![canonical.clone()],
                },
            )
            .unwrap();

        let mut stale = canonical.clone();
        stale.transcript_blocks.clear();
        stale.updated_at = canonical.updated_at.saturating_add(1);
        let ResponsePayload::TaskStateSaved { sessions } = client
            .request(
                Uuid::nil(),
                Uuid::nil(),
                Command::SaveTaskState {
                    projects: Vec::new(),
                    live_session_ids: vec![stale.id],
                    sessions: vec![stale],
                },
            )
            .unwrap()
        else {
            panic!("expected task-state save response");
        };

        assert_eq!(sessions[0].transcript_blocks.len(), 1);
        assert_eq!(
            sessions[0].transcript_blocks[0].activities[0].title,
            "Read file"
        );

        let mut stale = sessions[0].clone();
        stale.transcript_blocks[0].activities.clear();
        stale.updated_at = stale.updated_at.saturating_add(1);
        let ResponsePayload::TaskStateSaved { sessions } = client
            .request(
                Uuid::nil(),
                Uuid::nil(),
                Command::SaveTaskState {
                    projects: Vec::new(),
                    live_session_ids: vec![stale.id],
                    sessions: vec![stale],
                },
            )
            .unwrap()
        else {
            panic!("expected task-state save response");
        };
        assert_eq!(sessions[0].transcript_blocks[0].activities.len(), 1);
    }

    #[cfg(unix)]
    #[test]
    fn stale_save_can_append_a_client_turn_when_old_message_state_differs() {
        let runtime_id = Uuid::new_v4();
        let epoch = Uuid::new_v4();
        let mut canonical = AgentSession::new(Uuid::new_v4(), ProviderKind::Claude);
        canonical.status = crate::model::SessionStatus::Working;
        let daemon = ShidouTestDaemon::new("client-turn-race", |backend| {
            backend.set_active_runtime_for_test(canonical.id, runtime_id);
        });
        let client = daemon.connect();
        canonical.begin_turn("first");
        canonical.push_message(crate::model::MessageRole::Assistant, "first response");
        canonical.finish_active_turn(crate::model::TurnStatus::Completed);
        canonical.runtime_event_cursor = Some(crate::model::RuntimeEventCursor {
            runtime_id,
            epoch,
            sequence: 168,
        });
        client
            .request(
                Uuid::nil(),
                Uuid::nil(),
                Command::SaveTaskState {
                    projects: Vec::new(),
                    live_session_ids: vec![canonical.id],
                    sessions: vec![canonical.clone()],
                },
            )
            .unwrap();

        let ResponsePayload::Session {
            session: Some(hydrated),
        } = client
            .request(
                Uuid::nil(),
                Uuid::nil(),
                Command::HydrateSession {
                    session_id: canonical.id,
                },
            )
            .unwrap()
        else {
            panic!("expected hydrated session");
        };
        assert_eq!(hydrated.messages[0].id, canonical.messages[0].id);
        assert_eq!(hydrated.turns[0].id, canonical.turns[0].id);

        let mut incoming = hydrated;
        incoming.messages[1].streaming = true;
        incoming.begin_turn("come again");
        incoming.push_message(crate::model::MessageRole::Assistant, "session limit");
        incoming.finish_active_turn(crate::model::TurnStatus::Failed);
        incoming.status = crate::model::SessionStatus::Failed;
        incoming.runtime_event_cursor = Some(crate::model::RuntimeEventCursor {
            runtime_id,
            epoch,
            sequence: 167,
        });
        let ResponsePayload::TaskStateSaved { sessions } = client
            .request(
                Uuid::nil(),
                Uuid::nil(),
                Command::SaveTaskState {
                    projects: Vec::new(),
                    live_session_ids: vec![incoming.id],
                    sessions: vec![incoming],
                },
            )
            .unwrap()
        else {
            panic!("expected task-state save response");
        };

        assert!(
            sessions[0]
                .messages
                .iter()
                .any(|message| message.content == "come again")
        );
        assert_eq!(sessions[0].turns.len(), 2);
        assert_eq!(sessions[0].status, crate::model::SessionStatus::Failed);

        canonical.messages[1].content.clear();
        let ResponsePayload::TaskStateSaved { sessions } = client
            .request(
                Uuid::nil(),
                Uuid::nil(),
                Command::SaveTaskState {
                    projects: Vec::new(),
                    live_session_ids: vec![canonical.id],
                    sessions: vec![canonical],
                },
            )
            .unwrap()
        else {
            panic!("expected task-state save response");
        };
        assert_eq!(
            sessions[0].turns.len(),
            2,
            "an equal-cursor save shrank history"
        );
        assert!(
            sessions[0]
                .messages
                .iter()
                .any(|message| message.content == "first response"),
            "an equal-cursor save erased canonical message content"
        );

        let mut replaced_runtime = sessions[0].clone();
        replaced_runtime.begin_turn("one more time");
        replaced_runtime.status = crate::model::SessionStatus::Connecting;
        replaced_runtime.updated_at = replaced_runtime.updated_at.saturating_add(1);
        replaced_runtime.runtime_event_cursor = Some(crate::model::RuntimeEventCursor {
            runtime_id: Uuid::new_v4(),
            epoch: Uuid::new_v4(),
            sequence: 1,
        });
        let ResponsePayload::TaskStateSaved { sessions } = client
            .request(
                Uuid::nil(),
                Uuid::nil(),
                Command::SaveTaskState {
                    projects: Vec::new(),
                    live_session_ids: vec![replaced_runtime.id],
                    sessions: vec![replaced_runtime],
                },
            )
            .unwrap()
        else {
            panic!("expected task-state save response");
        };
        assert_eq!(sessions[0].turns.len(), 3);
        assert_eq!(
            sessions[0].runtime_event_cursor,
            Some(crate::model::RuntimeEventCursor {
                runtime_id,
                epoch,
                sequence: 168,
            })
        );
    }

    #[test]
    fn websocket_round_trip_sequences_provider_events() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let shutdown = Arc::new(AtomicBool::new(false));
        let server_shutdown = shutdown.clone();
        let server = std::thread::spawn(move || {
            serve(
                listener,
                "secret".into(),
                Arc::new(TestBackend::default()),
                server_shutdown,
                ServerOptions {
                    allow_shutdown: true,
                    ..ServerOptions::default()
                },
            )
            .unwrap()
        });

        assert!(
            DaemonClient::connect(&address.to_string(), "wrong-secret".into()).is_err(),
            "the server must reject a client before it can issue requests"
        );
        let client = DaemonClient::connect(&address.to_string(), "secret".into()).unwrap();
        let session_id = Uuid::new_v4();
        let runtime_id = Uuid::new_v4();
        let response = client
            .request(
                session_id,
                runtime_id,
                Command::Start {
                    options: WireDriverStartOptions {
                        provider: "codex".into(),
                        binary: PathBuf::from("codex"),
                        cwd: PathBuf::from("."),
                        mode: "fullAccess".into(),
                        interaction_mode: "build".into(),
                        model: None,
                        reasoning_effort: None,
                        service_tier: None,
                        context_window: None,
                        agent_preset: None,
                        computer_use_enabled: false,
                        provider_cursor: None,
                    },
                },
            )
            .unwrap();
        assert!(matches!(
            response,
            ResponsePayload::Started {
                supports_steer: true
            }
        ));
        // Start can emit before a refreshed app discovers and subscribes to
        // the daemon-owned runtime. The client must retain that replay.
        let events = client.subscribe(session_id, runtime_id);
        let event = events.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(event.runtime_id, runtime_id);
        assert_eq!(event.sequence, 1);
        assert_eq!(event.event.kind, "connected");

        client.shutdown();
        let exited = events.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(exited.runtime_id, runtime_id);
        assert_eq!(exited.event.kind, "processExited");
        server.join().unwrap();
    }

    /// A runtime closed while a turn is running must not take the turn's end
    /// with it: every connected client hears a failed turnFinished, or a
    /// phone left on the turn spins forever.
    #[test]
    fn closing_a_runtime_mid_turn_settles_the_turn_for_every_client() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let shutdown = Arc::new(AtomicBool::new(false));
        let server_shutdown = shutdown.clone();
        let server = std::thread::spawn(move || {
            serve(
                listener,
                "secret".into(),
                Arc::new(TestBackend::default()),
                server_shutdown,
                ServerOptions {
                    allow_shutdown: true,
                    ..ServerOptions::default()
                },
            )
            .unwrap()
        });

        let client = DaemonClient::connect(&address.to_string(), "secret".into()).unwrap();
        let observer = DaemonClient::connect(&address.to_string(), "secret".into()).unwrap();
        let session_id = Uuid::new_v4();
        let runtime_id = Uuid::new_v4();
        let observer_events = observer.subscribe(session_id, runtime_id);
        client
            .request(
                session_id,
                runtime_id,
                Command::Start {
                    options: WireDriverStartOptions {
                        provider: "codex".into(),
                        binary: PathBuf::from("codex"),
                        cwd: PathBuf::from("."),
                        mode: "fullAccess".into(),
                        interaction_mode: "build".into(),
                        model: None,
                        reasoning_effort: None,
                        service_tier: None,
                        context_window: None,
                        agent_preset: None,
                        computer_use_enabled: false,
                        provider_cursor: None,
                    },
                },
            )
            .unwrap();
        assert_eq!(
            observer_events
                .recv_timeout(Duration::from_secs(1))
                .unwrap()
                .event
                .kind,
            "connected"
        );

        client
            .request(session_id, runtime_id, Command::CloseSession)
            .unwrap();

        let settled = observer_events
            .recv_timeout(Duration::from_secs(1))
            .unwrap();
        assert_eq!(settled.event.kind, "turnFinished");
        assert_eq!(settled.event.payload["success"], json!(false));
        assert!(observer_events.try_recv().is_err());

        client.shutdown();
        observer.shutdown();
        shutdown.store(true, Ordering::Release);
        server.join().unwrap();
    }

    #[test]
    fn late_client_attaches_to_replay_and_live_runtime_events() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let shutdown = Arc::new(AtomicBool::new(false));
        let server_shutdown = shutdown.clone();
        let server = std::thread::spawn(move || {
            serve(
                listener,
                "secret".into(),
                Arc::new(TestBackend::default()),
                server_shutdown,
                ServerOptions {
                    allow_shutdown: true,
                    ..ServerOptions::default()
                },
            )
            .unwrap()
        });

        let source = DaemonClient::connect(&address.to_string(), "secret".into()).unwrap();
        let session_id = Uuid::new_v4();
        let runtime_id = Uuid::new_v4();
        let source_events = source.subscribe(session_id, runtime_id);
        source
            .request(
                session_id,
                runtime_id,
                Command::Start {
                    options: WireDriverStartOptions {
                        provider: "codex".into(),
                        binary: PathBuf::from("codex"),
                        cwd: PathBuf::from("."),
                        mode: "fullAccess".into(),
                        interaction_mode: "build".into(),
                        model: None,
                        reasoning_effort: None,
                        service_tier: None,
                        context_window: None,
                        agent_preset: None,
                        computer_use_enabled: false,
                        provider_cursor: None,
                    },
                },
            )
            .unwrap();
        assert_eq!(
            source_events
                .recv_timeout(Duration::from_secs(1))
                .unwrap()
                .event
                .kind,
            "connected"
        );

        let late = DaemonClient::connect(&address.to_string(), "secret".into()).unwrap();
        assert!(matches!(
            late.request(session_id, Uuid::nil(), Command::AttachSession)
                .unwrap(),
            ResponsePayload::SessionRuntime {
                runtime_id: Some(attached),
                supports_steer: true,
            } if attached == runtime_id
        ));
        let late_events = late.subscribe(session_id, runtime_id);
        let replayed = late_events.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(replayed.sequence, 1);
        assert_eq!(replayed.event.kind, "connected");

        source
            .request(
                session_id,
                runtime_id,
                Command::Prompt {
                    submission_id: Uuid::new_v4(),
                    prompt: "streamed from the first client".into(),
                },
            )
            .unwrap();
        for events in [&source_events, &late_events] {
            let live = events.recv_timeout(Duration::from_secs(1)).unwrap();
            assert_eq!(live.sequence, 2);
            assert_eq!(live.event.kind, "textDelta");
            assert_eq!(live.event.payload, json!("streamed from the first client"));
        }

        source
            .request(
                session_id,
                runtime_id,
                Command::Prompt {
                    submission_id: Uuid::new_v4(),
                    prompt: "__test_question__".into(),
                },
            )
            .unwrap();
        for events in [&source_events, &late_events] {
            let question = events.recv_timeout(Duration::from_secs(1)).unwrap();
            assert_eq!(question.sequence, 3);
            assert_eq!(question.event.kind, "userInputRequested");
        }
        // The second client answers. Every subscriber must learn that the
        // interaction is no longer pending before provider output resumes.
        late.request(
            session_id,
            runtime_id,
            Command::RespondUserInput {
                request_id: "question-1".into(),
                answers: Vec::new(),
            },
        )
        .unwrap();
        for events in [&source_events, &late_events] {
            let resolved = events.recv_timeout(Duration::from_secs(1)).unwrap();
            assert_eq!(resolved.sequence, 4);
            assert_eq!(resolved.event.kind, "interactionResolved");
            assert_eq!(resolved.event.payload["requestId"], "question-1");
        }
        let (_, pending_interaction, _replacement) =
            source.subscribe_runtime(session_id, runtime_id);
        assert!(
            pending_interaction.is_none(),
            "the first client retained a question answered by the second"
        );

        source
            .request(session_id, runtime_id, Command::CloseSession)
            .unwrap();
        let after_close = DaemonClient::connect(&address.to_string(), "secret".into()).unwrap();
        assert!(matches!(
            after_close
                .request(session_id, Uuid::nil(), Command::AttachSession)
                .unwrap(),
            ResponsePayload::SessionRuntime {
                runtime_id: None,
                supports_steer: true,
            }
        ));
        let stale_events = after_close.subscribe(session_id, runtime_id);
        assert!(
            stale_events
                .recv_timeout(Duration::from_millis(100))
                .is_err(),
            "an explicitly closed runtime must not replay into future clients"
        );

        source.shutdown();
        server.join().unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn dropping_an_idle_terminal_does_not_wait_for_output() {
        let root = std::env::temp_dir().join(format!("shidou-terminal-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let hub = Arc::new(Hub::default());
        let terminal = crate::terminal::DaemonTerminal::open(
            &root,
            80,
            24,
            hub.event_sink(Uuid::new_v4(), Uuid::new_v4()),
        )
        .unwrap();
        let (dropped, finished) = bounded(1);
        std::thread::spawn(move || {
            drop(terminal);
            let _ = dropped.send(());
        });

        assert!(
            finished.recv_timeout(Duration::from_secs(3)).is_ok(),
            "dropping an idle daemon terminal blocked on its output reader"
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn finished_reader_does_not_mask_a_live_hup_ignoring_child() {
        let root = std::env::temp_dir().join(format!("shidou-terminal-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let hub = Arc::new(Hub::default());
        let session_id = Uuid::new_v4();
        let runtime_id = Uuid::new_v4();
        hub.begin_runtime(session_id, runtime_id);
        let (outgoing, events) = unbounded();
        hub.subscribe(&[], outgoing);
        let mut terminal = crate::terminal::DaemonTerminal::open(
            &root,
            80,
            24,
            hub.event_sink(session_id, runtime_id),
        )
        .unwrap();
        terminal
            .write(
                b"exec sh -c \"trap '' HUP; printf 'SHIDOU_%s\\n' READER_STOPPED; while :; do sleep 1; done\"\r"
                    .to_vec(),
            )
            .unwrap();

        let marker = b"SHIDOU_READER_STOPPED";
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        let mut output = Vec::new();
        while std::time::Instant::now() < deadline
            && !output.windows(marker.len()).any(|window| window == marker)
        {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            let Ok(ServerMessage::Event(event)) = events.recv_timeout(remaining) else {
                continue;
            };
            if event.event.kind == "terminalOutput" {
                let data = event.event.payload["data"].as_str().unwrap();
                output.extend(
                    base64::engine::general_purpose::STANDARD
                        .decode(data)
                        .unwrap(),
                );
            }
        }
        assert!(
            output.windows(marker.len()).any(|window| window == marker),
            "the HUP-ignoring child did not start"
        );

        terminal.stop_reader_for_test();
        let (dropped, finished) = bounded(1);
        std::thread::spawn(move || {
            drop(terminal);
            let _ = dropped.send(());
        });
        assert!(
            finished.recv_timeout(Duration::from_secs(2)).is_ok(),
            "reader completion was mistaken for child exit"
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn websocket_terminal_round_trip_streams_input_and_output() {
        let root = std::env::temp_dir().join(format!("shidou-terminal-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let backend = ShidouBackend::new(
            DaemonSettingsStore::open(root.join("settings.json")).unwrap(),
            StateStore::daemon(root.join("app.db")),
        )
        .unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let shutdown = Arc::new(AtomicBool::new(false));
        let server_shutdown = shutdown.clone();
        let server = std::thread::spawn(move || {
            serve(
                listener,
                "secret".into(),
                Arc::new(backend),
                server_shutdown,
                ServerOptions {
                    allow_shutdown: true,
                    ..ServerOptions::default()
                },
            )
            .unwrap()
        });

        let client = DaemonClient::connect(&address.to_string(), "secret".into()).unwrap();
        let terminal_id = Uuid::new_v4();
        let events = client.subscribe(terminal_id, terminal_id);
        assert!(matches!(
            client
                .request(
                    terminal_id,
                    terminal_id,
                    Command::OpenTerminal {
                        cwd: root.clone(),
                        cols: 80,
                        rows: 24,
                    },
                )
                .unwrap(),
            ResponsePayload::Ack
        ));
        client
            .request(
                terminal_id,
                terminal_id,
                Command::WriteTerminal {
                    data: b"shidou-terminal-round-trip\r".to_vec(),
                },
            )
            .unwrap();

        // The raw test client intentionally does not emulate wterm's replies
        // to terminal capability queries. The PTY's local echo is enough to
        // prove that daemon-side input and output both crossed the WebSocket.
        let marker = b"shidou-terminal-round-trip";
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        let mut output = Vec::new();
        let mut seen_events = Vec::new();
        while std::time::Instant::now() < deadline
            && !output.windows(marker.len()).any(|window| window == marker)
        {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            let Ok(event) = events.recv_timeout(remaining) else {
                break;
            };
            seen_events.push(event.event.kind.clone());
            if event.event.kind != "terminalOutput" {
                continue;
            }
            let data = event.event.payload["data"].as_str().unwrap();
            output.extend(
                base64::engine::general_purpose::STANDARD
                    .decode(data)
                    .unwrap(),
            );
        }
        assert!(
            output.windows(marker.len()).any(|window| window == marker),
            "daemon terminal did not return the shell marker; events={seen_events:?}, output={}",
            String::from_utf8_lossy(&output)
        );
        assert!(matches!(
            client
                .request(terminal_id, terminal_id, Command::CloseTerminal)
                .unwrap(),
            ResponsePayload::Ack
        ));

        client.shutdown();
        server.join().unwrap();
        std::fs::remove_dir_all(root).unwrap();
    }

    /// Regression: stopping the reader before hanging up a shell let an exit
    /// trap fill the PTY and block forever, while Alacritty waited to reap that
    /// same shell. Keep draining through the trap and bound the assertion
    /// independently of the client's normal 120-second request timeout.
    #[cfg(unix)]
    #[test]
    fn closing_a_terminal_with_pending_output_responds_promptly() {
        let root = std::env::temp_dir().join(format!("shidou-terminal-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let backend = ShidouBackend::new(
            DaemonSettingsStore::open(root.join("settings.json")).unwrap(),
            StateStore::daemon(root.join("app.db")),
        )
        .unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let shutdown = Arc::new(AtomicBool::new(false));
        let server_shutdown = shutdown.clone();
        let server = std::thread::spawn(move || {
            serve(
                listener,
                "secret".into(),
                Arc::new(backend),
                server_shutdown,
                ServerOptions {
                    allow_shutdown: true,
                    ..ServerOptions::default()
                },
            )
            .unwrap()
        });

        let client = DaemonClient::connect(&address.to_string(), "secret".into()).unwrap();
        let terminal_id = Uuid::new_v4();
        let events = client.subscribe(terminal_id, terminal_id);
        client
            .request(
                terminal_id,
                terminal_id,
                Command::OpenTerminal {
                    cwd: root.clone(),
                    cols: 80,
                    rows: 24,
                },
            )
            .unwrap();
        client
            .request(
                terminal_id,
                terminal_id,
                Command::WriteTerminal {
                    data: b"sh -c \"trap 'head -c 1048576 /dev/zero; exit' HUP; printf 'SHIDOU_%s\\n' TRAP_READY; while :; do sleep 1; done\"\r".to_vec(),
                },
            )
            .unwrap();

        // Wait for the generated marker rather than the terminal's local echo;
        // the command text never contains this contiguous byte sequence.
        let marker = b"SHIDOU_TRAP_READY";
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        let mut output = Vec::new();
        while std::time::Instant::now() < deadline
            && !output.windows(marker.len()).any(|window| window == marker)
        {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            let Ok(event) = events.recv_timeout(remaining) else {
                break;
            };
            if event.event.kind == "terminalOutput" {
                let data = event.event.payload["data"].as_str().unwrap();
                output.extend(
                    base64::engine::general_purpose::STANDARD
                        .decode(data)
                        .unwrap(),
                );
            }
        }
        assert!(
            output.windows(marker.len()).any(|window| window == marker),
            "the terminal shell did not install its HUP trap; output={}",
            String::from_utf8_lossy(&output)
        );

        let close_client = client.clone();
        let (closed, close_result) = bounded(1);
        std::thread::spawn(move || {
            let result = close_client.request(terminal_id, terminal_id, Command::CloseTerminal);
            let _ = closed.send(result);
        });
        let result = close_result
            .recv_timeout(Duration::from_secs(5))
            .expect("terminal close did not answer within five seconds");
        assert!(matches!(result.unwrap(), ResponsePayload::Ack));

        client.shutdown();
        server.join().unwrap();
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn nil_request_ids_execute_without_responses_or_cache_entries() {
        let (outgoing, responses) = unbounded();
        let hub = Arc::new(Hub::default());
        let handled = handle_request(
            Request {
                request_id: Uuid::nil(),
                session_id: Uuid::nil(),
                runtime_id: Uuid::nil(),
                command: Command::GetSettings,
            },
            outgoing,
            0,
            Arc::new(TestBackend::default()),
            hub.clone(),
        );

        assert!(handled.executed);
        assert!(matches!(handled.outcome, ResponseOutcome::Ok { .. }));
        assert!(responses.try_recv().is_err());
        assert!(hub.cached_response(Uuid::nil()).is_none());
    }

    #[test]
    fn browser_origins_are_denied_unless_explicitly_allowed() {
        let request = HandshakeRequest::builder()
            .uri("/v1")
            .header(ORIGIN, "https://app.shidou.test")
            .body(())
            .unwrap();
        let response = HandshakeResponse::new(());
        assert_eq!(
            validate_handshake(&request, response, &HashSet::new())
                .unwrap_err()
                .status(),
            StatusCode::FORBIDDEN
        );

        let allowed = HashSet::from(["https://app.shidou.test".to_owned()]);
        assert!(validate_handshake(&request, HandshakeResponse::new(()), &allowed).is_ok());
        let native = HandshakeRequest::builder().uri("/v1").body(()).unwrap();
        assert!(validate_handshake(&native, HandshakeResponse::new(()), &HashSet::new()).is_ok());
    }

    #[test]
    fn daemon_tokens_require_an_exact_match() {
        assert!(token_matches("secret", "secret"));
        assert!(!token_matches("secret", "Secret"));
        assert!(!token_matches("secret", "secret-extra"));
    }

    #[test]
    fn replaced_runtime_ignores_late_events_from_the_old_generation() {
        let hub = Arc::new(Hub::default());
        let session_id = Uuid::new_v4();
        let old_runtime_id = Uuid::new_v4();
        let new_runtime_id = Uuid::new_v4();
        let (outgoing, events) = unbounded();
        hub.subscribe(&[], outgoing);

        hub.begin_runtime(session_id, old_runtime_id);
        let old_sink = hub.event_sink(session_id, old_runtime_id);
        old_sink
            .send(WireDriverEvent::new("old", serde_json::Value::Null))
            .unwrap();
        assert!(matches!(
            events.recv().unwrap(),
            ServerMessage::Event(event) if event.runtime_id == old_runtime_id
        ));

        hub.begin_runtime(session_id, new_runtime_id);
        old_sink
            .send(WireDriverEvent::new("stale", serde_json::Value::Null))
            .unwrap();
        hub.event_sink(session_id, new_runtime_id)
            .send(WireDriverEvent::new("new", serde_json::Value::Null))
            .unwrap();

        let ServerMessage::Event(event) = events.recv().unwrap() else {
            panic!("expected a daemon event");
        };
        assert_eq!(event.runtime_id, new_runtime_id);
        assert_eq!(event.sequence, 1);
        assert_eq!(event.event.kind, "new");
        assert!(events.try_recv().is_err());
    }

    #[test]
    fn replay_cursor_from_an_old_daemon_epoch_does_not_hide_new_events() {
        let hub = Arc::new(Hub::default());
        let session_id = Uuid::new_v4();
        let runtime_id = Uuid::new_v4();
        hub.begin_runtime(session_id, runtime_id);
        hub.event_sink(session_id, runtime_id)
            .send(WireDriverEvent::new("new-daemon", serde_json::Value::Null))
            .unwrap();

        let (outgoing, events) = unbounded();
        hub.subscribe(
            &[ReplayCursor {
                session_id,
                runtime_id,
                epoch: Uuid::nil(),
                sequence: u64::MAX,
            }],
            outgoing,
        );

        let ServerMessage::Event(event) = events.recv().unwrap() else {
            panic!("expected the new daemon event to replay");
        };
        assert_eq!(event.epoch, hub.epoch);
        assert_eq!(event.sequence, 1);
    }

    #[test]
    fn a_cursor_behind_the_journal_is_told_the_replay_has_a_hole() {
        let hub = Arc::new(Hub::new(4));
        let session_id = Uuid::new_v4();
        let runtime_id = Uuid::new_v4();
        hub.begin_runtime(session_id, runtime_id);
        let sink = hub.event_sink(session_id, runtime_id);
        for index in 0..10 {
            sink.send(WireDriverEvent::new(
                "textDelta",
                serde_json::Value::String(index.to_string()),
            ))
            .unwrap();
        }

        let (outgoing, events) = unbounded();
        hub.subscribe(
            &[ReplayCursor {
                session_id,
                runtime_id,
                epoch: hub.epoch,
                sequence: 2,
            }],
            outgoing,
        );

        // Sequences 3..=6 were evicted; the client hears that before it hears
        // anything that would otherwise look like the next event it missed.
        let ServerMessage::ReplayGap {
            first_available,
            epoch,
            ..
        } = events.recv().unwrap()
        else {
            panic!("a stale cursor must be told the journal moved past it");
        };
        assert_eq!(first_available, 7);
        assert_eq!(epoch, hub.epoch);

        let ServerMessage::Event(event) = events.recv().unwrap() else {
            panic!("the surviving tail still replays");
        };
        assert_eq!(event.sequence, 7);
    }

    #[test]
    fn a_cursor_the_journal_still_reaches_replays_without_a_gap() {
        let hub = Arc::new(Hub::new(4));
        let session_id = Uuid::new_v4();
        let runtime_id = Uuid::new_v4();
        hub.begin_runtime(session_id, runtime_id);
        let sink = hub.event_sink(session_id, runtime_id);
        for index in 0..4 {
            sink.send(WireDriverEvent::new(
                "textDelta",
                serde_json::Value::String(index.to_string()),
            ))
            .unwrap();
        }

        let (outgoing, events) = unbounded();
        hub.subscribe(
            &[ReplayCursor {
                session_id,
                runtime_id,
                epoch: hub.epoch,
                sequence: 2,
            }],
            outgoing,
        );

        let ServerMessage::Event(event) = events.recv().unwrap() else {
            panic!("a contiguous replay sends events and nothing else");
        };
        assert_eq!(event.sequence, 3);
    }

    /// A client that has never seen this runtime still gets the whole journal,
    /// and still has to be told when that journal is not the whole story.
    #[test]
    fn a_client_with_no_cursor_hears_about_an_overflowed_journal() {
        let hub = Arc::new(Hub::new(2));
        let session_id = Uuid::new_v4();
        let runtime_id = Uuid::new_v4();
        hub.begin_runtime(session_id, runtime_id);
        let sink = hub.event_sink(session_id, runtime_id);
        for index in 0..5 {
            sink.send(WireDriverEvent::new(
                "textDelta",
                serde_json::Value::String(index.to_string()),
            ))
            .unwrap();
        }

        let (outgoing, events) = unbounded();
        hub.subscribe(&[], outgoing);

        assert!(matches!(
            events.recv().unwrap(),
            ServerMessage::ReplayGap {
                first_available: 4,
                ..
            }
        ));
    }

    struct BlockingProbeBackend {
        probe_started: Sender<()>,
        release_probe: Receiver<()>,
    }

    impl Backend for BlockingProbeBackend {
        fn handle(&self, request: Request, _: EventSink) -> anyhow::Result<ResponsePayload> {
            if matches!(request.command, Command::ProbeProvider { .. }) {
                self.probe_started.send(()).unwrap();
                self.release_probe.recv().unwrap();
            }
            Ok(ResponsePayload::Ack)
        }
    }

    #[test]
    fn slow_background_command_does_not_block_session_hydration() {
        let (outgoing, response_rx) = unbounded();
        let (probe_started, probe_started_rx) = bounded(1);
        let (release_probe, release_probe_rx) = bounded(1);
        let backend: Arc<dyn Backend> = Arc::new(BlockingProbeBackend {
            probe_started,
            release_probe: release_probe_rx,
        });
        let hub = Arc::new(Hub::default());
        let dispatcher = RequestDispatcher::new(backend, hub);

        let probe_id = Uuid::new_v4();
        dispatcher.dispatch(
            Request {
                request_id: probe_id,
                session_id: Uuid::nil(),
                runtime_id: Uuid::nil(),
                command: Command::ProbeProvider {
                    provider: crate::model::ProviderKind::Codex,
                    binary_override: None,
                    discover_models: false,
                    probe_version: false,
                },
            },
            outgoing.clone(),
            0,
        );
        probe_started_rx
            .recv_timeout(Duration::from_secs(1))
            .unwrap();

        let hydration_id = Uuid::new_v4();
        dispatcher.dispatch(
            Request {
                request_id: hydration_id,
                session_id: Uuid::nil(),
                runtime_id: Uuid::nil(),
                command: Command::HydrateSession {
                    session_id: Uuid::new_v4(),
                },
            },
            outgoing,
            0,
        );
        assert!(matches!(
            response_rx.recv_timeout(Duration::from_secs(1)).unwrap(),
            ServerMessage::Response { request_id, .. } if request_id == hydration_id
        ));

        release_probe.send(()).unwrap();
        assert!(matches!(
            response_rx.recv_timeout(Duration::from_secs(1)).unwrap(),
            ServerMessage::Response { request_id, .. } if request_id == probe_id
        ));
    }

    struct RuntimeOrderingBackend {
        blocked_session_id: Uuid,
        handled: Sender<(Uuid, &'static str)>,
        release_start: Receiver<()>,
    }

    impl Backend for RuntimeOrderingBackend {
        fn handle(&self, request: Request, _: EventSink) -> anyhow::Result<ResponsePayload> {
            let command = match request.command {
                Command::Start { .. } => {
                    self.handled.send((request.session_id, "start")).unwrap();
                    if request.session_id == self.blocked_session_id {
                        self.release_start.recv().unwrap();
                    }
                    return Ok(ResponsePayload::Started {
                        supports_steer: true,
                    });
                }
                Command::Prompt { .. } => "prompt",
                Command::CloseSession => "close",
                _ => "other",
            };
            self.handled.send((request.session_id, command)).unwrap();
            Ok(ResponsePayload::Ack)
        }
    }

    #[test]
    fn runtime_commands_are_ordered_per_session_without_blocking_other_sessions() {
        let blocked_session_id = Uuid::new_v4();
        let blocked_runtime_id = Uuid::new_v4();
        let other_session_id = Uuid::new_v4();
        let other_runtime_id = Uuid::new_v4();
        let (handled, handled_rx) = unbounded();
        let (release_start, release_start_rx) = bounded(1);
        let dispatcher = RequestDispatcher::new(
            Arc::new(RuntimeOrderingBackend {
                blocked_session_id,
                handled,
                release_start: release_start_rx,
            }),
            Arc::new(Hub::default()),
        );
        let (start_outgoing, start_responses) = unbounded();
        let (second_client_outgoing, second_client_responses) = unbounded();
        let (other_outgoing, other_responses) = unbounded();

        let blocked_start_id = Uuid::new_v4();
        dispatcher.dispatch(
            Request {
                request_id: blocked_start_id,
                session_id: blocked_session_id,
                runtime_id: blocked_runtime_id,
                command: Command::Start {
                    options: test_start_options(),
                },
            },
            start_outgoing,
            0,
        );
        assert_eq!(
            handled_rx.recv_timeout(Duration::from_secs(1)).unwrap(),
            (blocked_session_id, "start")
        );

        let prompt_id = Uuid::new_v4();
        dispatcher.dispatch(
            Request {
                request_id: prompt_id,
                session_id: blocked_session_id,
                runtime_id: blocked_runtime_id,
                command: Command::Prompt {
                    submission_id: Uuid::new_v4(),
                    prompt: "after start".into(),
                },
            },
            second_client_outgoing,
            0,
        );

        let other_start_id = Uuid::new_v4();
        dispatcher.dispatch(
            Request {
                request_id: other_start_id,
                session_id: other_session_id,
                runtime_id: other_runtime_id,
                command: Command::Start {
                    options: test_start_options(),
                },
            },
            other_outgoing.clone(),
            0,
        );
        assert_eq!(
            handled_rx.recv_timeout(Duration::from_secs(1)).unwrap(),
            (other_session_id, "start")
        );
        assert!(matches!(
            other_responses
                .recv_timeout(Duration::from_secs(1))
                .unwrap(),
            ServerMessage::Response { request_id, .. } if request_id == other_start_id
        ));
        assert!(handled_rx.recv_timeout(Duration::from_millis(50)).is_err());

        release_start.send(()).unwrap();
        assert!(matches!(
            start_responses
                .recv_timeout(Duration::from_secs(1))
                .unwrap(),
            ServerMessage::Response { request_id, .. } if request_id == blocked_start_id
        ));
        assert_eq!(
            handled_rx.recv_timeout(Duration::from_secs(1)).unwrap(),
            (blocked_session_id, "prompt")
        );
        assert!(matches!(
            second_client_responses
                .recv_timeout(Duration::from_secs(1))
                .unwrap(),
            ServerMessage::Response { request_id, .. } if request_id == prompt_id
        ));

        let blocked_close_id = Uuid::new_v4();
        dispatcher.dispatch(
            Request {
                request_id: blocked_close_id,
                session_id: blocked_session_id,
                runtime_id: blocked_runtime_id,
                command: Command::CloseSession,
            },
            other_outgoing.clone(),
            0,
        );
        let other_close_id = Uuid::new_v4();
        dispatcher.dispatch(
            Request {
                request_id: other_close_id,
                session_id: other_session_id,
                runtime_id: other_runtime_id,
                command: Command::CloseSession,
            },
            other_outgoing,
            0,
        );
        let mut close_responses = [false; 2];
        for _ in 0..2 {
            let ServerMessage::Response { request_id, .. } = other_responses
                .recv_timeout(Duration::from_secs(1))
                .unwrap()
            else {
                panic!("expected a close response");
            };
            if request_id == blocked_close_id {
                close_responses[0] = true;
            } else if request_id == other_close_id {
                close_responses[1] = true;
            }
        }
        assert_eq!(close_responses, [true, true]);
    }

    fn test_start_options() -> WireDriverStartOptions {
        WireDriverStartOptions {
            provider: "codex".into(),
            binary: PathBuf::from("codex"),
            cwd: PathBuf::from("."),
            mode: "fullAccess".into(),
            interaction_mode: "build".into(),
            model: None,
            reasoning_effort: None,
            service_tier: None,
            context_window: None,
            agent_preset: None,
            computer_use_enabled: false,
            provider_cursor: None,
        }
    }
}
