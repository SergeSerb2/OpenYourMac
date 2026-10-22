//! Watch pathnames, including replacement files and retargeted symlinks.
use std::path::{Path, absolute};
use std::time::Duration;

use notify::{Event, EventHandler, EventKind, PollWatcher, RecursiveMode, Watcher};

use crate::errors::{Error, Result};

pub fn setup(path: &Path, handler: impl EventHandler) -> Result<Box<dyn Watcher>> {
    let path = absolute(path)?;
    let parent = path
        .parent()
        .ok_or_else(|| Error::InvalidConfig("config path must name a file".into()))?;
    if let Some(target) = crate::util::symlink_target(&path) {
        tracing::debug!(
            "watching config symlink {} -> {}",
            path.display(),
            target.display()
        );
    }
    // Polling follows the configured pathname afresh on every scan. Content
    // hashes also detect same-second writes and older symlink targets. Keep the
    // directory watch alive when the file disappears; never unwatch on Remove.
    let mut watcher = PollWatcher::new(
        handler,
        notify::Config::default()
            .with_poll_interval(Duration::from_secs(1))
            .with_compare_contents(true)
            .with_follow_symlinks(true),
    )?;
    watcher.watch(parent, RecursiveMode::NonRecursive)?;
    Ok(Box::new(watcher))
}

pub fn affects(event: &Event, path: &Path) -> bool {
    if !matches!(
        event.kind,
        EventKind::Any | EventKind::Create(_) | EventKind::Remove(_) | EventKind::Modify(_)
    ) {
        return false;
    }
    let Ok(path) = absolute(path) else {
        return false;
    };
    event.paths.iter().any(|changed| {
        absolute(changed).is_ok_and(|changed| path == changed || path.starts_with(changed))
    })
}
