//! The Rust-side plugin host (M17b): instantiate and drive a compiled mod's
//! `.wasm` module from Rust through the engine's `Store`, with no JavaScript in
//! front of the plugin.
//!
//! This is the same ABI the JS driver in `mods.js` implements (`sceneWasmModule`
//! / `modWasmTick`, M17a) — the same import list (`goats.log`, `goats.rng`,
//! `goats.publish`), the same exports, the same record layout — driven from the
//! host side, owning the module's memory directly. What it buys over the JS
//! shape is the memory: `log` and `publish` read the module's own bytes with no
//! decode step, and a frame path with nothing interpreted in front of the
//! module.

use slag::wasm::exec::{ExternVal, RunProgress, Store};
use slag::wasm::types::{FuncType, ValType};
use slag::wasm::values::Value;
use slag::wasm::{decode, validate};

/// The ABI a module negotiates (`goats_abi`), the record count, the record size
/// and the number of RNG streams — the same constants the JS driver uses, so
/// the two hosts agree on every byte.
const MOD_WASM_ABI: i32 = 1;
const MOD_WASM_RECORDS: i32 = 6;
const MOD_WASM_RECORD_BYTES: i32 = 16;
const MOD_WASM_STREAMS: usize = 8;
const MOD_WASM_PUBLISH_MAX: usize = 1024;

/// The host capabilities a compiled mod may import, keyed by the token each
/// `external_host` is registered under.
const TOKEN_LOG: u64 = 0;
const TOKEN_RNG: u64 = 1;
const TOKEN_PUBLISH: u64 = 2;

/// Which side of the world a mod runs on — the same distinction the manifest's
/// `side` carries. A world mod re-derives its streams from the session seed and
/// only ticks where the world is authoritative (the caller's job, not this
/// host's).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Side {
    Client,
    World,
}

/// One running compiled mod: a `Store` owning an instantiated module, its memory
/// and its live state.
pub struct Plugin {
    id: String,
    store: Store,
    instance: usize,
    memory: usize,
    record_ptr: i32,
    side: Side,
    abi: i32,
    frames: u64,
    error: Option<String>,
    last_log: String,
    published: Option<Vec<u8>>,
    rng_seed: [u32; MOD_WASM_STREAMS],
    rng: [u32; MOD_WASM_STREAMS],
    fn_abi: usize,
    fn_alloc: usize,
    fn_init: usize,
    fn_update: usize,
    fn_apply: Option<usize>,
}

/// FNV-1a over a string, as a `u32` — the same hash the JS driver uses to
/// derive a mod's per-stream base seed.
fn hash_key(key: &str) -> u32 {
    let mut hash: u32 = 2166136261;
    for byte in key.bytes() {
        hash ^= u32::from(byte);
        hash = hash.wrapping_mul(16777619);
    }
    hash
}

/// The host-owned xorshift both the `rng` capability and the session seeding
/// share (shifts 13/17/5), kept in one place so the two cannot drift.
fn xorshift(state: &mut u32) -> u32 {
    let mut s = *state;
    s ^= s.wrapping_shl(13);
    s ^= s >> 17;
    s ^= s.wrapping_shl(5);
    *state = s;
    s
}

fn log_type() -> FuncType {
    FuncType {
        params: vec![ValType::I32, ValType::I32],
        results: vec![],
    }
}

fn rng_type() -> FuncType {
    FuncType {
        params: vec![ValType::I32],
        results: vec![ValType::F64],
    }
}

fn publish_type() -> FuncType {
    FuncType {
        params: vec![ValType::I32, ValType::I32],
        results: vec![ValType::I32],
    }
}

fn i32_of(args: &[Value], index: usize) -> i32 {
    match args.get(index) {
        Some(Value::I32(value)) => *value,
        _ => 0,
    }
}

