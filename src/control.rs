//! Local IPC for controlling the visible editor. MCP transport lives in tools/readit_mcp.py.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    fs,
    io::{BufRead, BufReader, Write},
    os::unix::{
        fs::{DirBuilderExt, MetadataExt, PermissionsExt},
        net::{UnixListener, UnixStream},
    },
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};

pub const MAX_MESSAGE: usize = 262_144;
#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Call {
    pub method: String,
    #[serde(default)]
    pub arguments: Value,
}
pub struct Request {
    pub call: Call,
    pub reply: mpsc::SyncSender<Result<Value, String>>,
    pub cancelled: Arc<AtomicBool>,
    pub deadline: Instant,
}
impl Request {
    pub fn is_live(&self) -> bool {
        !self.cancelled.load(Ordering::Relaxed) && Instant::now() < self.deadline
    }
}
pub struct Server {
    path: PathBuf,
    inode: u64,
    stop: Arc<AtomicBool>,
    pub requests: mpsc::Receiver<Request>,
}
impl Server {
    pub fn bind(path: &Path) -> Result<Self, String> {
        if !path.is_absolute() {
            return Err("control socket must be an absolute path".into());
        }
        let parent = path.parent().ok_or("socket parent is missing")?;
        if !parent.exists() {
            fs::DirBuilder::new()
                .mode(0o700)
                .create(parent)
                .map_err(|e| e.to_string())?;
        }
        let metadata = fs::symlink_metadata(parent).map_err(|e| e.to_string())?;
        if !metadata.is_dir()
            || metadata.file_type().is_symlink()
            || metadata.permissions().mode() & 0o077 != 0
        {
            return Err("control socket needs a private directory (mode 700)".into());
        }
        // Do not unlink an existing endpoint: it may belong to another live editor.
        let listener = UnixListener::bind(path).map_err(|e| format!("{}: {e}", path.display()))?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600)).map_err(|e| e.to_string())?;
        listener.set_nonblocking(true).map_err(|e| e.to_string())?;
        let inode = fs::metadata(path).map_err(|e| e.to_string())?.ino();
        let stop = Arc::new(AtomicBool::new(false));
        let active = Arc::new(AtomicUsize::new(0));
        let (sender, requests) = mpsc::sync_channel(32);
        let stopping = stop.clone();
        std::thread::spawn(move || {
            while !stopping.load(Ordering::Relaxed) {
                match listener.accept() {
                    Ok((stream, _)) => {
                        if active.fetch_add(1, Ordering::Relaxed) >= 8 {
                            active.fetch_sub(1, Ordering::Relaxed);
                            continue;
                        }
                        let sender = sender.clone();
                        let active = active.clone();
                        std::thread::spawn(move || {
                            let _ = handle(stream, sender);
                            active.fetch_sub(1, Ordering::Relaxed);
                        });
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(15))
                    }
                    Err(_) => break,
                }
            }
        });
        Ok(Self {
            path: path.to_path_buf(),
            inode,
            stop,
            requests,
        })
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if fs::symlink_metadata(&self.path).is_ok_and(|m| m.ino() == self.inode) {
            let _ = fs::remove_file(&self.path);
        }
    }
}
fn handle(mut stream: UnixStream, sender: mpsc::SyncSender<Request>) -> Result<(), String> {
    // Accepted sockets may inherit the listener's nonblocking mode on macOS.
    // Each connection has a dedicated worker; wait for fragmented frames using
    // the bounded read/write timeouts below instead of failing on WouldBlock.
    stream.set_nonblocking(false).map_err(|e| e.to_string())?;
    stream
        .set_read_timeout(Some(Duration::from_secs(3)))
        .map_err(|e| e.to_string())?;
    stream
        .set_write_timeout(Some(Duration::from_secs(5)))
        .map_err(|e| e.to_string())?;
    let mut reader = BufReader::new(stream.try_clone().map_err(|e| e.to_string())?);
    let mut bytes = Vec::new();
    let result = (|| {
        // Bound the frame before allocating or parsing JSON.
        loop {
            let available = reader.fill_buf().map_err(|e| e.to_string())?;
            if available.is_empty() {
                return Err("incomplete request".into());
            }
            let count = available
                .iter()
                .position(|b| *b == b'\n')
                .map_or(available.len(), |i| i + 1);
            if bytes.len() + count > MAX_MESSAGE {
                return Err("request is too large".into());
            }
            bytes.extend_from_slice(&available[..count]);
            reader.consume(count);
            if bytes.last() == Some(&b'\n') {
                break;
            }
        }
        let call: Call = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
        let (reply, result) = mpsc::sync_channel(1);
        let cancelled = Arc::new(AtomicBool::new(false));
        sender
            .try_send(Request {
                call,
                reply,
                cancelled: cancelled.clone(),
                deadline: Instant::now() + Duration::from_secs(55),
            })
            .map_err(|_| "editor control queue is unavailable".to_string())?;
        match result.recv_timeout(Duration::from_secs(55)) {
            Ok(result) => result,
            Err(_) => {
                cancelled.store(true, Ordering::Relaxed);
                Err("editor did not respond; inspect its state before retrying".into())
            }
        }
    })();
    let response = match result {
        Ok(value) => serde_json::json!({"result":value}),
        Err(error) => serde_json::json!({"error":error}),
    };
    serde_json::to_writer(&mut stream, &response).map_err(|e| e.to_string())?;
    stream.write_all(b"\n").map_err(|e| e.to_string())
}

