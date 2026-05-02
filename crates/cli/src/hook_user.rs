//! User-scope Stop hook installer for Claude Code.
//!
//! Writes `~/.claude/hooks/fallow-stop-gate.sh` and merges a Stop hook
//! entry into `~/.claude/settings.json`. Idempotent and reversible.

use std::fmt;
use std::path::Path;

/// Errors from `install_at` / `uninstall_at`.
#[derive(Debug)]
#[allow(
    dead_code,
    reason = "variants constructed by Task 12–14 implementations; stub phase only"
)]
pub enum HookUserError {
    /// I/O error at a specific path.
    Io {
        path: String,
        source: std::io::Error,
    },
    /// settings.json is malformed.
    Json {
        path: String,
        source: serde_json::Error,
    },
    /// settings.json top level is not a JSON object.
    NotAnObject { path: String },
}

impl fmt::Display for HookUserError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io { path, source } => write!(f, "io error at {path}: {source}"),
            Self::Json { path, source } => {
                write!(f, "settings.json malformed at {path}: {source}")
            }
            Self::NotAnObject { path } => {
                write!(f, "settings.json top level must be a JSON object at {path}")
            }
        }
    }
}

impl std::error::Error for HookUserError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io { source, .. } => Some(source),
            Self::Json { source, .. } => Some(source),
            Self::NotAnObject { .. } => None,
        }
    }
}

/// Install the user-scope Stop hook into `home/.claude/`.
///
/// Tasks 12-13 implement this.
#[allow(clippy::unimplemented, reason = "stub — implemented in Task 12")]
pub fn install_at(_home: &Path) -> Result<(), HookUserError> {
    unimplemented!("Task 12 implements this")
}

/// Uninstall the user-scope Stop hook from `home/.claude/`.
///
/// Task 14 implements this.
#[allow(clippy::unimplemented, reason = "stub — implemented in Task 14")]
pub fn uninstall_at(_home: &Path) -> Result<(), HookUserError> {
    unimplemented!("Task 14 implements this")
}
