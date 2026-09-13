//! A file watcher for the mods directory, built on the platform's native
//! notification API through `notify` (inotify on Linux, kqueue on macOS,
//! `ReadDirectoryChangesW` on Windows) rather than polling.
//!
//! The host creates one when the user asks for it, then calls
//! [`ModWatcher::take_changed`] from its frame loop and reloads the mods the
//! returned paths belong to. Nothing here touches the engine, so it lives with
//! the loader and the server can share it.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use notify::{Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher as _};

/// A live watch on a mods directory. Dropping it stops the watch.
pub struct ModWatcher {
    // `notify` owns a background thread; the handle must be kept alive. It is
    // never read again, only held.
    _watcher: RecommendedWatcher,
    changed: Arc<Mutex<Vec<PathBuf>>>,
    dir: PathBuf,
}

impl ModWatcher {
    /// Start watching `dir` and its subdirectories. A missing directory is an
    /// error the caller can report and ignore.
    pub fn new(dir: &Path) -> Result<ModWatcher, String> {
        let changed: Arc<Mutex<Vec<PathBuf>>> = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&changed);
        let mut watcher = notify::recommended_watcher(move |event: notify::Result<Event>| {
            let Ok(event) = event else {
                return;
            };
            // Creating, editing and deleting a mod file all matter; access events
            // do not, and would fire constantly.
            if !matches!(
                event.kind,
                EventKind::Create(_) | EventKind::Modify(_) | EventKind::Remove(_)
            ) {
                return;
            }
            if let Ok(mut paths) = sink.lock() {
                paths.extend(event.paths);
            }
        })
        .map_err(|error| format!("cannot start a mod watcher: {error}"))?;
        watcher
            .watch(dir, RecursiveMode::Recursive)
            .map_err(|error| format!("cannot watch '{}': {error}", dir.display()))?;
        Ok(ModWatcher {
            _watcher: watcher,
            changed,
            dir: dir.to_path_buf(),
        })
    }

    /// The directory being watched.
    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// The paths that changed since the last call, sorted and deduplicated.
    pub fn take_changed(&self) -> Vec<PathBuf> {
        let Ok(mut paths) = self.changed.lock() else {
            return Vec::new();
        };
        let mut out: Vec<PathBuf> = std::mem::take(&mut *paths);
        out.sort();
        out.dedup();
        out
    }
}
