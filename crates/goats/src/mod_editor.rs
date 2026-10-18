//! The browser's mod editor bridge.
//!
//! The shell page (`godot/web/index.html`) drives a mod editor for both clients.
//! The Godot client installs four callbacks on `window` from `mods.gd`; this is
//! the reference client's half, with the same JSON protocol over a C ABI that
//! the page's Emscripten module can call:
//!
//!   `goats_mods_state()`          the scene's mod table (the editor's list)
//!   `goats_mods_read(name)`       a mod's files as `{name, files: {path: base64}}`
//!   `goats_mods_write(request)`   write `{name, files}` under `mods/`, then reload
//!
//! The four `window` functions are installed by the page (`bootReference` in
//! `godot/web/index.html`), because they also persist an edited mod's text files
//! in `localStorage` -- the reference build has no `user://` and no IndexedDB
//! layer of its own. `goats_mods_write` is the same call for Save and Run: the
//! emscripten filesystem is in memory, so "write this buffer" is not a
//! distinction the client can act on beyond what the page keeps.
//!
//! The state export is a *cache*: the frame loop owns the scene's table and
//! publishes it (`publish_table`) at boot and after every change, because the
//! table is JavaScript's and this file cannot reach the scene without the frame's
//! `Context`. Everything file-shaped is done here, on the filesystem both the
//! loader and the page see.
//!
//! Loaded ids are tracked so a save can tell "reload this mod" from "a folder
//! discovery has never seen". A new mod goes in through the same path a pulled
//! one does, minus the compiled half a browser does not have (WASM.md D4).

use std::cell::RefCell;
use std::collections::{BTreeMap, HashSet};
use std::ffi::{CStr, CString, c_char};
use std::path::{Path, PathBuf};
use std::rc::Rc;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use mods::Loader;
use slag::{Context, JsValue};

use crate::PluginSet;

thread_local! {
    /// Where discovery reads mods from, so a write lands in the same tree.
    static ROOT: RefCell<Option<PathBuf>> = const { RefCell::new(None) };
    /// The scene's table, serialised by the frame loop.
    static TABLE: RefCell<String> = const { RefCell::new(String::new()) };
    /// Mod ids to reload/insert on the next frame, deduplicated.
    static PENDING: RefCell<Vec<String>> = const { RefCell::new(Vec::new()) };
    /// The last answer, kept alive for the pointer returned to JavaScript.
    static ANSWER: RefCell<Option<CString>> = const { RefCell::new(None) };
}

/// Where discovery found the mods. Called once, at `run`'s boot.
pub fn set_root(dir: Option<PathBuf>) {
    ROOT.with(|slot| *slot.borrow_mut() = dir);
}

/// Cache the scene's table (`sceneModTable`) for `goats_mods_state`.
pub fn publish_table(context: &mut Context, getter: Option<&JsValue>) {
    let Some(getter) = getter else {
        return;
    };
    match context.call(getter, &JsValue::undefined(), &[]) {
        Ok(value) => {
            if let Some(text) = value.as_string() {
                TABLE.with(|slot| *slot.borrow_mut() = text);
            }
        }
        Err(error) => eprintln!("[mods] sceneModTable: {error}"),
    }
}

/// Apply the writes the page made since the last frame. Returns whether anything
/// changed, so the frame knows to publish the table again.
pub fn service(
    context: &mut Context,
    loader: &mut Loader,
    plugins: &Rc<RefCell<PluginSet>>,
    mods_dir: Option<&Path>,
    loaded: &mut HashSet<String>,
) -> bool {
    let pending = PENDING.with(|slot| std::mem::take(&mut *slot.borrow_mut()));
    if pending.is_empty() {
        return false;
    }
    for id in pending {
        if loaded.contains(&id) {
            crate::reload_and_eval(context, loader, plugins, &id);
            continue;
        }
        let Some(dir) = mods_dir else {
            eprintln!("[mods] {id} was saved but there is no mods directory");
            continue;
        };
        // A folder discovery has never seen: re-walk, then add every mod the
        // scene does not have yet. That is the pulled-mod path without a plugin
        // host to feed (WASM.md D4).
        *loader = Loader::discover(dir);
        for error in loader.errors() {
            eprintln!("[mods] {error}");
        }
        for candidate in loader.ids() {
            if !loaded.insert(candidate.clone()) {
                continue;
            }
            crate::add_pulled_mod(context, loader, plugins, &candidate);
        }
    }
    true
}

