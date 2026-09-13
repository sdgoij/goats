//! The goat mod loader: discovery, manifests, ordering, hashing and reading.
//!
//! This crate is deliberately pure. It walks the filesystem and parses JSON,
//! but it never touches the engine: the host reads bytes here, then registers
//! them and evaluates entry sources itself. That keeps the loader unit-testable
//! without a window, and lets the headless server (M14d) reuse it.
//!
//! JavaScript never sees a path. An asset is read into memory and addressed by
//! an opaque name (`mod:<id>:<slot>`), which is what the scene hands back to
//! `rl.load*`.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Component, Path, PathBuf};

/// The `goats` API major this build understands. A manifest targeting a
/// different major is refused rather than loaded halfway.
pub const MOD_API: u32 = 1;

/// How many mod directories are considered at all.
pub const MAX_MODS: usize = 256;
/// A manifest is metadata; it has no business being large.
pub const MAX_MANIFEST_BYTES: u64 = 256 * 1024;
/// A mod's entry source.
pub const MAX_ENTRY_BYTES: u64 = 4 * 1024 * 1024;
/// A single asset file (a model, a texture, an audio clip).
pub const MAX_ASSET_BYTES: u64 = 64 * 1024 * 1024;

/// Which side of a session a mod has to run on. `World` mods are part of the
/// compatibility set hashed into the join handshake (M14d); `Client` mods are
/// local and unhashed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Side {
    Client,
    World,
}

impl Side {
    pub fn as_str(self) -> &'static str {
        match self {
            Side::Client => "client",
            Side::World => "world",
        }
    }
}

/// Why a directory was refused. Collected rather than fatal: one bad mod must
/// never stop the others.
#[derive(Debug)]
pub struct LoadError {
    pub path: PathBuf,
    pub message: String,
}

impl std::fmt::Display for LoadError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        if self.path.as_os_str().is_empty() {
            write!(formatter, "{}", self.message)
        } else {
            write!(formatter, "{}: {}", self.path.display(), self.message)
        }
    }
}

/// One asset file, read into memory and addressed by an opaque engine name.
#[derive(Debug)]
pub struct Asset {
    /// The logical slot the mod is filling (`model.goat`, `sfx.music`, ...).
    pub slot: String,
    /// Position within a list-valued slot.
    pub index: usize,
    /// The name to register with the engine.
    pub name: String,
    pub bytes: Vec<u8>,
}

/// A validated manifest with everything the host needs to load it.
#[derive(Debug)]
pub struct Manifest {
    pub id: String,
    pub name: String,
    pub version: String,
    pub api: u32,
    pub side: Side,
    pub description: String,
    /// The entry file's name, if the mod has code.
    pub entry: Option<String>,
    /// The entry file's text, ready to wrap and evaluate.
    pub entry_source: Option<String>,
    /// Assets still held in memory; the host takes them to register.
    pub assets: Vec<Asset>,
    /// The tuning file's name and text, if the mod ships one.
    pub tuning: Option<String>,
    pub tuning_json: Option<String>,
    pub load_after: Vec<String>,
    /// The directory the mod lives in (for diagnostics).
    pub dir: PathBuf,
    /// The compatibility hash (FNV-1a over id, version, entry and assets).
    pub hash: u64,
}

impl Manifest {
    /// `slot -> opaque engine names`, for the scene's asset table.
    pub fn asset_map(&self) -> BTreeMap<String, Vec<String>> {
        let mut map: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for asset in &self.assets {
            map.entry(asset.slot.clone())
                .or_default()
                .push(asset.name.clone());
        }
        map
    }

    /// The JavaScript that loads this mod: a scoped wrapper so a reload cannot
    /// leak a binding, handed a per-mod `goats` handle.
    pub fn entry_js(&self) -> Option<String> {
        let source = self.entry_source.as_ref()?;
        let id = serde_json::to_string(&self.id).unwrap_or_else(|_| "\"\"".to_string());
        Some(format!(
            "(function (goats) {{\n\"use strict\";\n{source}\n}})(goats.begin({id}));\n"
        ))
    }

