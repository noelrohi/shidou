use std::collections::{HashMap, VecDeque};
use std::io;
use std::net::TcpStream;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use anyhow::{Context as _, anyhow, bail};
use crossbeam_channel::{Receiver, Sender, bounded, unbounded};
use parking_lot::Mutex;
use tungstenite::protocol::WebSocketConfig;
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{Message, WebSocket};
use uuid::Uuid;

use shidou_protocol::MAX_WIRE_MESSAGE_BYTES;
use shidou_protocol::{
    ClientMessage, Command, PROTOCOL_VERSION, ReplayCursor, Request, ResponseOutcome,
    ResponsePayload, RpcError, SequencedEvent, ServerMessage, WireDriverEvent,
};

const READ_POLL_INTERVAL: Duration = Duration::from_millis(25);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(120);
const MAX_BUFFERED_EVENTS_PER_RUNTIME: usize = 4096;

enum Outgoing {
    Message(ClientMessage),
    Shutdown,
}

struct ClientInner {
    outgoing: Sender<Outgoing>,
    pending: Mutex<HashMap<Uuid, Sender<Result<ResponsePayload, RpcError>>>>,
    sessions: Mutex<HashMap<(Uuid, Uuid), RuntimeEventSink>>,
    pending_events: Mutex<HashMap<(Uuid, Uuid), VecDeque<SequencedEvent>>>,
    /// Latest unresolved provider interaction per runtime. Unlike transcript
    /// projection, this is presentation state that must be offered again when
    /// an in-process App Reload replaces its runtime subscription.
    pending_interactions: Mutex<HashMap<(Uuid, Uuid), SequencedEvent>>,
    task_state_subscribers: Mutex<Vec<Sender<u64>>>,
    last_sequences: Mutex<HashMap<(Uuid, Uuid), LastSequence>>,
    disconnected: AtomicBool,
}

#[derive(Clone)]
struct RuntimeEventSink {
    subscription_id: Uuid,
    events: Sender<SequencedEvent>,
}

#[derive(Clone, Copy)]
struct LastSequence {
    epoch: Uuid,
    sequence: u64,
}

#[derive(Clone)]
pub struct DaemonClient {
    inner: Arc<ClientInner>,
}

impl DaemonClient {
    pub fn connect(address: &str, token: String) -> anyhow::Result<Self> {
        Self::connect_with_resume(address, token, Vec::new())
    }

    pub fn connect_with_resume(
        address: &str,
        token: String,
        resume_from: Vec<ReplayCursor>,
    ) -> anyhow::Result<Self> {
        let last_sequences = resume_from
            .iter()
            .map(|cursor| {
                (
                    (cursor.session_id, cursor.runtime_id),
                    LastSequence {
                        epoch: cursor.epoch,
                        sequence: cursor.sequence,
                    },
                )
            })
            .collect();
        let url = daemon_url(address)?;
        let config = WebSocketConfig::default()
            .max_message_size(Some(MAX_WIRE_MESSAGE_BYTES))
            .max_frame_size(Some(MAX_WIRE_MESSAGE_BYTES));
        let (mut socket, _) =
            tungstenite::client::connect_with_config(url.as_str(), Some(config), 3)
                .context("could not connect to Shidou daemon")?;
        set_client_read_timeout(&mut socket, Some(Duration::from_secs(5)))?;
        write_json(
            &mut socket,
            &ClientMessage::Hello {
                protocol_version: PROTOCOL_VERSION,
                token,
                client_id: Uuid::new_v4(),
                resume_from,
            },
        )?;
        let hello = read_server_message(&mut socket)?;
        match hello {
            ServerMessage::Hello {
                protocol_version, ..
            } if protocol_version == PROTOCOL_VERSION => {}
            ServerMessage::Hello {
                protocol_version, ..
            } => bail!(
                "daemon protocol {protocol_version} does not match desktop protocol {PROTOCOL_VERSION}"
            ),
            ServerMessage::Rejected { message } => bail!("daemon rejected connection: {message}"),
            other => bail!("daemon sent an invalid handshake response: {other:?}"),
        }
        set_client_read_timeout(&mut socket, Some(READ_POLL_INTERVAL))?;

        let (outgoing, outgoing_rx) = unbounded();
        let inner = Arc::new(ClientInner {
            outgoing,
            pending: Mutex::new(HashMap::new()),
            sessions: Mutex::new(HashMap::new()),
            pending_events: Mutex::new(HashMap::new()),
            pending_interactions: Mutex::new(HashMap::new()),
            task_state_subscribers: Mutex::new(Vec::new()),
            last_sequences: Mutex::new(last_sequences),
            disconnected: AtomicBool::new(false),
        });
        let thread_inner = inner.clone();
        std::thread::Builder::new()
            .name("shidou-daemon-client".into())
            .spawn(move || run_client(socket, outgoing_rx, thread_inner))
            .context("could not start Shidou daemon client thread")?;
        Ok(Self { inner })
    }

