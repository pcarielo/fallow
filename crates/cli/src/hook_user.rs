//! User-scope Stop hook installer for Claude Code.
//!
//! Writes `~/.claude/hooks/fallow-stop-gate.sh` and merges a Stop hook
//! entry into `~/.claude/settings.json`. Idempotent and reversible.

use std::fmt;
use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Map;

const SCRIPT: &str = include_str!("setup_hooks/fallow-stop-gate.sh");
const HOOK_COMMAND: &str = "\"$HOME\"/.claude/hooks/fallow-stop-gate.sh";

/// Errors from `install_at` / `uninstall_at`.
#[derive(Debug)]
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

fn io_err(path: &Path, source: std::io::Error) -> HookUserError {
    HookUserError::Io {
        path: path.display().to_string(),
        source,
    }
}

fn json_err(path: &Path, source: serde_json::Error) -> HookUserError {
    HookUserError::Json {
        path: path.display().to_string(),
        source,
    }
}

fn write_atomic(path: &Path, body: &[u8], mode: u32) -> Result<(), HookUserError> {
    let parent = path.parent().expect("write_atomic: path must have a parent");
    fs::create_dir_all(parent).map_err(|e| io_err(parent, e))?;
    let tmp = parent.join(format!(
        ".{}.tmp",
        path.file_name().unwrap().to_string_lossy()
    ));
    {
        let mut f = fs::File::create(&tmp).map_err(|e| io_err(&tmp, e))?;
        f.write_all(body).map_err(|e| io_err(&tmp, e))?;
        let mut perms = f.metadata().map_err(|e| io_err(&tmp, e))?.permissions();
        perms.set_mode(mode);
        f.set_permissions(perms).map_err(|e| io_err(&tmp, e))?;
    }
    fs::rename(&tmp, path).map_err(|e| io_err(path, e))?;
    Ok(())
}

fn settings_path(home: &Path) -> PathBuf {
    home.join(".claude").join("settings.json")
}

fn script_path(home: &Path) -> PathBuf {
    home.join(".claude")
        .join("hooks")
        .join("fallow-stop-gate.sh")
}

fn load_settings(path: &Path) -> Result<serde_json::Value, HookUserError> {
    if !path.exists() {
        return Ok(serde_json::json!({}));
    }
    let body = fs::read_to_string(path).map_err(|e| io_err(path, e))?;
    if body.trim().is_empty() {
        return Ok(serde_json::json!({}));
    }
    serde_json::from_str(&body).map_err(|e| json_err(path, e))
}

/// Insert the fallow-stop-gate Stop entry if not already present.
/// Returns `true` if settings was modified, `false` if already installed.
fn ensure_stop_entry(settings: &mut serde_json::Value) -> bool {
    use serde_json::{json, Value};
    let obj = settings
        .as_object_mut()
        .expect("ensure_stop_entry: caller must pass an object");
    let hooks = obj
        .entry("hooks")
        .or_insert_with(|| Value::Object(Map::default()));
    let hooks_obj = hooks
        .as_object_mut()
        .expect("hooks must be an object");
    let stop = hooks_obj
        .entry("Stop")
        .or_insert_with(|| Value::Array(Vec::new()));
    let stop_arr = stop.as_array_mut().expect("Stop must be an array");

    let already = stop_arr.iter().any(|entry| {
        entry
            .pointer("/hooks")
            .and_then(|h| h.as_array())
            .is_some_and(|hs| {
                hs.iter().any(|h| {
                    h.get("command")
                        .and_then(|c| c.as_str())
                        .is_some_and(|s| s.contains("fallow-stop-gate.sh"))
                })
            })
    });
    if already {
        return false;
    }

    stop_arr.push(json!({
        "matcher": "",
        "hooks": [
            {
                "type": "command",
                "command": HOOK_COMMAND,
                "timeout": 130
            }
        ]
    }));
    true
}

/// Install the user-scope Stop hook into `home/.claude/`.
pub fn install_at(home: &Path) -> Result<(), HookUserError> {
    let script = script_path(home);
    write_atomic(&script, SCRIPT.as_bytes(), 0o755)?;

    let settings = settings_path(home);
    let mut value = load_settings(&settings)?;
    if value.is_null() {
        value = serde_json::json!({});
    }
    if !value.is_object() {
        return Err(HookUserError::NotAnObject {
            path: settings.display().to_string(),
        });
    }
    if ensure_stop_entry(&mut value) {
        if settings.exists() {
            let secs = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_or(0, |d| d.as_secs());
            let backup = settings.with_extension(format!("json.bak.{secs}"));
            fs::copy(&settings, &backup).map_err(|e| io_err(&backup, e))?;
        }
        let body = serde_json::to_vec_pretty(&value).expect("serialize settings.json");
        write_atomic(&settings, &body, 0o644)?;
        eprintln!("✓ Installed user-scope fallow-stop-gate hook.");
    } else {
        eprintln!("ℹ Already installed (no changes to settings.json).");
    }

    Ok(())
}

/// Uninstall the user-scope Stop hook from `home/.claude/`.
pub fn uninstall_at(home: &Path) -> Result<(), HookUserError> {
    let settings = settings_path(home);
    if settings.exists() {
        let mut value = load_settings(&settings)?;
        let changed = if let Some(stop) = value
            .pointer_mut("/hooks/Stop")
            .and_then(|s| s.as_array_mut())
        {
            let before = stop.len();
            stop.retain(|entry| {
                let owns = entry
                    .pointer("/hooks")
                    .and_then(|h| h.as_array())
                    .is_some_and(|hs| {
                        hs.iter().any(|h| {
                            h.get("command")
                                .and_then(|c| c.as_str())
                                .is_some_and(|s| s.contains("fallow-stop-gate.sh"))
                        })
                    });
                !owns
            });
            stop.len() != before
        } else {
            false
        };
        if changed {
            let body = serde_json::to_vec_pretty(&value).expect("serialize settings.json");
            write_atomic(&settings, &body, 0o644)?;
        }
    }

    let script = script_path(home);
    if script.exists() {
        fs::remove_file(&script).map_err(|e| io_err(&script, e))?;
    }
    eprintln!("✓ Uninstalled user-scope fallow-stop-gate hook.");
    Ok(())
}
