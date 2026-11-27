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
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use clap::{Args, Parser, Subcommand};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use srssly_keys::{
    AccountId, AccountKeys, CredentialIdHash, Error, PRF_INPUT, PrfAuthenticator, PrfOutput,
    RecoveryKey, RootSecret, SoftPasskey,
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
    /// Register another passkey, using an unlocked device.
    AddPasskey {
        #[arg(long)]
        account: PathBuf,
        #[arg(long)]
        device: PathBuf,
        #[command(flatten)]
        passkey: PasskeyArgs,
        #[arg(long, default_value = "passkey")]
        label: String,
    },
    /// List registered passkeys.
    List {
        #[arg(long)]
        account: PathBuf,
    },
    /// Remove a passkey by credential ID hash or passkey file.
    RemovePasskey {
        #[arg(long)]
        account: PathBuf,
        /// An unlocked device, to re-sign the record.
        #[arg(long)]
        device: PathBuf,
        #[arg(long, conflicts_with = "passkey", required_unless_present = "passkey")]
        credential_id_hash: Option<String>,
        /// A software passkey file.
        #[arg(long)]
        passkey: Option<PathBuf>,
    },
    /// Replace the root secret and re-seal it to every passkey.
    Rotate {
        #[arg(long)]
        account: PathBuf,
        /// An unlocked device; updated with the new secret.
        #[arg(long)]
        device: PathBuf,
    },
    /// Print the recovery key (24 words) for an unlocked device.
    RecoveryKey {
        #[arg(long)]
        device: PathBuf,
    },
    /// Unlock with a recovery key.
    Recover {
        #[arg(long)]
        account: PathBuf,
        /// The 24 words, in one argument.
        #[arg(long)]
        words: String,
        #[arg(long)]
        device_out: Option<PathBuf>,
    },
    /// Check a device's root secret against the account and show its public keys.
    Verify {
        #[arg(long)]
        account: PathBuf,
        #[arg(long)]
        device: PathBuf,
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
        let mut prf: [u8; 32] = prf
            .try_into()
            .map_err(|_| CliError::usage("PRF output must be 32 bytes"))?;
        let prf = PrfOutput::from_bytes(&mut prf)
            .ok_or_else(|| CliError::usage("PRF output is not random"))?;
        Ok((id, prf))
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

    fn root(&self) -> Result<RootSecret, CliError> {
        let mut bytes: [u8; 32] = decode(&self.root_secret, "root secret")?
            .try_into()
            .map_err(|_| CliError::usage("root secret must be 32 bytes"))?;
        RootSecret::from_bytes(&mut bytes)
            .ok_or_else(|| CliError::usage("root secret is not random"))
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

/// Writes a file holding a secret (a device or passkey file), readable only
/// by its owner.
fn write_json(path: &Path, value: &impl Serialize) -> Result<(), CliError> {
    let contents = serde_json::to_string_pretty(value).expect("serializable");
    let mut options = fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let mut file = options.open(path).map_err(|e| CliError::io(path, e))?;
    // `mode` only applies to new files; tighten an existing one too.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        file.set_permissions(fs::Permissions::from_mode(0o600))
            .map_err(|e| CliError::io(path, e))?;
    }
    file.write_all(contents.as_bytes())
        .map_err(|e| CliError::io(path, e))
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
        "auth_public_key": B64.encode(keys.auth_public_key.to_bytes()),
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
                "prf": B64.encode(prf.export().as_slice()),
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
            write_json(&device, &Device::new(&keys, &root))?;
            write_account(&account, &keys)?;
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
        Command::AddPasskey {
            account,
            device,
            passkey,
            label,
        } => {
            let mut keys = read_account(&account)?;
            let root = read_json::<Device>(&device)?.root()?;
            let (id, prf) = passkey.resolve()?;
            keys.add_passkey_with_prf(&root, &id, &prf, &label)?;
            write_account(&account, &keys)?;
            Ok(summary(&keys))
        }
        Command::List { account } => {
            let keys = read_account(&account)?;
            let passkeys: Vec<Value> = keys
                .passkeys
                .iter()
                .map(|p| {
                    json!({
                        "label": p.label,
                        "credential_id_hash": p.credential_id_hash.to_base64url(),
                        "public_key": B64.encode(p.wrapped.public_key),
                    })
                })
                .collect();
            Ok(
                json!({ "account_id": keys.account_id.to_string(), "epoch": keys.epoch, "passkeys": passkeys }),
            )
        }
        Command::RemovePasskey {
            account,
            device,
            credential_id_hash,
            passkey,
        } => {
            let mut keys = read_account(&account)?;
            let root = read_json::<Device>(&device)?.root()?;
            let hash = match (credential_id_hash, passkey) {
                (Some(h), _) => CredentialIdHash::from_base64url(&h)?,
                (None, Some(path)) => {
                    CredentialIdHash::of(read_json::<SoftPasskey>(&path)?.credential_id())
                }
                (None, None) => unreachable!("clap requires one"),
            };
            let removed = keys.remove_passkey(&root, &hash)?;
            write_account(&account, &keys)?;
            let mut out = summary(&keys);
            out["removed"] = json!(removed.label);
            Ok(out)
        }
        Command::Rotate { account, device } => {
            let mut keys = read_account(&account)?;
            let root = read_json::<Device>(&device)?.root()?;
            let new_root = keys.rotate(&root)?;
            // Keep the new secret before publishing the record sealed to it,
            // as an app must: the other order can lose the account's keys.
            write_json(&device, &Device::new(&keys, &new_root))?;
            write_account(&account, &keys)?;
            Ok(summary(&keys))
        }
        Command::RecoveryKey { device } => {
            let root = read_json::<Device>(&device)?.root()?;
            Ok(json!({ "words": RecoveryKey::from_root(&root).words().as_str() }))
        }
        Command::Recover {
            account,
            words,
            device_out,
        } => {
            let keys = read_account(&account)?;
            let root = keys.unlock_with_recovery_key(&RecoveryKey::parse(&words)?)?;
            if let Some(path) = device_out {
                write_json(&path, &Device::new(&keys, &root))?;
            }
            Ok(summary(&keys))
        }
        Command::Verify { account, device } => {
            let keys = read_account(&account)?;
            let root = read_json::<Device>(&device)?.root()?;
            keys.verify_root(&root)?;
            let derived = root.derive(&keys.account_id);
            let mut out = summary(&keys);
            out["derived_auth_public_key"] =
                json!(B64.encode(derived.auth_public_key().to_bytes()));
            Ok(out)
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