    pub fn subscribe(&self, session_id: Uuid, runtime_id: Uuid) -> Receiver<SequencedEvent> {
        let (_, _, receiver) = self.subscribe_runtime(session_id, runtime_id);
        receiver
    }

    /// Registers one runtime attachment and returns any unresolved blocking
    /// interaction separately from the sequenced stream. The interaction may
    /// sit at or before the caller's persisted replay cursor, but it still has
    /// to be reconstructed after an App Reload.
    pub fn subscribe_runtime(
        &self,
        session_id: Uuid,
        runtime_id: Uuid,
    ) -> (Uuid, Option<SequencedEvent>, Receiver<SequencedEvent>) {
        let (events, receiver) = unbounded();
        let key = (session_id, runtime_id);
        let subscription_id = Uuid::new_v4();
        let mut sessions = self.inner.sessions.lock();
        sessions.insert(
            key,
            RuntimeEventSink {
                subscription_id,
                events: events.clone(),
            },
        );
        // Keep the subscription lock while draining the pre-subscription
        // replay queue. The socket thread takes these locks in the same order,
        // so a new live event cannot overtake older replayed events here.
        if let Some(buffered) = self.inner.pending_events.lock().remove(&key) {
            for event in buffered {
                let _ = events.send(event);
            }
        }
        let pending_interaction = self.inner.pending_interactions.lock().get(&key).cloned();
        (subscription_id, pending_interaction, receiver)
    }

    /// Removes this attachment only if it is still the registered owner. A
    /// forwarding thread from the tree replaced by App Reload can finish after
    /// the new tree subscribes to the same runtime.
    pub fn unsubscribe_runtime(&self, session_id: Uuid, runtime_id: Uuid, subscription_id: Uuid) {
        let key = (session_id, runtime_id);
        let mut sessions = self.inner.sessions.lock();
        if sessions
            .get(&key)
            .is_some_and(|sink| sink.subscription_id == subscription_id)
        {
            sessions.remove(&key);
        }
    }

    pub fn subscribe_task_state(&self) -> Receiver<u64> {
        let (events, receiver) = unbounded();
        self.inner.task_state_subscribers.lock().push(events);
        receiver
    }

    pub fn request(
        &self,
        session_id: Uuid,
        runtime_id: Uuid,
        command: Command,
    ) -> anyhow::Result<ResponsePayload> {
        if self.inner.disconnected.load(Ordering::Acquire) {
            bail!("Shidou daemon is disconnected");
        }
        let request_id = Uuid::new_v4();
        let (response, response_rx) = bounded(1);
        self.inner.pending.lock().insert(request_id, response);
        let message = ClientMessage::Request(Request {
            request_id,
            session_id,
            runtime_id,
            command,
        });
        if self
            .inner
            .outgoing
            .send(Outgoing::Message(message))
            .is_err()
        {
            self.inner.pending.lock().remove(&request_id);
            bail!("Shidou daemon connection is closed");
        }
        match response_rx.recv_timeout(REQUEST_TIMEOUT) {
            Ok(Ok(payload)) => Ok(payload),
            // Carried whole, not flattened to its message: `refusal` below
            // recovers the kind, which is how a caller tells a daemon that
            // declined from a daemon it could not reach.
            Ok(Err(error)) => Err(anyhow::Error::new(error)),
            Err(error) => {
                self.inner.pending.lock().remove(&request_id);
                Err(anyhow!("timed out waiting for Shidou daemon: {error}"))
            }
        }
    }