impl Plugin {
    /// Decode, instantiate and initialise a module. The import list is the API:
    /// the `resolve` closure grants exactly `goats.log`, `goats.rng` and
    /// `goats.publish`, and a module that asks for anything else fails to link
    /// here rather than being policed.
    pub fn new(id: &str, bytes: &[u8], side: Side) -> Result<Plugin, String> {
        let module = decode(bytes).map_err(|error| format!("decode: {error}"))?;
        validate(&module).map_err(|error| format!("validate: {error}"))?;

        let mut store = Store::new();
        let log_id = store.external_host(log_type(), TOKEN_LOG);
        let rng_id = store.external_host(rng_type(), TOKEN_RNG);
        let publish_id = store.external_host(publish_type(), TOKEN_PUBLISH);

        let mut resolve = |module_name: &str, field: &str| -> Option<ExternVal> {
            if module_name != "goats" {
                return None;
            }
            let id = match field {
                "log" => log_id,
                "rng" => rng_id,
                "publish" => publish_id,
                _ => return None,
            };
            Some(ExternVal::HostFunc(id))
        };
        let instance = store
            .instantiate(&module, &mut resolve)
            .map_err(|error| error.to_string())?;

        let memory = match store.export(instance, "memory") {
            Some(ExternVal::Memory(cell)) => cell,
            _ => return Err("the module must export its memory".to_string()),
        };
        let fn_abi = store
            .exported_func(instance, "goats_abi")
            .ok_or("missing export goats_abi")?;
        let fn_alloc = store
            .exported_func(instance, "goats_alloc")
            .ok_or("missing export goats_alloc")?;
        let fn_init = store
            .exported_func(instance, "goats_init")
            .ok_or("missing export goats_init")?;
        let fn_update = store
            .exported_func(instance, "goats_update")
            .ok_or("missing export goats_update")?;
        let fn_apply = store.exported_func(instance, "goats_apply");

        // The per-mod, per-stream base seed, the same as the JS driver's
        // `sceneWasmModule` computes.
        let base = hash_key(&format!("wasm:{id}"));
        let base = if base == 0 { 1 } else { base };
        let mut rng_seed = [0u32; MOD_WASM_STREAMS];
        for (i, slot) in rng_seed.iter_mut().enumerate() {
            let value = base ^ (i as u32).wrapping_mul(0x9e3779b9);
            *slot = if value == 0 { 1 } else { value };
        }

        let mut plugin = Plugin {
            id: id.to_string(),
            store,
            instance,
            memory,
            record_ptr: 0,
            side,
            abi: 0,
            frames: 0,
            error: None,
            last_log: String::new(),
            published: None,
            rng_seed,
            rng: rng_seed,
            fn_abi,
            fn_alloc,
            fn_init,
            fn_update,
            fn_apply,
        };

        // Negotiate the ABI, then allocate and seed the record buffer exactly as
        // the JS driver does.
        let abi = plugin.call_i32(plugin.fn_abi, &[])?;
        if abi != MOD_WASM_ABI {
            return Err(format!(
                "compiled for ABI {abi}, this build is ABI {MOD_WASM_ABI}"
            ));
        }
        plugin.abi = abi;

        let ptr = plugin.call_i32(
            plugin.fn_alloc,
            &[Value::I32(MOD_WASM_RECORDS * MOD_WASM_RECORD_BYTES)],
        )?;
        plugin.record_ptr = ptr;
        for i in 0..MOD_WASM_RECORDS {
            let offset = ptr as usize + i as usize * MOD_WASM_RECORD_BYTES as usize;
            plugin.write_f32(offset, i as f32 * 0.6 - 1.5);
            plugin.write_f32(offset + 4, 0.0);
            plugin.write_f32(offset + 8, 0.0);
            plugin.write_f32(offset + 12, 0.0);
        }

        // `goats_init` logs the module's ready line through `goats.log`.
        plugin.call(plugin.fn_init, &[Value::I32(0)])?;

        Ok(plugin)
    }

    /// Re-derive the RNG streams from the session seed, for a `side: "world"`
    /// mod. A client mod keeps its base streams. The caller runs this once, on
    /// the same seed every peer of a session shares.
    pub fn seed(&mut self, seed: i32) {
        if self.side != Side::World {
            return;
        }
        let mut state: u32 = seed as u32;
        if state == 0 {
            state = 1;
        }
        for i in 0..MOD_WASM_STREAMS {
            let next = xorshift(&mut state);
            let next = if next == 0 { 1 } else { next };
            let value = self.rng_seed[i] ^ next;
            self.rng[i] = if value == 0 { 1 } else { value };
        }
    }

