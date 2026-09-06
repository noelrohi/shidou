//! Computer Use helper process integration.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, SystemTime};

use anyhow::Context as _;
use uuid::Uuid;

use crate::computer_use;
use crate::driver::DriverEventSender;
use crate::fs_ext;
use crate::model::DriverEvent;

#[cfg(target_os = "macos")]
use std::ffi::OsString;
#[cfg(target_os = "macos")]
use std::os::unix::ffi::OsStringExt as _;

#[derive(Clone)]
pub(super) struct ComputerUseConfig {
    pub(super) server_path: PathBuf,
    pub(super) repl_path: PathBuf,
    pub(super) skill_path: PathBuf,
    pub(super) process_directory: PathBuf,
}

pub(super) struct ComputerUseRuntime {
    pub(super) config: ComputerUseConfig,
    preview_monitor: Option<ComputerUsePreviewMonitor>,
}

impl ComputerUseRuntime {
    pub(super) fn start(events: DriverEventSender) -> anyhow::Result<Self> {
        let server_path = computer_use::mcp_server_command()?;
        let repl_path = computer_use::js_repl_server_path()?;
        let skill_path = computer_use::skill_root_path()?
            .join("shidou-computer-use")
            .join("SKILL.md");
        let process_directory = create_process_directory()?;
        let preview_monitor =
            match ComputerUsePreviewMonitor::start(process_directory.clone(), events) {
                Ok(monitor) => monitor,
                Err(error) => {
                    let _ = fs::remove_dir_all(&process_directory);
                    return Err(error);
                }
            };
        Ok(Self {
            config: ComputerUseConfig {
                server_path,
                repl_path,
                skill_path,
                process_directory,
            },
            preview_monitor: Some(preview_monitor),
        })
    }

    pub(super) fn set_enabled(&self, enabled: bool) -> anyhow::Result<()> {
        // Revoke new actions without interrupting balanced input sequences or
        // breaking the persistent MCP connection needed for re-enable.
        set_enabled(&self.config.process_directory, enabled)
    }

    pub(super) fn stop(&self) {
        stop_registered_processes(&self.config.process_directory, &self.config.server_path);
    }
}

impl Drop for ComputerUseRuntime {
    fn drop(&mut self) {
        self.stop();
        drop(self.preview_monitor.take());
        let _ = fs::remove_dir_all(&self.config.process_directory);
    }
}

pub(super) struct ComputerUsePreviewMonitor {
    running: Arc<AtomicBool>,
}

impl ComputerUsePreviewMonitor {
    pub(super) fn start(directory: PathBuf, events: DriverEventSender) -> anyhow::Result<Self> {
        let running = Arc::new(AtomicBool::new(true));
        let thread_running = running.clone();
        thread::Builder::new()
            .name("shidou-computer-use-preview".into())
            .spawn(move || {
                let mut seen = HashMap::<PathBuf, (SystemTime, u64)>::new();
                while thread_running.load(Ordering::Acquire) {
                    if let Ok(entries) = fs::read_dir(&directory) {
                        for entry in entries.flatten() {
                            let path = entry.path();
                            let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
                                continue;
                            };
                            if !name.starts_with("preview-") || !name.ends_with(".json") {
                                continue;
                            }
                            let Ok(metadata) = entry.metadata() else {
                                continue;
                            };
                            let Ok(modified) = metadata.modified() else {
                                continue;
                            };
                            let revision = (modified, metadata.len());
                            if seen.get(&path) == Some(&revision) {
                                continue;
                            }
                            seen.insert(path.clone(), revision);
                            let Ok(data) = fs::read(&path) else {
                                continue;
                            };
                            if let Ok(state) = computer_use::decode_preview_update(&data) {
                                let _ = events.send(DriverEvent::ComputerUseUpdated(state));
                            }
                        }
                    }
                    thread::sleep(Duration::from_millis(50));
                }
            })
            .context("failed to start the Computer Use preview monitor")?;
        Ok(Self { running })
    }
}

impl Drop for ComputerUsePreviewMonitor {
    fn drop(&mut self) {
        self.running.store(false, Ordering::Release);
    }
}

pub(super) fn create_process_directory() -> anyhow::Result<PathBuf> {
    let directory = std::env::temp_dir()
        .join("shidou-computer-use")
        .join(Uuid::new_v4().simple().to_string());
    fs::create_dir_all(&directory).with_context(|| {
        format!(
            "could not create Computer Use process directory {}",
            directory.display()
        )
    })?;
    fs_ext::restrict_to_owner(&directory).with_context(|| {
        format!(
            "could not secure Computer Use process directory {}",
            directory.display()
        )
    })?;
    set_enabled(&directory, true)?;
    Ok(directory)
}