/// Convert the public, one-based UTF-16 coordinates without silently clamping.
pub fn offset_at(text: &str, line: u64, column: u64) -> Result<usize, String> {
    if line == 0 || column == 0 {
        return Err("line and column are one-based".into());
    }
    let mut base = 0;
    for (index, value) in text.split('\n').enumerate() {
        let value = value.strip_suffix('\r').unwrap_or(value);
        if index as u64 + 1 == line {
            let mut units = 1;
            for (offset, ch) in value.char_indices() {
                if units == column {
                    return Ok(base + offset);
                }
                units += ch.len_utf16() as u64;
                if units > column {
                    return Err("column splits a UTF-16 character".into());
                }
            }
            return if units == column {
                Ok(base + value.len())
            } else {
                Err("column is outside the line".into())
            };
        }
        // Keep CRLF bytes in the actual byte offset.
        base = text[base..].find('\n').map_or(text.len(), |i| base + i + 1);
    }
    Err("line is outside the file".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn coordinates_handle_crlf_emoji_and_eof() {
        let text = "a😀\r\n次\n";
        assert_eq!(offset_at(text, 1, 2).unwrap(), 1);
        assert!(offset_at(text, 1, 3).is_err());
        assert_eq!(offset_at(text, 1, 4).unwrap(), 5);
        assert_eq!(offset_at(text, 2, 1).unwrap(), 7);
        assert_eq!(offset_at(text, 3, 1).unwrap(), 11);
        assert!(offset_at(text, 0, 1).is_err());
        assert!(offset_at(text, 4, 1).is_err());
    }
    #[test]
    fn fragmented_request_waits_for_remaining_bytes_on_nonblocking_socket() {
        let (server, mut client) = UnixStream::pair().unwrap();
        server.set_nonblocking(true).unwrap();
        client.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
        let (tx,rx)=mpsc::sync_channel(1);
        let worker=std::thread::spawn(move ||handle(server,tx));
        client.write_all(b"{\"method\":\"readit_state\"").unwrap();
        // Keep the JSON incomplete while the worker drains the first fragment.
        std::thread::sleep(Duration::from_millis(40));
        client.write_all(b",\"arguments\":{}}\n").unwrap();
        let request=rx.recv_timeout(Duration::from_secs(3)).unwrap();
        assert_eq!(request.call.method,"readit_state");
        request.reply.send(Ok(serde_json::json!({"ok":true}))).unwrap();
        let mut response=String::new();
        BufReader::new(client).read_line(&mut response).unwrap();
        assert_eq!(serde_json::from_str::<Value>(&response).unwrap()["result"]["ok"],true);
        worker.join().unwrap().unwrap();
    }

    #[test]
    fn refuses_existing_socket_and_insecure_directory() {
        let dir = tempfile::tempdir().unwrap();
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let path = dir.path().join("control.sock");
        let server = Server::bind(&path).unwrap();
        assert!(Server::bind(&path).is_err());
        assert!(path.exists());
        drop(server);
        assert!(!path.exists());
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o755)).unwrap();
        assert!(Server::bind(&path).is_err());
    }
}
