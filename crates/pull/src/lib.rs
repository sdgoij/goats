//! Pulling a host's world mods, checking them, and installing them (M18b).
//!
//! This is the client half of M18. The transport is `session` (a second ALPN, a
//! request and one reply per mod) and the loader is `mods`, and neither should
//! learn about the other; what is left is the policy, and that lives here.
//!
//! Three rules shape it:
//!
//! - **Verify, then install.** A fetched archive is loaded with the same loader
//!   the join handshake's digest comes from, and its id, version and hash must
//!   equal the ones the host announced. Anything else is discarded, never
//!   installed -- otherwise the retried join would still not match, or worse,
//!   would run code the digest does not describe.
//! - **Never replace what the player has.** A mod whose id is already loaded is
//!   refused, not overwritten. `differing` is left for the player to resolve,
//!   because only they know whether their copy or the host's is the one they
//!   want.
//! - **Visible and removable.** Pulled mods land beside the player's own, under
//!   a name that says what they are, with a record of where each came from.
//!   Deleting them is the uninstall.
//!
//! What is deliberately *not* here: consent, the console, and the retry of the
//! join. Those are M18c, and they belong to the client that owns the loop.

use std::collections::BTreeMap;
use std::path::Path;

use session::registry::Registry;
use session::{Fetched, ModRef};

/// The prefix an installed archive gets, so a pulled mod is recognisable and
/// removable as a set without touching anything the player installed.
///
/// Deliberately not a dot-prefixed name. It looks tidier in a listing, but a
/// leading dot hides the file on Linux and macOS, and the one thing a player has
/// to be able to do with what a host installed on their behalf is *see* it: this
/// is somebody else's code arriving in their mods directory, and "where did these
/// files come from" is a worse question than "why are there extra files". The
/// staging name in [`install`] is what keeps a half-written archive out of
/// discovery, and that is a suffix, not a prefix.
pub const PREFIX: &str = "pulled-";

/// The provenance record, inside the mods directory: id -> where it came from.
/// Visible for the same reason as [`PREFIX`]: it is the answer to "what is this
/// and who put it here".
pub const RECORD: &str = "pulled.json";

/// What one pull did, for the caller to report.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Report {
    /// Installed and verified, in the order the host answered.
    pub installed: Vec<ModRef>,
    /// The host does not hold it.
    pub unavailable: Vec<(String, String)>,
    /// Held, but not installed: it would not verify, or the id is already here.
    pub refused: Vec<(String, String)>,
}

impl Report {
    /// One line for the console: what came in, and what did not.
    pub fn describe(&self) -> String {
        let mut parts = vec![format!("pulled {}", self.installed.len())];
        for (id, reason) in &self.refused {
            parts.push(format!("refused {id}: {reason}"));
        }
        for (id, reason) in &self.unavailable {
            parts.push(format!("unavailable {id}: {reason}"));
        }
        parts.join("; ")
    }
}

/// Fetch `want` from the host at `ticket`, check each against the identity it was
/// asked for, and install the ones that verify. Mods the client already has --
/// per `loader`, discovered before the pull -- are refused rather than replaced.
///
/// The caller re-discovers afterwards: `loader` does not include what this
/// installed, and the join's digest is taken over the set on disk.
pub async fn pull(
    ticket: &str,
    loader: &mods::Loader,
    mods_dir: &Path,
    want: Vec<ModRef>,
) -> Result<Report, String> {
    let mut report = Report::default();

    // Refuse-on-conflict, before asking: there is no point fetching a mod that
    // could not be installed, and a pull must never touch what the player has.
    let (wanted, refused) = unowned(loader, want);
    report.refused = refused;
    if wanted.is_empty() {
        return Ok(report);
    }

    let answers = session::fetch_mods(ticket, wanted)
        .await
        .map_err(|error| error.to_string())?;
    for answer in answers {
        match answer {
            Fetched::Unavailable { id, reason } => report.unavailable.push((id, reason)),
            Fetched::Mod { reference, bytes } => match install(mods_dir, &reference, &bytes) {
                Ok(()) => report.installed.push(reference),
                Err(reason) => report.refused.push((reference.id, reason)),
            },
        }
    }
    if !report.installed.is_empty() {
        record(mods_dir, ticket, &report.installed)?;
    }
    Ok(report)
}

