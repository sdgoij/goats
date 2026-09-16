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
//!
//! A mod's files come from a [`ModSource`]: a directory, or a `.zip` whose root
//! holds `mod.json`. The optional [`watch`] module reports filesystem changes so
//! a host can reload a mod while it is being developed.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Component, Path, PathBuf};

pub mod watch;

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

/// One asset file. `bytes` is empty in [`AssetMode::HashOnly`], where the file
/// was read only to hash it.
#[derive(Debug)]
pub struct Asset {
    /// The logical slot the mod is filling (`model.goat`, `sfx.music`, ...).
    pub slot: String,
    /// Position within a list-valued slot.
    pub index: usize,
    /// The name to register with the engine.
    pub name: String,
    pub bytes: Vec<u8>,
    /// FNV-1a over the file's bytes, so the manifest hash is the same whether
    /// the bytes were kept or streamed.
    pub content_hash: u64,
}

/// Whether discovery keeps asset bytes in memory.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AssetMode {
    /// Keep the bytes so the host can register them with the engine (a client).
    Keep,
    /// Hash the bytes and drop them; the headless server only needs the digest,
    /// and a mod's model should not sit in a server's memory for nothing.
    HashOnly,
    /// The headless server: hash and drop assets, but keep a mod's wasm module,
    /// because that is code the server must run rather than data to register.
    KeepWasm,
}

/// Where a mod's files live. A directory is the editable form; a `.zip` is the
/// distributable one, with `mod.json` at the archive root.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ModSource {
    Dir(PathBuf),
    Zip(PathBuf),
}

impl ModSource {
    /// The path to watch or report: the directory, or the archive file.
    pub fn path(&self) -> &Path {
        match self {
            ModSource::Dir(path) | ModSource::Zip(path) => path,
        }
    }

    /// Whether a filesystem change under the mods directory belongs to this mod.
    pub fn touches(&self, changed: &Path) -> bool {
        match self {
            ModSource::Dir(dir) => changed.starts_with(dir),
            ModSource::Zip(zip) => changed == zip,
        }
    }

    /// Read a manifest-relative file out of the source, capped at `max`.
    fn read(&self, relative: &str, max: u64, what: &str) -> Result<Vec<u8>, String> {
        match self {
            ModSource::Dir(dir) => {
                let path = safe_join(dir, relative)?;
                read_capped(&path, max, what)
            }
            ModSource::Zip(zip) => read_zip_entry(zip, relative, max, what),
        }
    }
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
    /// A compiled module this mod ships instead of (or beside) an entry.
    pub wasm: Option<WasmModule>,
    pub load_after: Vec<String>,
    /// Where the files were read from (for diagnostics and reloading).
    pub source: ModSource,
    /// The compatibility hash (FNV-1a over id, version, entry and assets).
    pub hash: u64,
}

