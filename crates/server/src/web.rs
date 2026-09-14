//! The optional status page a host can serve.
//!
//! `goatsd --listen host:port` starts one small HTTP server reporting what a
//! visitor needs in order to join: the ticket, how many players are connected,
//! the wire protocol in use, the mods the host is running, and where to get the
//! client and those mods. It is deliberately tiny -- one thread, one connection
//! at a time, `Connection: close`, no keep-alive -- because it is a convenience,
//! not a web service, and it only exists when `--listen` asks for it. Nothing
//! here is on the session's hot path.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

/// One mod the host is running, as the page lists it and `/info` reports it.
pub struct Mod {
    pub id: String,
    pub version: String,
    /// `"world"` or `"client"` (`mods::Side`), carried as text so this module
    /// stays free of the loader's types.
    pub side: &'static str,
}

/// What the page reports. Everything but the client count is fixed when the host
/// starts; the mods archive is built once at boot and served from memory.
pub struct Info {
    ticket: String,
    download: String,
    protocol: u16,
    mods: Vec<Mod>,
    mods_zip: Option<Vec<u8>>,
    clients: AtomicUsize,
}

impl Info {
    pub fn new(
        ticket: String,
        download: String,
        protocol: u16,
        mods: Vec<Mod>,
        mods_zip: Option<Vec<u8>>,
    ) -> Info {
        Info {
            ticket,
            download,
            protocol,
            mods,
            mods_zip,
            clients: AtomicUsize::new(0),
        }
    }

    /// Records how many clients are in, not counting the host.
    pub fn set_clients(&self, clients: usize) {
        self.clients.store(clients, Ordering::Relaxed);
    }

    /// The host's mods packaged as a `.zip`, or `None` when it runs none.
    pub fn mods_zip(&self) -> Option<&[u8]> {
        self.mods_zip.as_deref()
    }

    /// The mod list as HTML: each mod, with its version and the side it runs on.
    fn mods_html(&self) -> String {
        if self.mods.is_empty() {
            return "<p>Mods: <strong>none</strong></p>\n".to_string();
        }
        let mut items = String::new();
        for module in &self.mods {
            items.push_str(&format!(
                "<li><code>{}</code> <small>{}</small></li>\n",
                escape(&format!("{}@{}", module.id, module.version)),
                escape(module.side),
            ));
        }
        format!(
            "<p>Mods this host is running:</p>\n\
             <ul>\n{items}</ul>\n\
             <p><a href=\"/mods.zip\">Download all of this server's mods</a> \
             (extract into your <code>mods</code> directory)</p>\n"
        )
    }

    /// The page a visitor gets: the ticket to paste, the protocol in use, the
    /// mods, and where to get the client.
    pub fn page(&self) -> String {
        format!(
            "<!doctype html>\n\
             <html lang=\"en\">\n\
             <head>\n\
             <meta charset=\"utf-8\">\n\
             <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n\
             <title>Slag Goat session</title>\n\
             <style>\n\
             body {{ font: 16px/1.5 system-ui, sans-serif; margin: 3rem auto; max-width: 40rem; padding: 0 1rem; }}\n\
             pre {{ background: #f4f4f5; padding: .75rem; overflow-x: auto; }}\n\
             strong {{ font-size: 1.4em; }}\n\
             code {{ background: #f4f4f5; padding: 0 .2em; }}\n\
             small {{ color: #71717a; }}\n\
             </style>\n\
             </head>\n\
             <body>\n\
             <h1>Slag Goat session</h1>\n\
             <p>Players connected: <strong>{clients}</strong></p>\n\
             <p>Protocol version: <strong>{protocol}</strong></p>\n\
             <p>Paste this into the client's console as \
             <code>connect &lt;ticket&gt; &lt;name&gt;</code>:</p>\n\
             <pre>{ticket}</pre>\n\
             {mods}\
             <p><a href=\"{download}\">Download the client</a></p>\n\
             </body>\n\
             </html>\n",
            clients = self.clients.load(Ordering::Relaxed),
            protocol = self.protocol,
            ticket = escape(&self.ticket),
            mods = self.mods_html(),
            download = escape(&self.download),
        )
    }

    /// The same facts as JSON, so a page or a script can poll `GET /info`.
    pub fn json(&self) -> String {
        let mods: Vec<serde_json::Value> = self
            .mods
            .iter()
            .map(|module| {
                serde_json::json!({
                    "id": module.id,
                    "version": module.version,
                    "side": module.side,
                })
            })
            .collect();
        serde_json::json!({
            "ticket": self.ticket,
            "clients": self.clients.load(Ordering::Relaxed),
            "protocol": self.protocol,
            "mods": mods,
            "mods_url": self.mods_zip.as_ref().map(|_| "/mods.zip"),
            "download": self.download,
        })
        .to_string()
    }
}

