use std::process::Command;

#[test]
#[allow(clippy::print_stderr, reason = "test diagnostic output on failure")]
fn fallow_stop_gate_bash_suite() {
    let manifest = env!("CARGO_MANIFEST_DIR");
    let script = format!("{manifest}/tests/fallow_stop_gate/run.sh");
    let output = Command::new("bash")
        .arg(&script)
        .output()
        .expect("failed to spawn bash test runner");
    if !output.status.success() {
        eprintln!(
            "--- stdout ---\n{}",
            String::from_utf8_lossy(&output.stdout)
        );
        eprintln!(
            "--- stderr ---\n{}",
            String::from_utf8_lossy(&output.stderr)
        );
        panic!("fallow-stop-gate bash suite failed");
    }
}
