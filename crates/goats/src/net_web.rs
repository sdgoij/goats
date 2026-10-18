//! The browser's networking seam: the scene's JSON lines to and from a page.
//!
//! A tab still has no socket in Rust, so the page owns the WebSocket and this
//! module is the buffer between them. The frame loop drains the scene's
//! `sceneNetDrain()` into [`OUTBOX`], which `goats_net_drain` hands to the page;
//! the page pushes each line it receives from the gateway back through
//! `goats_net_push`, and the next frame delivers it to `sceneNetEvent`.
//!
//! The gateway (`goatsd --gateway`) speaks the same `session::bridge` lines, so
//! nothing on this side knows what a ticket, a pose datagram or a world part is.
//! The native client's `net.rs` is the other arm of the same seam; this module
//! is compiled only for wasm.

use std::cell::RefCell;
use std::collections::VecDeque;
use std::ffi::{CStr, CString, c_char};

use slag::{Context, JsValue};

/// Lines waiting for the page's socket, and lines the socket has delivered.
/// Both are bounded: a page that stops draining must not grow the heap without
/// limit, and the scene has nothing useful to do with an unbounded backlog.
const MAX_LINES: usize = 256;

thread_local! {
    static OUTBOX: RefCell<VecDeque<String>> = const { RefCell::new(VecDeque::new()) };
    static INBOX: RefCell<VecDeque<String>> = const { RefCell::new(VecDeque::new()) };
    static ANSWER: RefCell<Option<CString>> = const { RefCell::new(None) };
}

/// Deliver every line the page has pushed since the last frame. Called before
/// the scene steps, as the native bridge's event drain is.
pub fn deliver(context: &mut Context, handler: Option<&JsValue>) {
    let Some(handler) = handler else {
        return;
    };
    loop {
        let line = INBOX.with(|slot| slot.borrow_mut().pop_front());
        let Some(line) = line else {
            return;
        };
        if let Err(error) = context.call(handler, &JsValue::undefined(), &[JsValue::string(line)]) {
            eprintln!("[net] sceneNetEvent: {error}");
        }
    }
}

/// Ask the scene what it wants to send and queue it for the page's socket.
/// Called at the end of the step, where the native bridge drains the same
/// function into its networking thread.
pub fn collect(context: &mut Context, drain: Option<&JsValue>) {
    let Some(drain) = drain else {
        return;
    };
    let text = match context.call(drain, &JsValue::undefined(), &[]) {
        Ok(value) => value.as_string(),
        Err(error) => {
            eprintln!("[net] sceneNetDrain: {error}");
            None
        }
    };
    let Some(text) = text else {
        return;
    };
    OUTBOX.with(|slot| {
        let mut out = slot.borrow_mut();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            out.push_back(line.to_string());
            while out.len() > MAX_LINES {
                out.pop_front();
            }
        }
    });
}

/// `goats_net_drain`: the lines the page's socket should send, newline-joined.
/// An empty string means there is nothing to send.
#[unsafe(no_mangle)]
pub extern "C" fn goats_net_drain() -> *mut c_char {
    let text = OUTBOX.with(|slot| {
        let mut out = slot.borrow_mut();
        let text = out.drain(..).collect::<Vec<_>>().join("\n");
        text
    });
    answer(text)
}

/// `goats_net_push`: one line the page received from the gateway. The next
/// frame hands it to `sceneNetEvent`.
#[unsafe(no_mangle)]
pub extern "C" fn goats_net_push(line: *const c_char) {
    if line.is_null() {
        return;
    }
    // SAFETY: the page owns a NUL-terminated string for this call, which is the
    // whole contract of the C ABI; the read ends at that NUL.
    let text = unsafe { CStr::from_ptr(line) };
    let Ok(text) = text.to_str() else {
        return;
    };
    let text = text.trim();
    if text.is_empty() {
        return;
    }
    INBOX.with(|slot| {
        let mut inbox = slot.borrow_mut();
        inbox.push_back(text.to_string());
        while inbox.len() > MAX_LINES {
            inbox.pop_front();
        }
    });
}

/// Keep the answer alive for the pointer handed to JavaScript. The page reads it
/// synchronously, before the next call can replace it.
fn answer(text: String) -> *mut c_char {
    let string = CString::new(text).unwrap_or_default();
    ANSWER.with(|slot| {
        *slot.borrow_mut() = Some(string);
        slot.borrow()
            .as_ref()
            .map_or(std::ptr::null_mut(), |text| text.as_ptr() as *mut c_char)
    })
}
