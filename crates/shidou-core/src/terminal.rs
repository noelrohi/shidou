//! Daemon-owned pseudoterminals for remote clients.
//!
//! The daemon owns the shell, cwd, and PTY. Clients only render the byte
//! stream and send input/resize controls, so a browser can operate against a
//! daemon on another machine without interpreting any daemon-side paths.

#[cfg(not(unix))]
use std::path::Path;

#[cfg(not(unix))]
use anyhow::bail;

#[cfg(not(unix))]
use crate::EventSink;

#[cfg(unix)]
mod platform {
    use std::io::{Read as _, Write as _};
    use std::os::fd::AsRawFd as _;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::thread::JoinHandle;
    use std::time::Duration;

    use alacritty_terminal::event::{OnResize as _, WindowSize};
    use alacritty_terminal::tty::{self, EventedPty as _, EventedReadWrite as _, Shell};
    use anyhow::{Context as _, bail};
    use base64::Engine as _;
    use parking_lot::Mutex;
    use serde_json::json;

    use crate::{EventSink, WireDriverEvent};

    const CELL_WIDTH: u16 = 8;
    const CELL_HEIGHT: u16 = 16;
    const MIN_COLUMNS: u16 = 2;
    const MIN_ROWS: u16 = 1;
    /// How long a hung-up shell gets to finish exiting before it is killed.
    /// Generous enough for a login shell's exit hooks, short enough that a
    /// shell which ignores `SIGHUP` cannot stall a client's close request.
    const SHELL_EXIT_GRACE: Duration = Duration::from_millis(500);

    pub struct DaemonTerminal {
        pty: Arc<Mutex<tty::Pty>>,
        stopped: Arc<AtomicBool>,
        /// Set only after Alacritty's SIGCHLD channel confirms the child
        /// exited. Reader completion alone is not sufficient: the reader can
        /// also leave on an I/O error or panic while the shell is still alive.
        child_exited: Arc<AtomicBool>,
        /// True only when the master reports that every PTY slave is closed.
        /// A reader stopped by teardown or lost to an error does not set it.
        pty_closed: Arc<AtomicBool>,
        reader: Option<JoinHandle<()>>,
    }

    impl DaemonTerminal {
        pub fn open(
            cwd: &std::path::Path,
            cols: u16,
            rows: u16,
            events: EventSink,
        ) -> anyhow::Result<Self> {
            if !cwd.is_dir() {
                bail!(
                    "terminal working directory does not exist: {}",
                    cwd.display()
                );
            }

            let shell = crate::command_env::default_terminal_shell();
            let shell_args = crate::command_env::default_terminal_shell_args(&shell);
            let mut options = tty::Options {
                shell: Some(Shell::new(shell.to_string_lossy().into_owned(), shell_args)),
                working_directory: Some(cwd.to_owned()),
                drain_on_exit: false,
                ..Default::default()
            };
            for (name, value) in crate::command_env::shell_environment() {
                options.env.insert(
                    name.to_string_lossy().into_owned(),
                    value.to_string_lossy().into_owned(),
                );
            }
            options.env.insert("TERM".into(), "xterm-256color".into());
            options.env.insert("COLORTERM".into(), "truecolor".into());

            let size = window_size(cols, rows);
            let pty = tty::new(&options, size, 0)
                .with_context(|| format!("spawn terminal in {}", cwd.display()))?;
            let mut output = pty.file().try_clone().context("clone terminal output")?;
            let pty = Arc::new(Mutex::new(pty));
            let stopped = Arc::new(AtomicBool::new(false));
            let child_exited = Arc::new(AtomicBool::new(false));
            let pty_closed = Arc::new(AtomicBool::new(false));
            let reader_pty = pty.clone();
            let reader_stopped = stopped.clone();
            let reader_child_exited = child_exited.clone();
            let reader_pty_closed = pty_closed.clone();
            let reader = std::thread::Builder::new()
                .name("shidou-daemon-terminal-output".into())
                .spawn(move || {
                    let mut buffer = [0_u8; 32 * 1024];
                    while !reader_stopped.load(Ordering::Acquire) {
                        match output.read(&mut buffer) {
                            Ok(0) => {
                                reader_pty_closed.store(true, Ordering::Release);
                                let _ = events.send_ephemeral(WireDriverEvent::new(
                                    "terminalExited",
                                    serde_json::Value::Null,
                                ));
                                break;
                            }
                            Ok(read) => {
                                let data = base64::engine::general_purpose::STANDARD
                                    .encode(&buffer[..read]);
                                let _ = events.send_ephemeral(WireDriverEvent::new(
                                    "terminalOutput",
                                    json!({ "data": data }),
                                ));
                            }
                            Err(error)
                                if matches!(
                                    error.kind(),
                                    std::io::ErrorKind::WouldBlock
                                        | std::io::ErrorKind::TimedOut
                                        | std::io::ErrorKind::Interrupted
                                ) =>
                            {
                                std::thread::sleep(Duration::from_millis(4));
                            }
                            Err(error) if error.raw_os_error() == Some(libc::EIO) => {
                                // A PTY master may report EIO briefly before the
                                // freshly spawned child has attached its slave.
                                // Only treat it as EOF after Alacritty's SIGCHLD
                                // channel confirms the child actually exited.
                                if reader_child_exited.load(Ordering::Acquire)
                                    || reader_pty.lock().next_child_event().is_some()
                                {
                                    reader_child_exited.store(true, Ordering::Release);
                                    reader_pty_closed.store(true, Ordering::Release);
                                    let _ = events.send_ephemeral(WireDriverEvent::new(
                                        "terminalExited",
                                        serde_json::Value::Null,
                                    ));
                                    break;
                                }
                                std::thread::sleep(Duration::from_millis(4));
                            }
                            Err(error) => {
                                let _ = events.send_ephemeral(WireDriverEvent::new(
                                    "terminalError",
                                    serde_json::Value::String(error.to_string()),
                                ));
                                break;
                            }
                        }
                    }
                })
                .context("start terminal output thread")?;

            Ok(Self {
                pty,
                stopped,
                child_exited,
                pty_closed,
                reader: Some(reader),
            })
        }

