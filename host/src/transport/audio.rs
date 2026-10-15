use eternal_wire::v2::audio::AudioHeader;

use crate::audio::SessionPacket;
use crate::control::SharedControl;
use crate::stats::PIPELINE_STATS;

use super::link::{LinkId, PeerId};
use super::usb::TransportLinks;

#[derive(Default)]
pub(super) struct AudioSender {
    last_stream: Option<(u32, u32)>,
    reset_pending: bool,
}

impl AudioSender {
    pub fn prepare(
        &mut self,
        queued: SessionPacket,
        shared: &SharedControl,
        epoch: u32,
        now_us: u64,
    ) -> Option<(PeerId, Vec<u8>)> {
        if !shared
            .audio_enabled
            .load(std::sync::atomic::Ordering::SeqCst)
        {
            return None;
        }
        let peer = {
            let session = shared.session.lock();
            if session.audio_session_id() != Some(queued.session_id) {
                return None;
            }
            session.peer()?
        };
        if now_us.saturating_sub(queued.packet.capture_ts_us) > 100_000 {
            self.reset_pending = true;
            PIPELINE_STATS.lock().audio.dropped += 1;
            return None;
        }
        let stream = (queued.session_id, epoch);
        let header = AudioHeader {
            session_id: queued.session_id,
            stream_epoch: epoch,
            audio_seq: queued.packet.seq,
            capture_ts_us: queued.packet.capture_ts_us,
            discontinuity: queued.packet.discontinuity
                || self.reset_pending
                || self.last_stream != Some(stream),
        };
        let datagram = header.encode(&queued.packet.opus).ok()?;
        let datagram_limit = match peer.link {
            LinkId::Usb { .. } => eternal_wire::v2::MAX_DGRAM_SIZE,
            LinkId::Udp => shared.max_dgram.load(std::sync::atomic::Ordering::SeqCst) as usize,
        };
        if datagram.len() > datagram_limit {
            self.reset_pending = true;
            PIPELINE_STATS.lock().audio.dropped += 1;
            return None;
        }
        Some((peer, datagram))
    }