    /// The metadata the scene is handed (no paths, ever).
    pub fn json(&self) -> serde_json::Value {
        let mut assets = serde_json::Map::new();
        for (slot, names) in self.asset_map() {
            let value = if names.len() == 1 {
                serde_json::Value::String(names.into_iter().next().unwrap_or_default())
            } else {
                serde_json::Value::Array(names.into_iter().map(serde_json::Value::String).collect())
            };
            assets.insert(slot, value);
        }
        serde_json::json!({
            "id": self.id,
            "name": self.name,
            "version": self.version,
            "api": self.api,
            "side": self.side.as_str(),
            "description": self.description,
            "enabled": true,
            "hash": format!("{:016x}", self.hash),
            "assets": assets,
        })
    }

    /// Hand the asset bytes over. The host leaks them to `'static` to register
    /// them with the engine, so the loader should not keep a second copy.
    pub fn take_assets(&mut self) -> Vec<Asset> {
        std::mem::take(&mut self.assets)
    }
}

/// The set of mods the host found, in the order they should load.
#[derive(Debug, Default)]
pub struct Loader {
    mods: Vec<Manifest>,
    errors: Vec<LoadError>,
}

impl Loader {
    /// An empty loader, for `--no-mods` or a missing directory.
    pub fn empty() -> Loader {
        Loader::default()
    }

    /// Walk `dir`; every immediate subdirectory with a `mod.json` is a mod.
    pub fn discover(dir: &Path) -> Loader {
        let mut errors = Vec::new();
        let mut dirs = Vec::new();
        match std::fs::read_dir(dir) {
            Ok(entries) => {
                for entry in entries.flatten() {
                    let path = entry.path();
                    if path.is_dir() {
                        dirs.push(path);
                    }
                }
            }
            Err(error) => {
                errors.push(LoadError {
                    path: dir.to_path_buf(),
                    message: format!("cannot read the mods directory: {error}"),
                });
                return Loader {
                    mods: Vec::new(),
                    errors,
                };
            }
        }
        dirs.sort();
        if dirs.len() > MAX_MODS {
            errors.push(LoadError {
                path: dir.to_path_buf(),
                message: format!(
                    "{} subdirectories; only the first {MAX_MODS} are considered",
                    dirs.len()
                ),
            });
            dirs.truncate(MAX_MODS);
        }
        let mut mods = Vec::new();
        for path in dirs {
            let manifest_path = path.join("mod.json");
            if !manifest_path.is_file() {
                continue; // not a mod (a parked or unrelated directory)
            }
            match load_one(&path, &manifest_path) {
                Ok(manifest) => mods.push(manifest),
                Err(error) => errors.push(error),
            }
        }
        Loader {
            mods: order(mods, &mut errors),
            errors,
        }
    }

    pub fn mods(&self) -> &[Manifest] {
        &self.mods
    }

    pub fn mods_mut(&mut self) -> &mut [Manifest] {
        &mut self.mods
    }

    pub fn get(&self, id: &str) -> Option<&Manifest> {
        self.mods.iter().find(|manifest| manifest.id == id)
    }

    pub fn errors(&self) -> &[LoadError] {
        &self.errors
    }

    /// The load order's ids.
    pub fn ids(&self) -> Vec<String> {
        self.mods
            .iter()
            .map(|manifest| manifest.id.clone())
            .collect()
    }

    /// The metadata table for `sceneMods(json)`.
    pub fn table_json(&self) -> String {
        let list: Vec<serde_json::Value> = self.mods.iter().map(Manifest::json).collect();
        serde_json::to_string(&list).unwrap_or_else(|_| "[]".to_string())
    }
}

// ---- manifest -------------------------------------------------------------

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawManifest {
    id: String,
    name: String,
    version: String,
    api: u32,
    #[serde(default)]
    side: Option<String>,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    entry: Option<String>,
    #[serde(default)]
    assets: BTreeMap<String, OneOrMany>,
    #[serde(default)]
    tuning: Option<String>,
    #[serde(default)]
    load_after: Vec<String>,
}

#[derive(serde::Deserialize)]
#[serde(untagged)]
enum OneOrMany {
    One(String),
    Many(Vec<String>),
}

impl OneOrMany {
    /// The files this slot maps to, cloning so the caller can borrow the raw
    /// manifest while it reads them.
    fn to_vec(&self) -> Vec<String> {
        match self {
            OneOrMany::One(text) => vec![text.clone()],
            OneOrMany::Many(list) => list.clone(),
        }
    }
}

