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
fn full_lifecycle() {
    let e = Env::new();
    e.new_passkey("a.json");
    e.new_passkey("b.json");
    let c = e.new_passkey("c.json");

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
    let account_id = created["account_id"].clone();

    // A second and third passkey, added from the unlocked device.
    e.ok(&[
        "add-passkey",
        "--account",
        "acct.json",
        "--device",
        "dev.json",
        "--passkey",
        "b.json",
        "--label",
        "phone",
    ]);
    let added = e.ok(&[
        "add-passkey",
        "--account",
        "acct.json",
        "--device",
        "dev.json",
        "--passkey",
        "c.json",
        "--label",
        "yubikey",
    ]);
    assert_eq!(added["passkeys"], 3);
    assert_eq!(
        e.err(&[
            "add-passkey",
            "--account",
            "acct.json",
            "--device",
            "dev.json",
            "--passkey",
            "b.json"
        ]),
        "duplicate_passkey"
    );

    let list = e.ok(&["list", "--account", "acct.json"]);
    let labels: Vec<&str> = list["passkeys"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["label"].as_str().unwrap())
        .collect();
    assert_eq!(labels, ["laptop", "phone", "yubikey"]);

    // Every passkey unlocks the same account on a fresh device.
    for pk in ["a.json", "b.json", "c.json"] {
        let dev = format!("new-{pk}");
        let out = e.ok(&[
            "unlock",
            "--account",
            "acct.json",
            "--passkey",
            pk,
            "--device-out",
            &dev,
        ]);
        assert_eq!(out["account_id"], account_id);
        e.ok(&["verify", "--account", "acct.json", "--device", &dev]);
    }

    // An unregistered passkey can't.
    e.new_passkey("stranger.json");
    assert_eq!(
        e.err(&[
            "unlock",
            "--account",
            "acct.json",
            "--passkey",
            "stranger.json"
        ]),
        "unknown_passkey"
    );

    // Remove by credential ID hash.
    let hash = c["credential_id_hash"].as_str().unwrap();
    let removed = e.ok(&[
        "remove-passkey",
        "--account",
        "acct.json",
        "--credential-id-hash",
        hash,
    ]);
    assert_eq!(removed["removed"], "yubikey");
    assert_eq!(
        e.err(&["unlock", "--account", "acct.json", "--passkey", "c.json"]),
        "unknown_passkey"
    );

    // Recovery key works until rotation.
    let words = e.ok(&["recovery-key", "--device", "dev.json"])["words"]
        .as_str()
        .unwrap()
        .to_owned();
    e.ok(&[
        "recover",
        "--account",
        "acct.json",
        "--words",
        &words,
        "--device-out",
        "recovered.json",
    ]);
    e.ok(&[
        "verify",
        "--account",
        "acct.json",
        "--device",
        "recovered.json",
    ]);

    // Rotate: passkeys still unlock, old devices and recovery keys don't.
    let before = e.ok(&["verify", "--account", "acct.json", "--device", "dev.json"]);
    let rotated = e.ok(&["rotate", "--account", "acct.json", "--device", "dev.json"]);
    assert_eq!(rotated["epoch"], 1);
    assert_eq!(rotated["account_id"], account_id);
    assert_ne!(rotated["auth_public_key"], before["auth_public_key"]);
    e.ok(&["verify", "--account", "acct.json", "--device", "dev.json"]);
    assert_eq!(
        e.err(&[
            "verify",
            "--account",
            "acct.json",
            "--device",
            "recovered.json"
        ]),
        "wrong_root_secret"
    );
    assert_eq!(
        e.err(&["recover", "--account", "acct.json", "--words", &words]),
        "wrong_root_secret"
    );
    for pk in ["a.json", "b.json"] {
        assert_eq!(
            e.ok(&["unlock", "--account", "acct.json", "--passkey", pk])["epoch"],
            1
        );
    }

    // The last passkey can't be removed.
    e.ok(&[
        "remove-passkey",
        "--account",
        "acct.json",
        "--passkey",
        "b.json",
    ]);
    assert_eq!(
        e.err(&[
            "remove-passkey",
            "--account",
            "acct.json",
            "--passkey",
            "a.json"
        ]),
        "last_passkey"
    );
}

#[test]
fn raw_prf_matches_software_passkey() {
    // A real authenticator is driven by passing its credential ID and PRF
    // output; check that path agrees with the software passkey.
    let e = Env::new();
    e.new_passkey("a.json");
    let prf = e.ok(&["passkey", "prf", "--passkey", "a.json"]);
    let id = prf["credential_id"].as_str().unwrap();
    let out = prf["prf"].as_str().unwrap();

    e.ok(&[
        "create",
        "--account",
        "acct.json",
        "--device",
        "dev.json",
        "--credential-id",
        id,
        "--prf",
        out,
    ]);
    e.ok(&["unlock", "--account", "acct.json", "--passkey", "a.json"]);

    let mut wrong = out.to_owned();
    wrong.replace_range(0..1, if wrong.starts_with('A') { "B" } else { "A" });
    assert_eq!(
        e.err(&[
            "unlock",
            "--account",
            "acct.json",
            "--credential-id",
            id,
            "--prf",
            &wrong
        ]),
        "wrong_passkey"
    );
}

#[test]
fn account_file_holds_no_secrets() {
    let e = Env::new();
    e.new_passkey("a.json");
    let prf = e.ok(&["passkey", "prf", "--passkey", "a.json"])["prf"]
        .as_str()
        .unwrap()
        .to_owned();
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
    assert!(!account.contains(&prf));
}

#[test]
fn errors_are_json_with_codes() {
    let e = Env::new();
    assert_eq!(e.err(&["list", "--account", "missing.json"]), "io");
    std::fs::write(e.path("bad.json"), "{}").unwrap();
    assert_eq!(e.err(&["list", "--account", "bad.json"]), "malformed");
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
    assert_eq!(
        e.err(&["recover", "--account", "acct.json", "--words", "not words"]),
        "invalid_recovery_key"
    );
    assert_eq!(
        e.err(&[
            "unlock",
            "--account",
            "acct.json",
            "--credential-id",
            "!!",
            "--prf",
            "AA"
        ]),
        "usage"
    );
}
