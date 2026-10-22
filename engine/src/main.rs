#![allow(
    clippy::needless_pass_by_value,
    reason = "Bevy system and mlua callback signatures are by-value by contract"
)]

use std::io::IsTerminal;
use std::path::PathBuf;
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::time::Duration;

use clap::{Parser, Subcommand};
use tracing::{info, warn};
use tracing_subscriber::{fmt, prelude::*, reload};

#[allow(dead_code)] // Dormant upstream UI; the app owns permission guidance.
mod accessibility_prompt;
mod client;
mod commands;
mod config;
mod ecs;
mod errors;
mod events;
#[cfg(feature = "lua")]
mod lua;
mod manager;
#[allow(dead_code)] // Retained upstream UI code; never constructed by the supervised engine.
mod menubar;
mod minimap;
mod overlay;
mod pasteboard;
mod platform;
mod reader;
mod runtime;
mod util;

pub use paneru::types;

#[cfg(test)]
mod tests;

embed_plist::embed_info_plist!(concat!(env!("OUT_DIR"), "/Info.plist"));

use events::{Event, EventSender};

use client::ClientCommand;
use ecs::state::StateQueryKind;
use errors::Result;
use reader::CommandReader;
use types::script_state::ScriptStateWrite;
use types::script_value::ScriptValue;
use types::wire::ScriptStateRequest;

use crate::ecs::setup_bevy_app;
use crate::manager::check_ax_privilege;

pub const VERSION_STRING: &str = concat!(env!("OPENYOURMAC_VERSION"), " (Paneru 0.5.2 base)");

/// `Paneru` is the main command-line interface structure for the window manager.
/// It defines the app-supervised engine and client subcommands.
#[derive(Clone, Debug, Default, Parser)]
#[command(
    name = "openyourmac-engine",
    version = VERSION_STRING,
    author = clap::crate_authors!(),
    about = clap::crate_description!(),
)]
pub struct Paneru {
    /// The subcommand to execute (e.g., `launch`, `check-config`, `send-cmd`).
    #[clap(subcommand)]
    subcmd: Option<SubCmd>,
    /// Configuration file (also `OPENYOURMAC_CONFIG`).
    #[arg(long, global = true)]
    config: Option<PathBuf>,
}

/// Engine lifecycle, validation and read-only client entry points.
#[derive(Clone, Debug, Subcommand)]
pub enum SubCmd {
    /// Render a synthetic strip without windows or Accessibility.
    #[command(hide = true)]
    RenderMinimap { output: PathBuf },
    /// Launch the app-supervised engine in the foreground (default).
    Launch {
        /// Serve and parse commands only. No window management or platform setup.
        #[arg(long, hide = true)]
        ipc_only: bool,
    },
    /// Validate configuration and resolve its bindings without managing windows.
    CheckConfig { path: Option<PathBuf> },
    /// Send command argv to the engine's Mach service.
    SendCmd {
        #[arg(trailing_var_arg = true)]
        cmd: Vec<String>,
    },

    /// Queries structured state from the running daemon.
    Query {
        #[clap(subcommand)]
        query: QueryCmd,
    },

    /// Subscribes to structured state events from the running daemon.
    Subscribe {
        #[arg(long)]
        json: bool,
    },

    /// Reads and writes the script state store, the same one `paneru.state`
    /// gives a Lua script.
    State {
        #[clap(subcommand)]
        state: StateCmd,
    },
}

#[derive(Clone, Debug, Subcommand)]
pub enum StateCmd {
    /// Prints the value stored under a key, or `null`.
    Get { key: String },
    /// Stores a value, given as JSON.
    Set { key: String, value: String },
    /// Removes a key.
    Remove { key: String },
    /// Stores a value only if the key still holds what it was read as. Both
    /// values are JSON, or `-` for "no value": absent in `expected`, a removal
    /// in `value`.
    Cas {
        key: String,
        expected: String,
        value: String,
    },
}

#[derive(Clone, Debug, Subcommand)]
pub enum QueryCmd {
    /// Prints the complete state document.
    State {
        #[arg(long)]
        json: bool,
    },
    /// Prints the virtual workspace list.
    VirtualWorkspaces {
        #[arg(long)]
        json: bool,
    },
    /// Prints the active focus/workspace state.
    Active {
        #[arg(long)]
        json: bool,
    },
    /// Prints the windows currently visible on screen, slivers excluded.
    OnScreen {
        #[arg(long)]
        json: bool,
    },
}