/// Escapes what matters inside an HTML element or a quoted attribute. The
/// download link and the mod ids are not assumed to be harmless: one is operator
/// input, the other comes from a mod manifest.
fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

/// One response: the status, the content type, an optional attachment filename,
/// and the body bytes (the mods archive is binary, so the body is not a `String`).
struct Response {
    status: &'static str,
    content_type: &'static str,
    attachment: Option<&'static str>,
    body: Vec<u8>,
}

/// Serves the status page until the process ends. A timeout keeps a client that
/// connects and then says nothing from wedging the loop.
pub fn serve(listener: TcpListener, info: Arc<Info>) {
    for stream in listener.incoming() {
        let Ok(mut stream) = stream else {
            continue;
        };
        let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
        let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
        let response = route(&mut stream, &info);
        let _ = write_response(&mut stream, &response);
    }
}

fn not_found() -> Response {
    Response {
        status: "404 Not Found",
        content_type: "text/plain; charset=utf-8",
        attachment: None,
        body: b"not found\n".to_vec(),
    }
}

/// The response for one request.
fn route(stream: &mut TcpStream, info: &Info) -> Response {
    match request_target(stream).as_deref() {
        Some("/") => Response {
            status: "200 OK",
            content_type: "text/html; charset=utf-8",
            attachment: None,
            body: info.page().into_bytes(),
        },
        Some("/info") => Response {
            status: "200 OK",
            content_type: "application/json",
            attachment: None,
            body: info.json().into_bytes(),
        },
        // The host's mods, so a visitor can obtain exactly what the session
        // requires rather than assembling the set by hand.
        Some("/mods.zip") => match info.mods_zip() {
            Some(bytes) => Response {
                status: "200 OK",
                content_type: "application/zip",
                attachment: Some("mods.zip"),
                body: bytes.to_vec(),
            },
            None => not_found(),
        },
        // Browsers ask for this unprompted; there is nothing to send.
        Some("/favicon.ico") => Response {
            status: "204 No Content",
            content_type: "text/plain",
            attachment: None,
            body: Vec::new(),
        },
        _ => not_found(),
    }
}

/// Reads the request and returns the path, with any query dropped. Only `GET` is
/// served, and a GET has no body, so reading to the end of the header block is
/// the whole request -- which also matters for the close: a socket dropped with
/// bytes still unread is reset rather than finished, and a well-behaved client
/// sees that as an error instead of the response.
fn request_target(stream: &mut TcpStream) -> Option<String> {
    let mut request = Vec::with_capacity(256);
    let mut byte = [0u8; 1];
    while request.len() < 8192 {
        match stream.read(&mut byte) {
            Ok(0) | Err(_) => break,
            Ok(_) => {
                request.push(byte[0]);
                if request.ends_with(b"\r\n\r\n") || request.ends_with(b"\n\n") {
                    break;
                }
            }
        }
    }
    let request = String::from_utf8_lossy(&request);
    let mut parts = request.lines().next()?.split_whitespace();
    if parts.next()? != "GET" {
        return None;
    }
    let target = parts.next()?;
    Some(target.split('?').next().unwrap_or(target).to_string())
}

