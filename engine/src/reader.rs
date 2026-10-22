//! Where requests from other processes come in.
//!
//! Paneru publishes a Mach service under a well-known name; the CLI, the
//! loadable Lua module and anything else that wants to drive the window manager
//! connect to that name and send it a [`Request`]. Each one is turned into an
//! [`Event`] for the world, and the ones that expect an answer carry a reply
//! channel the answering system fills in.

use crate::types::commands::Command;
use crate::types::wire::{self, Delivery, Reply as MachReply, Request, Response, service_name};
use bevy::tasks::{IoTaskPool, TaskPool};
use futures_lite::StreamExt;
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};
use tracing::{error, info, warn};

use crate::errors::Result;
use crate::events::{Event, EventSender, Reply};

/// `CommandReader` owns the service port and feeds what arrives on it into the
/// world.
pub struct CommandReader {
    events: Option<EventSender>,
    diagnostic_config: Option<crate::config::Config>,
}

impl CommandReader {
    /// Creates a new `CommandReader`.
    ///
    /// # Arguments
    ///
    /// * `events` - An `EventSender` to dispatch received requests on.
    #[must_use]
    pub fn new(events: EventSender) -> Self {
        CommandReader {
            events: Some(events),
            diagnostic_config: None,
        }
    }

    /// Claims the service name and starts serving it on a thread of its own.
    ///
    /// # Errors
    ///
    /// Returns an error if another Paneru daemon already owns the name.
    pub fn ipc_only(config: crate::config::Config) -> Self {
        Self {
            events: None,
            diagnostic_config: Some(config),
        }
    }

    pub fn start(self) -> Result<bool> {
        let name = service_name();
        // bootstrap_check_in can return BOOTSTRAP_NOT_PRIVILEGED (0x44c)
        // for an already-registered foreground service, not AlreadyRunning.
        // Looking up a live send right is harmless and handles that case.
        // A predecessor may still own its receive right while processing
        // SIGUSR1/SIGTERM. Never steal it; allow a bounded handover window.
        let deadline = Instant::now() + Duration::from_secs(2);
        let receiver = loop {
            if wire::connect::<Request>(&name).is_err() {
                match wire::bind::<Request>(&name) {
                    Ok(receiver) => break receiver,
                    Err(err)
                        if matches!(err, wire::Error::AlreadyRunning)
                            || wire::connect::<Request>(&name).is_ok() => {}
                    Err(err) => return Err(err.into()),
                }
            }
            if Instant::now() >= deadline {
                return Ok(already_running());
            }
            thread::sleep(Duration::from_millis(50));
        };

        thread::spawn(move || {
            // Parks this one thread for the process lifetime; each request is
            // handed to the IO pool rather than served inline.
            futures_lite::future::block_on(async move {
                let mut requests = std::pin::pin!(receiver);
                while let Some(delivery) = requests.next().await {
                    match delivery {
                        Ok(delivery) => self.dispatch(delivery),
                        // A request that fails to decode is a bad client, not a
                        // reason to stop serving.
                        Err(err) => warn!("reading request: {err}"),
                    }
                }
            });
        });

        Ok(true)
    }