    /// One frame: call `goats_update(record_ptr, count, dt)`.
    pub fn tick(&mut self, dt: f32) -> Result<(), String> {
        if let Some(error) = &self.error {
            return Err(error.clone());
        }
        let args = [
            Value::I32(self.record_ptr),
            Value::I32(MOD_WASM_RECORDS),
            Value::F32(dt.to_bits()),
        ];
        match self.call(self.fn_update, &args) {
            Ok(_) => {
                self.frames += 1;
                Ok(())
            }
            Err(error) => {
                self.error = Some(error.clone());
                Err(error)
            }
        }
    }

    /// Deliver a peer's published state: write it into the module's record
    /// buffer and call `goats_apply`, so a mirroring module adopts it without
    /// running `goats_update`.
    pub fn apply(&mut self, bytes: &[u8]) -> Result<(), String> {
        let Some(fn_apply) = self.fn_apply else {
            return Ok(());
        };
        let count = bytes
            .len()
            .min(MOD_WASM_RECORDS as usize * MOD_WASM_RECORD_BYTES as usize);
        if let Some(block) = self.store.memory_block(self.memory) {
            let _ = block.write(self.record_ptr as usize, &bytes[..count]);
        }
        self.call(
            fn_apply,
            &[Value::I32(self.record_ptr), Value::I32(count as i32)],
        )?;
        Ok(())
    }

    /// The records the module is working on, read back out of its memory.
    pub fn records(&self) -> Vec<[f32; 4]> {
        let mut out = Vec::with_capacity(MOD_WASM_RECORDS as usize);
        for i in 0..MOD_WASM_RECORDS {
            let offset = self.record_ptr as usize + i as usize * MOD_WASM_RECORD_BYTES as usize;
            out.push([
                self.read_f32(offset),
                self.read_f32(offset + 4),
                self.read_f32(offset + 8),
                self.read_f32(offset + 12),
            ]);
        }
        out
    }

    pub fn abi(&self) -> i32 {
        self.abi
    }

    pub fn frames(&self) -> u64 {
        self.frames
    }

    pub fn side(&self) -> Side {
        self.side
    }

    pub fn log(&self) -> &str {
        &self.last_log
    }

    pub fn published(&self) -> Option<&[u8]> {
        self.published.as_deref()
    }

    /// A resumable call: run `func` to completion, servicing any external host
    /// call it makes (`goats.rng`, `goats.log`, `goats.publish`) with the store
    /// unborrowed in between.
    fn call(&mut self, func: usize, args: &[Value]) -> Result<Vec<Value>, String> {
        let mut progress = self
            .store
            .start(self.instance, func, args)
            .map_err(|error| format!("{error:?}"))?;
        loop {
            match progress {
                RunProgress::Finished(results) => return Ok(results),
                RunProgress::Host(request) => {
                    let reply = self.handle_host(request.token, request.args);
                    progress = self
                        .store
                        .resume(Ok(reply))
                        .map_err(|error| format!("{error:?}"))?;
                }
            }
        }
    }

    fn call_i32(&mut self, func: usize, args: &[Value]) -> Result<i32, String> {
        let results = self.call(func, args)?;
        match results.first() {
            Some(Value::I32(value)) => Ok(*value),
            other => Err(format!("expected an i32 result, got {other:?}")),
        }
    }

    /// Run one host capability, reading the module's memory for the two that
    /// carry a pointer.
    fn handle_host(&mut self, token: u64, args: Vec<Value>) -> Vec<Value> {
        match token {
            TOKEN_LOG => {
                let ptr = i32_of(&args, 0);
                let len = i32_of(&args, 1);
                let text = self.read_string(ptr, len);
                self.last_log = text.clone();
                eprintln!("[plugin] {}: {text}", self.id);
                vec![]
            }
            TOKEN_RNG => {
                let stream = i32_of(&args, 0);
                let draw = self.rng_draw(stream);
                vec![Value::F64(draw.to_bits())]
            }
            TOKEN_PUBLISH => {
                let ptr = i32_of(&args, 0);
                let len = i32_of(&args, 1);
                self.published = Some(self.read_bytes(ptr, len, MOD_WASM_PUBLISH_MAX));
                vec![Value::I32(0)]
            }
            _ => vec![],
        }
    }

