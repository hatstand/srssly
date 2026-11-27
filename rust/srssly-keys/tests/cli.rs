//! End-to-end tests of key management through the `srssly-keys` CLI.

use std::path::PathBuf;
use std::process::Command;

use serde_json::Value;
use tempfile::TempDir;

struct Env {
    dir: TempDir,
}

struct Output {
    ok: bool,
    json: Value,
}

impl Env {
    fn new() -> Self {
        Self {
            dir: TempDir::new().unwrap(),
        }
    }

    fn path(&self, name: &str) -> PathBuf {
        self.dir.path().join(name)
    }

    fn run(&self, args: &[&str]) -> Output {
        let out = Command::new(env!("CARGO_BIN_EXE_srssly-keys"))
            .args(args)
            .current_dir(self.dir.path())
            .output()
            .unwrap();
        let stream = if out.status.success() {
            &out.stdout
        } else {
            &out.stderr
        };
        let text = String::from_utf8_lossy(stream);
        let json = serde_json::from_str(&text)
            .unwrap_or_else(|_| panic!("{args:?} printed non-JSON: {text}"));
        Output {
            ok: out.status.success(),
            json,
        }
    }

    fn ok(&self, args: &[&str]) -> Value {
        let out = self.run(args);
        assert!(out.ok, "{args:?} failed: {}", out.json);
        out.json
    }

    fn err(&self, args: &[&str]) -> String {
        let out = self.run(args);
        assert!(!out.ok, "{args:?} unexpectedly succeeded: {}", out.json);
        out.json["error"].as_str().unwrap().to_owned()
    }

    fn new_passkey(&self, name: &str) -> Value {
        self.ok(&["passkey", "new", "--out", name])
    }
}

#[test]
fn software_passkeys() {
    let e = Env::new();
    let a = e.new_passkey("a.json");
    let b = e.new_passkey("b.json");
    assert_ne!(a["credential_id"], b["credential_id"]);
}

#[test]
fn create_account() {
    let e = Env::new();
    e.new_passkey("a.json");
    let created = e.ok(&[
        "create",
        "--account",
        "acct.json",
        "--device",
        "dev.json",
        "--passkey",
        "a.json",
        "--label",
        "laptop",
    ]);
    assert_eq!(created["epoch"], 0);
    assert_eq!(created["passkeys"], 1);
    let account = std::fs::read_to_string(e.path("acct.json")).unwrap();
    assert!(account.contains("\"laptop\""));
}

#[test]
fn account_file_holds_no_secrets() {
    let e = Env::new();
    e.new_passkey("a.json");
    e.ok(&[
        "create",
        "--account",
        "acct.json",
        "--device",
        "dev.json",
        "--passkey",
        "a.json",
    ]);
    let account = std::fs::read_to_string(e.path("acct.json")).unwrap();
    let device: Value =
        serde_json::from_str(&std::fs::read_to_string(e.path("dev.json")).unwrap()).unwrap();
    assert!(!account.contains(device["root_secret"].as_str().unwrap()));
}

#[test]
fn errors_are_json_with_codes() {
    let e = Env::new();
    assert_eq!(
        e.err(&["passkey", "new", "--out", "missing-dir/a.json"]),
        "io"
    );
    let create = |pk| {
        [
            "create",
            "--account",
            "a.json",
            "--device",
            "d.json",
            "--passkey",
            pk,
        ]
    };
    assert_eq!(e.err(&create("missing.json")), "io");
    std::fs::write(e.path("bad.json"), "{}").unwrap();
    assert_eq!(e.err(&create("bad.json")), "malformed");
}