/// `goats_mods_state`: the cached table, JSON.
#[unsafe(no_mangle)]
pub extern "C" fn goats_mods_state() -> *mut c_char {
    answer(TABLE.with(|slot| slot.borrow().clone()))
}

/// `goats_mods_read`: `{name, files: {relative path: base64}}`, or `error ...`.
#[unsafe(no_mangle)]
pub extern "C" fn goats_mods_read(name: *const c_char) -> *mut c_char {
    let Some(name) = text_arg(name) else {
        return answer("error no mod name".to_string());
    };
    match read(&name) {
        Ok(json) => answer(json),
        Err(error) => answer(format!("error {error}")),
    }
}

/// `goats_mods_write`: write `{name, files: {relative path: base64}}` under the
/// mods directory, then reload (or insert) that mod on the next frame.
#[unsafe(no_mangle)]
pub extern "C" fn goats_mods_write(request: *const c_char) -> *mut c_char {
    let Some(request) = text_arg(request) else {
        return answer("error no request".to_string());
    };
    match write(&request) {
        Ok(message) => answer(message),
        Err(error) => answer(format!("error {error}")),
    }
}

/// A string crossing from JavaScript. Emscripten's `ccall(..., 'string', ...)`
/// NUL-terminates it, so this is the whole request.
fn text_arg(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    // SAFETY: the caller (the page) owns a NUL-terminated string for this call,
    // which is the only contract a C ABI has; the read ends at that NUL.
    let text = unsafe { CStr::from_ptr(ptr) };
    Some(text.to_string_lossy().into_owned())
}

/// Keep the answer alive and hand JavaScript its pointer. The next export call
/// replaces it, which is fine: the page reads each answer synchronously.
fn answer(text: String) -> *mut c_char {
    let string = CString::new(text).unwrap_or_default();
    ANSWER.with(|slot| {
        *slot.borrow_mut() = Some(string);
        slot.borrow()
            .as_ref()
            .map_or(std::ptr::null_mut(), |text| text.as_ptr() as *mut c_char)
    })
}

fn read(name: &str) -> Result<String, String> {
    let root = root()?;
    let folder = locate(&root, name).ok_or_else(|| format!("no mod named '{name}'"))?;
    let mut files: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    collect(&folder, &folder, &mut files)?;
    let encoded: BTreeMap<String, String> = files
        .into_iter()
        .map(|(path, bytes)| (path, STANDARD.encode(bytes)))
        .collect();
    serde_json::to_string(&serde_json::json!({ "name": name, "files": encoded }))
        .map_err(|error| error.to_string())
}

fn write(request: &str) -> Result<String, String> {
    let root = root()?;
    let value: serde_json::Value = serde_json::from_str(request)
        .map_err(|error| format!("the request is not JSON: {error}"))?;
    let name = value
        .get("name")
        .and_then(serde_json::Value::as_str)
        .ok_or("the request needs a name")?;
    if !segment_ok(name) {
        return Err(format!("'{name}' is not a mod folder name"));
    }
    let files = value
        .get("files")
        .and_then(serde_json::Value::as_object)
        .ok_or("the request needs a files object")?;
    let folder = root.join(name);
    for (relative, encoded) in files {
        if !relative_ok(relative) {
            return Err(format!("'{relative}' is not a relative file name"));
        }
        let text = encoded
            .as_str()
            .ok_or_else(|| format!("'{relative}' is not base64 text"))?;
        let bytes = STANDARD
            .decode(text)
            .map_err(|error| format!("'{relative}': {error}"))?;
        let path = folder.join(relative);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|error| format!("cannot create '{}': {error}", parent.display()))?;
        }
        std::fs::write(&path, bytes)
            .map_err(|error| format!("cannot write '{}': {error}", path.display()))?;
    }
    // The folder's manifest decides which id is reloaded. The editor writes a
    // whole mod, so `mod.json` is always part of the request.
    let id = files
        .get("mod.json")
        .and_then(|encoded| encoded.as_str())
        .and_then(|text| STANDARD.decode(text).ok())
        .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
        .and_then(|manifest| {
            manifest
                .get("id")
                .and_then(serde_json::Value::as_str)
                .map(str::to_string)
        })
        .ok_or("the request has no readable mod.json id")?;
    // The reload happens on the next frame, where the scene's `Context` is; the
    // answer is the write's, and the editor's list polls itself current.
    PENDING.with(|slot| {
        let mut pending = slot.borrow_mut();
        if !pending.contains(&id) {
            pending.push(id);
        }
    });
    Ok(format!("ok saved {name}"))
}

