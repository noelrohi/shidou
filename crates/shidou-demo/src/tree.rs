//! The Demo Session's workspace: a repository that exists only in memory.
//!
//! Every read-only workspace surface in the app — the file tree, the file
//! viewer, the changes pane, the visuals grid, the project picker's Browse…
//! — is answered from the tables below rather than from the demo host's
//! filesystem. A reviewer therefore sees a believable project, and the demo
//! binary never opens a path a client named.
//!
//! Paths read as a macOS checkout because that is where a real Shidou session
//! lives. Nothing here resolves against the host, so the demo runs the same on
//! the Linux VPS that serves it.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use anyhow::{anyhow, bail};
use shidou_protocol::composer::{CommandScope, FileEntry, SlashCommand};
use shidou_protocol::git::{BranchEntry, BranchSnapshot, CommitSnapshot};
use shidou_protocol::workspace::{
    ReviewDiffData, ReviewDiffSource, WorkingTreeEntry, WorkingTreeStatus,
};

pub const HOME: &str = "/Users/demo";
pub const WORKSPACE_ROOT: &str = "/Users/demo/Developer/shidou";
pub const NOTES_ROOT: &str = "/Users/demo/Developer/notes";

/// The file the scripted turn edits. Its diff is the one the changes surface,
/// the review diff, and the transcript's file-change row all describe.
pub const EDITED_FILE: &str = "src/limiter.rs";

pub const BRANCH: &str = "demo/rate-limiter";
pub const DEFAULT_BRANCH: &str = "main";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Content {
    Directory,
    Text(&'static str),
    /// Rendered by [`crate::blobs`] from these dimensions and hue, so the
    /// bytes are a pure function of the entry.
    Image {
        width: u32,
        height: u32,
        hue: u32,
    },
}

#[derive(Clone, Copy, Debug)]
pub struct Node {
    pub relative_path: &'static str,
    pub content: Content,
    /// Only leaves declare a status; ancestors inherit the strongest one, the
    /// way `git status --porcelain` is folded into a tree on a real host.
    pub status: Option<WorkingTreeStatus>,
}

const fn dir(relative_path: &'static str) -> Node {
    Node {
        relative_path,
        content: Content::Directory,
        status: None,
    }
}

const fn text(relative_path: &'static str, body: &'static str) -> Node {
    Node {
        relative_path,
        content: Content::Text(body),
        status: None,
    }
}

const fn changed(mut node: Node, status: WorkingTreeStatus) -> Node {
    node.status = Some(status);
    node
}

pub const WORKSPACE: &[Node] = &[
    text("Cargo.toml", CARGO_TOML),
    text("README.md", README),
    dir("assets"),
    Node {
        relative_path: "assets/latency-after.png",
        content: Content::Image {
            width: 480,
            height: 300,
            hue: 152,
        },
        status: Some(WorkingTreeStatus::Untracked),
    },
    Node {
        relative_path: "assets/latency-before.png",
        content: Content::Image {
            width: 480,
            height: 300,
            hue: 8,
        },
        status: None,
    },
    dir("docs"),
    text("docs/architecture.md", ARCHITECTURE),
    dir("src"),
    changed(
        text("src/limiter.rs", LIMITER_AFTER),
        WorkingTreeStatus::Modified,
    ),
    text("src/main.rs", MAIN),
    text("src/routes.rs", ROUTES),
];

const NOTES: &[Node] = &[
    text(
        "Inbox.md",
        "# Inbox\n\n- Ask about the rate limiter rollout\n",
    ),
    dir("weekly"),
    text(
        "weekly/2026-08-24.md",
        "# Week of 24 August\n\n- Shipped the pairing flow\n- Started the limiter fix\n",
    ),
];

/// Directories the project picker's Browse… can walk. Only these exist; a
/// path outside them is reported as missing rather than probed on the host.
const BROWSABLE: &[&str] = &[
    "/",
    "/Users",
    "/Users/demo",
    "/Users/demo/Developer",
    "/Users/demo/Developer/notes",
    "/Users/demo/Developer/scratch",
    "/Users/demo/Developer/shidou",
    "/Users/demo/Documents",
    "/Users/demo/Downloads",
];

/// Resolves a workspace root to the node table that backs it.
fn nodes_for(root: &Path) -> anyhow::Result<&'static [Node]> {
    match root.to_str() {
        Some(WORKSPACE_ROOT) => Ok(WORKSPACE),
        Some(NOTES_ROOT) => Ok(NOTES),
        _ => bail!(
            "{} is not part of the Shidou demo workspace",
            root.display()
        ),
    }
}

