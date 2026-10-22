//! App supervision, signal-safe shutdown requests, and reloadable logging.
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use tracing::{info, warn};
use tracing_subscriber::{EnvFilter, Registry, reload};

use crate::events::{Event, EventSender};

static EXIT: AtomicU8 = AtomicU8::new(0);
static HANDOVER: AtomicBool = AtomicBool::new(false);
static DETAILED: AtomicBool = AtomicBool::new(false);
static FILTER: OnceLock<reload::Handle<EnvFilter, Registry>> = OnceLock::new();
static PAUSED_UNTIL: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
static CLOCK: OnceLock<Instant> = OnceLock::new();

extern "C" fn signal_handler(signal: libc::c_int) {
    if signal == libc::SIGUSR1 {
        HANDOVER.store(true, Ordering::Release);
    }
    EXIT.store(1, Ordering::Release);
}

pub fn handing_over() -> bool {
    HANDOVER.load(Ordering::Acquire)
}

pub fn exiting() -> bool {
    EXIT.load(Ordering::Acquire) != 0
}

/// Install before any AX/platform setup. The handler only sets lock-free atomics;
/// the control thread sends the same exit event as an ordinary engine quit.
pub fn supervise(sender: Option<EventSender>) {
    let parent = unsafe { libc::getppid() };
    for signal in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP, libc::SIGUSR1] {
        // SAFETY: the C handler lives for the process lifetime and performs no IO.
        unsafe {
            libc::signal(signal, signal_handler as *const () as libc::sighandler_t);
        }
    }
    thread::spawn(move || {
        let mut checked_parent = Instant::now();
        loop {
            thread::sleep(Duration::from_millis(50));
            if parent >= 2 && checked_parent.elapsed() >= Duration::from_millis(500) {
                checked_parent = Instant::now();
                let current = unsafe { libc::getppid() };
                if current != parent {
                    warn!(
                        "openyourmac-engine: parent process {parent} exited (now reparented to {current}); shutting down."
                    );
                    EXIT.store(1, Ordering::Release);
                }
            }
            if exiting() {
                if handing_over() && sender.is_some() {
                    info!(
                        "openyourmac-engine: handing over to a new engine; leaving windows in place."
                    );
                }
                if let Some(sender) = sender {
                    _ = sender.send(Event::Exit);
                }
                return;
            }
        }
    });
}

fn monotonic_millis() -> u64 {
    u64::try_from(CLOCK.get_or_init(Instant::now).elapsed().as_millis())
        .unwrap_or(u64::MAX - 20_000)
        + 1
}

pub fn pause_bindings(paused: bool) {
    PAUSED_UNTIL.store(
        if paused {
            monotonic_millis().saturating_add(20_000)
        } else {
            0
        },
        Ordering::Release,
    );
    info!(
        "engine bindings {}",
        if paused {
            "paused for 20 seconds"
        } else {
            "resumed"
        }
    );
}

pub fn bindings_paused() -> bool {
    let deadline = PAUSED_UNTIL.load(Ordering::Acquire);
    deadline != 0 && monotonic_millis() < deadline
}

pub fn log_filter(detailed: bool) -> EnvFilter {
    let mut filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    if detailed {
        for target in ["openyourmac_engine", "paneru"] {
            filter = filter.add_directive(
                format!("{target}=debug")
                    .parse()
                    .expect("static log directive"),
            );
        }
    }
    filter
}

pub fn set_log_filter(handle: reload::Handle<EnvFilter, Registry>) {
    _ = FILTER.set(handle);
}

/// Called only after a valid config has been adopted, including hot reload.
pub fn detailed_logging(enabled: bool) {
    if DETAILED.swap(enabled, Ordering::AcqRel) == enabled {
        return;
    }
    if let Some(filter) = FILTER.get()
        && let Err(err) = filter.reload(log_filter(enabled))
    {
        warn!("reloading engine log filter: {err}");
    }
    info!("detailed_logging switched to {enabled}");
}

pub struct LocalMillis;
impl tracing_subscriber::fmt::time::FormatTime for LocalMillis {
    fn format_time(
        &self,
        writer: &mut tracing_subscriber::fmt::format::Writer<'_>,
    ) -> std::fmt::Result {
        write!(
            writer,
            "{}",
            chrono::Local::now().format("%Y-%m-%d %H:%M:%S%.3f")
        )
    }
}