fn root() -> Result<PathBuf, String> {
    ROOT.with(|slot| slot.borrow().clone())
        .ok_or_else(|| "this client has no mods directory".to_string())
}

/// The folder a name refers to: the name itself, or a bundled folder whose
/// manifest name or id tail matches what the editor picked. The editor's two
/// candidates are the display name's slug and the id's last segment, and a
/// folder like `example` is a prefix of `Example Mod`'s slug.
fn locate(root: &Path, name: &str) -> Option<PathBuf> {
    let direct = root.join(name);
    if direct.is_dir() {
        return Some(direct);
    }
    let wanted = slug(name);
    for entry in std::fs::read_dir(root).ok()? {
        let path = entry.ok()?.path();
        if !path.is_dir() {
            continue;
        }
        let folder = path
            .file_name()
            .map(|name| name.to_string_lossy().to_string())
            .unwrap_or_default();
        let folder_slug = slug(&folder);
        let manifest = std::fs::read(path.join("mod.json"))
            .ok()
            .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok());
        let display = manifest
            .as_ref()
            .and_then(|json| json.get("name"))
            .and_then(serde_json::Value::as_str)
            .unwrap_or("");
        let id = manifest
            .as_ref()
            .and_then(|json| json.get("id"))
            .and_then(serde_json::Value::as_str)
            .unwrap_or("");
        let tail = id.rsplit('.').next().unwrap_or("");
        if slug(display) == wanted
            || slug(tail) == wanted
            || wanted.starts_with(&folder_slug)
            || folder_slug.starts_with(&wanted)
            || slug(&folder) == wanted
        {
            return Some(path);
        }
    }
    None
}

/// Every file under `at`, relative to `folder`, with `/` separators.
fn collect(folder: &Path, at: &Path, out: &mut BTreeMap<String, Vec<u8>>) -> Result<(), String> {
    for entry in std::fs::read_dir(at).map_err(|error| error.to_string())? {
        let path = entry.map_err(|error| error.to_string())?.path();
        if path.is_dir() {
            collect(folder, &path, out)?;
            continue;
        }
        let relative = path
            .strip_prefix(folder)
            .map_err(|error| error.to_string())?
            .to_string_lossy()
            .replace('\\', "/");
        let bytes = std::fs::read(&path).map_err(|error| error.to_string())?;
        out.insert(relative, bytes);
    }
    Ok(())
}

/// One path segment: not empty, not `.`/`..`, and no separators.
fn segment_ok(name: &str) -> bool {
    !name.is_empty() && name != "." && name != ".." && !name.contains('/') && !name.contains('\\')
}

fn relative_ok(path: &str) -> bool {
    !path.is_empty()
        && !path.starts_with('/')
        && !path.starts_with('\\')
        && !path.contains(':')
        && path
            .split(['/', '\\'])
            .all(|part| !part.is_empty() && part != "." && part != "..")
}

/// `modSlug` in the shell: lowercase, then only `[a-z0-9]`.
fn slug(text: &str) -> String {
    text.chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .map(|c| c.to_ascii_lowercase())
        .collect()
}