    fn rng_draw(&mut self, stream: i32) -> f64 {
        let at = (stream % MOD_WASM_STREAMS as i32 + MOD_WASM_STREAMS as i32) as usize
            % MOD_WASM_STREAMS;
        let value = xorshift(&mut self.rng[at]);
        f64::from(value) / 4294967296.0
    }

    fn read_string(&self, ptr: i32, len: i32) -> String {
        let Some(bytes) = self.store.memory_bytes(self.memory) else {
            return String::new();
        };
        let at = ptr.max(0) as usize;
        let count = (len.max(0) as usize).min(200);
        let mut out = String::new();
        for i in 0..count {
            if at + i >= bytes.len() {
                break;
            }
            out.push(bytes[at + i] as char);
        }
        out
    }

    fn read_bytes(&self, ptr: i32, len: i32, max: usize) -> Vec<u8> {
        let Some(bytes) = self.store.memory_bytes(self.memory) else {
            return Vec::new();
        };
        let at = ptr.max(0) as usize;
        let count = (len.max(0) as usize).min(max);
        let mut out = Vec::with_capacity(count);
        for i in 0..count {
            if at + i >= bytes.len() {
                break;
            }
            out.push(bytes[at + i]);
        }
        out
    }

    fn read_f32(&self, offset: usize) -> f32 {
        let Some(bytes) = self.store.memory_bytes(self.memory) else {
            return 0.0;
        };
        if offset + 4 > bytes.len() {
            return 0.0;
        }
        f32::from_le_bytes([
            bytes[offset],
            bytes[offset + 1],
            bytes[offset + 2],
            bytes[offset + 3],
        ])
    }

    fn write_f32(&self, offset: usize, value: f32) {
        if let Some(block) = self.store.memory_block(self.memory) {
            let _ = block.write(offset, &value.to_le_bytes());
        }
    }
}

/// Standard base64 with padding — the same alphabet and padding the JS driver's
/// `modWasmB64Encode` uses, so a published payload round-trips through the mods
/// datagram unchanged.
pub fn base64_encode(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity((bytes.len() + 2) / 3 * 4);
    for chunk in bytes.chunks(3) {
        let b0 = chunk[0];
        let b1 = *chunk.get(1).unwrap_or(&0);
        let b2 = *chunk.get(2).unwrap_or(&0);
        out.push(ALPHABET[(b0 >> 2) as usize] as char);
        out.push(ALPHABET[(((b0 & 0x3) << 4) | (b1 >> 4)) as usize] as char);
        out.push(if chunk.len() > 1 {
            ALPHABET[(((b1 & 0xf) << 2) | (b2 >> 6)) as usize] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            ALPHABET[(b2 & 0x3f) as usize] as char
        } else {
            '='
        });
    }
    out
}

/// The inverse of [`base64_encode`], for the apply bridge. Returns `None` on a
/// character outside the alphabet.
pub fn base64_decode(text: &str) -> Option<Vec<u8>> {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = Vec::with_capacity(text.len() * 3 / 4);
    let mut acc: u32 = 0;
    let mut bits = 0u32;
    for byte in text.bytes() {
        if byte == b'=' || byte.is_ascii_whitespace() {
            continue;
        }
        let value = ALPHABET.iter().position(|b| *b == byte)? as u32;
        acc = (acc << 6) | value;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
        }
    }
    Some(out)
}

/// A set of running compiled mods, keyed by id, ticked together and readable for
/// the world-mod datagram bridge.
#[derive(Default)]
pub struct PluginSet {
    plugins: std::collections::BTreeMap<String, Plugin>,
}

impl PluginSet {
    pub fn new() -> PluginSet {
        PluginSet {
            plugins: std::collections::BTreeMap::new(),
        }
    }

    pub fn add(&mut self, id: &str, bytes: &[u8], side: Side) -> Result<(), String> {
        self.plugins
            .insert(id.to_string(), Plugin::new(id, bytes, side)?);
        Ok(())
    }

    pub fn remove(&mut self, id: &str) {
        self.plugins.remove(id);
    }

    pub fn is_empty(&self) -> bool {
        self.plugins.is_empty()
    }