/// Split `want` into what can be fetched and what the player already has. A mod
/// whose id is loaded is refused rather than replaced: only the player knows
/// whether their copy or the network's is the one they want.
fn unowned(loader: &mods::Loader, want: Vec<ModRef>) -> (Vec<ModRef>, Vec<(String, String)>) {
    let mut wanted = Vec::new();
    let mut refused = Vec::new();
    for reference in want {
        match loader.get(&reference.id) {
            None => wanted.push(reference),
            Some(existing) => refused.push((
                reference.id.clone(),
                if existing.version == reference.version && existing.hash == reference.hash {
                    "you already have it".to_string()
                } else {
                    format!(
                        "you have {}#{:016x}, the host has {}#{:016x}",
                        existing.version, existing.hash, reference.version, reference.hash
                    )
                },
            )),
        }
    }
    (wanted, refused)
}

/// Fetch `want` from the registry rather than from a host (M18f). The same
/// verify-then-install policy as [`pull`], with a collection as the transport:
/// `Registry::fetch` writes a tree into a staging directory, the loader re-reads
/// it, and only then is it renamed into the mods directory.
///
/// Staging lives in `mods/.staging/`, which discovery ignores because it has no
/// `mod.json` of its own -- the same trick the zip pull plays with a `.part`
/// suffix, adapted to a directory the walker would otherwise see.
pub async fn pull_registry(
    registry: &Registry,
    loader: &mods::Loader,
    mods_dir: &Path,
    want: Vec<ModRef>,
) -> Result<Report, String> {
    let (wanted, refused) = unowned(loader, want);
    let mut report = Report {
        refused,
        ..Default::default()
    };
    if wanted.is_empty() {
        return Ok(report);
    }

    let staging = mods_dir.join(STAGING);
    std::fs::create_dir_all(&staging).map_err(|error| format!("{}: {error}", staging.display()))?;

    for reference in wanted {
        let Some(record) = registry.find(&reference) else {
            report
                .unavailable
                .push((reference.id, "the registry has no record".to_string()));
            continue;
        };
        if registry.providers(&record.root).is_empty() {
            report
                .unavailable
                .push((reference.id, "no provider has it".to_string()));
            continue;
        }

        let staged = staging.join(dir_name(&reference.id));
        let _ = std::fs::remove_dir_all(&staged);
        if let Err(reason) = registry.fetch(&record, &staged).await {
            let _ = std::fs::remove_dir_all(&staged);
            report.refused.push((reference.id, reason));
            continue;
        }
        if let Err(reason) = install_tree(mods_dir, &reference, &staged) {
            let _ = std::fs::remove_dir_all(&staged);
            report.refused.push((reference.id, reason));
            continue;
        }
        report.installed.push(reference);
    }

    // Leave no empty staging directory behind. A non-empty one means a failed
    // step above kept its evidence, which is deliberate.
    let _ = std::fs::remove_dir(&staging);
    if !report.installed.is_empty() {
        record(mods_dir, "registry", &report.installed)?;
    }
    Ok(report)
}

/// The staging directory inside the mods directory. It has no `mod.json` of its
/// own, so [`mods::Loader::discover`] skips it; a half-written tree is therefore
/// invisible even if the process dies mid-export.
const STAGING: &str = ".staging";

