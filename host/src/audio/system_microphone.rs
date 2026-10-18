//! Optional USB microphone output for ordinary Windows recording applications.
//!
//! This sink has its own short queue and audio thread. A missing virtual device
//! never interrupts the authenticated UDP sink, USB video, input, or playback.

use std::collections::VecDeque;
use std::io;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use parking_lot::Mutex;

#[cfg(windows)]
#[path = "system_microphone_windows.rs"]
mod platform;

const INPUT_SAMPLES: usize = 320;
const INPUT_BYTES: usize = INPUT_SAMPLES * 2;
const OUTPUT_FRAMES: usize = INPUT_SAMPLES * 3;
const OUTPUT_CHANNELS: usize = 2;
const QUEUE_FRAMES: usize = 3;
const MAX_FRAME_AGE: Duration = Duration::from_millis(60);

struct PcmFrame {
    received_at: Instant,
    samples: [i16; INPUT_SAMPLES],
}

struct FrameQueue {
    closed: AtomicBool,
    frames: Mutex<VecDeque<PcmFrame>>,
}

impl FrameQueue {
    fn new() -> Self {
        Self {
            closed: AtomicBool::new(false),
            frames: Mutex::new(VecDeque::with_capacity(QUEUE_FRAMES)),
        }
    }

    fn push_at(&self, pcm: &[u8], received_at: Instant) -> bool {
        if pcm.len() != INPUT_BYTES || self.closed.load(Ordering::Acquire) {
            return false;
        }
        // Never wait for the audio worker on the USB transport thread.
        let Some(mut frames) = self.frames.try_lock() else {
            return false;
        };
        if self.closed.load(Ordering::Acquire) {
            return false;
        }
        let mut samples = [0i16; INPUT_SAMPLES];
        for (sample, bytes) in samples.iter_mut().zip(pcm.chunks_exact(2)) {
            *sample = i16::from_le_bytes([bytes[0], bytes[1]]);
        }
        if frames.len() == QUEUE_FRAMES {
            frames.pop_front();
        }
        frames.push_back(PcmFrame { received_at, samples });
        true
    }

    fn pop_at(&self, now: Instant) -> Option<PcmFrame> {
        if self.closed.load(Ordering::Acquire) {
            return None;
        }
        let mut frames = self.frames.try_lock()?;
        while let Some(frame) = frames.pop_front() {
            if now.saturating_duration_since(frame.received_at) <= MAX_FRAME_AGE {
                return Some(frame);
            }
        }
        None
    }

    fn close(&self) {
        self.closed.store(true, Ordering::Release);
        if let Some(mut frames) = self.frames.try_lock() {
            frames.clear();
        }
    }
}

/// A session-scoped, best-effort sink. `push` accepts exactly one authenticated
/// 20 ms, 16 kHz, mono PCM16 frame and never blocks the USB task.
pub struct SystemMicrophone {
    queue: Arc<FrameQueue>,
}

impl SystemMicrophone {
    pub fn new() -> io::Result<Self> {
        #[cfg(not(windows))]
        {
            Err(io::Error::new(io::ErrorKind::Unsupported, "System microphone output requires Windows"))
        }
        #[cfg(windows)]
        {
            let queue = Arc::new(FrameQueue::new());
            let worker_queue = Arc::clone(&queue);
            std::thread::Builder::new()
                .name("system-microphone".into())
                .spawn(move || {
                    if let Err(error) = platform::run(&worker_queue) {
                        tracing::warn!(%error, "Windows USB microphone output unavailable; other streams remain active");
                    }
                    worker_queue.close();
                })?;
            Ok(Self { queue })
        }
    }

    pub fn push(&self, pcm: &[u8]) -> bool {
        self.queue.push_at(pcm, Instant::now())
    }

    pub fn is_active(&self) -> bool {
        !self.queue.closed.load(Ordering::Acquire)
    }
}

impl Drop for SystemMicrophone {
    fn drop(&mut self) {
        self.queue.close();
        // WASAPI waits are capped at 10 ms. Do not join a driver/COM call on
        // the transport thread: the worker stops and releases its own COM
        // interfaces after observing this flag, including during startup.
    }
}

/// Continuous linear 3:1 interpolation, including across packet boundaries.
/// The endpoint gain protection is applied later, when writing WASAPI PCM.
#[derive(Default)]
struct Upsampler {
    previous: Option<f32>,
}

