//! Optional local HTTP server so a phone can view the same cost + coach-tip
//! data this app already computes from local session files — no cloud backend
//! of ours involved. An ngrok tunnel can be layered on top for access away
//! from the home network, using the user's own ngrok account.

use ngrok::config::ForwarderBuilder;
use ngrok::tunnel::{EndpointInfo, HttpTunnel};
use rand::distributions::Alphanumeric;
use rand::Rng;
use serde::Serialize;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use tiny_http::{Header, Response, Server};

/// Fixed so the same LAN URL keeps working across app restarts.
pub const PORT: u16 = 47654;

const PAGE: &str = include_str!("../mobile/index.html");

struct RunningServer {
    server: Arc<Server>,
    thread: JoinHandle<()>,
    token: Arc<Mutex<String>>,
}

#[derive(Default)]
pub struct RemoteManager {
    server: Mutex<Option<RunningServer>>,
    forwarder: Mutex<Option<ngrok::forwarder::Forwarder<HttpTunnel>>>,
}

#[derive(Serialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct RemoteStatus {
    running: bool,
    local_url: Option<String>,
    token: Option<String>,
    tunnel_url: Option<String>,
}

pub fn generate_token() -> String {
    rand::thread_rng()
        .sample_iter(&Alphanumeric)
        .take(24)
        .map(char::from)
        .collect()
}

fn content_type(value: &'static str) -> Header {
    Header::from_bytes(&b"Content-Type"[..], value.as_bytes()).unwrap()
}

fn query_param<'a>(query: &'a str, key: &str) -> Option<&'a str> {
    query.split('&').find_map(|kv| {
        let (k, v) = kv.split_once('=')?;
        (k == key).then_some(v)
    })
}

fn handle_request(request: tiny_http::Request, token: &Arc<Mutex<String>>) {
    let full_url = request.url().to_string();
    let (path, query) = full_url.split_once('?').unwrap_or((full_url.as_str(), ""));
    let expected = token.lock().unwrap().clone();
    let given = query_param(query, "token").unwrap_or("");
    if expected.is_empty() || given != expected {
        let _ = request.respond(Response::from_string("Unauthorized: missing or wrong token").with_status_code(401));
        return;
    }
    match path {
        "/" | "/index.html" => {
            let _ = request.respond(Response::from_string(PAGE).with_header(content_type("text/html; charset=utf-8")));
        }
        "/api/summary" => {
            let range = query_param(query, "range").unwrap_or("today");
            let snapshot = crate::build_snapshot(range);
            let body = serde_json::to_string(&snapshot).unwrap_or_else(|_| "{}".into());
            let _ = request.respond(Response::from_string(body).with_header(content_type("application/json")));
        }
        _ => {
            let _ = request.respond(Response::from_string("Not found").with_status_code(404));
        }
    }
}

impl RemoteManager {
    /// Starts the server if it isn't running yet. `existing_token` lets the caller
    /// keep reusing the same link/QR code across app restarts; a fresh one is
    /// minted when there isn't one yet.
    pub fn enable(&self, existing_token: Option<String>) -> Result<RemoteStatus, String> {
        let mut guard = self.server.lock().unwrap();
        if guard.is_none() {
            let token = existing_token
                .filter(|t| !t.trim().is_empty())
                .unwrap_or_else(generate_token);
            let server = Server::http(("0.0.0.0", PORT))
                .map_err(|e| format!("Couldn't start the local server on port {PORT}: {e}"))?;
            let server = Arc::new(server);
            let token_shared = Arc::new(Mutex::new(token));
            let server_bg = server.clone();
            let token_bg = token_shared.clone();
            let thread = std::thread::spawn(move || {
                for request in server_bg.incoming_requests() {
                    handle_request(request, &token_bg);
                }
            });
            *guard = Some(RunningServer { server, thread, token: token_shared });
        }
        drop(guard);
        Ok(self.status())
    }

    pub fn regenerate_token(&self) -> RemoteStatus {
        if let Some(running) = self.server.lock().unwrap().as_ref() {
            *running.token.lock().unwrap() = generate_token();
        }
        self.status()
    }