/// A positive authorization lease shared with the native helper. Missing leases
/// fail closed, including when the runtime directory has been removed. Keep the
/// filename in sync with ComputerUseAuthorization in ShidouComputerUse.swift.
pub(super) fn set_enabled(directory: &Path, enabled: bool) -> anyhow::Result<()> {
    let lease = directory.join("enabled");
    if enabled {
        // Unrelated settings updates must not briefly truncate a live lease.
        if fs::read(&lease).ok().as_deref() == Some(b"enabled") {
            return Ok(());
        }
        fs::write(&lease, b"enabled")
            .with_context(|| format!("could not enable Computer Use in {}", directory.display()))?;
    } else {
        match fs::remove_file(&lease) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error).context("could not disable Computer Use"),
        }
    }
    Ok(())
}

pub(super) fn stop_registered_processes(directory: &Path, helper_executable: &Path) {
    let expected_executable =
        fs::canonicalize(helper_executable).unwrap_or_else(|_| helper_executable.to_path_buf());
    for (pid, registration) in registered_processes(directory) {
        if process_executable(pid).as_deref() == Some(expected_executable.as_path()) {
            // Unreachable off unix, where `process_executable` never resolves
            // and the loop only clears stale registration files.
            #[cfg(unix)]
            unsafe {
                libc::kill(pid, libc::SIGTERM);
            }
        }
        let _ = fs::remove_file(registration);
    }
}

pub(super) fn registered_processes(directory: &Path) -> Vec<(i32, PathBuf)> {
    let Ok(entries) = fs::read_dir(directory) else {
        return Vec::new();
    };
    entries
        .filter_map(Result::ok)
        .filter_map(|entry| {
            if !entry.file_type().ok()?.is_file() {
                return None;
            }
            let pid = entry.file_name().to_str()?.parse::<i32>().ok()?;
            (pid > 1).then_some((pid, entry.path()))
        })
        .collect()
}

#[cfg(target_os = "macos")]
pub(super) fn process_executable(pid: i32) -> Option<PathBuf> {
    let mut buffer = vec![0_u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    let length = unsafe {
        libc::proc_pidpath(
            pid,
            buffer.as_mut_ptr().cast(),
            libc::PROC_PIDPATHINFO_MAXSIZE as u32,
        )
    };
    if length <= 0 {
        return None;
    }
    buffer.truncate(length as usize);
    Some(PathBuf::from(OsString::from_vec(buffer)))
}

#[cfg(target_os = "linux")]
pub(super) fn process_executable(pid: i32) -> Option<PathBuf> {
    fs::read_link(format!("/proc/{pid}/exe")).ok()
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
pub(super) fn process_executable(_: i32) -> Option<PathBuf> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn computer_use_lease_tracks_live_settings_and_fails_closed_after_cleanup() {
        let directory = create_process_directory().unwrap();
        let lease = directory.join("enabled");
        assert_eq!(fs::read(&lease).unwrap(), b"enabled");
        set_enabled(&directory, false).unwrap();
        assert!(!lease.exists());
        set_enabled(&directory, false).unwrap();
        set_enabled(&directory, true).unwrap();
        assert_eq!(fs::read(&lease).unwrap(), b"enabled");
        fs::remove_dir_all(&directory).unwrap();
        set_enabled(&directory, false).unwrap();
        assert!(set_enabled(&directory, true).is_err());
        assert!(!directory.exists());
    }

    #[test]
    fn computer_use_settings_are_session_scoped() {
        let first = create_process_directory().unwrap();
        let second = create_process_directory().unwrap();
        set_enabled(&first, false).unwrap();
        assert_eq!(fs::read(second.join("enabled")).unwrap(), b"enabled");
        // Authorization files must never be mistaken for helper PID records.
        assert!(registered_processes(&second).is_empty());
        fs::remove_dir_all(first).unwrap();
        fs::remove_dir_all(second).unwrap();
    }

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[test]
    fn computer_use_disable_preserves_helper_and_agent_while_revoking_lease() {
        use std::process::Command;
        let mut helper = Command::new("/bin/sleep").arg("30").spawn().unwrap();
        let mut agent = Command::new("/bin/sleep").arg("30").spawn().unwrap();
        let directory = create_process_directory().unwrap();
        fs::write(directory.join(helper.id().to_string()), b"").unwrap();
        let runtime = ComputerUseRuntime {
            config: ComputerUseConfig {
                server_path: PathBuf::from("/bin/sleep"),
                repl_path: PathBuf::new(),
                skill_path: PathBuf::new(),
                process_directory: directory.clone(),
            },
            preview_monitor: None,
        };
        runtime.set_enabled(false).unwrap();
        assert!(!directory.join("enabled").exists());
        // Give an accidental SIGTERM time to arrive before checking liveness.
        thread::sleep(Duration::from_millis(50));
        let helper_running = helper.try_wait().unwrap().is_none();
        let agent_running = agent.try_wait().unwrap().is_none();
        runtime.set_enabled(true).unwrap();
        assert_eq!(fs::read(directory.join("enabled")).unwrap(), b"enabled");
        assert_eq!(registered_processes(&directory).len(), 1);
        let _ = helper.kill();
        let _ = helper.wait();
        let _ = agent.kill();
        let _ = agent.wait();
        assert!(helper_running);
        assert!(agent_running);
    }
}