impl Manifest {
    /// The directory or archive the mod was read from.
    pub fn path(&self) -> &Path {
        self.source.path()
    }

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
        let mut value = serde_json::json!({
            "id": self.id,
            "name": self.name,
            "version": self.version,
            "api": self.api,
            "side": self.side.as_str(),
            "description": self.description,
            "enabled": true,
            "hash": format!("{:016x}", self.hash),
            "assets": assets,
        });
        // The scene merges this before the entry runs. A malformed tree is the
        // scene's to warn about; here it is passed through verbatim, since only
        // the scene knows which paths the tree has.
        if let Some(text) = &self.tuning_json
            && let Ok(tuning) = serde_json::from_str::<serde_json::Value>(text)
        {
            value["tuning"] = tuning;
        }
        // A compiled mod has no entry to run; the name is here so the console
        // and the Mods screen can say what kind of mod it is.
        if let Some(wasm) = &self.wasm {
            value["wasm"] = serde_json::json!(wasm.module);
        }
        value
    }

    /// Hand the asset bytes over. The host leaks them to `'static` to register
    /// them with the engine, so the loader does not keep a second copy -- but the
    /// slot and the opaque name are not the bytes: they are what the metadata
    /// table ([`Manifest::json`]) is built from, and the host pushes that table
    /// *after* the handover. Emptying the list here is what left every
    /// boot-loaded mod with no `assets` in the table, so a slot the mod declared
    /// resolved to nothing.
    pub fn take_assets(&mut self) -> Vec<Asset> {
        let taken = std::mem::take(&mut self.assets);
        self.assets = taken
            .iter()
            .map(|asset| Asset {
                slot: asset.slot.clone(),
                index: asset.index,
                name: asset.name.clone(),
                bytes: Vec::new(),
                content_hash: asset.content_hash,
            })
            .collect();
        taken
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
    /// Asset bytes are kept, for a host that will register them.
    pub fn discover(dir: &Path) -> Loader {
        Loader::discover_with(dir, AssetMode::Keep)
    }

    /// Walk `dir`, with control over whether asset bytes are kept. Every
    /// immediate subdirectory with a `mod.json` is a mod, and so is every
    /// `*.zip` with `mod.json` at its root.
    pub fn discover_with(dir: &Path, mode: AssetMode) -> Loader {
        let mut errors = Vec::new();
        let mut sources = Vec::new();
        match std::fs::read_dir(dir) {
            Ok(entries) => {
                for entry in entries.flatten() {
                    let path = entry.path();
                    if path.is_dir() {
                        // A directory without a manifest is parked or unrelated,
                        // not a broken mod, so it is skipped silently.
                        if path.join("mod.json").is_file() {
                            sources.push(ModSource::Dir(path));
                        }
                    } else if is_zip(&path) {
                        sources.push(ModSource::Zip(path));
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
        sources.sort_by(|a, b| a.path().cmp(b.path()));
        if sources.len() > MAX_MODS {
            errors.push(LoadError {
                path: dir.to_path_buf(),
                message: format!(
                    "{} mod sources; only the first {MAX_MODS} are considered",
                    sources.len()
                ),
            });
            sources.truncate(MAX_MODS);
        }
        let mut mods = Vec::new();
        for source in sources {
            match load_source(&source, mode) {
                Ok(manifest) => mods.push(manifest),
                Err(error) => errors.push(error),
            }
        }
        Loader {
            mods: order(mods, &mut errors),
            errors,
        }
    }

    /// Re-read one mod from its source, replacing the cached manifest, so a
    /// change on disk takes effect without a restart. Its id must not have
    /// changed: a rename needs a fresh discovery and a restart.
    pub fn reload(&mut self, id: &str, mode: AssetMode) -> Result<(), LoadError> {
        let index = self
            .mods
            .iter()
            .position(|manifest| manifest.id == id)
            .ok_or_else(|| LoadError {
                path: PathBuf::new(),
                message: format!("unknown mod '{id}'"),
            })?;
        let source = self.mods[index].source.clone();
        let manifest = load_source(&source, mode)?;
        if manifest.id != id {
            return Err(LoadError {
                path: source.path().to_path_buf(),
                message: format!(
                    "reloaded '{id}' now declares id '{}'; restart to rename it",
                    manifest.id
                ),
            });
        }
        self.mods[index] = manifest;
        Ok(())
    }

    /// The ids whose source contains `changed` -- a file the watcher reported.
    pub fn mods_touching(&self, changed: &Path) -> Vec<String> {
        self.mods
            .iter()
            .filter(|manifest| manifest.source.touches(changed))
            .map(|manifest| manifest.id.clone())
            .collect()
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

/// A compiled mod: the module's bytes, and the file they came from.
///
/// The bytes are handed to the scene as an `ArrayBuffer` -- the host never gives
/// a mod a path, and a module is content like any other asset (`APIv1.md`
/// section 0). The ABI version is not here: the module reports its own through
/// `goats_abi()`, which is the number its code was actually built against, so
/// the manifest does not get to claim one.
#[derive(Debug, Clone)]
pub struct WasmModule {
    /// The declared file name, for diagnostics and reload.
    pub module: String,
    pub bytes: Vec<u8>,
    /// FNV-1a over the bytes, so the digest is the same whether they were kept
    /// or streamed.
    pub content_hash: u64,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawWasm {
    module: String,
}

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
    wasm: Option<RawWasm>,
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

fn load_source(source: &ModSource, mode: AssetMode) -> Result<Manifest, LoadError> {
    let fail = |message: String| LoadError {
        path: source.path().to_path_buf(),
        message,
    };

    let text =
        read_source_text(source, "mod.json", MAX_MANIFEST_BYTES, "mod.json").map_err(fail)?;
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
        Some(name) => Some(read_source_text(source, name, MAX_ENTRY_BYTES, "entry").map_err(fail)?),
        None => None,
    };
    let tuning_json = match &raw.tuning {
        Some(name) => {
            Some(read_source_text(source, name, MAX_MANIFEST_BYTES, "tuning").map_err(fail)?)
        }
        None => None,
    };

    let mut assets = Vec::new();
    for (slot, files) in &raw.assets {
        let files = files.to_vec();
        for (index, file) in files.iter().enumerate() {
            let (bytes, content_hash) = read_asset_source(source, file, mode == AssetMode::Keep)
                .map_err(|message| fail(format!("asset '{slot}': {message}")))?;
            // One file fills the slot on its own; several are addressed by
            // index, so a mod can replace a whole sound list.
            //
            // The name ends in the source file's extension because the engine
            // materialises the bytes to a temp file and raylib picks its decoder
            // from that extension. A name ending in the slot (`...model.fatguy`)
            // is handed to raylib as `.fatguy`, which no decoder claims. A file
            // with no extension keeps the bare name.
            let extension = std::path::Path::new(file)
                .extension()
                .and_then(|extension| extension.to_str())
                .map(|extension| format!(".{extension}"))
                .unwrap_or_default();
            let name = if files.len() == 1 {
                format!("mod:{}:{}{}", raw.id, slot, extension)
            } else {
                format!("mod:{}:{}:{}{}", raw.id, slot, index, extension)
            };
            assets.push(Asset {
                slot: slot.clone(),
                index,
                name,
                bytes,
                content_hash,
            });
        }
    }

    let wasm = match &raw.wasm {
        Some(declared) => {
            // A server keeps the module it must run but drops assets; a client
            // keeps both. The magic-number check only runs when the bytes were
            // kept, because a `HashOnly` read deliberately returns none.
            let keep_wasm = mode != AssetMode::HashOnly;
            let (bytes, content_hash) =
                read_asset_source(source, &declared.module, keep_wasm).map_err(fail)?;
            if keep_wasm && !bytes.starts_with(b"\0asm") {
                return Err(fail(format!(
                    "wasm module '{}' is not a WebAssembly module (no magic number)",
                    declared.module
                )));
            }
            Some(WasmModule {
                module: declared.module.clone(),
                bytes,
                content_hash,
            })
        }
        None => None,
    };

    let hash = hash_manifest(
        &raw.id,
        &raw.version,
        entry_source.as_deref(),
        tuning_json.as_deref(),
        wasm.as_ref().map(|module| module.content_hash),
        &assets,
    );
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
        wasm,
        load_after: raw.load_after,
        source: source.clone(),
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
    valid_relative(relative)?;
    Ok(dir.join(Path::new(relative)))
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

/// Read an asset, returning its bytes (empty in hash-only mode) and the FNV-1a
/// hash the manifest folds in. Both modes hash the same bytes, so a client and
/// a server agree on the digest.
fn read_asset(path: &Path, keep: bool) -> Result<(Vec<u8>, u64), String> {
    if keep {
        let bytes = read_capped(path, MAX_ASSET_BYTES, "asset")?;
        let mut hash = FNV_OFFSET;
        fnv1a(&mut hash, &bytes);
        return Ok((bytes, hash));
    }

    let metadata = std::fs::metadata(path)
        .map_err(|error| format!("'asset' '{}': {error}", path.display()))?;
    if !metadata.is_file() {
        return Err(format!("asset '{}' is not a file", path.display()));
    }
    if metadata.len() > MAX_ASSET_BYTES {
        return Err(format!(
            "asset '{}' is {} bytes (limit {MAX_ASSET_BYTES})",
            path.display(),
            metadata.len()
        ));
    }
    use std::io::Read;
    let mut file = std::fs::File::open(path)
        .map_err(|error| format!("asset '{}': {error}", path.display()))?;
    let mut hash = FNV_OFFSET;
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|error| format!("asset '{}': {error}", path.display()))?;
        if read == 0 {
            break;
        }
        fnv1a(&mut hash, &buffer[..read]);
    }
    Ok((Vec::new(), hash))
}

/// A `.zip` file (case-insensitive extension) is a candidate mod source.
fn is_zip(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| extension.eq_ignore_ascii_case("zip"))
}

/// Refuse a manifest-relative path that could escape the mod.
fn valid_relative(relative: &str) -> Result<(), String> {
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
    Ok(())
}

/// Read a text file the loader parses -- an entry, a tuning tree -- with its
/// line endings normalised to `\n`.
///
/// This is not cosmetic. The compatibility digest is taken over this text, so a
/// `\r\n` checkout of the same mod on Windows and an `\n` one on Linux would
/// otherwise hash differently and the two ends would refuse each other's
/// sessions -- which is exactly what happened: the same commit, built on a
/// Windows box and a Linux server, could not play together. JavaScript and JSON
/// do not care which line ending a statement ends with, so neither does a mod's
/// identity. (Opaque assets are still compared byte for byte: the loader does not
/// know what they are, and normalising bytes it cannot read would be worse.)
fn read_source_text(
    source: &ModSource,
    relative: &str,
    max: u64,
    what: &str,
) -> Result<String, String> {
    let bytes = source.read(relative, max, what)?;
    let text = String::from_utf8(bytes).map_err(|_| format!("{what} '{relative}' is not UTF-8"))?;
    Ok(if text.contains('\r') {
        text.replace("\r\n", "\n")
    } else {
        text
    })
}

/// Read an asset from either source, returning its bytes (empty in hash-only
/// mode) and the FNV-1a hash the manifest folds in. Both sources hash the same
/// bytes, so a directory mod and its zipped twin have the same digest.
fn read_asset_source(source: &ModSource, file: &str, keep: bool) -> Result<(Vec<u8>, u64), String> {
    match source {
        ModSource::Dir(dir) => {
            let path = safe_join(dir, file)?;
            read_asset(&path, keep)
        }
        ModSource::Zip(_) => {
            // A zip entry cannot be streamed without decompressing it first.
            let bytes = source.read(file, MAX_ASSET_BYTES, "asset")?;
            let mut hash = FNV_OFFSET;
            fnv1a(&mut hash, &bytes);
            Ok(if keep {
                (bytes, hash)
            } else {
                (Vec::new(), hash)
            })
        }
    }
}

/// Read one entry from a `.zip`. `mod.json` at the archive root is the
/// convention; a zip that wrapped everything in a single top-level directory
/// still works, because a unique `*/<name>` match is accepted.
fn read_zip_entry(zip: &Path, relative: &str, max: u64, what: &str) -> Result<Vec<u8>, String> {
    valid_relative(relative)?;
    let label = || format!("{what} '{relative}' in '{}'", zip.display());
    let file = std::fs::File::open(zip).map_err(|error| format!("{}: {error}", label()))?;
    let mut archive = zip::ZipArchive::new(file)
        .map_err(|error| format!("'{}' is not a readable zip: {error}", zip.display()))?;

    let entry_name = if archive.by_name(relative).is_ok() {
        relative.to_string()
    } else {
        let suffix = format!("/{relative}");
        let mut matches: Vec<&str> = archive
            .file_names()
            .filter(|name| name.ends_with(&suffix))
            .collect();
        matches.sort();
        matches.dedup();
        match matches.as_slice() {
            [only] => (*only).to_string(),
            [] => return Err(format!("{}: not found", label())),
            _ => {
                return Err(format!(
                    "{}: ambiguous, {} candidates",
                    label(),
                    matches.len()
                ));
            }
        }
    };

    let mut entry = archive
        .by_name(&entry_name)
        .map_err(|error| format!("{}: {error}", label()))?;
    if entry.size() > max {
        return Err(format!(
            "{} is {} bytes (limit {max})",
            label(),
            entry.size()
        ));
    }
    let mut bytes = Vec::with_capacity(entry.size() as usize);
    std::io::Read::read_to_end(&mut entry, &mut bytes)
        .map_err(|error| format!("{}: {error}", label()))?;
    if bytes.len() as u64 > max {
        return Err(format!(
            "{} is {} bytes (limit {max})",
            label(),
            bytes.len()
        ));
    }
    Ok(bytes)
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
                path: manifest.path().to_path_buf(),
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
                    path: manifest.path().to_path_buf(),
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
///
/// The content is the entry's text and the tuning tree (both normalised to `\n`
/// by `read_source_text`), every asset's name and bytes, and a compiled module's
/// bytes. The tuning belongs here because a world mod whose `tuning.json` differs
/// but whose code does not is exactly the silent divergence this digest exists to
/// catch -- and so does a compiled module, whose bytes are what its `goats_abi()`
/// reports.
fn hash_manifest(
    id: &str,
    version: &str,
    entry: Option<&str>,
    tuning: Option<&str>,
    wasm: Option<u64>,
    assets: &[Asset],
) -> u64 {
    let mut hash = FNV_OFFSET;
    fnv1a(&mut hash, id.as_bytes());
    fnv1a(&mut hash, &[0]);
    fnv1a(&mut hash, version.as_bytes());
    if let Some(source) = entry {
        fnv1a(&mut hash, &[0]);
        fnv1a(&mut hash, source.as_bytes());
    }
    if let Some(tuning) = tuning {
        fnv1a(&mut hash, &[0]);
        fnv1a(&mut hash, tuning.as_bytes());
    }
    if let Some(wasm) = wasm {
        fnv1a(&mut hash, &[0]);
        fnv1a(&mut hash, &wasm.to_le_bytes());
    }
    for asset in assets {
        fnv1a(&mut hash, &[0]);
        fnv1a(&mut hash, asset.name.as_bytes());
        fnv1a(&mut hash, &asset.content_hash.to_le_bytes());
    }
    hash
}

/// Package a mods directory into a `.zip` in memory, every file stored under its
/// path relative to `dir`. Extracting the archive into a joiner's `mods/`
/// reproduces the set this host is running -- the distribution side of
/// [`Loader::discover`], which `goatsd`'s status page hands out.
///
/// The layout is preserved rather than flattened because the loader expects one
/// directory per mod (or a single `*.zip`), and a directory mod and its zipped
/// twin must hash the same.
pub fn archive_dir(dir: &Path) -> Result<Vec<u8>, String> {
    use std::io::Write as _;

    fn add<W: std::io::Write + std::io::Seek>(
        archive: &mut zip::ZipWriter<W>,
        root: &Path,
        dir: &Path,
    ) -> Result<(), String> {
        let read =
            std::fs::read_dir(dir).map_err(|error| format!("'{}': {error}", dir.display()))?;
        let mut paths: Vec<PathBuf> = Vec::new();
        for entry in read {
            let entry = entry.map_err(|error| format!("'{}': {error}", dir.display()))?;
            paths.push(entry.path());
        }
        paths.sort();
        for path in paths {
            if path.is_dir() {
                add(archive, root, &path)?;
                continue;
            }
            let name = path
                .strip_prefix(root)
                .map_err(|error| format!("'{}': {error}", path.display()))?
                .to_string_lossy()
                .replace('\\', "/");
            let bytes =
                std::fs::read(&path).map_err(|error| format!("'{}': {error}", path.display()))?;
            let options = zip::write::FileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated);
            archive
                .start_file(&name, options)
                .map_err(|error| format!("zip '{name}': {error}"))?;
            archive
                .write_all(&bytes)
                .map_err(|error| format!("zip '{name}': {error}"))?;
        }
        Ok(())
    }

    let cursor = std::io::Cursor::new(Vec::new());
    let mut archive = zip::ZipWriter::new(cursor);
    add(&mut archive, dir, dir)?;
    let cursor = archive.finish().map_err(|error| format!("zip: {error}"))?;
    Ok(cursor.into_inner())
}

/// A mod in the one form a joiner can install: a `.zip` with `mod.json` at the
/// root. A directory mod is packaged; a mod already stored as a `.zip` is served
/// as it is. This is what a host hands a fetching client (M18).
pub fn archive_source(source: &ModSource) -> Result<Vec<u8>, String> {
    match source {
        ModSource::Dir(dir) => archive_dir(dir),
        ModSource::Zip(zip) => {
            std::fs::read(zip).map_err(|error| format!("'{}': {error}", zip.display()))
        }
    }
}

/// Load one `.zip` as a mod, without walking a directory -- the inverse of
/// [`archive_source`], for an archive a caller has just written to disk and must
/// check against the identity it was promised (M18b). Asset bytes are kept: this
/// is an install, not a digest pass.
pub fn load_zip(path: &Path) -> Result<Manifest, LoadError> {
    load_source(&ModSource::Zip(path.to_path_buf()), AssetMode::Keep)
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
    fn a_windows_checkout_hashes_like_a_linux_one() {
        // The bug this exists for: the digest is taken over the entry's text, so a
        // `\r\n` checkout on Windows and an `\n` one on Linux hashed differently
        // for the same mod -- the same commit, built on a Windows box and a Linux
        // server, refused each other's sessions. JavaScript does not care which
        // line ending ends a statement, so a mod's identity must not either.
        let lf = workspace("eol-lf");
        let crlf = workspace("eol-crlf");
        let manifest = r#"{ "id": "com.example.eol", "name": "Eol", "version": "1",
            "api": 1, "side": "world", "entry": "mod.js", "tuning": "tuning.json" }"#;
        write_mod(&lf, "eol", manifest);
        write_mod(&crlf, "eol", manifest);

        let source = "let n = 1;\nreturn n;\n";
        let tuning = "{\n  \"camera\": { \"dist\": 6.5 }\n}\n";
        write(&lf.join("eol").join("mod.js"), source);
        write(&lf.join("eol").join("tuning.json"), tuning);
        write(
            &crlf.join("eol").join("mod.js"),
            &source.replace('\n', "\r\n"),
        );
        write(
            &crlf.join("eol").join("tuning.json"),
            &tuning.replace('\n', "\r\n"),
        );

        let a = Loader::discover(&lf);
        let b = Loader::discover(&crlf);
        assert!(a.errors().is_empty(), "{:?}", a.errors());
        assert!(b.errors().is_empty(), "{:?}", b.errors());

        // The two fixtures really do differ on disk, byte for byte: without the
        // normalisation in `read_source_text` this test *is* the bug report.
        assert_ne!(
            std::fs::read(lf.join("eol").join("mod.js")).expect("the lf entry"),
            std::fs::read(crlf.join("eol").join("mod.js")).expect("the crlf entry"),
            "the fixtures should differ as bytes"
        );

        let a = a.get("com.example.eol").expect("the lf mod");
        let b = b.get("com.example.eol").expect("the crlf mod");
        assert_eq!(a.hash, b.hash, "line endings are not content");
        assert_eq!(a.entry_source, b.entry_source);
        assert_eq!(a.tuning_json, b.tuning_json);
        // What runs is the same too, not just what is hashed.
        assert_eq!(a.entry_js(), b.entry_js());

        let _ = std::fs::remove_dir_all(&lf);
        let _ = std::fs::remove_dir_all(&crlf);
    }

    #[test]
    fn a_different_tuning_tree_is_a_different_mod() {
        // A world mod whose `tuning.json` differs but whose code does not is
        // exactly the silent divergence the digest exists to catch.
        let root = workspace("tuning-digest");
        write_mod(
            &root,
            "t",
            r#"{ "id": "com.example.t", "name": "T", "version": "1",
                "api": 1, "side": "world", "entry": "mod.js", "tuning": "tuning.json" }"#,
        );
        write(&root.join("t").join("mod.js"), "1;\n");
        write(
            &root.join("t").join("tuning.json"),
            r#"{ "camera": { "dist": 6.5 } }"#,
        );
        let before = Loader::discover(&root);
        let hash = before.get("com.example.t").expect("the mod").hash;

        write(
            &root.join("t").join("tuning.json"),
            r#"{ "camera": { "dist": 8.0 } }"#,
        );
        let after = Loader::discover(&root);
        assert_ne!(
            hash,
            after.get("com.example.t").expect("the mod").hash,
            "the tuning tree is content"
        );
        let _ = std::fs::remove_dir_all(&root);
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
            &vec!["mod:coat:model.goat.glb".to_string()]
        );
        // The engine reads the extension off the name to pick raylib's decoder,
        // so the opaque name has to carry the file's own.
        assert_eq!(manifest.assets[0].name, "mod:coat:model.goat.glb");
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
    fn the_table_still_names_the_assets_after_the_bytes_are_taken() {
        let root = workspace("assets-table");
        write_mod(
            &root,
            "pack",
            r#"{ "id": "pack", "name": "Pack", "version": "1.0.0", "api": 1, "side": "client",
                 "assets": { "model.fatguy": "guy.glb" } }"#,
        );
        write(&root.join("pack").join("guy.glb"), "not really a glb");
        let mut loader = Loader::discover(&root);
        // The host registers the bytes with the engine before the scene is handed
        // the table, so the handover comes first -- and it must not cost the table
        // the names. It did: every boot-loaded mod arrived with no `assets`, so the
        // slots it declared resolved to nothing.
        for manifest in loader.mods_mut() {
            assert_eq!(manifest.take_assets().len(), 1);
        }
        let table: serde_json::Value = serde_json::from_str(&loader.table_json()).unwrap();
        assert_eq!(
            table[0]["assets"]["model.fatguy"],
            "mod:pack:model.fatguy.glb"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn the_table_json_carries_the_declared_tuning() {
        let root = workspace("tuning-table");
        write_mod(
            &root,
            "tune",
            r#"{ "id": "tune", "name": "Tune", "version": "1", "api": 1, "tuning": "tuning.json" }"#,
        );
        write(
            &root.join("tune").join("tuning.json"),
            r#"{ "stats": { "max": 120 }, "nope": 1 }"#,
        );
        let loader = Loader::discover(&root);
        let table: serde_json::Value = serde_json::from_str(&loader.table_json()).unwrap();
        // The tree travels verbatim; the scene is what validates a leaf, so a
        // typo reaches it to be warned about rather than being dropped here.
        assert_eq!(table[0]["tuning"]["stats"]["max"], 120);
        assert_eq!(table[0]["tuning"]["nope"], 1);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn hashing_assets_without_keeping_them_matches() {
        let root = workspace("hashonly");
        write_mod(
            &root,
            "m",
            r#"{ "id": "m", "name": "M", "version": "1", "api": 1, "assets": { "sfx.music": "a.bin" } }"#,
        );
        write(&root.join("m").join("a.bin"), "some bytes to hash");
        let keep = Loader::discover_with(&root, AssetMode::Keep);
        let hash_only = Loader::discover_with(&root, AssetMode::HashOnly);
        assert_eq!(
            keep.get("m").unwrap().hash,
            hash_only.get("m").unwrap().hash,
            "both modes must agree on the digest"
        );
        assert!(hash_only.get("m").unwrap().assets[0].bytes.is_empty());
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

    /// Write a `.zip` mod into `root`. Returns the archive path.
    fn write_zip(root: &Path, name: &str, files: &[(&str, &str)]) -> PathBuf {
        use std::io::Write as _;
        std::fs::create_dir_all(root).unwrap();
        let path = root.join(name);
        let file = std::fs::File::create(&path).unwrap();
        let mut archive = zip::ZipWriter::new(file);
        let options =
            zip::write::FileOptions::default().compression_method(zip::CompressionMethod::Deflated);
        for (entry, text) in files {
            archive.start_file(*entry, options).unwrap();
            archive.write_all(text.as_bytes()).unwrap();
        }
        archive.finish().unwrap();
        path
    }

    /// Zip the *contents* of `src` into `dest`, so `mod.json` lands at the root
    /// exactly as a packaged mod does.
    fn zip_directory(dest: &Path, src: &Path) {
        use std::io::Write as _;
        std::fs::create_dir_all(dest.parent().unwrap()).unwrap();
        fn add(archive: &mut zip::ZipWriter<std::fs::File>, src: &Path, dir: &Path) {
            let mut paths: Vec<PathBuf> = std::fs::read_dir(dir)
                .unwrap()
                .map(|entry| entry.unwrap().path())
                .collect();
            paths.sort();
            for path in paths {
                if path.is_dir() {
                    add(archive, src, &path);
                    continue;
                }
                let name = path
                    .strip_prefix(src)
                    .unwrap()
                    .to_string_lossy()
                    .replace('\\', "/");
                let options = zip::write::FileOptions::default()
                    .compression_method(zip::CompressionMethod::Deflated);
                archive.start_file(name, options).unwrap();
                archive.write_all(&std::fs::read(&path).unwrap()).unwrap();
            }
        }
        let file = std::fs::File::create(dest).unwrap();
        let mut archive = zip::ZipWriter::new(file);
        add(&mut archive, src, src);
        archive.finish().unwrap();
    }

    #[test]
    fn the_birds_fixture_is_identical_from_a_zip() {
        // The release ships `mods/birds/` zipped. This proves the zip is a real
        // mod source with the same id, entry and digest as the directory, so a
        // release that cannot load it is caught here rather than in the wild.
        let mods_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("..")
            .join("mods");
        let birds_dir = mods_dir.join("birds");
        let from_dir = Loader::discover(&mods_dir);
        assert!(from_dir.errors().is_empty(), "{:?}", from_dir.errors());
        let dir_manifest = from_dir
            .mods()
            .iter()
            .find(|manifest| manifest.path().ends_with("birds"))
            .expect("the birds directory mod");

        let root = workspace("birdszip");
        zip_directory(&root.join("birds.zip"), &birds_dir);
        let from_zip = Loader::discover(&root);
        assert!(from_zip.errors().is_empty(), "{:?}", from_zip.errors());
        let zip_manifest = from_zip
            .get(&dir_manifest.id)
            .expect("the same mod from a zip");

        assert_eq!(dir_manifest.hash, zip_manifest.hash, "digests must match");
        assert_eq!(dir_manifest.entry_source, zip_manifest.entry_source);
        assert!(
            zip_manifest
                .entry_source
                .as_deref()
                .unwrap_or("")
                .contains("procedural birds"),
            "the entry must be the real birds source"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn the_mods_directory_archives_and_reloads_identically() {
        // What `goatsd`'s status page hands out: the mods directory packaged as
        // a `.zip`. Extracting it must reproduce the same mods, digests and all,
        // or a joiner who downloaded it would still be refused at the join.
        let mods_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("..")
            .join("mods");
        let original = Loader::discover(&mods_dir);
        assert!(original.errors().is_empty(), "{:?}", original.errors());
        assert!(!original.mods().is_empty(), "the fixture tree has mods");

        let bytes = archive_dir(&mods_dir).expect("archive the mods directory");
        assert_eq!(&bytes[..2], b"PK", "a zip archive");

        // Extract it the way the page says to: into a mods directory.
        let root = workspace("archived");
        let mut archive =
            zip::ZipArchive::new(std::io::Cursor::new(bytes)).expect("read the archive");
        for index in 0..archive.len() {
            let mut entry = archive.by_index(index).unwrap();
            let name = entry.name().to_string();
            assert!(!name.contains(".."), "an entry must stay inside: {name}");
            let path = root.join(&name);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            let mut file = std::fs::File::create(&path).unwrap();
            std::io::copy(&mut entry, &mut file).unwrap();
        }

        let reloaded = Loader::discover(&root);
        assert!(reloaded.errors().is_empty(), "{:?}", reloaded.errors());
        let summarise = |loader: &Loader| -> Vec<(String, u64)> {
            loader
                .mods()
                .iter()
                .map(|manifest| (manifest.id.clone(), manifest.hash))
                .collect()
        };
        assert_eq!(
            summarise(&original),
            summarise(&reloaded),
            "the archive must reload as the same mods"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_mod_archives_from_either_source() {
        // M18's host hands a fetching joiner one mod in its distributable form.
        // A directory mod is packaged; a mod already in a `.zip` is served as it
        // is -- and both must reload as the same mod, or the joiner's digest
        // would not match the one it fetched against.
        let root = workspace("archive-source");
        let manifest = r#"{ "id": "com.example.one", "name": "One", "version": "1.2.3",
            "api": 1, "side": "world", "entry": "mod.js" }"#;
        write_mod(&root, "one", manifest);
        write(&root.join("one").join("mod.js"), "return 1;\n");
        let loader = Loader::discover(&root);
        let dir_manifest = loader.get("com.example.one").expect("the directory mod");

        // A directory mod is packaged with `mod.json` at the archive root.
        let bytes = archive_source(&dir_manifest.source).expect("archive a directory");
        assert_eq!(&bytes[..2], b"PK", "a zip archive");
        let zipped = workspace("archive-source-zip");
        std::fs::write(zipped.join("one.zip"), &bytes).unwrap();
        let reloaded = Loader::discover(&zipped);
        assert!(reloaded.errors().is_empty(), "{:?}", reloaded.errors());
        let zip_manifest = reloaded.get("com.example.one").expect("the zipped mod");
        assert_eq!(
            dir_manifest.hash, zip_manifest.hash,
            "the packaged mod must reload to the same digest"
        );

        // A mod already stored as a zip is served byte for byte.
        let served = archive_source(&zip_manifest.source).expect("serve a zip");
        assert_eq!(served, bytes);
        let _ = std::fs::remove_dir_all(&root);
        let _ = std::fs::remove_dir_all(&zipped);
    }

    #[test]
    fn the_birds_fixture_digest_is_pinned() {
        // A release ships this mod, and a client refuses a server whose `birds`
        // differs -- by design. So its digest is a compatibility surface, not an
        // implementation detail: editing the fixture, or the inputs
        // `hash_manifest` folds in, decides who can play with whom, and it
        // should be a deliberate act rather than a surprise on the next release.
        // If this fails and the change is intended, update the constant and say
        // so in the release notes.
        let mods_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("..")
            .join("mods");
        let loader = Loader::discover(&mods_dir);
        assert!(loader.errors().is_empty(), "{:?}", loader.errors());
        let birds = loader
            .mods()
            .iter()
            .find(|manifest| manifest.path().ends_with("birds"))
            .expect("the birds fixture");

        assert_eq!(
            birds.hash, 0xbf1f_98a7_4046_0a01,
            "the birds digest changed: {}@{}",
            birds.id, birds.version
        );
    }

    #[test]
    fn a_compiled_mod_loads_its_module() {
        // A mod with no JavaScript at all: the module is the whole mod, and the
        // host hands the scene bytes rather than a path.
        let root = workspace("wasm-mod");
        write_mod(
            &root,
            "w",
            r#"{ "id": "com.example.w", "name": "W", "version": "1", "api": 1,
                "wasm": { "module": "plugin.wasm" } }"#,
        );
        let dir = root.join("w");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("plugin.wasm"), b"\0asm\x01\0\0\0").unwrap();

        let loader = Loader::discover(&root);
        assert!(loader.errors().is_empty(), "{:?}", loader.errors());
        let manifest = loader.get("com.example.w").expect("the mod");
        let wasm = manifest.wasm.as_ref().expect("a wasm module");
        assert_eq!(wasm.module, "plugin.wasm");
        assert_eq!(wasm.bytes, b"\0asm\x01\0\0\0");
        assert!(manifest.entry.is_none(), "a compiled mod needs no entry");
        // The scene is told what kind of mod it is.
        assert_eq!(manifest.json()["wasm"], "plugin.wasm");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_compiled_world_mod_joins_the_digest() {
        // A `side: "world"` mod with a module is legal now, and the module is part
        // of its identity: two hosts that agree on the id and version but differ on
        // the module's bytes refuse each other in the join handshake, which is the
        // whole point of the digest.
        let root = workspace("wasm-world");
        write_mod(
            &root,
            "w",
            r#"{ "id": "com.example.w", "name": "W", "version": "1", "api": 1,
                "side": "world", "wasm": { "module": "plugin.wasm" } }"#,
        );
        let dir = root.join("w");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("plugin.wasm"), b"\0asm\x01\0\0\0").unwrap();

        let before = Loader::discover(&root);
        assert!(before.errors().is_empty(), "{:?}", before.errors());
        let hash = before.get("com.example.w").expect("the mod").hash;

        std::fs::write(dir.join("plugin.wasm"), b"\0asm\x01\0\0\0\x01").unwrap();
        let after = Loader::discover(&root);
        assert!(after.errors().is_empty(), "{:?}", after.errors());
        assert_ne!(
            hash,
            after.get("com.example.w").expect("the mod").hash,
            "the module's bytes are content"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn keep_wasm_keeps_a_module_but_hashes_assets() {
        // The server's mode: it needs the wasm bytes to run the world, but it
        // must not carry a mod's model. The digest must still agree with a full
        // `Keep` read, so the two ends recognise each other by the same hash.
        let root = workspace("keepwasm");
        write_mod(
            &root,
            "w",
            r#"{ "id": "com.example.w", "name": "W", "version": "1", "api": 1,
                "side": "world", "wasm": { "module": "plugin.wasm" },
                "assets": { "model.goat": "m.bin" } }"#,
        );
        let dir = root.join("w");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("plugin.wasm"), b"\0asm\x01\0\0\0").unwrap();
        std::fs::write(dir.join("m.bin"), "a model, hashed and dropped").unwrap();

        let keep = Loader::discover_with(&root, AssetMode::Keep);
        let keep_wasm = Loader::discover_with(&root, AssetMode::KeepWasm);
        assert!(keep_wasm.errors().is_empty(), "{:?}", keep_wasm.errors());

        let manifest = keep_wasm.get("com.example.w").expect("the mod");
        assert_eq!(
            manifest.hash,
            keep.get("com.example.w").unwrap().hash,
            "the digest must not depend on which bytes were kept"
        );
        assert_eq!(
            manifest.wasm.as_ref().unwrap().bytes,
            b"\0asm\x01\0\0\0",
            "the module is kept so the server can run it"
        );
        assert!(
            manifest.assets[0].bytes.is_empty(),
            "assets are hashed, not kept"
        );

        // The hash-only twin still drops the module too.
        let hash_only = Loader::discover_with(&root, AssetMode::HashOnly);
        assert!(
            hash_only
                .get("com.example.w")
                .unwrap()
                .wasm
                .as_ref()
                .unwrap()
                .bytes
                .is_empty(),
            "HashOnly drops the module"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn something_that_is_not_a_module_is_refused_by_name() {
        let root = workspace("wasm-bogus");
        write_mod(
            &root,
            "w",
            r#"{ "id": "com.example.w", "name": "W", "version": "1", "api": 1,
                "wasm": { "module": "plugin.wasm" } }"#,
        );
        let dir = root.join("w");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("plugin.wasm"), b"not a module").unwrap();

        let loader = Loader::discover(&root);
        assert!(loader.get("com.example.w").is_none(), "it must not load");
        let text = format!("{:?}", loader.errors());
        assert!(text.contains("magic"), "{text}");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn the_wasm_fixture_mod_loads() {
        // The shipped fixture, through the real loader: it is the mod the hosts
        // and the game itself instantiate, so an edit that breaks it should be a
        // red test rather than a surprise on the next run.
        let mods_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("..")
            .join("mods");
        let loader = Loader::discover(&mods_dir);
        assert!(loader.errors().is_empty(), "{:?}", loader.errors());
        let manifest = loader
            .get("com.github.sdgoij.goats.wasm")
            .expect("the wasm fixture mod");
        let wasm = manifest.wasm.as_ref().expect("its module");
        assert!(wasm.bytes.starts_with(b"\0asm"), "a real module");
        assert!(wasm.bytes.len() > 100, "and not an empty stub");
        assert!(manifest.entry.is_none(), "it ships no JavaScript");
    }

    #[test]
    fn a_zip_mod_is_discovered_and_read() {
        let root = workspace("zip");
        write_zip(
            &root,
            "pack.zip",
            &[
                (
                    "mod.json",
                    r#"{ "id": "com.zip.mod", "name": "Zip", "version": "1", "api": 1, "entry": "mod.js", "assets": { "sfx.rain": "audio/rain.ogg" } }"#,
                ),
                ("mod.js", "goats.log('zip');\n"),
                ("audio/rain.ogg", "not really ogg"),
            ],
        );
        let loader = Loader::discover(&root);
        assert!(loader.errors().is_empty(), "{:?}", loader.errors());
        let manifest = loader.get("com.zip.mod").expect("the zip mod");
        assert_eq!(
            manifest.entry_source.as_deref(),
            Some("goats.log('zip');\n")
        );
        assert_eq!(manifest.assets.len(), 1);
        assert_eq!(manifest.assets[0].name, "mod:com.zip.mod:sfx.rain.ogg");
        assert_eq!(manifest.assets[0].bytes, b"not really ogg");
        assert!(matches!(manifest.source, ModSource::Zip(_)));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_zip_wrapped_in_a_directory_is_read() {
        let root = workspace("zipwrap");
        write_zip(
            &root,
            "wrapped.zip",
            &[
                (
                    "pack/mod.json",
                    r#"{ "id": "com.zip.wrapped", "name": "Wrapped", "version": "1", "api": 1, "entry": "mod.js" }"#,
                ),
                ("pack/mod.js", "entry\n"),
            ],
        );
        let loader = Loader::discover(&root);
        assert!(loader.errors().is_empty(), "{:?}", loader.errors());
        let manifest = loader.get("com.zip.wrapped").expect("the wrapped zip mod");
        assert_eq!(manifest.entry_source.as_deref(), Some("entry\n"));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_zip_without_a_manifest_is_reported() {
        let root = workspace("zipbad");
        write_zip(&root, "empty.zip", &[("readme.txt", "no mod here")]);
        let loader = Loader::discover(&root);
        assert_eq!(loader.mods().len(), 0);
        assert_eq!(loader.errors().len(), 1);
        assert!(loader.errors()[0].message.contains("mod.json"));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn reload_re_reads_a_mod_from_disk() {
        let root = workspace("reload");
        write_mod(
            &root,
            "hot",
            r#"{ "id": "hot", "name": "Hot", "version": "1", "api": 1, "entry": "mod.js" }"#,
        );
        write(&root.join("hot").join("mod.js"), "1\n");
        let mut loader = Loader::discover(&root);
        assert_eq!(
            loader.get("hot").unwrap().entry_source.as_deref(),
            Some("1\n")
        );

        write(&root.join("hot").join("mod.js"), "2\n");
        loader.reload("hot", AssetMode::Keep).unwrap();
        assert_eq!(
            loader.get("hot").unwrap().entry_source.as_deref(),
            Some("2\n")
        );

        // An unknown id is refused rather than created.
        assert!(loader.reload("nope", AssetMode::Keep).is_err());

        // A rename is refused with a clear message: it needs a restart.
        write_mod(
            &root,
            "hot",
            r#"{ "id": "renamed", "name": "Hot", "version": "1", "api": 1, "entry": "mod.js" }"#,
        );
        let error = loader.reload("hot", AssetMode::Keep).unwrap_err();
        assert!(error.message.contains("restart"), "{}", error.message);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn changed_paths_map_to_their_mod() {
        let root = workspace("touch");
        write_mod(
            &root,
            "dir",
            r#"{ "id": "dir.mod", "name": "Dir", "version": "1", "api": 1 }"#,
        );
        write_zip(
            &root,
            "pack.zip",
            &[(
                "mod.json",
                r#"{ "id": "zip.mod", "name": "Zip", "version": "1", "api": 1 }"#,
            )],
        );
        let loader = Loader::discover(&root);
        assert!(loader.errors().is_empty(), "{:?}", loader.errors());
        assert_eq!(
            loader.mods_touching(&root.join("dir").join("mod.js")),
            vec!["dir.mod".to_string()]
        );
        assert_eq!(
            loader.mods_touching(&root.join("pack.zip")),
            vec!["zip.mod".to_string()]
        );
        assert!(loader.mods_touching(&root.join("unrelated.txt")).is_empty());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn the_watcher_reports_a_changed_file() {
        let root = workspace("watch");
        std::fs::create_dir_all(&root).unwrap();
        write(&root.join("mod.json"), "{}");
        let watcher = crate::watch::ModWatcher::new(&root).expect("a watcher");

        write(&root.join("mod.json"), r#"{ "id": "x" }"#);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        let mut seen = Vec::new();
        while std::time::Instant::now() < deadline {
            seen = watcher.take_changed();
            if seen.iter().any(|path| path.ends_with("mod.json")) {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        assert!(
            seen.iter().any(|path| path.ends_with("mod.json")),
            "no change reported: {seen:?}"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_watched_change_reloads_the_mod_it_belongs_to() {
        let root = workspace("watchreload");
        write_mod(
            &root,
            "hot",
            r#"{ "id": "hot", "name": "Hot", "version": "1", "api": 1, "entry": "mod.js" }"#,
        );
        write(&root.join("hot").join("mod.js"), "1\n");
        let mut loader = Loader::discover(&root);
        let watcher = crate::watch::ModWatcher::new(&root).expect("a watcher");

        write(&root.join("hot").join("mod.js"), "2\n");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        let mut ids = Vec::new();
        while std::time::Instant::now() < deadline && ids.is_empty() {
            for path in watcher.take_changed() {
                for id in loader.mods_touching(&path) {
                    if !ids.contains(&id) {
                        ids.push(id);
                    }
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        assert_eq!(ids, vec!["hot".to_string()], "a change must map to its mod");
        loader.reload(&ids[0], AssetMode::Keep).unwrap();
        assert_eq!(
            loader.get("hot").unwrap().entry_source.as_deref(),
            Some("2\n")
        );
        let _ = std::fs::remove_dir_all(&root);
    }
}