/// Verify a fetched tree and move it into place. The loader is the authority:
/// the tree must carry `mod.json`, and the id, version and digest must be the
/// ones the record promised. A destination that already exists is refused, never
/// overwritten.
fn install_tree(mods_dir: &Path, reference: &ModRef, staged: &Path) -> Result<(), String> {
    let name = dir_name(&reference.id);
    let checked = mods::load_dir(staged);
    let verified = matches!(
        &checked,
        Ok(manifest)
            if manifest.id == reference.id
                && manifest.version == reference.version
                && manifest.hash == reference.hash
    );
    if !verified {
        return Err(match checked {
            Ok(manifest) => format!(
                "it is {}@{}#{:016x}, not the {}@{}#{:016x} asked for",
                manifest.id,
                manifest.version,
                manifest.hash,
                reference.id,
                reference.version,
                reference.hash
            ),
            Err(error) => format!("it does not load: {}", error.message),
        });
    }

    let path = mods_dir.join(name);
    if path.exists() {
        return Err("you already have it".to_string());
    }
    std::fs::rename(staged, &path).map_err(|error| format!("{}: {error}", path.display()))
}

/// Where a fetched tree lands: the archive name without the suffix, since the
/// package is a directory now.
fn dir_name(id: &str) -> String {
    let filtered: String = id
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
        .take(96)
        .collect();
    let stem = if filtered.is_empty() {
        "mod".to_string()
    } else {
        filtered
    };
    format!("{PREFIX}{stem}")
}

/// The client half of a recovery that prefers the host and falls back to the
/// registry only for what the host could not serve. The host is authoritative
/// and is usually a direct connection; the registry is what makes a world set
/// fetchable when it is not.
pub async fn recover_with(
    ticket: &str,
    loader: &mods::Loader,
    mods_dir: &Path,
    registry: Option<&Registry>,
) -> Result<Recovery, String> {
    let host = match session::fetch_catalogue(ticket).await {
        Ok(host) => host,
        Err(error) => return Ok(Recovery::Unreachable(error.to_string())),
    };
    let ours = world_mods(loader);
    let mismatch = session::compare_world_mods(&host, &ours);
    if !mismatch.extra.is_empty() || !mismatch.differing.is_empty() {
        return Ok(Recovery::Unfixable(mismatch));
    }
    let want: Vec<ModRef> = host
        .iter()
        .filter(|reference| !ours.iter().any(|ours| ours.id == reference.id))
        .cloned()
        .collect();
    if want.is_empty() {
        return Ok(Recovery::Matched);
    }

    let report = pull(ticket, loader, mods_dir, want.clone()).await?;
    let Some(registry) = registry else {
        return Ok(Recovery::Pulled(report));
    };
    let missing: Vec<ModRef> = report
        .unavailable
        .iter()
        .filter_map(|(id, _)| want.iter().find(|reference| &reference.id == id).cloned())
        .collect();
    if missing.is_empty() {
        return Ok(Recovery::Pulled(report));
    }
    let fallback = pull_registry(registry, loader, mods_dir, missing).await?;
    Ok(Recovery::Pulled(merge(report, fallback)))
}

/// Fold a fallback's report into the host's, dropping an "unavailable" line the
/// fallback then satisfied.
fn merge(mut report: Report, fallback: Report) -> Report {
    report.unavailable.retain(|(id, _)| {
        !fallback
            .installed
            .iter()
            .any(|reference| &reference.id == id)
    });
    report.installed.extend(fallback.installed);
    report.unavailable.extend(fallback.unavailable);
    report.refused.extend(fallback.refused);
    report
}

/// What a recovery attempt found, for the caller to act on.
#[derive(Debug)]
pub enum Recovery {
    /// The client already presents the host's set: a retry should succeed, or the
    /// refusal was not about mods at all.
    Matched,
    /// What was missing was fetched and installed; a retry is worth attempting.
    Pulled(Report),
    /// The host cannot be matched by pulling: either it lacks a mod this client
    /// runs, or the two hold a shared id at different versions. Only the player
    /// can resolve that, so nothing is installed.
    Unfixable(session::ModMismatch),
    /// The host does not serve its mods -- no fetch surface, or the fetch failed.
    /// The refusal and the status page's download are all that is left.
    Unreachable(String),
}

