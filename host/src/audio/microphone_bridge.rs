//! Session-scoped, USB-only iPad microphone forwarding to a local ASR client.
//! No endpoint is opened and no system recording-device preference is changed.
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::net::{Ipv4Addr, SocketAddrV4, UdpSocket};
use std::path::{Path, PathBuf};

use eternal_wire::v2::microphone::{MicrophoneHeader, MICROPHONE_PCM_BYTES};
use serde::{Deserialize, Serialize};
use tracing::warn;

use crate::transport::link::{LinkId, PeerId};

pub const BRIDGE_PORT: u16 = 19878;
pub const BRIDGE_HEADER_SIZE: usize = 40;
const CONFIG_MAX_BYTES: u64 = 1024;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct BridgeConfig {
    schema_version: u8,
    port: u16,
    token_hex: String,
}

impl BridgeConfig {
    fn token(&self) -> io::Result<[u8; 16]> {
        if self.schema_version != 1 || self.port != BRIDGE_PORT {
            return Err(invalid("unsupported microphone bridge configuration"));
        }
        crate::pairing::parse_token(&self.token_hex)
            .ok_or_else(|| invalid("invalid microphone bridge token"))
    }
}

fn invalid(message: &'static str) -> io::Error { io::Error::new(io::ErrorKind::InvalidData, message) }

fn read_config(path: &Path) -> io::Result<BridgeConfig> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_file() || metadata.len() > CONFIG_MAX_BYTES {
        return Err(invalid("invalid microphone bridge configuration file"));
    }
    let mut data = Vec::new();
    fs::File::open(path)?.take(CONFIG_MAX_BYTES + 1).read_to_end(&mut data)?;
    if data.len() as u64 > CONFIG_MAX_BYTES { return Err(invalid("microphone bridge configuration is too large")); }
    let config: BridgeConfig = serde_json::from_slice(&data)
        .map_err(|_| invalid("invalid microphone bridge configuration JSON"))?;
    config.token()?;
    Ok(config)
}

/// Publish a complete config without replacing an existing user's token.
/// A same-directory hard link is an atomic create-if-absent operation on the
/// supported NTFS/APFS/ext filesystems. Failure leaves existing files intact.
fn load_or_create_config(path: &Path) -> io::Result<BridgeConfig> {
    match read_config(path) {
        Ok(config) => return Ok(config),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    let parent = path.parent().ok_or_else(|| invalid("missing microphone bridge directory"))?;
    fs::create_dir_all(parent)?;
    let token = crate::pairing::new_token().map_err(|_| invalid("microphone bridge entropy unavailable"))?;
    let config = BridgeConfig { schema_version: 1, port: BRIDGE_PORT, token_hex: crate::pairing::token_hex(&token) };
    let nonce = crate::pairing::new_token().map_err(|_| invalid("microphone bridge entropy unavailable"))?;
    let temporary = parent.join(format!(".microphone-bridge-{}.tmp", crate::pairing::token_hex(&nonce)));
    let result = (|| {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)] {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary)?;
        let json = serde_json::to_vec_pretty(&config).map_err(|_| invalid("cannot serialize microphone bridge configuration"))?;
        file.write_all(&json)?;
        file.sync_all()?;
        drop(file);
        match fs::hard_link(&temporary, path) {
            Ok(()) => Ok(config),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => read_config(path),
            Err(error) => Err(error),
        }
    })();
    let _ = fs::remove_file(temporary);
    result
}

/// EMM1 + version/flags/length + local token + session/sequence/capture time.
/// The token never appears on USB/Wi-Fi, diagnostics, or in checked-in source.
pub fn encode_bridge_packet(token: &[u8; 16], header: MicrophoneHeader, pcm: &[u8]) -> io::Result<Vec<u8>> {
    if *token == [0; 16] || header.session_id == 0 || pcm.len() != if header.end { 0 } else { MICROPHONE_PCM_BYTES } {
        return Err(invalid("invalid microphone bridge packet"));
    }
    let mut bytes = vec![0; BRIDGE_HEADER_SIZE + pcm.len()];
    bytes[..4].copy_from_slice(b"EMM1");
    bytes[4] = 1;
    bytes[5] = u8::from(header.end);
    bytes[6..8].copy_from_slice(&(pcm.len() as u16).to_le_bytes());
    bytes[8..24].copy_from_slice(token);
    bytes[24..28].copy_from_slice(&header.session_id.to_le_bytes());
    bytes[28..32].copy_from_slice(&header.mic_seq.to_le_bytes());
    bytes[32..40].copy_from_slice(&header.capture_ts_us.to_le_bytes());
    bytes[BRIDGE_HEADER_SIZE..].copy_from_slice(pcm);
    Ok(bytes)
}