    /// Re-derive the streams of every world plugin from the session seed.
    pub fn seed_all(&mut self, seed: i32) {
        for plugin in self.plugins.values_mut() {
            plugin.seed(seed);
        }
    }

    /// One frame for every plugin. `tick_world` gates world plugins: a mirroring
    /// client passes `false`, the server and a solo host pass `true`.
    pub fn tick_all(&mut self, dt: f32, tick_world: bool) {
        for plugin in self.plugins.values_mut() {
            if plugin.side() == Side::World && !tick_world {
                continue;
            }
            let _ = plugin.tick(dt);
        }
    }

    pub fn apply(&mut self, id: &str, bytes: &[u8]) -> Result<(), String> {
        match self.plugins.get_mut(id) {
            Some(plugin) => plugin.apply(bytes),
            None => Err(format!("unknown plugin '{id}'")),
        }
    }

    /// The published state of every world plugin, as `{ id: base64 }` — the
    /// shape `sceneWorldMods().data` carries.
    pub fn published_json(&self) -> String {
        let mut map = serde_json::Map::new();
        for (id, plugin) in &self.plugins {
            if plugin.side() != Side::World {
                continue;
            }
            if let Some(bytes) = plugin.published() {
                map.insert(id.clone(), serde_json::Value::String(base64_encode(bytes)));
            }
        }
        serde_json::Value::Object(map).to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MODULE: &[u8] = include_bytes!("../../../mods/wasm/plugin.wasm");

    #[test]
    fn the_rust_host_drives_the_compiled_mod() {
        let mut plugin =
            Plugin::new("com.github.sdgoij.goats.wasm", MODULE, Side::Client).expect("instantiate");
        assert_eq!(plugin.abi(), 1);
        assert_eq!(plugin.log(), "wasm mod: ready");

        let before = plugin.records();
        for _ in 0..60 {
            plugin.tick(1.0 / 60.0).expect("tick");
        }
        assert_eq!(plugin.frames(), 60);

        let after = plugin.records();
        assert!(
            after.iter().any(|row| row[0] != before[0][0]),
            "the records should have moved: {after:?}"
        );
        assert!(
            plugin.published().is_some(),
            "the module pushes its state through publish"
        );
    }

    #[test]
    fn the_same_module_replays_the_same_records() {
        let mut first = Plugin::new("com.github.sdgoij.goats.wasm", MODULE, Side::Client).unwrap();
        let mut second = Plugin::new("com.github.sdgoij.goats.wasm", MODULE, Side::Client).unwrap();
        for _ in 0..90 {
            first.tick(1.0 / 60.0).unwrap();
            second.tick(1.0 / 60.0).unwrap();
        }
        assert_eq!(first.records(), second.records());
        assert!(first.records().iter().any(|row| row[0] != 0.0));
    }

    #[test]
    fn a_world_module_seeds_and_replays() {
        let mut first = Plugin::new("com.example.worldwasm", MODULE, Side::World).unwrap();
        let mut same = Plugin::new("com.example.worldwasm", MODULE, Side::World).unwrap();
        first.seed(1001);
        same.seed(1001);
        for _ in 0..80 {
            first.tick(1.0 / 60.0).unwrap();
            same.tick(1.0 / 60.0).unwrap();
        }
        assert_eq!(first.records(), same.records());

        let mut other = Plugin::new("com.example.worldwasm", MODULE, Side::World).unwrap();
        other.seed(1002);
        for _ in 0..80 {
            other.tick(1.0 / 60.0).unwrap();
        }
        assert_ne!(first.records(), other.records());
    }

    #[test]
    fn a_mirroring_module_applies_peer_state() {
        let mut host = Plugin::new("com.example.worldwasm", MODULE, Side::World).unwrap();
        host.seed(1001);
        for _ in 0..80 {
            host.tick(1.0 / 60.0).unwrap();
        }
        let host_records = host.records();
        let published = host.published().expect("published").to_vec();

        let mut client = Plugin::new("com.example.worldwasm", MODULE, Side::World).unwrap();
        client.seed(1001);
        let before = client.records();
        client.apply(&published).expect("apply");
        assert_eq!(client.records(), host_records);
        assert_ne!(before, client.records());
    }
}
