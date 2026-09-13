//! The optional status page a host can serve.
//!
//! `goatsd --listen host:port` starts one small HTTP server reporting what a
//! visitor needs in order to join: the ticket, how many players are connected,
//! and where to get the client. It is deliberately tiny -- one thread, one
//! connection at a time, `Connection: close`, no keep-alive -- because it is a
//! convenience, not a web service, and it only exists when `--listen` asks for
//! it. Nothing here is on the session's hot path.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

/// What the page reports. The ticket and the download link are fixed when the
/// host starts; the client count moves as players come and go.
pub struct Info {
    ticket: String,
    download: String,
    clients: AtomicUsize,
}

impl Info {
    pub fn new(ticket: String, download: String) -> Info {
        Info {
            ticket,
            download,
            clients: AtomicUsize::new(0),
        }
    }

    /// Records how many clients are in, not counting the host.
    pub fn set_clients(&self, clients: usize) {
        self.clients.store(clients, Ordering::Relaxed);
    }

    /// The page a visitor gets: the ticket to paste, and the client to download.
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
             </style>\n\
             </head>\n\
             <body>\n\
             <h1>Slag Goat session</h1>\n\
             <p>Players connected: <strong>{clients}</strong></p>\n\
             <p>Paste this into the client's console as \
             <code>connect &lt;ticket&gt; &lt;name&gt;</code>:</p>\n\
             <pre>{ticket}</pre>\n\
             <p><a href=\"{download}\">Download the client</a></p>\n\
             </body>\n\
             </html>\n",
            clients = self.clients.load(Ordering::Relaxed),
            ticket = escape(&self.ticket),
            download = escape(&self.download),
        )
    }

    /// The same facts as JSON, so a page or a script can poll `GET /info`.
    pub fn json(&self) -> String {
        serde_json::json!({
            "ticket": self.ticket,
            "clients": self.clients.load(Ordering::Relaxed),
            "download": self.download,
        })
        .to_string()
    }
}

/// Escapes what matters inside an HTML element or a quoted attribute. The
/// download link is operator-supplied, so it is not assumed to be harmless.
fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
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
        let (status, content_type, body) = route(&mut stream, &info);
        let _ = write_response(&mut stream, status, content_type, &body);
    }
}

/// The response for one request.
fn route(stream: &mut TcpStream, info: &Info) -> (&'static str, &'static str, String) {
    match request_target(stream).as_deref() {
        Some("/") => ("200 OK", "text/html; charset=utf-8", info.page()),
        Some("/info") => ("200 OK", "application/json", info.json()),
        // Browsers ask for this unprompted; there is nothing to send.
        Some("/favicon.ico") => ("204 No Content", "text/plain", String::new()),
        _ => (
            "404 Not Found",
            "text/plain; charset=utf-8",
            "not found\n".to_string(),
        ),
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
fn write_response(
    stream: &mut TcpStream,
    status: &str,
    content_type: &str,
    body: &str,
) -> std::io::Result<()> {
    let response = format!(
        "HTTP/1.1 {status}\r\n\
         Content-Type: {content_type}\r\n\
         Content-Length: {}\r\n\
         Connection: close\r\n\
         \r\n\
         {body}",
        body.len()
    );
    stream.write_all(response.as_bytes())?;
    stream.flush()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::SocketAddr;

    #[test]
    fn the_page_carries_the_ticket_the_count_and_the_link() {
        let info = Info::new(
            "endpointabc".to_string(),
            "https://example.test/dl".to_string(),
        );
        info.set_clients(2);
        let page = info.page();
        assert!(page.contains("<pre>endpointabc</pre>"), "{page}");
        assert!(page.contains("<strong>2</strong>"), "{page}");
        assert!(page.contains("href=\"https://example.test/dl\""), "{page}");
    }

    #[test]
    fn the_page_escapes_the_download_link() {
        // A link is operator input, so it must not be able to inject markup.
        let info = Info::new("t".to_string(), "\" onmouseover=\"alert(1)".to_string());
        let page = info.page();
        assert!(!page.contains("onmouseover=\"alert"), "{page}");
        assert!(page.contains("&quot;"), "{page}");
    }

    #[test]
    fn the_json_reports_the_same_facts() {
        let info = Info::new(
            "endpointabc".to_string(),
            "https://example.test".to_string(),
        );
        info.set_clients(3);
        let json = info.json();
        assert!(json.contains("\"ticket\":\"endpointabc\""), "{json}");
        assert!(json.contains("\"clients\":3"), "{json}");
        assert!(
            json.contains("\"download\":\"https://example.test\""),
            "{json}"
        );
    }

    /// The whole thing, over a real socket: bind, serve, request. The serving
    /// thread runs until the test binary exits, which is soon enough.
    #[test]
    fn the_server_answers_the_page_and_info() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let address = listener.local_addr().expect("bound address");
        let info = Arc::new(Info::new(
            "endpointabc".to_string(),
            "https://example.test".to_string(),
        ));
        info.set_clients(1);
        std::thread::spawn(move || serve(listener, info));

        let json = request(address, "/info");
        assert!(json.contains("\"ticket\":\"endpointabc\""), "{json}");
        assert!(json.contains("\"clients\":1"), "{json}");

        let page = request(address, "/");
        assert!(page.contains("<pre>endpointabc</pre>"), "{page}");
        assert!(page.contains("https://example.test"), "{page}");

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