/// Make this client's world-mod set match the host's, by fetching what it is
/// missing (M18c). The host is asked what it runs over the fetch ALPN rather
/// than the refusal carrying it, so no `PROTOCOL_VERSION` change is needed, and a
/// host with no fetch surface simply does not answer.
///
/// `loader` is the set as discovered *before* the pull: what the player already
/// has is never replaced. The caller re-discovers afterwards, so the digest the
/// retried join presents is the one on disk.
pub async fn recover(
    ticket: &str,
    loader: &mods::Loader,
    mods_dir: &Path,
) -> Result<Recovery, String> {
    recover_with(ticket, loader, mods_dir, None).await
}

/// The world-mod set a loader presents, in the shape the handshake compares and
/// in id order -- the same set `goatsd` builds from its own loader.
fn world_mods(loader: &mods::Loader) -> Vec<ModRef> {
    let mut refs: Vec<ModRef> = loader
        .mods()
        .iter()
        .filter(|manifest| manifest.side == mods::Side::World)
        .map(|manifest| ModRef {
            id: manifest.id.clone(),
            version: manifest.version.clone(),
            hash: manifest.hash,
        })
        .collect();
    refs.sort_by(|a, b| a.id.cmp(&b.id));
    refs
}

/// Install one fetched archive, or say why not. The bytes are written under a
/// name the loader ignores, checked by the loader itself, and only then renamed
/// into place -- so a fetch that was cut short, or a host that sent something
/// else, leaves nothing behind for the next discovery to read.
fn install(mods_dir: &Path, reference: &ModRef, bytes: &[u8]) -> Result<(), String> {
    std::fs::create_dir_all(mods_dir)
        .map_err(|error| format!("{}: {error}", mods_dir.display()))?;
    let name = archive_name(&reference.id);
    // The `.part` suffix is not a `.zip`, so a staging file is invisible to
    // discovery even if this process dies between the write and the rename.
    let staged = mods_dir.join(format!("{name}.part"));
    std::fs::write(&staged, bytes).map_err(|error| format!("{}: {error}", staged.display()))?;

    let checked = mods::load_zip(&staged);
    let verified = matches!(
        &checked,
        Ok(manifest)
            if manifest.id == reference.id
                && manifest.version == reference.version
                && manifest.hash == reference.hash
    );
    if !verified {
        let _ = std::fs::remove_file(&staged);
        return Err(match checked {
            Ok(manifest) => format!(
                "it is {}@{}#{:016x}, not the {}@{}#{:016x} asked for",
                manifest.id,
                manifest.version,
                manifest.hash,
                reference.id,
                reference.version,
                reference.hash
            ),
            Err(error) => format!("it does not load: {}", error.message),
        });
    }

    let path = mods_dir.join(name);
    std::fs::rename(&staged, &path).map_err(|error| format!("{}: {error}", path.display()))
}

/// Where a pulled mod lands: a name the loader reads as a `.zip` mod and the
/// player can recognise and see (see [`PREFIX`]). The id comes from the host, so
/// only what cannot escape the directory survives -- the prefix alone makes a `..`
/// harmless, but the rest is filtered too.
fn archive_name(id: &str) -> String {
    let filtered: String = id
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
        .take(96)
        .collect();
    let stem = if filtered.is_empty() {
        "mod"
    } else {
        filtered.as_str()
    };
    format!("{PREFIX}{stem}.zip")
}