        pub fn write(&self, data: Vec<u8>) -> anyhow::Result<()> {
            if data.is_empty() {
                return Ok(());
            }
            let mut pty = self.pty.lock();
            pty.writer()
                .write_all(&data)
                .context("write terminal input")?;
            pty.writer().flush().context("flush terminal input")
        }

        pub fn resize(&self, cols: u16, rows: u16) {
            self.pty.lock().on_resize(window_size(cols, rows));
        }

        #[cfg(test)]
        pub(crate) fn stop_reader_for_test(&mut self) {
            self.stopped.store(true, Ordering::Release);
            if let Some(reader) = self.reader.take() {
                reader.join().unwrap();
            }
        }
    }

    impl DaemonTerminal {
        fn child_has_exited(&self) -> bool {
            if self.child_exited.load(Ordering::Acquire) {
                return true;
            }
            if self.pty.lock().next_child_event().is_some() {
                self.child_exited.store(true, Ordering::Release);
                return true;
            }
            false
        }

        fn teardown_complete(&self) -> bool {
            self.child_has_exited() && self.pty_closed.load(Ordering::Acquire)
        }

        fn terminal_process_groups(&self) -> (libc::pid_t, libc::pid_t) {
            let pty = self.pty.lock();
            let shell_group = pty.child().id() as libc::pid_t;
            let foreground_group = unsafe { libc::tcgetpgrp(pty.file().as_raw_fd()) };
            (shell_group, foreground_group)
        }

        fn signal_process_groups(groups: (libc::pid_t, libc::pid_t), signal: libc::c_int) {
            let (shell_group, foreground_group) = groups;
            // Alacritty starts the shell with `setsid`, but an interactive
            // shell gives its foreground job a different process group. Signal
            // both or that job can keep the PTY slave open after the shell is
            // gone and strand Alacritty's child wait.
            unsafe {
                if foreground_group > 0 && foreground_group != shell_group {
                    libc::kill(-foreground_group, signal);
                }
                libc::kill(-shell_group, signal);
                libc::kill(shell_group, signal);
            }
        }
    }

    impl Drop for DaemonTerminal {
        fn drop(&mut self) {
            // Hang the shell up, then keep the output reader running while it
            // exits. Draining the master here is not optional: a shell with
            // unread bytes still in the PTY blocks writing its own exit
            // output, and alacritty's `Pty::drop` reaps the child with an
            // unbounded `Child::wait`, so stopping the reader first deadlocks
            // this thread forever — for the daemon that means the session's
            // request worker never answers another command.
            let initial_groups = self.terminal_process_groups();
            Self::signal_process_groups(initial_groups, libc::SIGHUP);
            // Poll the child event directly as well as letting the reader do
            // so. A reader that exits on an I/O error must not be mistaken for
            // a shell that has exited.
            let deadline = std::time::Instant::now() + SHELL_EXIT_GRACE;
            while !self.teardown_complete() && std::time::Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(4));
            }
            // A shell that ignores SIGHUP, or is wedged on something other
            // than its own output, must not outlive the grace. The child is
            // still unreaped here — alacritty reaps it below — so its pid
            // cannot yet have been reused by another process.
            if !self.teardown_complete() {
                // The shell can exit after forwarding SIGHUP, at which point
                // tcgetpgrp falls back to its old group even though the former
                // foreground job still owns the slave. Retain and kill the
                // group observed before hangup as well as the current groups.
                Self::signal_process_groups(initial_groups, libc::SIGKILL);
                let current_groups = self.terminal_process_groups();
                if current_groups != initial_groups {
                    Self::signal_process_groups(current_groups, libc::SIGKILL);
                }
                let kill_deadline = std::time::Instant::now() + SHELL_EXIT_GRACE;
                while !self.child_has_exited() && std::time::Instant::now() < kill_deadline {
                    std::thread::sleep(Duration::from_millis(4));
                }
            }
            self.stopped.store(true, Ordering::Release);
            if let Some(reader) = self.reader.take() {
                let _ = reader.join();
            }
        }
    }

    fn window_size(cols: u16, rows: u16) -> WindowSize {
        WindowSize {
            num_lines: rows.max(MIN_ROWS),
            num_cols: cols.max(MIN_COLUMNS),
            cell_width: CELL_WIDTH,
            cell_height: CELL_HEIGHT,
        }
    }
}

#[cfg(unix)]
pub use platform::DaemonTerminal;

#[cfg(not(unix))]
pub struct DaemonTerminal;

#[cfg(not(unix))]
impl DaemonTerminal {
    pub fn open(_cwd: &Path, _cols: u16, _rows: u16, _events: EventSink) -> anyhow::Result<Self> {
        bail!("daemon terminals are not supported on this platform")
    }

    pub fn write(&self, _data: Vec<u8>) -> anyhow::Result<()> {
        bail!("daemon terminals are not supported on this platform")
    }

    pub fn resize(&self, _cols: u16, _rows: u16) {}
}