    pub fn disable(&self) {
        if let Some(running) = self.server.lock().unwrap().take() {
            running.server.unblock();
            let _ = running.thread.join();
        }
        *self.forwarder.lock().unwrap() = None;
    }

    pub fn status(&self) -> RemoteStatus {
        let guard = self.server.lock().unwrap();
        let Some(running) = guard.as_ref() else {
            return RemoteStatus::default();
        };
        let token = running.token.lock().unwrap().clone();
        let local_url = local_ip_address::local_ip()
            .map(|ip| format!("http://{ip}:{PORT}/?token={token}"))
            .ok();
        RemoteStatus {
            running: true,
            local_url,
            token: Some(token),
            tunnel_url: self.forwarder.lock().unwrap().as_ref().map(|f| f.url().to_string()),
        }
    }

    pub fn set_forwarder(&self, forwarder: ngrok::forwarder::Forwarder<HttpTunnel>) {
        *self.forwarder.lock().unwrap() = Some(forwarder);
    }

    pub fn stop_tunnel(&self) {
        *self.forwarder.lock().unwrap() = None;
    }

    pub fn is_running(&self) -> bool {
        self.server.lock().unwrap().is_some()
    }
}

#[tauri::command]
pub fn remote_status(state: tauri::State<RemoteManager>) -> RemoteStatus {
    state.status()
}

#[tauri::command]
pub fn remote_enable(existing_token: Option<String>, state: tauri::State<RemoteManager>) -> Result<RemoteStatus, String> {
    state.enable(existing_token)
}

#[tauri::command]
pub fn remote_disable(state: tauri::State<RemoteManager>) {
    state.disable();
}

#[tauri::command]
pub fn remote_regenerate_token(state: tauri::State<RemoteManager>) -> RemoteStatus {
    state.regenerate_token()
}

#[tauri::command]
pub async fn remote_start_tunnel(
    authtoken: String,
    state: tauri::State<'_, RemoteManager>,
) -> Result<String, String> {
    if !state.is_running() {
        return Err("Turn on phone access first.".into());
    }
    if authtoken.trim().is_empty() {
        return Err("Paste your ngrok authtoken first (ngrok.com → your dashboard → Your Authtoken).".into());
    }
    let session = ngrok::Session::builder()
        .authtoken(authtoken.trim())
        .connect()
        .await
        .map_err(|e| format!("Couldn't connect to ngrok: {e}"))?;
    let local_target = url::Url::parse(&format!("http://127.0.0.1:{PORT}")).unwrap();
    let forwarder = session
        .http_endpoint()
        .listen_and_forward(local_target)
        .await
        .map_err(|e| format!("Couldn't open a tunnel: {e}"))?;
    let public_url = forwarder.url().to_string();
    state.set_forwarder(forwarder);
    Ok(public_url)
}

#[tauri::command]
pub fn remote_stop_tunnel(state: tauri::State<RemoteManager>) {
    state.stop_tunnel();
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpStream;

    fn http_get(port: u16, path: &str) -> String {
        let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
        write!(stream, "GET {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n").unwrap();
        let mut buf = String::new();
        stream.read_to_string(&mut buf).unwrap();
        buf
    }

    #[test]
    fn rejects_wrong_token_and_serves_summary_with_the_right_one() {
        let mgr = RemoteManager::default();
        let status = mgr.enable(Some("test-token-123".into())).unwrap();
        assert!(status.running);
        assert_eq!(status.token.as_deref(), Some("test-token-123"));
        assert!(status.local_url.as_deref().unwrap_or("").contains("test-token-123"));

        assert!(http_get(PORT, "/?token=wrong-token").starts_with("HTTP/1.1 401"));

        let page = http_get(PORT, "/?token=test-token-123");
        assert!(page.starts_with("HTTP/1.1 200"));
        assert!(page.contains("AI Usage Tracker"));

        let summary = http_get(PORT, "/api/summary?range=today&token=test-token-123");
        assert!(summary.starts_with("HTTP/1.1 200"));
        assert!(summary.contains("asOfDate"));

        mgr.disable();
        assert!(!mgr.is_running());
    }
}