    pub async fn send(
        &mut self,
        queued: SessionPacket,
        links: &TransportLinks,
        shared: &SharedControl,
        epoch: u32,
    ) {
        let session_id = queued.session_id;
        let payload_size = queued.packet.opus.len();
        if let Some((peer, datagram)) =
            self.prepare(queued, shared, epoch, crate::clock::host_now_us())
        {
            if links.send_to(&datagram, peer).await.is_ok() {
                self.last_stream = Some((session_id, epoch));
                self.reset_pending = false;
                PIPELINE_STATS.lock().audio.record_sent(payload_size);
            } else {
                self.reset_pending = true;
                PIPELINE_STATS.lock().audio.dropped += 1;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use eternal_wire::v2::control::*;
    use std::sync::atomic::Ordering;
    use std::time::Instant;

    fn session(caps: u16) -> (SharedControl, u32) {
        session_with_peer(caps, PeerId::udp("127.0.0.1:19891".parse().unwrap()))
    }

    fn session_with_peer(caps: u16, peer: PeerId) -> (SharedControl, u32) {
        let shared = SharedControl::new(9876, 15_000_000);
        shared.pairing.lock().required = false;
        let config = super::super::SharedConfigSource {
            shared: &shared,
            stream_epoch: 7,
            pen_available: false,
        };
        shared.session.lock().handle_control(
            peer,
            0,
            ControlMessage::Hello2(Hello2 {
                proto_min: 2,
                proto_max: 2,
                client_nonce: 1,
                listen_port: 19891,
                decoder_caps: CAP_DECODE_H264,
                feature_caps: caps,
                screen_px_w: 640,
                screen_px_h: 360,
                screen_pt_w: 640,
                screen_pt_h: 360,
                refresh_hz: 60,
                device_name: "audio test".into(),
                device_id: 11,
                preferred_fps: 60,
                auth_token: [0; 16],
                pairing_code: 0,
            }),
            &config,
            Instant::now(),
        );
        let id = shared.session.lock().session_id().unwrap();
        (shared, id)
    }

    fn packet(id: u32, time: u64) -> SessionPacket {
        SessionPacket {
            session_id: id,
            packet: crate::audio::AudioPacket {
                seq: 3,
                capture_ts_us: time,
                discontinuity: false,
                opus: vec![0xF8, 0xFF, 0xFE],
            },
        }
    }

    #[test]
    fn usb_audio_bursts_ignore_video_fragment_size_but_keep_the_wire_limit() {
        use eternal_wire::v2::{audio::AUDIO_HEADER_SIZE, media::MIN_DGRAM_SIZE, MAX_DGRAM_SIZE};

        let peer = PeerId::usb(11);
        let (shared, id) = session_with_peer(FEATURE_WANTS_AUDIO, peer);
        shared.max_dgram.store(MIN_DGRAM_SIZE as u32, Ordering::SeqCst);
        let mut sender = AudioSender::default();
        // 552 is the real CVBR burst that previously disabled capture.
        // Also exercise the largest payload the already installed iPad accepts.
        for size in [552, MAX_DGRAM_SIZE - AUDIO_HEADER_SIZE] {
            let mut queued = packet(id, 100);
            if size == 552 {
                // One valid 20 ms Opus silence frame with RFC 6716 padding.
                queued.packet.opus = vec![0xFB, 0x41, 255, 255, 37, 0xFF, 0xFE];
            }
            queued.packet.opus.resize(size, 0);
            let expected = queued.packet.opus.clone();
            let (destination, bytes) = sender.prepare(queued, &shared, 7, 100).unwrap();
            assert_eq!(destination, peer);
            let (_, payload) = AudioHeader::decode(&bytes).unwrap();
            assert_eq!(payload, expected, "audio must never be truncated");
        }
        let mut oversized = packet(id, 100);
        oversized.packet.opus.resize(MAX_DGRAM_SIZE - AUDIO_HEADER_SIZE + 1, 0);
        assert!(sender.prepare(oversized, &shared, 7, 100).is_none());

        let (udp, id) = session(FEATURE_WANTS_AUDIO);
        udp.max_dgram.store(MIN_DGRAM_SIZE as u32, Ordering::SeqCst);
        let mut queued = packet(id, 100);
        queued.packet.opus.resize(552, 0);
        assert!(sender.prepare(queued, &udp, 7, 100).is_none());
        // The existing UDP budget remains usable after a dropped burst.
        assert!(sender.prepare(packet(id, 100), &udp, 7, 100).is_some());
    }

    #[test]
    fn audio_requires_both_peers_and_the_current_session_and_epoch() {
        let mut sender = AudioSender::default();
        let (legacy, id) = session(0);
        assert!(crate::audio::wanted_session(&legacy).is_none());
        assert!(sender.prepare(packet(id, 100), &legacy, 7, 100).is_none());
        let (shared, id) = session(FEATURE_WANTS_AUDIO);
        assert_eq!(crate::audio::wanted_session(&shared), Some(id));
        shared.audio_enabled.store(false, Ordering::SeqCst);
        assert!(sender.prepare(packet(id, 100), &shared, 7, 100).is_none());
        shared.audio_enabled.store(true, Ordering::SeqCst);
        assert!(sender
            .prepare(packet(id + 1, 100), &shared, 7, 100)
            .is_none());
        let (_, bytes) = sender.prepare(packet(id, 100), &shared, 7, 100).unwrap();
        assert!(AudioHeader::decode(&bytes).unwrap().0.discontinuity);
        sender.last_stream = Some((id, 7));
        assert!(
            !AudioHeader::decode(&sender.prepare(packet(id, 100), &shared, 7, 100).unwrap().1)
                .unwrap()
                .0
                .discontinuity
        );
        assert!(
            AudioHeader::decode(&sender.prepare(packet(id, 100), &shared, 8, 100).unwrap().1)
                .unwrap()
                .0
                .discontinuity
        );
        assert!(sender
            .prepare(packet(id, 100), &shared, 7, 100_101)
            .is_none());
        assert!(
            AudioHeader::decode(
                &sender
                    .prepare(packet(id, 100_101), &shared, 7, 100_101)
                    .unwrap()
                    .1
            )
            .unwrap()
            .0
            .discontinuity
        );
    }
}