/// Record where each installed mod came from, beside the archives. The file is
/// the inventory a player reads when they want to know what a fetch added and
/// which host it came from; nothing parses it, so deleting it costs only the
/// answer.
fn record(mods_dir: &Path, ticket: &str, installed: &[ModRef]) -> Result<(), String> {
    let path = mods_dir.join(RECORD);
    let mut inventory: BTreeMap<String, serde_json::Value> = match std::fs::read_to_string(&path) {
        Ok(text) => serde_json::from_str(&text).unwrap_or_default(),
        Err(_) => BTreeMap::new(),
    };
    let fetched_at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs())
        .unwrap_or(0);
    for reference in installed {
        inventory.insert(
            reference.id.clone(),
            serde_json::json!({
                "source": ticket,
                "version": reference.version,
                "hash": format!("{:016x}", reference.hash),
                "fetched_at": fetched_at,
            }),
        );
    }
    let text = serde_json::to_string_pretty(&inventory).map_err(|error| error.to_string())?;
    std::fs::write(&path, text).map_err(|error| format!("{}: {error}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::time::Duration;

    use session::Host;

    static COUNTER: AtomicU32 = AtomicU32::new(0);

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "goats-pull-{}-{}-{name}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn write(path: &Path, text: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }

    /// Every test gets a deadline, so a fetch that cannot connect fails instead
    /// of waiting on iroh's own long timeouts.
    async fn within<F: std::future::Future>(future: F) -> F::Output {
        tokio::time::timeout(Duration::from_secs(30), future)
            .await
            .expect("the pull finished")
    }

    /// A real world mod, packaged the way a host would serve it, with the
    /// `ModRef` the loader's own digest gives it.
    fn a_world_mod(name: &str, id: &str) -> (PathBuf, ModRef, Vec<u8>) {
        let dir = temp_dir(name);
        write(
            &dir.join("mod").join("mod.json"),
            &format!(
                r#"{{ "id": "{id}", "name": "Fixture", "version": "1.0.0",
                     "api": 1, "side": "world", "entry": "mod.js" }}"#
            ),
        );
        write(&dir.join("mod").join("mod.js"), "return 1;\n");
        let loader = mods::Loader::discover(&dir);
        assert!(loader.errors().is_empty(), "{:?}", loader.errors());
        let manifest = loader.get(id).expect("the fixture mod");
        let reference = ModRef {
            id: manifest.id.clone(),
            version: manifest.version.clone(),
            hash: manifest.hash,
        };
        let bytes = mods::archive_source(&manifest.source).expect("archive it");
        (dir, reference, bytes)
    }

    /// What an installed archive is called, and why (M18d). The name is the one
    /// thing a player has to be able to find, so it is neither hidden nor able to
    /// climb out of the mods directory: the id arrives from a host.
    #[tokio::test(flavor = "multi_thread")]
    async fn the_registry_installs_a_world_mod_the_host_cannot_serve() {
        use session::registry::{Registry, RegistryConfig};
        use session::swarm::{Reach, parse_peer};

        let dir = temp_dir("registry");
        let host_mods = dir.join("host-mods");
        write(
            &host_mods.join("mod").join("mod.json"),
            r#"{ "id": "com.example.birds", "name": "Birds", "version": "1.0.0",
                 "api": 1, "side": "world", "entry": "mod.js" }"#,
        );
        write(&host_mods.join("mod").join("mod.js"), "return 1;\n");
        let digest = mods::Loader::discover(&host_mods)
            .get("com.example.birds")
            .expect("the fixture mod")
            .hash;
        let reference = ModRef {
            id: "com.example.birds".to_string(),
            version: "1.0.0".to_string(),
            hash: digest,
        };

        let topic = session::registry::RegistryConfig::default_topic();
        let config = |name: &str| RegistryConfig {
            topic,
            peers: Vec::new(),
            secret: None,
            reach: Reach::Direct,
            store: dir.join(name),
            every: Duration::from_millis(50),
            ttl: Duration::from_secs(2),
        };
        let host = Registry::start(config("host-store"))
            .await
            .expect("host registry");
        let record = session::ModRecord {
            id: reference.id.clone(),
            version: reference.version.clone(),
            api: 1,
            side: session::ModSide::World,
            hash: reference.hash,
            root: [0u8; 32],
            size: 0,
            author: [0u8; 32],
        };
        host.share(record, &host_mods.join("mod"))
            .await
            .expect("shared the tree");

        let client = Registry::start(RegistryConfig {
            peers: vec![parse_peer(host.ticket()).expect("the host ticket")],
            ..config("client-store")
        })
        .await
        .expect("client registry");
        let mut listed = false;
        for _ in 0..200 {
            if let Some(record) = client.find(&reference)
                && !client.providers(&record.root).is_empty()
            {
                listed = true;
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        assert!(listed, "the registry never listed the mod with a provider");

        let mods_dir = dir.join("client-mods");
        std::fs::create_dir_all(&mods_dir).unwrap();
        let report = within(pull_registry(
            &client,
            &mods::Loader::empty(),
            &mods_dir,
            vec![reference.clone()],
        ))
        .await
        .expect("the registry pull");
        assert_eq!(report.installed, vec![reference.clone()]);
        assert!(report.unavailable.is_empty(), "{:?}", report.unavailable);

        let loader = mods::Loader::discover(&mods_dir);
        assert!(loader.errors().is_empty(), "{:?}", loader.errors());
        assert_eq!(
            loader
                .get("com.example.birds")
                .map(|manifest| manifest.hash),
            Some(reference.hash)
        );
        assert!(
            mods_dir.join(RECORD).is_file(),
            "the provenance record names the registry"
        );

        // The same request a second time is refused rather than overwritten.
        let again = pull_registry(&client, &loader, &mods_dir, vec![reference.clone()])
            .await
            .expect("the second pull");
        assert!(again.installed.is_empty());
        assert_eq!(again.refused.len(), 1);
        assert_eq!(again.refused[0].0, reference.id);

        client.shutdown().await;
        host.shutdown().await;
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_registry_with_no_record_reports_the_mod_unavailable() {
        use session::registry::{Registry, RegistryConfig};
        use session::swarm::Reach;

        let dir = temp_dir("registry-empty");
        let registry = Registry::start(RegistryConfig {
            topic: RegistryConfig::default_topic(),
            peers: Vec::new(),
            secret: None,
            reach: Reach::Direct,
            store: dir.join("store"),
            every: Duration::from_millis(50),
            ttl: Duration::from_secs(2),
        })
        .await
        .expect("registry");

        let report = pull_registry(
            &registry,
            &mods::Loader::empty(),
            &dir.join("mods"),
            vec![ModRef {
                id: "com.example.missing".to_string(),
                version: "1".to_string(),
                hash: 1,
            }],
        )
        .await
        .expect("the pull");
        assert!(report.installed.is_empty());
        assert_eq!(report.unavailable.len(), 1);
        assert!(report.unavailable[0].1.contains("no record"));

        registry.shutdown().await;
    }

    #[test]
    fn an_installed_archive_is_visible_and_contained() {
        let name = archive_name("com.example.birds");
        assert_eq!(name, "pulled-com.example.birds.zip");
        // A leading dot would hide it on Linux and macOS, which is exactly what a
        // file somebody else's host wrote into your mods directory must not do.
        assert!(!name.starts_with('.'), "{name}");

        // The prefix is what makes a hostile id harmless, so it is asserted with
        // one rather than assumed: whatever survives the filter stays a file the
        // directory reads as a mod and nothing else.
        let hostile = archive_name("../../evil/../../x");
        assert_eq!(hostile, "pulled-....evil....x.zip");
        assert!(!hostile.contains('/'), "{hostile}");
        assert!(!hostile.contains("..\\"), "{hostile}");

        // An id with nothing usable in it still points at a real file rather than
        // at the prefix itself.
        assert_eq!(archive_name("///"), "pulled-mod.zip");
    }

    #[tokio::test]
    async fn recover_pulls_what_the_host_runs_and_the_client_lacks() {
        within(async {
            let (source, reference, bytes) = a_world_mod("recover", "com.example.dash");
            let host = Host::start_with_mods_and_archives(
                "host",
                vec![reference.clone()],
                vec![(reference.clone(), bytes)],
            )
            .await
            .expect("host");

            let mods_dir = temp_dir("recover-mods");
            match recover(host.ticket(), &mods::Loader::empty(), &mods_dir)
                .await
                .expect("recover")
            {
                Recovery::Pulled(report) => {
                    assert_eq!(report.installed, vec![reference.clone()], "{report:?}")
                }
                other => panic!("expected a pull, got {other:?}"),
            }

            // Re-discovering gives the set the retried join would present --
            // which is the whole point: it must equal the host's.
            let after = mods::Loader::discover(&mods_dir);
            assert!(after.errors().is_empty(), "{:?}", after.errors());
            assert_eq!(world_mods(&after), vec![reference.clone()]);

            // And now there is nothing left to do.
            match recover(host.ticket(), &after, &mods_dir)
                .await
                .expect("recover")
            {
                Recovery::Matched => {}
                other => panic!("expected matched, got {other:?}"),
            }

            host.close().await;
            let _ = std::fs::remove_dir_all(&source);
            let _ = std::fs::remove_dir_all(&mods_dir);
        })
        .await;
    }

    #[tokio::test]
    async fn recover_refuses_when_the_client_has_a_world_mod_the_host_lacks() {
        within(async {
            // The host runs nothing; this client runs a world mod pulling cannot
            // drop. Recovering would be a lie, so it is refused instead.
            let (source, reference, bytes) = a_world_mod("extra", "com.example.mine");
            let mods_dir = temp_dir("extra-mods");
            std::fs::write(mods_dir.join(archive_name(&reference.id)), &bytes).unwrap();
            let mine = mods::Loader::discover(&mods_dir);
            assert!(mine.errors().is_empty(), "{:?}", mine.errors());

            let host = Host::start("host").await.expect("host");
            match recover(host.ticket(), &mine, &mods_dir)
                .await
                .expect("recover")
            {
                Recovery::Unfixable(mismatch) => {
                    assert_eq!(mismatch.extra, vec!["com.example.mine".to_string()])
                }
                other => panic!("expected unfixable, got {other:?}"),
            }

            host.close().await;
            let _ = std::fs::remove_dir_all(&source);
            let _ = std::fs::remove_dir_all(&mods_dir);
        })
        .await;
    }

    #[tokio::test]
    async fn recover_says_so_when_the_host_cannot_be_asked() {
        within(async {
            // A host with no fetch surface fails at the handshake, which is the
            // signal to fall back on the refusal and the status page's download.
            let mods_dir = temp_dir("unreachable-mods");
            match recover("not a ticket", &mods::Loader::empty(), &mods_dir)
                .await
                .expect("recover")
            {
                Recovery::Unreachable(reason) => assert!(!reason.is_empty(), "{reason}"),
                other => panic!("expected unreachable, got {other:?}"),
            }
            let _ = std::fs::remove_dir_all(&mods_dir);
        })
        .await;
    }

    #[tokio::test]
    async fn a_pull_installs_and_verifies_a_missing_mod() {
        within(async {
            let (source, reference, bytes) = a_world_mod("install", "com.example.dash");
            let host = Host::start_with_mods_and_archives(
                "host",
                vec![reference.clone()],
                vec![(reference.clone(), bytes)],
            )
            .await
            .expect("host");

            let mods_dir = temp_dir("install-mods");
            let report = pull(
                host.ticket(),
                &mods::Loader::empty(),
                &mods_dir,
                vec![reference.clone()],
            )
            .await
            .expect("pull");
            assert_eq!(report.installed, vec![reference.clone()], "{report:?}");
            assert!(report.refused.is_empty(), "{report:?}");

            // The loader finds it, at the digest the host announced -- which is
            // what makes the retried join match.
            let after = mods::Loader::discover(&mods_dir);
            assert!(after.errors().is_empty(), "{:?}", after.errors());
            let installed = after.get(&reference.id).expect("installed");
            assert_eq!(installed.hash, reference.hash);
            assert_eq!(installed.version, reference.version);

            // The record says where it came from.
            let record = std::fs::read_to_string(mods_dir.join(RECORD)).expect("the record");
            assert!(record.contains(&reference.id), "{record}");
            assert!(record.contains(host.ticket()), "{record}");

            host.close().await;
            let _ = std::fs::remove_dir_all(&source);
            let _ = std::fs::remove_dir_all(&mods_dir);
        })
        .await;
    }

    #[tokio::test]
    async fn a_pull_refuses_an_id_the_player_already_has() {
        within(async {
            let (source, reference, bytes) = a_world_mod("conflict", "com.example.dash");
            let host = Host::start_with_mods_and_archives(
                "host",
                vec![reference.clone()],
                vec![(reference.clone(), bytes)],
            )
            .await
            .expect("host");

            // The player's own copy: the same id, different content. It must be
            // left exactly as it is -- only they know which copy they want.
            let mods_dir = temp_dir("conflict-mods");
            write(
                &mods_dir.join("dash").join("mod.json"),
                r#"{ "id": "com.example.dash", "name": "Mine", "version": "2.0.0",
                     "api": 1, "side": "world", "entry": "mod.js" }"#,
            );
            write(&mods_dir.join("dash").join("mod.js"), "return 2;\n");
            let mine = mods::Loader::discover(&mods_dir);
            assert!(mine.errors().is_empty(), "{:?}", mine.errors());

            let report = pull(host.ticket(), &mine, &mods_dir, vec![reference.clone()])
                .await
                .expect("pull");
            assert!(report.installed.is_empty(), "{report:?}");
            assert_eq!(report.refused.len(), 1, "{report:?}");
            assert!(report.refused[0].1.contains("2.0.0"), "{report:?}");

            // Nothing was written, and the player's copy is untouched.
            assert!(!mods_dir.join(archive_name(&reference.id)).exists());
            assert!(!mods_dir.join(RECORD).exists(), "no record for no install");
            let after = mods::Loader::discover(&mods_dir);
            assert_eq!(
                after.get("com.example.dash").expect("still there").version,
                "2.0.0"
            );

            host.close().await;
            let _ = std::fs::remove_dir_all(&source);
            let _ = std::fs::remove_dir_all(&mods_dir);
        })
        .await;
    }

    #[tokio::test]
    async fn a_pull_discards_an_archive_that_does_not_verify() {
        within(async {
            // A host that announces one mod and serves another's bytes: the id
            // it was asked for is what it checks, so this is what a host that
            // lies looks like.
            let (source, reference, _) = a_world_mod("forged", "com.example.dash");
            let (other_source, _, other_bytes) = a_world_mod("forged-other", "com.example.other");
            let host = Host::start_with_mods_and_archives(
                "host",
                vec![reference.clone()],
                vec![(reference.clone(), other_bytes)],
            )
            .await
            .expect("host");

            let mods_dir = temp_dir("forged-mods");
            let report = pull(
                host.ticket(),
                &mods::Loader::empty(),
                &mods_dir,
                vec![reference.clone()],
            )
            .await
            .expect("pull");
            assert!(report.installed.is_empty(), "{report:?}");
            assert_eq!(report.refused.len(), 1, "{report:?}");
            assert!(
                report.refused[0].1.contains("not the"),
                "the refusal must say what arrived: {report:?}"
            );

            // Nothing is left behind: not the archive, not a staging file.
            let leftover: Vec<String> = std::fs::read_dir(&mods_dir)
                .expect("the mods dir")
                .flatten()
                .map(|entry| entry.file_name().to_string_lossy().into_owned())
                .collect();
            assert!(leftover.is_empty(), "{leftover:?}");

            host.close().await;
            let _ = std::fs::remove_dir_all(&source);
            let _ = std::fs::remove_dir_all(&other_source);
            let _ = std::fs::remove_dir_all(&mods_dir);
        })
        .await;
    }
}