    pub fn notify(
        &self,
        session_id: Uuid,
        runtime_id: Uuid,
        command: Command,
    ) -> anyhow::Result<()> {
        if self.inner.disconnected.load(Ordering::Acquire) {
            bail!("Shidou daemon is disconnected");
        }
        let resolved_request_id = match &command {
            Command::Respond { request_id, .. } | Command::RespondUserInput { request_id, .. } => {
                Some(request_id.clone())
            }
            _ => None,
        };
        let clears_all_interactions = matches!(command, Command::Cancel | Command::CloseSession);
        self.inner
            .outgoing
            .send(Outgoing::Message(ClientMessage::Request(Request {
                // The nil request id is reserved for fire-and-forget controls;
                // the daemon executes them in the runtime mailbox but does
                // not allocate or send a response.
                request_id: Uuid::nil(),
                session_id,
                runtime_id,
                command,
            })))
            .map_err(|_| anyhow!("Shidou daemon connection is closed"))?;
        let key = (session_id, runtime_id);
        let mut pending = self.inner.pending_interactions.lock();
        if clears_all_interactions {
            pending.remove(&key);
        } else if let Some(request_id) = resolved_request_id {
            clear_matching_interaction(&mut pending, key, &request_id);
        }
        Ok(())
    }

    pub fn last_sequences(&self) -> Vec<ReplayCursor> {
        self.inner
            .last_sequences
            .lock()
            .iter()
            .map(|(&(session_id, runtime_id), cursor)| ReplayCursor {
                session_id,
                runtime_id,
                epoch: cursor.epoch,
                sequence: cursor.sequence,
            })
            .collect()
    }

    pub fn shutdown(&self) {
        let _ = self.inner.outgoing.send(Outgoing::Shutdown);
    }
}

fn daemon_url(address: &str) -> anyhow::Result<String> {
    let normalized = if address.starts_with("ws://") || address.starts_with("wss://") {
        address.to_owned()
    } else {
        format!("ws://{address}")
    };
    let mut url = url::Url::parse(&normalized).context("Shidou daemon address is invalid")?;
    url.set_path("/v1");
    url.set_query(None);
    url.set_fragment(None);
    Ok(url.into())
}

fn run_client(
    mut socket: WebSocket<MaybeTlsStream<TcpStream>>,
    outgoing: Receiver<Outgoing>,
    inner: Arc<ClientInner>,
) {
    'connection: loop {
        while let Ok(message) = outgoing.try_recv() {
            match message {
                Outgoing::Message(message) => {
                    if write_json(&mut socket, &message).is_err() {
                        break 'connection;
                    }
                }
                Outgoing::Shutdown => {
                    let _ = write_json(&mut socket, &ClientMessage::Shutdown);
                    let _ = socket.flush();
                    break 'connection;
                }
            }
        }

        match socket.read() {
            Ok(Message::Text(text)) => {
                let Ok(message) = serde_json::from_str::<ServerMessage>(text.as_ref()) else {
                    continue;
                };
                match message {
                    ServerMessage::Response {
                        request_id,
                        outcome,
                    } => {
                        if let Some(pending) = inner.pending.lock().remove(&request_id) {
                            let result = match outcome {
                                ResponseOutcome::Ok { payload } => Ok(payload),
                                ResponseOutcome::Error { error } => Err(error),
                            };
                            let _ = pending.send(result);
                        }
                    }
                    ServerMessage::Event(event) => {
                        let should_deliver = {
                            let mut sequences = inner.last_sequences.lock();
                            let previous = sequences
                                .entry((event.session_id, event.runtime_id))
                                .or_insert(LastSequence {
                                    epoch: event.epoch,
                                    sequence: 0,
                                });
                            if previous.epoch == event.epoch && event.sequence <= previous.sequence
                            {
                                false
                            } else {
                                previous.epoch = event.epoch;
                                previous.sequence = event.sequence;
                                true
                            }
                        };
                        if should_deliver {
                            let key = (event.session_id, event.runtime_id);
                            track_pending_interaction(&inner.pending_interactions, key, &event);
                            let sessions = inner.sessions.lock();
                            if let Some(sink) = sessions.get(&key) {
                                let _ = sink.events.send(event);
                            } else {
                                let mut pending = inner.pending_events.lock();
                                let buffered = pending.entry(key).or_default();
                                buffered.push_back(event);
                                while buffered.len() > MAX_BUFFERED_EVENTS_PER_RUNTIME {
                                    buffered.pop_front();
                                }
                            }
                        }
                    }
                    ServerMessage::TaskStateChanged { revision } => {
                        inner
                            .task_state_subscribers
                            .lock()
                            .retain(|subscriber| subscriber.send(revision).is_ok());
                    }
                    ServerMessage::ShuttingDown => break,
                    // The desktop shares a lifetime with the daemon it talks
                    // to and always connects without replay cursors, so it
                    // has no projection older than the socket for a gap to
                    // invalidate. Remote clients, which outlive their daemon
                    // connection, are the ones this message exists for.
                    ServerMessage::ReplayGap { .. }
                    | ServerMessage::Hello { .. }
                    | ServerMessage::Rejected { .. } => {}
                }
            }
            Ok(Message::Close(_)) => break,
            Ok(Message::Ping(_)) => {
                let _ = socket.flush();
            }
            Ok(_) => {}
            Err(tungstenite::Error::Io(error)) if retryable_io(&error) => {}
            Err(tungstenite::Error::ConnectionClosed | tungstenite::Error::AlreadyClosed) => break,
            Err(_) => break,
        }
    }

    inner.disconnected.store(true, Ordering::Release);
    let pending = std::mem::take(&mut *inner.pending.lock());
    for (_, response) in pending {
        let _ = response.send(Err(RpcError {
            message: "Shidou daemon disconnected".into(),
            kind: None,
        }));
    }
    let sessions = std::mem::take(&mut *inner.sessions.lock());
    for ((session_id, runtime_id), sink) in sessions {
        // This event is synthesized locally and is not present in the
        // daemon's replay journal. Do not advance the replay cursor for it or
        // reconnecting to the same daemon would skip the next real event.
        let (epoch, sequence) = inner
            .last_sequences
            .lock()
            .get(&(session_id, runtime_id))
            .map(|cursor| (cursor.epoch, cursor.sequence))
            .unwrap_or((Uuid::nil(), 0));
        let _ = sink.events.send(SequencedEvent {
            session_id,
            runtime_id,
            epoch,
            sequence,
            event: WireDriverEvent::new("processExited", serde_json::Value::Null),
        });
    }
    inner.task_state_subscribers.lock().clear();
}