/// The main entry point of the `paneru` application.
/// It sets up logging and dispatches commands accordingly.
///
/// # Returns
///
/// `Ok(())` if the application runs successfully, otherwise `Err(Error)`.
fn main() {
    if let Err(err) = run_main() {
        if let errors::Error::InvalidInput(message) = &err {
            eprintln!("error: {message}");
            std::process::exit(2);
        }
        let message = match err {
            errors::Error::Generic(message) => message,
            other => other.to_string(),
        };
        eprintln!("openyourmac-engine: {message}");
        std::process::exit(1);
    }
}

fn run_main() -> Result<()> {
    let cli = Paneru::parse();
    // One-shot tools print only their result; the daemon logs at info.
    let quiet = matches!(
        cli.subcmd,
        Some(SubCmd::CheckConfig { .. } | SubCmd::SendCmd { .. })
    ) && std::env::var_os("RUST_LOG").is_none();
    let initial_filter = if quiet {
        tracing_subscriber::EnvFilter::new("warn")
    } else {
        runtime::log_filter(false)
    };
    let (filter, handle) = reload::Layer::new(initial_filter);
    runtime::set_log_filter(handle);
    tracing_subscriber::registry()
        .with(filter)
        .with(
            fmt::layer()
                .with_timer(runtime::LocalMillis)
                .with_ansi(
                    std::env::var_os("NO_COLOR").is_none() && std::io::stderr().is_terminal(),
                )
                .with_level(true)
                .with_line_number(true)
                .with_file(true)
                .with_target(true)
                .with_thread_ids(false)
                .with_writer(std::io::stderr)
                .compact(),
        )
        .init();

    // Resolve before CONFIGURATION_FILE's LazyLock or any loader is touched.
    // Do not mutate process environment after IPC threads have started.
    if let Some(path) = cli.config {
        unsafe {
            std::env::set_var("OPENYOURMAC_CONFIG", path);
        }
    }
    match cli.subcmd.unwrap_or(SubCmd::Launch { ipc_only: false }) {
        SubCmd::Launch { ipc_only: true } => run_ipc_only()?,
        SubCmd::Launch { ipc_only: false } => {
            // Validate path resolution before the infallible config-path cache
            // is read. Missing HOME is an ordinary error, never a LazyLock panic.
            config::resolved_configuration_file()?;
            let (sender, receiver) = EventSender::new();
            if !CommandReader::new(sender.clone()).start()? {
                std::process::exit(75);
            }
            runtime::supervise(Some(sender.clone()));
            if std::env::var("OYM_ASSUME_APP_AX").as_deref() == Ok("1") {
                info!("Skipping engine AX trust gate because the app holds the permission");
            } else if !wait_for_accessibility(&receiver) {
                return Ok(());
            }
            if runtime::exiting() {
                return Ok(());
            }
            let mut app = objc2::rc::autoreleasepool(|_| setup_bevy_app(sender, receiver))?;
            app.run();
        }
        SubCmd::CheckConfig { path } => {
            let implicit = path.is_none();
            let path = path.map_or_else(config::resolved_configuration_file, Ok)?;
            if implicit && !path.exists() {
                config::Config::load(Some(&path))?;
                println!(
                    "ok: built-in product defaults ({} is missing)",
                    path.display()
                );
            } else if !config::check_config(&path) {
                std::process::exit(1);
            }
        }
        SubCmd::RenderMinimap { output } => minimap::render_diagnostic(&output)?,
        SubCmd::SendCmd { cmd } => client::run(ClientCommand::Send(cmd))?,
        SubCmd::Query { query } => client::run(ClientCommand::Query(query.kind()))?,
        SubCmd::Subscribe { json: _ } => client::run(ClientCommand::Subscribe)?,
        SubCmd::State { state } => client::run(ClientCommand::ScriptState(state.request()?))?,
    }
    Ok(())
}

