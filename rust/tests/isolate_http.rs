//! Isolation: can the shared runtime's reqwest reach a local socket?
use snapstore_auth::runtime;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::thread;

#[test]
fn runtime_http_reaches_local_server() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let addr = listener.local_addr().expect("addr");
    let server = thread::spawn(move || {
        let (mut s, _) = listener.accept().expect("accept");
        let mut buf = [0u8; 4096];
        let _ = s.read(&mut buf);
        let resp = b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}";
        s.write_all(resp).ok();
    });

    // Single future: request + body in one go (never block_on inside a task).
    let out = runtime::block_on(async move {
        let r = reqwest::Client::new()
            .get(format!("http://{}/ping", addr))
            .send()
            .await
            .map_err(|e| e.to_string())?;
        let status = r.status();
        let body = r.text().await.map_err(|e| e.to_string())?;
        Ok::<(u16, String), String>((status.as_u16(), body))
    });
    server.join().ok();
    match out {
        Ok((status, body)) => {
            assert_eq!(status, 200, "status {status}");
            assert_eq!(body, "{}");
        }
        Err(e) => panic!("request failed: {e}"),
    }
}
