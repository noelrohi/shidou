//! The demo's operational log — the only place a demo message is ever written.
//!
//! `shidou.dev/privacy` makes a narrow, specific promise about this daemon:
//!
//! > Messages typed into the demo land in server logs alongside the
//! > requester's IP address and a timestamp. Those logs exist only to tell us
//! > whether the demo is up. They are deleted after 7 days. They are not sold,
//! > not shared, and not used to train anything.
//!
//! That sentence is the contract, so this module is built to it exactly:
//!
//! * **One destination.** Records go to stderr and nowhere else. The demo
//!   opens no database, writes no transcript, and has no crash reporter, so a
//!   prompt cannot come to rest anywhere but the host's journal. Every other
//!   piece of state the daemon holds is a fixture built in memory.
//! * **The IP comes from the proxy.** TLS terminates at Caddy in front of this
//!   process, so the daemon sees a loopback peer and could only ever log a
//!   useless address. The reverse proxy's access log carries the real IP and
//!   the same timestamp, which is what correlates the two halves.
//! * **Seven days is somebody's job.** Deletion is log rotation on the host
//!   (see the demo host provisioning ticket), because a ceiling that only
//!   intent enforces is not a ceiling. This process retains nothing to expire.
//!
//! Widening what is recorded here widens the published policy and the App
//! Privacy label with it. Before adding a field, check it against the sentence
//! above.

use std::io::Write as _;

/// Prompts are logged whole up to this length. The cap is operational — a
/// pasted file should not push the record that says the demo is up out of a
/// rotated log — and it only ever records *less* than the policy allows.
const MAX_LOGGED_PROMPT_CHARS: usize = 512;

pub enum Record<'a> {
    /// The daemon is accepting connections.
    Listening {
        address: &'a str,
    },
    /// A client started a runtime for a session.
    RuntimeStarted {
        session: &'a str,
    },
    /// A message a tester typed. The one record that carries user content.
    Prompt {
        session: &'a str,
        text: &'a str,
    },
    /// A request the fixture refused, with the reason a client was given.
    Refused {
        command: &'a str,
        reason: &'a str,
    },
    Stopping,
}

/// Writes one record to stderr.
///
/// Field order is fixed and values are quoted, so `grep prompt` over the
/// host's journal answers "is the demo being used" without a parser.
pub fn record(record: Record<'_>) {
    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let line = match record {
        Record::Listening { address } => format!("event=listening address={address}"),
        Record::RuntimeStarted { session } => format!("event=runtime_started session={session}"),
        Record::Prompt { session, text } => format!(
            "event=prompt session={session} message={}",
            quote(&truncate(text))
        ),
        Record::Refused { command, reason } => {
            format!("event=refused command={command} reason={}", quote(reason))
        }
        Record::Stopping => "event=stopping".to_owned(),
    };
    let mut stderr = std::io::stderr().lock();
    let _ = writeln!(stderr, "{now} {line}");
}

fn truncate(text: &str) -> String {
    let mut truncated = text
        .chars()
        .take(MAX_LOGGED_PROMPT_CHARS)
        .collect::<String>();
    if truncated.chars().count() < text.chars().count() {
        truncated.push('…');
    }
    truncated
}

/// Keeps a record on one line: newlines and quotes inside a message must not
/// be able to forge a second record.
fn quote(value: &str) -> String {
    let mut quoted = String::with_capacity(value.len() + 2);
    quoted.push('"');
    for character in value.chars() {
        match character {
            '"' => quoted.push_str("\\\""),
            '\\' => quoted.push_str("\\\\"),
            '\n' => quoted.push_str("\\n"),
            '\r' => quoted.push_str("\\r"),
            '\t' => quoted.push_str("\\t"),
            other => quoted.push(other),
        }
    }
    quoted.push('"');
    quoted
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_message_cannot_forge_a_second_record() {
        let forged = quote("hello\n2026-01-01T00:00:00Z event=listening address=evil");

        assert!(!forged.contains('\n'));
        assert!(forged.starts_with('"') && forged.ends_with('"'));
    }

    #[test]
    fn quotes_and_backslashes_survive_escaping() {
        assert_eq!(quote(r#"say "hi"\"#), r#""say \"hi\"\\""#);
    }

    #[test]
    fn a_long_prompt_is_capped_and_marked_as_capped() {
        let long = "x".repeat(MAX_LOGGED_PROMPT_CHARS * 2);
        let truncated = truncate(&long);

        assert_eq!(truncated.chars().count(), MAX_LOGGED_PROMPT_CHARS + 1);
        assert!(truncated.ends_with('…'));
        assert_eq!(truncate("short"), "short");
    }

    #[test]
    fn multibyte_prompts_are_cut_on_character_boundaries() {
        let long = "日".repeat(MAX_LOGGED_PROMPT_CHARS * 2);

        assert_eq!(truncate(&long).chars().count(), MAX_LOGGED_PROMPT_CHARS + 1);
    }
}