/// One short response, after which the connection closes.
fn write_response(stream: &mut TcpStream, response: &Response) -> std::io::Result<()> {
    let disposition = match response.attachment {
        Some(name) => format!("Content-Disposition: attachment; filename=\"{name}\"\r\n"),
        None => String::new(),
    };
    let header = format!(
        "HTTP/1.1 {status}\r\n\
         Content-Type: {content_type}\r\n\
         {disposition}\
         Content-Length: {len}\r\n\
         Connection: close\r\n\
         \r\n",
        status = response.status,
        content_type = response.content_type,
        len = response.body.len(),
    );
    stream.write_all(header.as_bytes())?;
    stream.write_all(&response.body)?;
    stream.flush()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::SocketAddr;

    fn sample_mods() -> Vec<Mod> {
        vec![
            Mod {
                id: "com.example.a".to_string(),
                version: "1.0.0".to_string(),
                side: "world",
            },
            Mod {
                id: "com.example.b".to_string(),
                version: "2.1.0".to_string(),
                side: "client",
            },
        ]
    }

    fn info_with(mods: Vec<Mod>, zip: Option<Vec<u8>>) -> Info {
        Info::new(
            "endpointabc".to_string(),
            "https://example.test/dl".to_string(),
            8,
            mods,
            zip,
        )
    }

    #[test]
    fn the_page_carries_the_ticket_the_count_the_protocol_and_the_mods() {
        let info = info_with(sample_mods(), Some(b"PK-fixture".to_vec()));
        info.set_clients(2);
        let page = info.page();
        assert!(page.contains("<pre>endpointabc</pre>"), "{page}");
        assert!(page.contains("<strong>2</strong>"), "{page}");
        assert!(
            page.contains("Protocol version: <strong>8</strong>"),
            "{page}"
        );
        assert!(page.contains("com.example.a@1.0.0"), "{page}");
        assert!(page.contains("com.example.b@2.1.0"), "{page}");
        assert!(page.contains(">world<"), "{page}");
        assert!(page.contains(">client<"), "{page}");
        assert!(page.contains("href=\"/mods.zip\""), "{page}");
        assert!(page.contains("href=\"https://example.test/dl\""), "{page}");
    }

    #[test]
    fn a_host_without_mods_offers_no_archive() {
        let info = info_with(Vec::new(), None);
        let page = info.page();
        assert!(page.contains("Mods: <strong>none</strong>"), "{page}");
        assert!(!page.contains("/mods.zip"), "{page}");
        let json = info.json();
        assert!(json.contains("\"mods\":[]"), "{json}");
        assert!(json.contains("\"mods_url\":null"), "{json}");
    }

    #[test]
    fn the_page_escapes_the_link_and_the_mod_ids() {
        // A link is operator input and an id comes from a manifest, so neither
        // may inject markup.
        let info = Info::new(
            "t".to_string(),
            "\" onmouseover=\"alert(1)".to_string(),
            8,
            vec![Mod {
                id: "<script>".to_string(),
                version: "1".to_string(),
                side: "world",
            }],
            None,
        );
        let page = info.page();
        assert!(!page.contains("onmouseover=\"alert"), "{page}");
        assert!(!page.contains("<script>"), "{page}");
        assert!(page.contains("&quot;"), "{page}");
        assert!(page.contains("&lt;script&gt;"), "{page}");
    }

    #[test]
    fn the_json_reports_the_same_facts() {
        let info = info_with(sample_mods(), Some(vec![1, 2, 3]));
        info.set_clients(3);
        let json = info.json();
        assert!(json.contains("\"ticket\":\"endpointabc\""), "{json}");
        assert!(json.contains("\"clients\":3"), "{json}");
        assert!(json.contains("\"protocol\":8"), "{json}");
        assert!(
            json.contains("\"download\":\"https://example.test/dl\""),
            "{json}"
        );
        assert!(json.contains("\"id\":\"com.example.a\""), "{json}");
        assert!(json.contains("\"side\":\"world\""), "{json}");
        assert!(json.contains("\"mods_url\":\"/mods.zip\""), "{json}");
    }

    /// The whole thing, over a real socket: bind, serve, request. The serving
    /// thread runs until the test binary exits, which is soon enough.
    #[test]
    fn the_server_answers_the_page_the_info_and_the_archive() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let address = listener.local_addr().expect("bound address");
        let info = Arc::new(info_with(sample_mods(), Some(b"PK-fixture".to_vec())));
        info.set_clients(1);
        std::thread::spawn(move || serve(listener, info));

        let json = request(address, "/info");
        assert!(json.contains("\"ticket\":\"endpointabc\""), "{json}");
        assert!(json.contains("\"clients\":1"), "{json}");
        assert!(json.contains("\"protocol\":8"), "{json}");

        let page = request(address, "/");
        assert!(page.contains("<pre>endpointabc</pre>"), "{page}");
        assert!(page.contains("https://example.test"), "{page}");
        assert!(page.contains("com.example.a@1.0.0"), "{page}");

        let archive = request(address, "/mods.zip");
        assert!(archive.starts_with("HTTP/1.1 200"), "{archive}");
        assert!(
            archive.contains("Content-Type: application/zip"),
            "{archive}"
        );
        assert!(
            archive.contains("Content-Disposition: attachment; filename=\"mods.zip\""),
            "{archive}"
        );
        assert!(archive.ends_with("PK-fixture"), "{archive}");

        let missing = request(address, "/nope");
        assert!(missing.starts_with("HTTP/1.1 404"), "{missing}");
    }

    /// Sends one request and returns the whole response; the server closes the
    /// connection, so reading to the end terminates.
    fn request(address: SocketAddr, path: &str) -> String {
        let mut stream = TcpStream::connect(address).expect("connect");
        stream
            .write_all(format!("GET {path} HTTP/1.1\r\nHost: localhost\r\n\r\n").as_bytes())
            .expect("write");
        let mut response = String::new();
        stream.read_to_string(&mut response).expect("read");
        response
    }
}