fn load_one(dir: &Path, manifest_path: &Path) -> Result<Manifest, LoadError> {
    let fail = |message: String| LoadError {
        path: manifest_path.to_path_buf(),
        message,
    };

    let text = read_text(manifest_path, MAX_MANIFEST_BYTES, "mod.json").map_err(fail)?;
    let raw: RawManifest =
        serde_json::from_str(&text).map_err(|error| fail(format!("invalid manifest: {error}")))?;

    if !valid_id(&raw.id) {
        return Err(fail(format!(
            "'{}' is not a valid id (use letters, digits, '.', '_' or '-')",
            raw.id
        )));
    }
    if raw.name.trim().is_empty() {
        return Err(fail("'name' must not be empty".to_string()));
    }
    if raw.version.trim().is_empty() {
        return Err(fail("'version' must not be empty".to_string()));
    }
    if raw.api != MOD_API {
        return Err(fail(format!(
            "api {} is not supported by this build (api {MOD_API})",
            raw.api
        )));
    }
    let side = match raw.side.as_deref() {
        None | Some("client") => Side::Client,
        Some("world") => Side::World,
        Some(other) => {
            return Err(fail(format!(
                "side must be \"client\" or \"world\", not \"{other}\""
            )));
        }
    };

    let entry_source = match &raw.entry {
        Some(name) => {
            let path = safe_join(dir, name).map_err(fail)?;
            Some(read_text(&path, MAX_ENTRY_BYTES, "entry").map_err(fail)?)
        }
        None => None,
    };
    let tuning_json = match &raw.tuning {
        Some(name) => {
            let path = safe_join(dir, name).map_err(fail)?;
            Some(read_text(&path, MAX_MANIFEST_BYTES, "tuning").map_err(fail)?)
        }
        None => None,
    };

    let mut assets = Vec::new();
    for (slot, files) in &raw.assets {
        let files = files.to_vec();
        for (index, file) in files.iter().enumerate() {
            let path = safe_join(dir, file)
                .map_err(|message| fail(format!("asset '{slot}': {message}")))?;
            let bytes = read_capped(&path, MAX_ASSET_BYTES, "asset")
                .map_err(|message| fail(format!("asset '{slot}': {message}")))?;
            // One file fills the slot on its own; several are addressed by
            // index, so a mod can replace a whole sound list.
            let name = if files.len() == 1 {
                format!("mod:{}:{}", raw.id, slot)
            } else {
                format!("mod:{}:{}:{}", raw.id, slot, index)
            };
            assets.push(Asset {
                slot: slot.clone(),
                index,
                name,
                bytes,
            });
        }
    }

    let hash = hash_manifest(&raw.id, &raw.version, entry_source.as_deref(), &assets);
    Ok(Manifest {
        id: raw.id,
        name: raw.name,
        version: raw.version,
        api: raw.api,
        side,
        description: raw.description.unwrap_or_default(),
        entry: raw.entry,
        entry_source,
        assets,
        tuning: raw.tuning,
        tuning_json,
        load_after: raw.load_after,
        dir: dir.to_path_buf(),
        hash,
    })
}

fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

/// Resolve a manifest-relative path, refusing anything that could escape the
/// mod's directory.
fn safe_join(dir: &Path, relative: &str) -> Result<PathBuf, String> {
    let rel = Path::new(relative);
    if rel.is_absolute() {
        return Err(format!(
            "'{relative}' must be relative to the mod directory"
        ));
    }
    for component in rel.components() {
        match component {
            Component::Normal(_) | Component::CurDir => {}
            _ => return Err(format!("'{relative}' must not contain '..' or a root")),
        }
    }
    Ok(dir.join(rel))
}

fn read_capped(path: &Path, max: u64, what: &str) -> Result<Vec<u8>, String> {
    let metadata = std::fs::metadata(path)
        .map_err(|error| format!("'{what}' '{}': {error}", path.display()))?;
    if !metadata.is_file() {
        return Err(format!("{what} '{}' is not a file", path.display()));
    }
    if metadata.len() > max {
        return Err(format!(
            "{what} '{}' is {} bytes (limit {max})",
            path.display(),
            metadata.len()
        ));
    }
    std::fs::read(path).map_err(|error| format!("{what} '{}': {error}", path.display()))
}

fn read_text(path: &Path, max: u64, what: &str) -> Result<String, String> {
    let bytes = read_capped(path, max, what)?;
    String::from_utf8(bytes).map_err(|_| format!("{what} '{}' is not UTF-8", path.display()))
}

// ---- ordering -------------------------------------------------------------