    /// Turns one request into an event, and arranges for its answer.
    fn dispatch(&self, delivery: Delivery<Request>) {
        if let Request::CommandArgv(argv) = &delivery.value {
            let borrowed = argv.iter().map(String::as_str).collect::<Vec<_>>();
            let parsed = crate::types::argv::parse_command(&borrowed);
            match parsed {
                Ok(command) => {
                    if self.events.is_none() {
                        info!("ipc-only: received {argv:?} -> {command:?}");
                        if matches!(command, Command::PrintState)
                            && let Some(config) = &self.diagnostic_config
                        {
                            info!("ipc-only: active options: {:?}", config.options());
                        }
                    }
                    self.command(command, delivery.reply);
                }
                Err(err) => {
                    warn!("parsing command {argv:?}: {err}");
                    if let Some(reply) = delivery.reply {
                        _ = reply.send(&Response::Error(err.to_string()));
                    }
                }
            }
            return;
        }
        if let Request::Command(Command::PauseBindings(paused)) = &delivery.value {
            self.command(Command::PauseBindings(*paused), delivery.reply);
            return;
        }
        let Some(events) = self.events.clone() else {
            // Safe mode never dispatches even typed requests to the ECS.
            info!("ipc-only: ignoring typed request {:?}", delivery.value);
            return;
        };
        let Delivery {
            value,
            reply,
            subscriber,
        } = delivery;

        match value {
            // Fire-and-forget: no reply is sent for this request.
            Request::CommandArgv(_) => unreachable!("argv handled above"),
            Request::Command(command) => {
                send(&events, Event::Command { command });
            }
            Request::WindowSetApply(ops) => {
                send(
                    &events,
                    Event::Command {
                        command: crate::commands::Command::Layout(ops),
                    },
                );
            }

            Request::Query(kind) => {
                answer(events, reply, "state query", move |respond_to| {
                    Event::StateQuery { kind, respond_to }
                });
            }
            Request::WindowSet => {
                answer(events, reply, "window set query", |respond_to| {
                    Event::WindowSetQuery { respond_to }
                });
            }
            Request::ScriptState(request) => {
                answer(events, reply, "script state request", move |respond_to| {
                    Event::ScriptState {
                        request,
                        respond_to,
                    }
                });
            }

            Request::Subscribe => {
                if let Some(subscriber) = subscriber {
                    send(
                        &events,
                        Event::StateSubscribe {
                            subscriber: Arc::new(subscriber),
                        },
                    );
                } else {
                    // No channel to push events to; the sender built the
                    // request by hand and got it wrong.
                    warn!("subscribe request carried no event channel");
                }
            }
        }
    }

    fn command(&self, command: Command, reply: Option<MachReply>) {
        if let Command::PauseBindings(paused) = command {
            // Apply directly to the atomic lease checked by the input tap,
            // before replying. Do not queue a second application in the ECS.
            // IPC-only acknowledges this same lease, but installs no input tap.
            crate::runtime::pause_bindings(paused);
            if let Some(events) = &self.events {
                if paused {
                    crate::minimap::cancel_input();
                }
                events.waker().wake();
            }
            if let Some(reply) = reply
                && let Err(err) = reply.send(&Response::BindingsPaused(paused))
            {
                warn!("answering binding pause/resume: {err}");
            }
        } else if let Some(events) = &self.events {
            send(events, Event::Command { command });
        }
    }
}

/// Sends an event that expects no answer.
fn send(events: &EventSender, event: Event) {
    _ = events
        .send(event)
        .inspect_err(|err| error!("sending event: {err}"));
}

/// Sends a request-carrying event to the world and answers the client with
/// whatever comes back. `what` only names the request in the log.
///
/// The wait runs on the IO pool, not the receive loop, so a slow client blocks
/// only itself. There is no timeout: the reply sender travels inside the
/// event, so if the world never answers, the event is dropped, the channel
/// closes, and `recv` resolves anyway.
fn answer(
    events: EventSender,
    reply: Option<MachReply>,
    what: &'static str,
    request: impl FnOnce(Reply) -> Event + Send + 'static,
) {
    let Some(reply) = reply else {
        warn!("{what} arrived without a reply channel");
        return;
    };

    let (tx, rx) = async_channel::bounded(1);
    if events
        .send(request(tx))
        .inspect_err(|err| error!("sending {what}: {err}"))
        .is_err()
    {
        return;
    }

    // `get_or_init`, not `get`: the reader starts before the Bevy app is built,
    // so an early client would otherwise find no pool at all and panic.
    IoTaskPool::get_or_init(TaskPool::default)
        .spawn(async move {
            match rx.recv().await {
                Ok(response) => {
                    if let Err(err) = reply.send(&response) {
                        // A client that stopped waiting is normal — an
                        // interrupted `paneru query` does exactly this.
                        warn!("answering {what}: {err}");
                    }
                }
                Err(err) => error!("waiting for {what} response: {err}"),
            }
        })
        .detach();
}

fn already_running() -> bool {
    eprintln!("openyourmac-engine: another engine instance is already running; retry later.");
    false
}