fn run_ipc_only() -> Result<()> {
    // Safety boundary: config parsing/watching and IPC only. No
    // EventSender, Bevy app, AX trust query, Cocoa loop or platform handlers.
    let path = std::path::absolute(config::resolved_configuration_file()?)?;
    let mut config = config::Config::load(Some(&path))?;
    if !CommandReader::ipc_only(config.clone()).start()? {
        std::process::exit(75); // EX_TEMPFAIL: a supervisor can retry.
    }
    let (tx, rx) = std::sync::mpsc::channel();
    let mut watcher = None;
    runtime::supervise(None);
    while !runtime::exiting() {
        let mut refresh = false;
        if watcher.is_none() && path.parent().is_some_and(std::path::Path::is_dir) {
            let tx = tx.clone();
            match config::watch::setup(&path, move |event| {
                _ = tx.send(event);
            }) {
                Ok(new_watcher) => {
                    watcher = Some(new_watcher);
                    refresh = true;
                }
                Err(err) => warn!("ipc-only: watching config: {err}"),
            }
        }
        refresh |= rx.try_iter().any(|event| match event {
            Ok(event) => config::watch::affects(&event, &path),
            Err(err) => {
                warn!("ipc-only: watching config: {err}");
                false
            }
        });
        if refresh {
            match config.reload_config(&path) {
                Ok(()) => info!("ipc-only: active options: {:?}", config.options()),
                Err(err) => warn!("ipc-only: keeping previous config: {err}"),
            }
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    // No ECS exists in this mode, so main reports the handover itself.
    if runtime::handing_over() {
        info!("openyourmac-engine: handing over to a new engine; leaving windows in place.");
    }
    Ok(())
}

fn wait_for_accessibility(receiver: &Receiver<Event>) -> bool {
    if check_ax_privilege() {
        return true;
    }
    warn!("Accessibility access is required; waiting silently for the app's permission setup.");
    loop {
        if runtime::exiting() {
            return false;
        }
        if check_ax_privilege() {
            return true;
        }
        match receiver.recv_timeout(Duration::from_millis(500)) {
            Ok(
                Event::Exit
                | Event::Command {
                    command: commands::Command::Quit,
                },
            )
            | Err(RecvTimeoutError::Disconnected) => return false,
            Ok(event) => warn!(
                ?event,
                "ignoring event while waiting for Accessibility access"
            ),
            Err(RecvTimeoutError::Timeout) => {}
        }
    }
}

impl QueryCmd {
    fn kind(&self) -> StateQueryKind {
        match self {
            QueryCmd::State { json: _ } => StateQueryKind::State,
            QueryCmd::VirtualWorkspaces { json: _ } => StateQueryKind::VirtualWorkspaces,
            QueryCmd::Active { json: _ } => StateQueryKind::Active,
            QueryCmd::OnScreen { json: _ } => StateQueryKind::OnScreen,
        }
    }
}

impl StateCmd {
    /// The request this asks the daemon for. Values arrive from the shell as
    /// JSON text and are parsed here, so nothing past this point deals in
    /// strings.
    fn request(&self) -> errors::Result<ScriptStateRequest> {
        /// The `-` that a shell caller writes for "there is no value here":
        /// absent in `expected`, a removal in `value`. It cannot collide with
        /// JSON, where a string is quoted.
        const ABSENT: &str = "-";

        let parse = |raw: &str| -> errors::Result<ScriptValue> {
            serde_json::from_str::<serde_json::Value>(raw)
                .map(ScriptValue::from)
                .map_err(|err| errors::Error::InvalidInput(format!("{raw:?} is not JSON: {err}")))
        };
        let maybe = |raw: &str| -> errors::Result<Option<ScriptValue>> {
            if raw == ABSENT {
                Ok(None)
            } else {
                parse(raw).map(Some)
            }
        };

        Ok(match self {
            StateCmd::Get { key } => ScriptStateRequest::Get { key: key.clone() },
            StateCmd::Set { key, value } => {
                ScriptStateRequest::Write(ScriptStateWrite::set(key.clone(), parse(value)?))
            }
            StateCmd::Remove { key } => {
                ScriptStateRequest::Write(ScriptStateWrite::remove(key.clone()))
            }
            StateCmd::Cas {
                key,
                expected,
                value,
            } => ScriptStateRequest::Write(ScriptStateWrite::compare_and_set(
                key.clone(),
                maybe(expected)?,
                maybe(value)?,
            )),
        })
    }
}
