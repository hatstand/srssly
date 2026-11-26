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
use clap::{Args, Parser, Subcommand};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use srssly_keys::{
    AccountId, AccountKeys, CredentialIdHash, Error, PRF_INPUT, PrfAuthenticator, PrfOutput,
    RootSecret, SoftPasskey,
};

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
    /// Create an account with a new root secret and its first passkey.
    Create {
        #[arg(long)]
        account: PathBuf,
        /// Where to save the unlocked root secret.
        #[arg(long)]
        device: PathBuf,
        #[command(flatten)]
        passkey: PasskeyArgs,
        #[arg(long, default_value = "passkey")]
        label: String,
    },
    /// Unlock the root secret with a passkey.
    Unlock {
        #[arg(long)]
        account: PathBuf,
        #[command(flatten)]
        passkey: PasskeyArgs,
        /// Save the unlocked root secret here.
        #[arg(long)]
        device_out: Option<PathBuf>,
    },
}

#[derive(Subcommand)]
enum PasskeyCommand {
    /// Create a software passkey.
    New {
        #[arg(long)]
        out: PathBuf,
    },
    /// Evaluate a software passkey's PRF, as a browser would report it.
    Prf {
        #[arg(long)]
        passkey: PathBuf,
        /// The WebAuthn PRF input; defaults to the one Srssly uses.
        #[arg(long)]
        input: Option<String>,
    },
}

/// Either a software passkey file, or a credential ID and PRF output taken
/// from a real authenticator (for example a browser's WebAuthn PRF result).
#[derive(Args)]
struct PasskeyArgs {
    /// A software passkey file.
    #[arg(long, required_unless_present = "prf", conflicts_with_all = ["credential_id", "prf"])]
    passkey: Option<PathBuf>,
    /// Credential ID, base64url.
    #[arg(long, requires = "prf", allow_hyphen_values = true)]
    credential_id: Option<String>,
    /// PRF output for Srssly's PRF input, base64url (32 bytes).
    #[arg(long, requires = "credential_id", allow_hyphen_values = true)]
    prf: Option<String>,
}

impl PasskeyArgs {
    fn resolve(&self) -> Result<(Vec<u8>, PrfOutput), CliError> {
        if let Some(path) = &self.passkey {
            let pk: SoftPasskey = read_json(path)?;
            let prf = pk.evaluate_prf(PRF_INPUT)?;
            return Ok((pk.credential_id().to_vec(), prf));
        }
        let id = decode(
            self.credential_id.as_deref().unwrap_or_default(),
            "credential ID",
        )?;
        let prf = decode(self.prf.as_deref().unwrap_or_default(), "PRF output")?;
        let prf: [u8; 32] = prf
            .try_into()
            .map_err(|_| CliError::usage("PRF output must be 32 bytes"))?;
        Ok((id, PrfOutput::from_bytes(prf)))
    }
}

/// The device file: an unlocked root secret. TEST ONLY.
#[derive(Serialize, Deserialize)]
struct Device {
    account_id: AccountId,
    epoch: u32,
    root_secret: String,
}

impl Device {
    fn new(keys: &AccountKeys, root: &RootSecret) -> Self {
        Self {
            account_id: keys.account_id,
            epoch: keys.epoch,
            root_secret: B64.encode(root.export().as_slice()),
        }
    }
}

struct CliError {
    code: &'static str,
    message: String,
}

impl CliError {
    fn usage(message: impl Into<String>) -> Self {
        let message = message.into();
        Self {
            code: "usage",
            message,
        }
    }

    fn io(path: &Path, e: impl std::fmt::Display) -> Self {
        let message = format!("{}: {e}", path.display());
        Self {
            code: "io",
            message,
        }
    }
}

impl From<Error> for CliError {
    fn from(e: Error) -> Self {
        Self {
            code: e.code(),
            message: e.to_string(),
        }
    }
}

fn read(path: &Path) -> Result<String, CliError> {
    fs::read_to_string(path).map_err(|e| CliError::io(path, e))
}

fn read_json<T: for<'de> Deserialize<'de>>(path: &Path) -> Result<T, CliError> {
    serde_json::from_str(&read(path)?).map_err(|e| CliError {
        code: "malformed",
        message: format!("{}: {e}", path.display()),
    })
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

fn decode(s: &str, what: &str) -> Result<Vec<u8>, CliError> {
    B64.decode(s)
        .map_err(|_| CliError::usage(format!("{what} is not valid base64url")))
}

fn read_account(path: &Path) -> Result<AccountKeys, CliError> {
    Ok(AccountKeys::from_json(&read(path)?)?)
}

fn write_account(path: &Path, keys: &AccountKeys) -> Result<(), CliError> {
    write(path, &keys.to_json())
}

fn summary(keys: &AccountKeys) -> Value {
    json!({
        "account_id": keys.account_id.to_string(),
        "epoch": keys.epoch,
        "key_check": B64.encode(keys.key_check.as_bytes()),
        "auth_public_key": B64.encode(keys.auth_public_key),
        "passkeys": keys.passkeys.len(),
    })
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
        Command::Passkey(PasskeyCommand::Prf { passkey, input }) => {
            let pk: SoftPasskey = read_json(&passkey)?;
            let input = input.map_or(PRF_INPUT.to_vec(), String::into_bytes);
            let prf = pk.evaluate_prf(&input)?;
            Ok(json!({
                "credential_id": B64.encode(pk.credential_id()),
                "prf": B64.encode(prf.as_bytes()),
            }))
        }
        Command::Create {
            account,
            device,
            passkey,
            label,
        } => {
            let (id, prf) = passkey.resolve()?;
            let (keys, root) = AccountKeys::create_with_prf(&id, &prf, &label)?;
            write_account(&account, &keys)?;
            write_json(&device, &Device::new(&keys, &root))?;
            Ok(summary(&keys))
        }
        Command::Unlock {
            account,
            passkey,
            device_out,
        } => {
            let keys = read_account(&account)?;
            let (id, prf) = passkey.resolve()?;
            let root = keys.unlock_with_prf(&id, &prf)?;
            if let Some(path) = device_out {
                write_json(&path, &Device::new(&keys, &root))?;
            }
            Ok(summary(&keys))
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