/// Sort by id, then satisfy `loadAfter` with a deterministic topological sort.
/// A missing dependency is a warning; a cycle is a warning and the leftovers
/// keep id order rather than disappearing.
fn order(mut mods: Vec<Manifest>, errors: &mut Vec<LoadError>) -> Vec<Manifest> {
    mods.sort_by(|a, b| a.id.cmp(&b.id));

    let mut seen = BTreeSet::new();
    let mut unique = Vec::with_capacity(mods.len());
    for manifest in mods {
        if !seen.insert(manifest.id.clone()) {
            errors.push(LoadError {
                path: manifest.dir.clone(),
                message: format!("duplicate mod id '{}'; this one is ignored", manifest.id),
            });
            continue;
        }
        unique.push(manifest);
    }

    let mods = unique;
    let count = mods.len();
    let mut index: BTreeMap<String, usize> = BTreeMap::new();
    for (at, manifest) in mods.iter().enumerate() {
        index.insert(manifest.id.clone(), at);
    }

    let mut indegree = vec![0usize; count];
    let mut edges: Vec<Vec<usize>> = vec![Vec::new(); count];
    for (at, manifest) in mods.iter().enumerate() {
        for dependency in &manifest.load_after {
            if dependency == &manifest.id {
                continue;
            }
            match index.get(dependency) {
                Some(&before) => {
                    edges[before].push(at);
                    indegree[at] += 1;
                }
                None => errors.push(LoadError {
                    path: manifest.dir.clone(),
                    message: format!(
                        "mod '{}' wants to load after '{dependency}', which is not installed",
                        manifest.id
                    ),
                }),
            }
        }
    }

    let mut ready: BTreeSet<usize> = (0..count).filter(|&at| indegree[at] == 0).collect();
    let mut slots: Vec<Option<Manifest>> = mods.into_iter().map(Some).collect();
    let mut ordered = Vec::with_capacity(count);
    while let Some(&at) = ready.iter().next() {
        ready.remove(&at);
        if let Some(manifest) = slots[at].take() {
            ordered.push(manifest);
        }
        for &after in &edges[at] {
            indegree[after] -= 1;
            if indegree[after] == 0 {
                ready.insert(after);
            }
        }
    }

    if ordered.len() < count {
        errors.push(LoadError {
            path: PathBuf::new(),
            message: "loadAfter cycle detected; the remaining mods load in id order".to_string(),
        });
        for slot in slots.iter_mut() {
            if let Some(manifest) = slot.take() {
                ordered.push(manifest);
            }
        }
    }

    ordered
}

// ---- hashing --------------------------------------------------------------

const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;

fn fnv1a(hash: &mut u64, bytes: &[u8]) {
    for &byte in bytes {
        *hash ^= byte as u64;
        *hash = hash.wrapping_mul(FNV_PRIME);
    }
}

