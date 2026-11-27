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

#[cfg(unix)]
#[test]
fn secret_files_are_private() {
    use std::os::unix::fs::PermissionsExt;
    let e = Env::new();
    let mode = |name| {
        std::fs::metadata(e.path(name))
            .unwrap()
            .permissions()
            .mode()
            & 0o777
    };
    std::fs::write(e.path("a.json"), "").unwrap();
    std::fs::set_permissions(e.path("a.json"), std::fs::Permissions::from_mode(0o644)).unwrap();
    e.new_passkey("a.json");
    e.ok(&[
        "create",
        "--account",
        "acct",
        "--device",
        "d",
        "--passkey",
        "a.json",
    ]);
    assert_eq!((mode("a.json"), mode("d")), (0o600, 0o600));
}

#[test]
fn software_passkeys() {
    let e = Env::new();
    let a = e.new_passkey("a.json");
    let b = e.new_passkey("b.json");
    assert_ne!(a["credential_id"], b["credential_id"]);
    let prf = e.ok(&["passkey", "prf", "--passkey", "a.json"]);
    assert_eq!(prf["credential_id"], a["credential_id"]);
    assert_eq!(prf, e.ok(&["passkey", "prf", "--passkey", "a.json"]));
    let other = e.ok(&["passkey", "prf", "--passkey", "a.json", "--input", "other"]);
    assert_ne!(prf["prf"], other["prf"]);
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
fn create_then_unlock() {
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
    assert_eq!(
        (created["epoch"].clone(), created["passkeys"].clone()),
        (0.into(), 1.into())
    );
    let unlocked = e.ok(&[
        "unlock",
        "--account",
        "acct.json",
        "--passkey",
        "a.json",
        "--device-out",
        "dev2.json",
    ]);
    let mut expected = created.clone();
    expected["rebound"] = false.into();
    assert_eq!(unlocked, expected);
    let dev = std::fs::read_to_string(e.path("dev.json")).unwrap();
    assert_eq!(dev, std::fs::read_to_string(e.path("dev2.json")).unwrap());

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
}

#[test]
fn manage_passkeys() {
    let e = Env::new();
    e.new_passkey("a.json");
    e.new_passkey("b.json");
    let c = e.new_passkey("c.json");
    e.ok(&[
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
    let add = |pk, label| {
        [
            "add-passkey",
            "--account",
            "acct.json",
            "--device",
            "dev.json",
            "--passkey",
            pk,
            "--label",
            label,
        ]
    };
    e.ok(&add("b.json", "phone"));
    assert_eq!(e.ok(&add("c.json", "yubikey"))["passkeys"], 3);
    assert_eq!(e.err(&add("b.json", "again")), "duplicate_passkey");

    let list = e.ok(&["list", "--account", "acct.json"]);
    let labels: Vec<&str> = list["passkeys"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["label"].as_str().unwrap())
        .collect();
    assert_eq!(labels, ["laptop", "phone", "yubikey"]);
    assert_eq!(list["verified"], false);
    let list = e.ok(&["list", "--account", "acct.json", "--device", "dev.json"]);
    assert_eq!(list["verified"], true);

    // Every passkey unlocks the same account on a fresh device.
    for pk in ["a.json", "b.json", "c.json"] {
        let dev = format!("new-{pk}");
        e.ok(&[
            "unlock",
            "--account",
            "acct.json",
            "--passkey",
            pk,
            "--device-out",
            &dev,
        ]);
        e.ok(&["verify", "--account", "acct.json", "--device", &dev]);
    }

    // Remove by credential ID hash, then by passkey file; never the last.
    let hash = c["credential_id_hash"].as_str().unwrap();
    let removed = e.ok(&[
        "remove-passkey",
        "--account",
        "acct.json",
        "--device",
        "dev.json",
        "--credential-id-hash",
        hash,
    ]);
    assert_eq!(removed["removed"], "yubikey");
    assert_eq!(
        e.err(&["unlock", "--account", "acct.json", "--passkey", "c.json"]),
        "unknown_passkey"
    );
    e.ok(&[
        "remove-passkey",
        "--account",
        "acct.json",
        "--device",
        "dev.json",
        "--passkey",
        "b.json",
    ]);
    assert_eq!(
        e.err(&[
            "remove-passkey",
            "--account",
            "acct.json",
            "--device",
            "dev.json",
            "--passkey",
            "a.json"
        ]),
        "last_passkey"
    );
}

#[test]
fn verify_rejects_another_accounts_device() {
    let e = Env::new();
    e.new_passkey("a.json");
    e.ok(&[
        "create",
        "--account",
        "one.json",
        "--device",
        "one-dev.json",
        "--passkey",
        "a.json",
    ]);
    e.ok(&[
        "create",
        "--account",
        "two.json",
        "--device",
        "two-dev.json",
        "--passkey",
        "a.json",
    ]);
    let ok = e.ok(&[
        "verify",
        "--account",
        "one.json",
        "--device",
        "one-dev.json",
    ]);
    assert_eq!(ok["derived_auth_public_key"], ok["auth_public_key"]);
    assert_eq!(
        e.err(&[
            "verify",
            "--account",
            "one.json",
            "--device",
            "two-dev.json"
        ]),
        "wrong_root_secret"
    );
}

#[test]
fn recovery_key_and_rotation() {
    let e = Env::new();
    e.new_passkey("a.json");
    e.new_passkey("b.json");
    let created = e.ok(&[
        "create",
        "--account",
        "acct.json",
        "--device",
        "dev.json",
        "--passkey",
        "a.json",
    ]);
    e.ok(&[
        "add-passkey",
        "--account",
        "acct.json",
        "--device",
        "dev.json",
        "--passkey",
        "b.json",
    ]);

    // The recovery key unlocks a new device.
    let words = e.ok(&["recovery-key", "--device", "dev.json"])["words"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(words.split(' ').count(), 24);
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

    // Rotation keeps the account and passkeys but retires the old secret.
    let rotated = e.ok(&["rotate", "--account", "acct.json", "--device", "dev.json"]);
    assert_eq!(rotated["epoch"], 1);
    assert_eq!(rotated["account_id"], created["account_id"]);
    assert_ne!(rotated["auth_public_key"], created["auth_public_key"]);
    e.ok(&["verify", "--account", "acct.json", "--device", "dev.json"]);
    // The first unlock after a rotation rebinds the passkey; the next doesn't.
    for pk in ["a.json", "b.json"] {
        let unlock = ["unlock", "--account", "acct.json", "--passkey", pk];
        let first = e.ok(&unlock);
        assert_eq!(
            (&first["epoch"], &first["rebound"]),
            (&1.into(), &true.into())
        );
        assert_eq!(e.ok(&unlock)["rebound"], false);
    }
    let stale = [
        "verify",
        "--account",
        "acct.json",
        "--device",
        "recovered.json",
    ];
    assert_eq!(e.err(&stale), "wrong_root_secret");
    let old_words = ["recover", "--account", "acct.json", "--words", &words];
    assert_eq!(e.err(&old_words), "wrong_root_secret");
    let bad_words = ["recover", "--account", "acct.json", "--words", "not words"];
    assert_eq!(e.err(&bad_words), "invalid_recovery_key");
}

#[test]
fn errors_are_json_with_codes() {
    let e = Env::new();
    assert_eq!(
        e.err(&["passkey", "prf", "--passkey", "missing.json"]),
        "io"
    );
    std::fs::write(e.path("bad.json"), "{}").unwrap();
    assert_eq!(
        e.err(&["passkey", "prf", "--passkey", "bad.json"]),
        "malformed"
    );
    e.new_passkey("a.json");
    assert_eq!(
        e.err(&["unlock", "--account", "bad.json", "--passkey", "a.json"]),
        "malformed"
    );
    let raw = |id, prf| {
        [
            "create",
            "--account",
            "a",
            "--device",
            "d",
            "--credential-id",
            id,
            "--prf",
            prf,
        ]
    };
    assert_eq!(e.err(&raw("!!", "AA")), "usage");
    assert_eq!(e.err(&raw("AA", "AA")), "usage");
    // 32 zero bytes: well-formed, but not a PRF output.
    assert_eq!(e.err(&raw("AA", &"A".repeat(43))), "usage");
}

#[test]
fn raw_values_may_start_with_a_hyphen() {
    // base64url uses '-', so a random credential ID or PRF can start with one.
    let e = Env::new();
    let prf = "-AECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";
    let created = e.ok(&[
        "create",
        "--account",
        "a",
        "--device",
        "d",
        "--credential-id",
        "-AAA",
        "--prf",
        prf,
    ]);
    assert_eq!(created["epoch"], 0);
}
