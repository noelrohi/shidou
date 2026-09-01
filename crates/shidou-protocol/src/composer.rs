use serde::{Deserialize, Serialize};
use ts_rs::TS;

use crate::model::ProviderKind;

#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize, TS)]
pub enum CommandScope {
    Project,
    User,
    Skill,
    Builtin,
}

impl CommandScope {
    /// Presentation order in the composer picker. Resolution precedence is
    /// separate: project and user commands can still override less-specific
    /// commands with the same name.
    pub const fn display_rank(self) -> u8 {
        match self {
            Self::Builtin => 0,
            Self::Project => 1,
            Self::User => 2,
            Self::Skill => 3,
        }
    }

    pub fn label(self) -> String {
        match self {
            Self::Project => tr!("command_scope.project"),
            Self::User => tr!("command_scope.user"),
            Self::Skill => tr!("command_scope.skill"),
            Self::Builtin => tr!("command_scope.builtin"),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize, TS)]
pub struct SlashCommand {
    pub name: String,
    pub description: String,
    pub scope: CommandScope,
    pub argument_hint: Option<String>,
    pub template: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize, TS)]
pub struct FileEntry {
    pub path: String,
    pub is_dir: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum LocalComposerCommand {
    NewSession,
    CopyLastResponse,
    RenameSession(String),
    Compact(String),
}

/// Resolve a command that the client owns instead of sending it to the provider.
pub fn local_composer_command(
    provider: ProviderKind,
    prompt: &str,
    commands: &[SlashCommand],
) -> Option<LocalComposerCommand> {
    if provider != ProviderKind::Pi {
        return None;
    }
    let prompt = prompt.trim_end();
    let (name, action) = match prompt {
        "/new" => ("new", LocalComposerCommand::NewSession),
        "/copy" => ("copy", LocalComposerCommand::CopyLastResponse),
        "/name" => ("name", LocalComposerCommand::RenameSession(String::new())),
        "/compact" => ("compact", LocalComposerCommand::Compact(String::new())),
        _ if let Some(name) = prompt.strip_prefix("/name ") => (
            "name",
            LocalComposerCommand::RenameSession(name.trim().to_owned()),
        ),
        _ if let Some(instructions) = prompt.strip_prefix("/compact ") => (
            "compact",
            LocalComposerCommand::Compact(instructions.trim().to_owned()),
        ),
        _ => return None,
    };
    commands
        .iter()
        .any(|command| command.name == name && command.scope == CommandScope::Builtin)
        .then_some(action)
}