struct BridgeSink {
    socket: UdpSocket,
    token: [u8; 16],
}
impl BridgeSink {
    fn open(path: &Path) -> io::Result<Self> {
        let config = load_or_create_config(path)?;
        let socket = UdpSocket::bind(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 0))?;
        socket.set_nonblocking(true)?;
        socket.connect(SocketAddrV4::new(Ipv4Addr::LOCALHOST, BRIDGE_PORT))?;
        Ok(Self { socket, token: config.token()? })
    }
    fn send(&self, header: MicrophoneHeader, pcm: &[u8]) -> io::Result<()> {
        let packet = encode_bridge_packet(&self.token, header, pcm)?;
        if self.socket.send(&packet)? != packet.len() { return Err(invalid("partial microphone bridge datagram")); }
        Ok(())
    }
}

struct ActiveMicrophone {
    peer: PeerId,
    session_id: u32,
    last_seq: Option<u32>,
    capture_ts_us: u64,
    open: bool,
}
impl ActiveMicrophone {
    fn accepts(&self, sequence: u32) -> bool {
        self.last_seq.is_none_or(|last| {
            let delta = sequence.wrapping_sub(last);
            delta != 0 && delta < 0x8000_0000
        })
    }
}

pub struct MicrophoneBridge {
    config_path: Option<PathBuf>,
    active: Option<ActiveMicrophone>,
    sink: Option<BridgeSink>,
    failed_session: Option<(PeerId, u32)>,
}
impl Default for MicrophoneBridge {
    fn default() -> Self {
        Self::new(crate::settings::app_data_dir().map(|dir| dir.join("microphone-bridge.json")))
    }
}
impl MicrophoneBridge {
    fn new(config_path: Option<PathBuf>) -> Self {
        Self { config_path, active: None, sink: None, failed_session: None }
    }

    /// Call only after Session::accept_microphone validates the live HELLO.
    /// This additional transport check makes a mistaken caller fail closed.
    pub fn receive_authorized(&mut self, peer: PeerId, header: MicrophoneHeader, pcm: &[u8]) -> bool {
        if !matches!(peer.link, LinkId::Usb { .. }) || header.session_id == 0
            || pcm.len() != if header.end { 0 } else { MICROPHONE_PCM_BYTES } { return false; }
        let key = (peer, header.session_id);
        if self.failed_session == Some(key) { return false; }
        if self.active.as_ref().is_some_and(|active| (active.peer, active.session_id) != key) {
            self.finish();
        }
        if self.active.is_none() {
            // A stop packet alone must not create credentials or open a socket.
            if header.end { return false; }
            let sink = self.config_path.as_deref().ok_or_else(|| invalid("microphone bridge directory unavailable"))
                .and_then(BridgeSink::open);
            match sink {
                Ok(sink) => self.sink = Some(sink),
                Err(_) => {
                    self.failed_session = Some(key);
                    warn!("Local microphone bridge unavailable for this session");
                    return false;
                }
            }
            self.active = Some(ActiveMicrophone { peer, session_id: header.session_id,
                last_seq: None, capture_ts_us: 0, open: false });
        }
        let active = self.active.as_ref().unwrap();
        if !active.accepts(header.mic_seq) { return false; }
        if self.sink.as_ref().is_none_or(|sink| sink.send(header, pcm).is_err()) {
            self.finish();
            self.failed_session = Some(key);
            warn!("Local microphone bridge stopped after a send failure");
            return false;
        }
        let active = self.active.as_mut().unwrap();
        active.last_seq = Some(header.mic_seq);
        active.capture_ts_us = header.capture_ts_us;
        active.open = !header.end;
        true
    }

    /// Ending a session (BYE, cable loss, timeout, stop, task drop) emits one
    /// header-only end packet before dropping local state. No stream resumes
    /// automatically after reconnect, and stale sequence IDs cannot leak in.
    pub fn finish(&mut self) {
        if let (Some(active), Some(sink)) = (&self.active, &self.sink) {
            if active.open {
                let _ = sink.send(MicrophoneHeader { session_id: active.session_id,
                    mic_seq: active.last_seq.unwrap_or(0).wrapping_add(1),
                    capture_ts_us: active.capture_ts_us, end: true }, &[]);
            }
        }
        self.active = None;
        self.sink = None;
        self.failed_session = None;
    }
}
impl Drop for MicrophoneBridge { fn drop(&mut self) { self.finish(); } }