/// The compatibility hash: a stable FNV-1a over the identity and the content.
/// It is for "same version, different content" during development, not for
/// security.
fn hash_manifest(id: &str, version: &str, entry: Option<&str>, assets: &[Asset]) -> u64 {
    let mut hash = FNV_OFFSET;
    fnv1a(&mut hash, id.as_bytes());
    fnv1a(&mut hash, &[0]);
    fnv1a(&mut hash, version.as_bytes());
    if let Some(source) = entry {
        fnv1a(&mut hash, &[0]);
        fnv1a(&mut hash, source.as_bytes());
    }
    for asset in assets {
        fnv1a(&mut hash, &[0]);
        fnv1a(&mut hash, asset.name.as_bytes());
        fnv1a(&mut hash, &asset.bytes);
    }
    hash
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};

    static COUNTER: AtomicU32 = AtomicU32::new(0);

    fn workspace(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "goats-mods-{}-{}-{name}",
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

    fn write_mod(root: &Path, id: &str, manifest: &str) {
        write(&root.join(id).join("mod.json"), manifest);
    }

    #[test]
    fn a_minimal_manifest_defaults_to_client() {
        let root = workspace("minimal");
        write_mod(
            &root,
            "hello",
            r#"{ "id": "hello", "name": "Hello", "version": "1.0.0", "api": 1, "entry": "mod.js" }"#,
        );
        write(&root.join("hello").join("mod.js"), "goats.log('hi');");
        let loader = Loader::discover(&root);
        assert!(loader.errors().is_empty(), "{:?}", loader.errors());
        assert_eq!(loader.mods().len(), 1);
        let manifest = &loader.mods()[0];
        assert_eq!(manifest.side, Side::Client);
        assert_eq!(manifest.entry.as_deref(), Some("mod.js"));
        assert!(
            manifest
                .entry_source
                .as_deref()
                .unwrap()
                .contains("goats.log")
        );
        assert_ne!(manifest.hash, 0);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn the_api_major_must_match() {
        let root = workspace("api");
        write_mod(
            &root,
            "future",
            r#"{ "id": "future", "name": "Future", "version": "1", "api": 2 }"#,
        );
        let loader = Loader::discover(&root);
        assert!(loader.mods().is_empty());
        assert_eq!(loader.errors().len(), 1);
        assert!(
            loader.errors()[0].message.contains("api 2"),
            "{:?}",
            loader.errors()
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn load_after_overrides_the_id_order() {
        let root = workspace("order");
        write_mod(
            &root,
            "a",
            r#"{ "id": "a", "name": "A", "version": "1", "api": 1, "loadAfter": ["z"] }"#,
        );
        write_mod(
            &root,
            "z",
            r#"{ "id": "z", "name": "Z", "version": "1", "api": 1 }"#,
        );
        let loader = Loader::discover(&root);
        assert!(loader.errors().is_empty(), "{:?}", loader.errors());
        assert_eq!(loader.ids(), vec!["z".to_string(), "a".to_string()]);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_cycle_keeps_everything_in_id_order() {
        let root = workspace("cycle");
        write_mod(
            &root,
            "a",
            r#"{ "id": "a", "name": "A", "version": "1", "api": 1, "loadAfter": ["b"] }"#,
        );
        write_mod(
            &root,
            "b",
            r#"{ "id": "b", "name": "B", "version": "1", "api": 1, "loadAfter": ["a"] }"#,
        );
        let loader = Loader::discover(&root);
        assert_eq!(loader.ids(), vec!["a".to_string(), "b".to_string()]);
        assert!(loader.errors().iter().any(|e| e.message.contains("cycle")));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_path_that_escapes_the_mod_is_refused() {
        let root = workspace("escape");
        write_mod(
            &root,
            "sneaky",
            r#"{ "id": "sneaky", "name": "S", "version": "1", "api": 1, "entry": "../evil.js" }"#,
        );
        let loader = Loader::discover(&root);
        assert!(loader.mods().is_empty());
        assert!(
            loader.errors()[0].message.contains(".."),
            "{:?}",
            loader.errors()
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn assets_are_addressed_by_an_opaque_name() {
        let root = workspace("assets");
        write_mod(
            &root,
            "coat",
            r#"{ "id": "coat", "name": "Coat", "version": "1", "api": 1, "assets": { "model.goat": "models/goat.glb" } }"#,
        );
        write(
            &root.join("coat").join("models").join("goat.glb"),
            "glTF-bytes",
        );
        let loader = Loader::discover(&root);
        let manifest = &loader.mods()[0];
        assert_eq!(
            manifest.asset_map().get("model.goat").unwrap(),
            &vec!["mod:coat:model.goat".to_string()]
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn the_table_json_carries_the_metadata() {
        let root = workspace("table");
        write_mod(
            &root,
            "dash",
            r#"{ "id": "dash", "name": "Dash", "version": "2.0.0", "api": 1, "side": "world" }"#,
        );
        let loader = Loader::discover(&root);
        let table: serde_json::Value = serde_json::from_str(&loader.table_json()).unwrap();
        assert_eq!(table[0]["id"], "dash");
        assert_eq!(table[0]["side"], "world");
        assert_eq!(table[0]["api"], 1);
        assert!(table[0]["hash"].as_str().unwrap().len() == 16);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn entry_js_is_wrapped_in_a_scope_with_a_handle() {
        let root = workspace("wrap");
        write_mod(
            &root,
            "hi",
            r#"{ "id": "hi", "name": "Hi", "version": "1", "api": 1, "entry": "mod.js" }"#,
        );
        write(&root.join("hi").join("mod.js"), "goats.log('hi');");
        let loader = Loader::discover(&root);
        let js = loader.get("hi").unwrap().entry_js().unwrap();
        assert!(js.contains("goats.begin(\"hi\")"), "{js}");
        assert!(js.contains("\"use strict\""), "{js}");
        let _ = std::fs::remove_dir_all(&root);
    }
}
