use fallow_cli::hook_user;

#[ignore = "Task 12 implements install_at"]
#[test]
fn install_writes_script_and_settings() {
    let temp = tempfile::tempdir().expect("tempdir");
    let home = temp.path().to_path_buf();

    hook_user::install_at(&home).expect("install ok");

    let script = home
        .join(".claude")
        .join("hooks")
        .join("fallow-stop-gate.sh");
    assert!(script.exists(), "script not created");

    let settings = home.join(".claude").join("settings.json");
    let body = std::fs::read_to_string(&settings).expect("read settings");
    assert!(
        body.contains("fallow-stop-gate.sh"),
        "settings missing entry"
    );
}