#[cfg(test)]
mod tests {
    use super::*;
    struct TestDirectory(PathBuf);
    impl TestDirectory {
        fn new() -> Self {
            let token = crate::pairing::token_hex(&crate::pairing::new_token().unwrap());
            Self(std::env::temp_dir().join(format!("eternal-mic-bridge-{token}")))
        }
        fn config(&self) -> PathBuf { self.0.join("microphone-bridge.json") }
    }
    impl Drop for TestDirectory { fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); } }

    #[test]
    fn configuration_is_created_once_and_never_replaces_bad_credentials() {
        let directory = TestDirectory::new();
        let path = directory.config();
        let first = load_or_create_config(&path).unwrap();
        assert_eq!(first.port, BRIDGE_PORT);
        assert_ne!(first.token().unwrap(), [0; 16]);
        assert_eq!(first.token().unwrap(), load_or_create_config(&path).unwrap().token().unwrap());
        #[cfg(unix)] {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        }
        fs::write(&path, b"invalid configuration kept for inspection").unwrap();
        assert!(load_or_create_config(&path).is_err());
        assert_eq!(fs::read(&path).unwrap(), b"invalid configuration kept for inspection");
    }

    #[test]
    fn configuration_rejects_external_ports_zero_tokens_and_oversized_files() {
        let directory = TestDirectory::new(); fs::create_dir_all(&directory.0).unwrap();
        let path = directory.config();
        for json in [
            r#"{"schema_version":1,"port":19879,"token_hex":"11111111111111111111111111111111"}"#,
            r#"{"schema_version":2,"port":19878,"token_hex":"11111111111111111111111111111111"}"#,
            r#"{"schema_version":1,"port":19878,"token_hex":"00000000000000000000000000000000"}"#,
            r#"{"schema_version":1,"port":19878,"token_hex":"invalid"}"#,
            r#"{"schema_version":1,"port":19878,"token_hex":"11111111111111111111111111111111","host":"8.8.8.8"}"#,
        ] { fs::write(&path, json).unwrap(); assert!(read_config(&path).is_err()); }
        fs::write(&path, vec![b' '; CONFIG_MAX_BYTES as usize + 1]).unwrap();
        assert!(read_config(&path).is_err());
    }

    #[test]
    fn bridge_packet_offsets_match_consumer_contract() {
        let header = MicrophoneHeader { session_id: 0x12345678, mic_seq: 7, capture_ts_us: 123456, end: false };
        let packet = encode_bridge_packet(&[0xab; 16], header, &[0x5a; MICROPHONE_PCM_BYTES]).unwrap();
        assert_eq!(packet.len(), 680);
        assert_eq!(&packet[..8], b"EMM1\x01\x00\x80\x02");
        assert_eq!(&packet[8..24], &[0xab; 16]);
        assert_eq!(&packet[24..28], &header.session_id.to_le_bytes());
        assert_eq!(&packet[28..32], &7u32.to_le_bytes());
        assert_eq!(&packet[32..40], &123456u64.to_le_bytes());
        assert!(packet[40..].iter().all(|byte| *byte == 0x5a));
        let end = encode_bridge_packet(&[1; 16], MicrophoneHeader { end: true, ..header }, &[]).unwrap();
        assert_eq!(end.len(), 40); assert_eq!(end[5], 1); assert_eq!(&end[6..8], &[0, 0]);
        assert!(encode_bridge_packet(&[0; 16], header, &[0; MICROPHONE_PCM_BYTES]).is_err());
    }

    #[test]
    fn sequence_drops_duplicates_and_old_packets_but_accepts_wrapping() {
        let mut active = ActiveMicrophone { peer: PeerId::usb(7), session_id: 2,
            last_seq: None, capture_ts_us: 0, open: false };
        assert!(active.accepts(0)); active.last_seq = Some(u32::MAX);
        assert!(!active.accepts(u32::MAX)); assert!(!active.accepts(u32::MAX - 1));
        assert!(active.accepts(0)); assert!(!active.accepts(0x7fffffff));
    }

    #[test]
    fn wifi_and_stop_only_packets_cannot_create_local_credentials() {
        let directory = TestDirectory::new(); let path = directory.config();
        let mut bridge = MicrophoneBridge::new(Some(path.clone()));
        let header = MicrophoneHeader { session_id: 1, mic_seq: 0, capture_ts_us: 1, end: false };
        assert!(!bridge.receive_authorized(PeerId::udp("127.0.0.1:9876".parse().unwrap()), header, &[0; MICROPHONE_PCM_BYTES]));
        assert!(!bridge.receive_authorized(PeerId::usb(7), MicrophoneHeader { end: true, ..header }, &[]));
        assert!(!path.exists());
    }

    #[test]
    fn forwarding_and_cleanup_emit_exactly_one_local_end() {
        let receiver = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        receiver.set_read_timeout(Some(std::time::Duration::from_millis(100))).unwrap();
        let sender = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        sender.set_nonblocking(true).unwrap(); sender.connect(receiver.local_addr().unwrap()).unwrap();
        let peer = PeerId::usb(7);
        let mut bridge = MicrophoneBridge::new(None);
        bridge.sink = Some(BridgeSink { socket: sender, token: [0x34; 16] });
        bridge.active = Some(ActiveMicrophone { peer, session_id: 23, last_seq: None, capture_ts_us: 0, open: false });
        let header = MicrophoneHeader { session_id: 23, mic_seq: 10, capture_ts_us: 123, end: false };
        assert!(bridge.receive_authorized(peer, header, &[0x45; MICROPHONE_PCM_BYTES]));
        assert!(!bridge.receive_authorized(peer, header, &[0x45; MICROPHONE_PCM_BYTES]));
        let mut bytes = [0; 1024];
        assert_eq!(receiver.recv(&mut bytes).unwrap(), 680); assert_eq!(&bytes[8..24], &[0x34; 16]);
        bridge.finish();
        assert_eq!(receiver.recv(&mut bytes).unwrap(), 40);
        assert_eq!(bytes[5], 1); assert_eq!(u32::from_le_bytes(bytes[28..32].try_into().unwrap()), 11);
        bridge.finish(); assert!(receiver.recv(&mut bytes).is_err());
    }
}
