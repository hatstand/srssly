//! Command-line tool for manual and automated testing of Srssly key management.
//!
//! Files it reads and writes:
//! - account file: the `AccountKeys` record the relay would store (no secrets).
//! - device file: an unlocked root secret, standing in for a device's
//!   Keychain or Keystore. TEST ONLY: it holds the root secret in plain text.
//! - passkey file: a software passkey (`SoftPasskey`). TEST ONLY.
//!
//! Every command prints one JSON object on stdout. On failure it prints
//! `{"error": "<code>", "message": "..."}` on stderr and exits with status 1.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use clap::{Parser, Subcommand};
use serde::Serialize;
use serde_json::{Value, json};
use srssly_keys::{CredentialIdHash, PrfAuthenticator, SoftPasskey};

#[derive(Parser)]
#[command(name = "srssly-keys", version, about)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Software passkeys for testing.
    #[command(subcommand)]
    Passkey(PasskeyCommand),
}

#[derive(Subcommand)]
enum PasskeyCommand {
    /// Create a software passkey.
    New {
        #[arg(long)]
        out: PathBuf,
    },
}

struct CliError {
    code: &'static str,
    message: String,
}

impl CliError {
    fn io(path: &Path, e: impl std::fmt::Display) -> Self {
        let message = format!("{}: {e}", path.display());
        Self {
            code: "io",
            message,
        }
    }
}

fn write(path: &Path, contents: &str) -> Result<(), CliError> {
    fs::write(path, contents).map_err(|e| CliError::io(path, e))
}

fn write_json(path: &Path, value: &impl Serialize) -> Result<(), CliError> {
    write(
        path,
        &serde_json::to_string_pretty(value).expect("serializable"),
    )
}

fn run(cli: Cli) -> Result<Value, CliError> {
    match cli.command {
        Command::Passkey(PasskeyCommand::New { out }) => {
            let pk = SoftPasskey::generate();
            write_json(&out, &pk)?;
            Ok(json!({
                "credential_id": B64.encode(pk.credential_id()),
                "credential_id_hash": CredentialIdHash::of(pk.credential_id()).to_base64url(),
            }))
        }
    }
}

fn main() -> ExitCode {
    match run(Cli::parse()) {
        Ok(value) => {
            println!("{value}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("{}", json!({ "error": e.code, "message": e.message }));
            ExitCode::FAILURE
        }
    }
}
