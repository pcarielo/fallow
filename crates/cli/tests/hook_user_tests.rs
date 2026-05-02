use std::os::unix::fs::PermissionsExt;

use fallow_cli::hook_user;

#[test]
fn install_writes_script_and_settings() {
    let temp = tempfile::tempdir().expect("tempdir");
    let home = temp.path().to_path_buf();

    hook_user::install_at(&home).expect("install ok");

    let script = home.join(".claude").join("hooks").join("fallow-stop-gate.sh");
    assert!(script.exists(), "script not created");

    let settings = home.join(".claude").join("settings.json");
    let body = std::fs::read_to_string(&settings).expect("read settings");
    assert!(body.contains("fallow-stop-gate.sh"), "settings missing entry");
}

#[test]
fn install_creates_dirs_and_correct_mode() {
    let temp = tempfile::tempdir().expect("tempdir");
    let home = temp.path();
    hook_user::install_at(home).expect("install");

    let hooks_dir = home.join(".claude").join("hooks");
    let script = hooks_dir.join("fallow-stop-gate.sh");
    assert!(hooks_dir.is_dir());
    let mode = std::fs::metadata(&script).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o755, "script must be 0755, got {mode:o}");

    let settings_text = std::fs::read_to_string(home.join(".claude").join("settings.json")).unwrap();
    let settings: serde_json::Value = serde_json::from_str(&settings_text).unwrap();
    let stop_arr = settings
        .pointer("/hooks/Stop")
        .and_then(|v| v.as_array())
        .expect("Stop array");
    let any = stop_arr.iter().any(|entry| {
        entry
            .pointer("/hooks/0/command")
            .and_then(|v| v.as_str())
            .is_some_and(|s| s.contains("fallow-stop-gate.sh"))
    });
    assert!(any, "Stop array missing fallow-stop-gate entry: {settings_text}");
}

#[test]
fn install_is_idempotent_and_preserves_other_hooks() {
    let temp = tempfile::tempdir().expect("tempdir");
    let home = temp.path();
    let claude = home.join(".claude");
    std::fs::create_dir_all(&claude).unwrap();
    let settings = claude.join("settings.json");
    std::fs::write(
        &settings,
        r#"{
      "hooks": {
        "Stop": [
          {"matcher":"","hooks":[{"type":"command","command":"/usr/bin/env hookz-speaker"}]}
        ]
      }
    }"#,
    )
    .unwrap();

    fallow_cli::hook_user::install_at(home).expect("install 1");
    fallow_cli::hook_user::install_at(home).expect("install 2 (idempotent)");

    let body = std::fs::read_to_string(&settings).unwrap();
    let v: serde_json::Value = serde_json::from_str(&body).unwrap();
    let stop = v.pointer("/hooks/Stop").and_then(|s| s.as_array()).unwrap();
    assert_eq!(stop.len(), 2, "must have hookz + fallow-stop-gate, got {body}");

    let entries: Vec<&str> = stop
        .iter()
        .filter_map(|e| e.pointer("/hooks/0/command").and_then(|c| c.as_str()))
        .collect();
    assert!(
        entries.iter().any(|s| s.contains("hookz-speaker")),
        "hookz preserved"
    );
    assert!(
        entries.iter().any(|s| s.contains("fallow-stop-gate.sh")),
        "fallow added"
    );
}

#[test]
fn uninstall_removes_only_our_entry() {
    let temp = tempfile::tempdir().expect("tempdir");
    let home = temp.path();
    let claude = home.join(".claude");
    std::fs::create_dir_all(&claude).unwrap();
    std::fs::write(
        claude.join("settings.json"),
        r#"{
      "hooks": {
        "Stop": [
          {"matcher":"","hooks":[{"type":"command","command":"/usr/bin/env hookz-speaker"}]}
        ]
      }
    }"#,
    )
    .unwrap();

    fallow_cli::hook_user::install_at(home).expect("install");
    fallow_cli::hook_user::uninstall_at(home).expect("uninstall");

    let body = std::fs::read_to_string(claude.join("settings.json")).unwrap();
    let v: serde_json::Value = serde_json::from_str(&body).unwrap();
    let stop = v.pointer("/hooks/Stop").and_then(|s| s.as_array()).unwrap();
    assert_eq!(stop.len(), 1);
    let cmd = stop[0]
        .pointer("/hooks/0/command")
        .and_then(|c| c.as_str())
        .unwrap();
    assert!(cmd.contains("hookz-speaker"));

    let script = home.join(".claude").join("hooks").join("fallow-stop-gate.sh");
    assert!(!script.exists(), "script must be removed");
}

#[test]
fn install_aborts_cleanly_on_corrupt_settings() {
    let temp = tempfile::tempdir().expect("tempdir");
    let home = temp.path();
    let claude = home.join(".claude");
    std::fs::create_dir_all(&claude).unwrap();
    std::fs::write(claude.join("settings.json"), b"{ this is not json").unwrap();
    let err = fallow_cli::hook_user::install_at(home).unwrap_err();
    assert!(matches!(
        err,
        fallow_cli::hook_user::HookUserError::Json { .. }
    ));
}

#[test]
fn cli_init_hook_user_invokes_install() {
    let temp = tempfile::tempdir().expect("tempdir");
    let home = temp.path();
    let bin = env!("CARGO_BIN_EXE_fallow");

    let status = std::process::Command::new(bin)
        .args(["init", "--hook-user"])
        .env("HOME", home)
        .status()
        .expect("spawn fallow init");
    assert!(status.success(), "init --hook-user failed: {status}");
    assert!(home
        .join(".claude")
        .join("hooks")
        .join("fallow-stop-gate.sh")
        .exists());

    let status = std::process::Command::new(bin)
        .args(["init", "--hook-user", "--uninstall"])
        .env("HOME", home)
        .status()
        .expect("spawn fallow init uninstall");
    assert!(status.success());
    assert!(!home
        .join(".claude")
        .join("hooks")
        .join("fallow-stop-gate.sh")
        .exists());
}