impl Upsampler {
    fn convert(&mut self, input: &[i16; INPUT_SAMPLES]) -> [f32; OUTPUT_FRAMES * OUTPUT_CHANNELS] {
        let mut output = [0f32; OUTPUT_FRAMES * OUTPUT_CHANNELS];
        for (index, sample) in input.iter().enumerate() {
            let current = f32::from(*sample) / 32768.0;
            let previous = self.previous.unwrap_or(current);
            for phase in 0..3 {
                let interpolated = previous + (current - previous) * ((phase + 1) as f32 / 3.0);
                let offset = (index * 3 + phase) * OUTPUT_CHANNELS;
                output[offset] = interpolated;
                output[offset + 1] = interpolated;
            }
            self.previous = Some(current);
        }
        output
    }

    fn silence(&mut self) {
        self.previous = Some(0.0);
    }
}

/// Compensate only a positive aggregate endpoint gain. This prevents the
/// Steam microphone's +30 dB default recording level from clipping ordinary
/// iPad PCM without changing any Windows volume/mute setting or boosting it.
fn protective_attenuation(render_db: f32, capture_db: f32) -> f32 {
    if !render_db.is_finite() || !capture_db.is_finite() {
        return 0.0;
    }
    10f32.powf(-(render_db + capture_db).max(0.0) / 20.0).clamp(0.0, 1.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pcm(value: i16) -> Vec<u8> {
        value.to_le_bytes().repeat(INPUT_SAMPLES)
    }

    #[test]
    fn queue_keeps_only_the_latest_three_complete_frames() {
        let queue = FrameQueue::new();
        let now = Instant::now();
        for value in 1..=8 { assert!(queue.push_at(&pcm(value), now)); }
        assert_eq!(queue.frames.lock().len(), 3);
        for expected in [6, 7, 8] {
            assert_eq!(queue.pop_at(now).unwrap().samples[0], expected);
        }
        assert!(queue.pop_at(now).is_none());
    }

    #[test]
    fn stale_frames_and_closed_sessions_never_replay() {
        let queue = FrameQueue::new();
        let now = Instant::now();
        assert!(queue.push_at(&pcm(123), now));
        assert!(queue.pop_at(now + MAX_FRAME_AGE + Duration::from_millis(1)).is_none());
        assert!(queue.push_at(&pcm(456), now));
        queue.close();
        assert!(!queue.push_at(&pcm(789), now));
        assert!(queue.pop_at(now).is_none());
    }

    #[test]
    fn malformed_pcm_and_contended_queue_do_not_block_or_enter_the_sink() {
        let queue = FrameQueue::new();
        let now = Instant::now();
        assert!(!queue.push_at(&[0; INPUT_BYTES - 1], now));
        assert!(!queue.push_at(&[0; INPUT_BYTES + 1], now));
        let _lock = queue.frames.lock();
        assert!(!queue.push_at(&pcm(1), now));
    }

    #[test]
    fn pcm_conversion_preserves_signed_level_stereo_and_packet_continuity() {
        let mut up = Upsampler::default();
        let first = up.convert(&[16384; INPUT_SAMPLES]);
        assert_eq!(first.len(), 1920);
        assert!(first.iter().all(|sample| *sample == 0.5));
        let second = up.convert(&[-16384; INPUT_SAMPLES]);
        assert!((second[0] - (0.5 - 1.0 / 3.0)).abs() < 1e-6);
        assert_eq!(second[0], second[1]);
        assert_eq!(second[4], -0.5);
        assert_eq!(second[5], -0.5);
        let silence = up.convert(&[0; INPUT_SAMPLES]);
        assert_eq!(*silence.last().unwrap(), 0.0);
    }

    #[test]
    fn gain_protection_cancels_the_measured_thirty_db_without_boosting() {
        let attenuation = protective_attenuation(0.0, 30.0);
        assert!((attenuation - 0.031622775).abs() < 1e-7);
        assert!((0.06 * attenuation * 10f32.powf(30.0 / 20.0) - 0.06).abs() < 1e-7);
        assert_eq!(protective_attenuation(-20.0, 0.0), 1.0);
        assert_eq!(protective_attenuation(f32::NAN, 30.0), 0.0);
    }
}