fn node(root: &Path, relative_path: &str) -> Option<&'static Node> {
    nodes_for(root)
        .ok()?
        .iter()
        .find(|node| node.relative_path == relative_path)
}

/// Every image in the demo workspace, as `(root-relative path, content)`.
pub fn images() -> impl Iterator<Item = (&'static str, Content)> {
    WORKSPACE
        .iter()
        .chain(NOTES)
        .filter(|node| matches!(node.content, Content::Image { .. }))
        .map(|node| (node.relative_path, node.content))
}

/// Working-copy status per root-relative path, with directories carrying the
/// strongest status among their descendants.
fn statuses(nodes: &[Node]) -> Vec<(&'static str, WorkingTreeStatus)> {
    let mut statuses: Vec<(&'static str, WorkingTreeStatus)> = Vec::new();
    for node in nodes {
        let Some(status) = node.status else { continue };
        let mut path = node.relative_path;
        loop {
            match statuses.iter_mut().find(|(known, _)| *known == path) {
                Some(entry) if status == WorkingTreeStatus::Modified => entry.1 = status,
                Some(_) => {}
                None => statuses.push((path, status)),
            }
            let Some(index) = path.rfind('/') else { break };
            path = &path[..index];
        }
    }
    statuses
}

pub fn list_tree(root: &Path, expanded_paths: &[PathBuf]) -> anyhow::Result<Vec<WorkingTreeEntry>> {
    let nodes = nodes_for(root)?;
    let statuses = statuses(nodes);
    let mut entries = Vec::new();
    for node in nodes {
        let depth = node.relative_path.matches('/').count();
        let parent = node.relative_path.rsplit_once('/').map(|(head, _)| head);
        // A child is listed only when every directory above it is expanded,
        // which is what the real tree's recursive walk produces.
        if let Some(parent) = parent
            && !entries
                .iter()
                .any(|entry: &WorkingTreeEntry| entry.relative_path == parent && entry.expanded)
        {
            continue;
        }
        let absolute_path = root.join(node.relative_path);
        let is_dir = matches!(node.content, Content::Directory);
        entries.push(WorkingTreeEntry {
            relative_path: node.relative_path.to_owned(),
            name: node
                .relative_path
                .rsplit('/')
                .next()
                .unwrap_or(node.relative_path)
                .to_owned(),
            is_dir,
            expanded: is_dir && expanded_paths.iter().any(|path| path == &absolute_path),
            depth,
            status: statuses
                .iter()
                .find(|(path, _)| *path == node.relative_path)
                .map(|(_, status)| *status),
            absolute_path,
        });
    }
    Ok(entries)
}

pub fn read_text_file(root: &Path, relative_path: &Path) -> anyhow::Result<String> {
    let relative = relative_path
        .to_str()
        .ok_or_else(|| anyhow!("workspace path is not valid UTF-8"))?;
    match node(root, relative).map(|node| node.content) {
        Some(Content::Text(body)) => Ok(body.to_owned()),
        Some(Content::Image { .. }) => bail!("{relative} is an image, not a text file"),
        Some(Content::Directory) => bail!("{relative} is a directory"),
        None => bail!("{relative} does not exist in the Shidou demo workspace"),
    }
}

/// Mirrors the daemon's project-file listing: directories carry a trailing
/// slash, and shallow entries sort first so an empty query opens on the
/// project's own top level.
pub fn list_project_files(root: &Path, cap: usize) -> anyhow::Result<Vec<FileEntry>> {
    let nodes = nodes_for(root)?;
    let files = nodes
        .iter()
        .filter(|node| !matches!(node.content, Content::Directory))
        .map(|node| node.relative_path.to_owned())
        .collect::<Vec<_>>();
    let mut directories = BTreeSet::new();
    for file in &files {
        let mut path = file.as_str();
        while let Some(index) = path.rfind('/') {
            path = &path[..index];
            if !directories.insert(path.to_owned()) {
                break;
            }
        }
    }
    let mut entries = directories
        .into_iter()
        .map(|directory| FileEntry {
            path: format!("{directory}/"),
            is_dir: true,
        })
        .chain(files.into_iter().map(|path| FileEntry {
            path,
            is_dir: false,
        }))
        .collect::<Vec<_>>();
    entries.sort_by(|left, right| {
        let depth = |entry: &FileEntry| entry.path.matches('/').count() - usize::from(entry.is_dir);
        (depth(left), left.path.clone()).cmp(&(depth(right), right.path.clone()))
    });
    entries.truncate(cap);
    Ok(entries)
}

pub struct Directory {
    pub path: PathBuf,
    pub parent: Option<PathBuf>,
    pub entries: Vec<WorkingTreeEntry>,
}

pub fn browse(path: Option<&Path>) -> anyhow::Result<Directory> {
    let path = path.unwrap_or(Path::new(HOME));
    let key = path
        .to_str()
        .ok_or_else(|| anyhow!("directory path is not valid UTF-8"))?
        .trim_end_matches('/');
    let key = if key.is_empty() { "/" } else { key };
    if !BROWSABLE.contains(&key) {
        bail!("{key} is not part of the Shidou demo filesystem");
    }
    let prefix = if key == "/" {
        "/".to_owned()
    } else {
        format!("{key}/")
    };
    let mut entries = BROWSABLE
        .iter()
        .filter(|candidate| **candidate != key)
        .filter_map(|candidate| candidate.strip_prefix(&prefix))
        .filter(|remainder| !remainder.is_empty() && !remainder.contains('/'))
        .map(|name| WorkingTreeEntry {
            relative_path: name.to_owned(),
            absolute_path: PathBuf::from(format!("{prefix}{name}")),
            name: name.to_owned(),
            is_dir: true,
            expanded: false,
            depth: 0,
            status: None,
        })
        .collect::<Vec<_>>();
    entries.sort_by_key(|entry| entry.name.to_lowercase());
    Ok(Directory {
        parent: (key != "/").then(|| {
            PathBuf::from(match key.rsplit_once('/') {
                Some(("", _)) | None => "/".to_owned(),
                Some((head, _)) => head.to_owned(),
            })
        }),
        path: PathBuf::from(key),
        entries,
    })
}

pub fn branch_snapshot(root: &Path) -> anyhow::Result<BranchSnapshot> {
    nodes_for(root)?;
    Ok(BranchSnapshot {
        repository: root.to_owned(),
        current: Some(BRANCH.to_owned()),
        detached_head: None,
        default_branch: Some(DEFAULT_BRANCH.to_owned()),
        branches: [DEFAULT_BRANCH, BRANCH, "demo/pairing-qr"]
            .into_iter()
            .map(|name| BranchEntry {
                name: name.to_owned(),
                checked_out_elsewhere: name == "demo/pairing-qr",
            })
            .collect(),
        additions: ADDITIONS,
        deletions: DELETIONS,
    })
}

pub fn commit_snapshot(root: &Path) -> anyhow::Result<CommitSnapshot> {
    nodes_for(root)?;
    Ok(CommitSnapshot {
        branch: BRANCH.to_owned(),
        additions: ADDITIONS,
        deletions: DELETIONS,
        staged_additions: 0,
        staged_deletions: 0,
        has_staged: false,
        has_unstaged: true,
        can_push: true,
    })
}

pub fn review_diff(root: &Path, source: ReviewDiffSource) -> anyhow::Result<ReviewDiffData> {
    nodes_for(root)?;
    Ok(ReviewDiffData {
        source,
        numstat: format!("{ADDITIONS}\t{DELETIONS}\t{EDITED_FILE}\n"),
        patch: LIMITER_PATCH.to_owned(),
        complete_context: true,
    })
}

/// The commands the demo project advertises. Deliberately provider-neutral:
/// the real discovery walks per-provider directories, and there are none here.
pub fn slash_commands() -> Vec<SlashCommand> {
    [
        ("review", "Review the working tree", CommandScope::Project),
        ("changelog", "Draft a changelog entry", CommandScope::User),
        ("tdd", "Drive the change test-first", CommandScope::Skill),
    ]
    .into_iter()
    .map(|(name, description, scope)| SlashCommand {
        name: name.to_owned(),
        description: description.to_owned(),
        scope,
        argument_hint: None,
        template: None,
    })
    .collect()
}

/// Line counts for the one edited file, kept beside the patch they describe.
pub const ADDITIONS: u64 = 11;
pub const DELETIONS: u64 = 6;

pub const LIMITER_PATCH: &str = include_str!("fixtures/limiter.patch");
const LIMITER_AFTER: &str = include_str!("fixtures/limiter.rs.txt");
const CARGO_TOML: &str = include_str!("fixtures/Cargo.toml.txt");
const README: &str = include_str!("fixtures/README.md.txt");
const ARCHITECTURE: &str = include_str!("fixtures/architecture.md.txt");
const MAIN: &str = include_str!("fixtures/main.rs.txt");
const ROUTES: &str = include_str!("fixtures/routes.rs.txt");

#[cfg(test)]
mod tests {
    use super::*;

    fn root() -> PathBuf {
        PathBuf::from(WORKSPACE_ROOT)
    }

    #[test]
    fn a_collapsed_tree_lists_only_the_top_level() {
        let entries = list_tree(&root(), &[]).unwrap();

        assert!(entries.iter().all(|entry| entry.depth == 0));
        assert_eq!(
            entries
                .iter()
                .map(|entry| entry.name.as_str())
                .collect::<Vec<_>>(),
            ["Cargo.toml", "README.md", "assets", "docs", "src"]
        );
    }

    #[test]
    fn expanding_a_directory_reveals_its_children_at_the_next_depth() {
        let entries = list_tree(&root(), &[root().join("src")]).unwrap();
        let children = entries
            .iter()
            .filter(|entry| entry.depth == 1)
            .map(|entry| entry.relative_path.as_str())
            .collect::<Vec<_>>();

        assert_eq!(children, ["src/limiter.rs", "src/main.rs", "src/routes.rs"]);
        assert!(
            entries
                .iter()
                .any(|entry| entry.name == "src" && entry.expanded)
        );
    }

    #[test]
    fn a_changed_file_marks_every_directory_above_it() {
        let entries = list_tree(&root(), &[root().join("src")]).unwrap();
        let status = |path: &str| {
            entries
                .iter()
                .find(|entry| entry.relative_path == path)
                .and_then(|entry| entry.status)
        };

        assert_eq!(status("src/limiter.rs"), Some(WorkingTreeStatus::Modified));
        assert_eq!(status("src"), Some(WorkingTreeStatus::Modified));
        assert_eq!(status("assets"), Some(WorkingTreeStatus::Untracked));
        assert_eq!(status("src/main.rs"), None);
    }

    #[test]
    fn text_files_read_back_and_other_paths_report_why_not() {
        assert!(
            read_text_file(&root(), Path::new(EDITED_FILE))
                .unwrap()
                .contains("refill")
        );
        assert!(read_text_file(&root(), Path::new("src")).is_err());
        assert!(read_text_file(&root(), Path::new("../../etc/passwd")).is_err());
        assert!(read_text_file(Path::new("/etc"), Path::new("passwd")).is_err());
    }

    #[test]
    fn the_project_file_listing_puts_shallow_entries_first() {
        let entries = list_project_files(&root(), 64).unwrap();

        assert_eq!(entries[0].path, "Cargo.toml");
        assert!(
            entries
                .iter()
                .any(|entry| entry.path == "src/" && entry.is_dir)
        );
        assert!(
            entries
                .iter()
                .any(|entry| entry.path == "assets/latency-after.png")
        );
    }

    #[test]
    fn browsing_walks_only_the_demo_filesystem() {
        let home = browse(None).unwrap();

        assert_eq!(home.path, PathBuf::from(HOME));
        assert_eq!(home.parent, Some(PathBuf::from("/Users")));
        assert_eq!(
            home.entries
                .iter()
                .map(|entry| entry.name.as_str())
                .collect::<Vec<_>>(),
            ["Developer", "Documents", "Downloads"]
        );
        assert_eq!(browse(Some(Path::new("/"))).unwrap().parent, None);
        assert!(browse(Some(Path::new("/etc"))).is_err());
    }

    #[test]
    fn the_review_diff_numstat_agrees_with_the_branch_snapshot() {
        let diff = review_diff(&root(), ReviewDiffSource::Uncommitted).unwrap();
        let snapshot = branch_snapshot(&root()).unwrap();

        assert_eq!(
            diff.numstat,
            format!(
                "{}\t{}\t{EDITED_FILE}\n",
                snapshot.additions, snapshot.deletions
            )
        );
        assert!(diff.patch.starts_with("diff --git"));
        assert!(commit_snapshot(&root()).unwrap().can_push);
    }

    /// The patch is the same text the transcript's file-change row carries, so
    /// a hand edit to one and not the other would show two different diffs.
    #[test]
    fn the_patch_line_counts_match_its_declared_numstat() {
        let additions = LIMITER_PATCH
            .lines()
            .filter(|line| line.starts_with('+') && !line.starts_with("+++"))
            .count() as u64;
        let deletions = LIMITER_PATCH
            .lines()
            .filter(|line| line.starts_with('-') && !line.starts_with("---"))
            .count() as u64;

        assert_eq!((additions, deletions), (ADDITIONS, DELETIONS));
    }
}