fn interaction_request_id(event: &SequencedEvent) -> Option<&str> {
    event.event.payload.get("requestId")?.as_str()
}

fn clear_matching_interaction(
    pending: &mut HashMap<(Uuid, Uuid), SequencedEvent>,
    key: (Uuid, Uuid),
    request_id: &str,
) {
    if pending
        .get(&key)
        .and_then(interaction_request_id)
        .is_some_and(|pending_id| pending_id == request_id)
    {
        pending.remove(&key);
    }
}

fn track_pending_interaction(
    pending: &Mutex<HashMap<(Uuid, Uuid), SequencedEvent>>,
    key: (Uuid, Uuid),
    event: &SequencedEvent,
) {
    let mut pending = pending.lock();
    match event.event.kind.as_str() {
        "permission" | "userInputRequested" => {
            pending.insert(key, event.clone());
        }
        "interactionResolved" => {
            if let Some(request_id) = interaction_request_id(event) {
                clear_matching_interaction(&mut pending, key, request_id);
            }
        }
        "turnFinished" | "processExited" | "error" => {
            pending.remove(&key);
        }
        _ => {}
    }
}

fn set_client_read_timeout(
    socket: &mut WebSocket<MaybeTlsStream<TcpStream>>,
    timeout: Option<Duration>,
) -> io::Result<()> {
    match socket.get_mut() {
        MaybeTlsStream::Plain(stream) => stream.set_read_timeout(timeout),
        MaybeTlsStream::Rustls(stream) => stream.sock.set_read_timeout(timeout),
        #[allow(unreachable_patterns)]
        _ => Ok(()),
    }
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

fn write_json<S: io::Read + io::Write, T: serde::Serialize>(
    socket: &mut WebSocket<S>,
    value: &T,
) -> anyhow::Result<()> {
    let payload = serde_json::to_string(value)?;
    socket.send(Message::Text(payload.into()))?;
    Ok(())
}

fn read_server_message(
    socket: &mut WebSocket<MaybeTlsStream<TcpStream>>,
) -> anyhow::Result<ServerMessage> {
    loop {
        match socket.read()? {
            Message::Text(text) => return Ok(serde_json::from_str(text.as_ref())?),
            Message::Ping(_) => socket.flush()?,
            Message::Close(_) => bail!("Shidou daemon closed during handshake"),
            _ => {}
        }
    }
}

/// The daemon's refusal, if this is one.
///
/// A refusal means the daemon received the command, understood it, and
/// declined it — so a caller shows it and stops, rather than retrying. A
/// timeout, a dropped connection, and an ordinary daemon failure all return
/// `None`, because retrying those can succeed.
pub fn refusal(error: &anyhow::Error) -> Option<&RpcError> {
    error
        .downcast_ref::<RpcError>()
        .filter(|error| error.is_refusal())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_client() -> DaemonClient {
        let (outgoing, _outgoing_rx) = unbounded();
        DaemonClient {
            inner: Arc::new(ClientInner {
                outgoing,
                pending: Mutex::new(HashMap::new()),
                sessions: Mutex::new(HashMap::new()),
                pending_events: Mutex::new(HashMap::new()),
                pending_interactions: Mutex::new(HashMap::new()),
                task_state_subscribers: Mutex::new(Vec::new()),
                last_sequences: Mutex::new(HashMap::new()),
                disconnected: AtomicBool::new(false),
            }),
        }
    }

    #[test]
    fn stale_runtime_unsubscribe_does_not_remove_replacement_subscription() {
        let client = test_client();
        let session_id = Uuid::new_v4();
        let runtime_id = Uuid::new_v4();
        let (old_id, _, _old) = client.subscribe_runtime(session_id, runtime_id);
        let (_, _, replacement) = client.subscribe_runtime(session_id, runtime_id);

        client.unsubscribe_runtime(session_id, runtime_id, old_id);

        let event = SequencedEvent {
            session_id,
            runtime_id,
            epoch: Uuid::new_v4(),
            sequence: 1,
            event: WireDriverEvent::new("textDelta", serde_json::Value::Null),
        };
        let sender = client
            .inner
            .sessions
            .lock()
            .get(&(session_id, runtime_id))
            .cloned()
            .expect("the replacement subscription must remain registered");
        sender.events.send(event).unwrap();
        assert_eq!(replacement.recv().unwrap().sequence, 1);
    }

    #[test]
    fn runtime_subscription_restores_an_unresolved_interaction() {
        let client = test_client();
        let session_id = Uuid::new_v4();
        let runtime_id = Uuid::new_v4();
        let interaction = SequencedEvent {
            session_id,
            runtime_id,
            epoch: Uuid::new_v4(),
            sequence: 7,
            event: WireDriverEvent::new("userInputRequested", serde_json::Value::Null),
        };
        client
            .inner
            .pending_interactions
            .lock()
            .insert((session_id, runtime_id), interaction.clone());

        let (_, pending, _events) = client.subscribe_runtime(session_id, runtime_id);

        assert_eq!(pending.unwrap().sequence, interaction.sequence);

        let resolved = SequencedEvent {
            session_id,
            runtime_id,
            epoch: interaction.epoch,
            sequence: 8,
            event: WireDriverEvent::new(
                "interactionResolved",
                serde_json::json!({ "requestId": "question-1" }),
            ),
        };
        // Give the cached interaction the same request identity used by the
        // resolution event, then verify a response observed from any client
        // clears it.
        client.inner.pending_interactions.lock().insert(
            (session_id, runtime_id),
            SequencedEvent {
                event: WireDriverEvent::new(
                    "userInputRequested",
                    serde_json::json!({ "requestId": "question-1" }),
                ),
                ..interaction
            },
        );
        track_pending_interaction(
            &client.inner.pending_interactions,
            (session_id, runtime_id),
            &resolved,
        );
        let (_, pending, _events) = client.subscribe_runtime(session_id, runtime_id);
        assert!(pending.is_none());
    }

    #[test]
    fn daemon_endpoint_accepts_addresses_and_secure_urls() {
        assert_eq!(
            daemon_url("127.0.0.1:4312").unwrap(),
            "ws://127.0.0.1:4312/v1"
        );
        assert_eq!(
            daemon_url("wss://shidou.example.test/old?ignored=1").unwrap(),
            "wss://shidou.example.test/v1"
        );
    }
}
