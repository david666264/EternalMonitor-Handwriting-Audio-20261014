//! Explicit, synthetic-only smoke test for the production Windows mic sink.
//!
//! Run with `cargo run -p eternal-host --example system_microphone_probe`.
//! This example never opens a recording endpoint or saves audio. It feeds the
//! same public sink used by authenticated USB microphone packets; a separate
//! in-memory capture tool can measure frequency, level, and silence after Drop.

use eternal_host::audio::system_microphone::SystemMicrophone;
use std::error::Error;
use std::io;
use std::thread;
use std::time::{Duration, Instant};

const RATE: usize = 16_000;
const SAMPLES: usize = 320;
const PERIOD: Duration = Duration::from_millis(20);
const WARMUP_PACKETS: usize = 40;
const TONE_PACKETS: usize = 100;
const FREQUENCY: f64 = 997.0;
const PEAK: f64 = 0.06;

fn unavailable() -> io::Error {
    io::Error::new(io::ErrorKind::NotConnected, "The system microphone sink stopped")
}

fn pace(deadline: &mut Instant) {
    *deadline += PERIOD;
    let now = Instant::now();
    if *deadline > now {
        thread::sleep(*deadline - now);
    } else {
        // A delayed machine must not burst old audio into the bounded queue.
        *deadline = now;
    }
}

fn main() -> Result<(), Box<dyn Error>> {
    let _ = tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_max_level(tracing::Level::INFO)
        .try_init();
    let started = Instant::now();
    let sink = SystemMicrophone::new()?;
    let mut deadline = Instant::now();
    let silence = [0u8; SAMPLES * 2];
    let mut warmup_rejected = 0;

    println!("{}", serde_json::json!({
        "event": "warmup", "sample_rate": RATE, "channels": 1,
        "samples_per_packet": SAMPLES, "duration_ms": WARMUP_PACKETS * 20
    }));
    for _ in 0..WARMUP_PACKETS {
        if !sink.is_active() { return Err(unavailable().into()); }
        if !sink.push(&silence) { warmup_rejected += 1; }
        pace(&mut deadline);
    }
    if !sink.is_active() { return Err(unavailable().into()); }

    println!("{}", serde_json::json!({
        "event": "tone", "frequency_hz": FREQUENCY, "source_peak": PEAK,
        "duration_ms": TONE_PACKETS * 20, "elapsed_ms": started.elapsed().as_millis()
    }));
    let mut rejected = 0;
    for packet in 0..TONE_PACKETS {
        if !sink.is_active() { return Err(unavailable().into()); }
        let mut pcm = [0u8; SAMPLES * 2];
        for sample in 0..SAMPLES {
            let index = packet * SAMPLES + sample;
            let phase = std::f64::consts::TAU * FREQUENCY * index as f64 / RATE as f64;
            let value = (phase.sin() * PEAK * 32767.0).round() as i16;
            pcm[sample * 2..sample * 2 + 2].copy_from_slice(&value.to_le_bytes());
        }
        if !sink.push(&pcm) { rejected += 1; }
        pace(&mut deadline);
    }
    if !sink.is_active() { return Err(unavailable().into()); }
    drop(sink);
    println!("{}", serde_json::json!({
        "event": "dropped", "elapsed_ms": started.elapsed().as_millis(),
        "tone_packets": TONE_PACKETS, "tone_rejected": rejected,
        "warmup_rejected": warmup_rejected
    }));
    // Keep the process alive while the worker observes Drop and releases
    // WASAPI; this also leaves a measurable post-Drop interval for the probe.
    thread::sleep(Duration::from_millis(300));
    if rejected != 0 {
        return Err(io::Error::new(io::ErrorKind::WouldBlock,
                                 "The synthetic source encountered rejected tone packets").into());
    }
    println!("{}", serde_json::json!({
        "event": "complete", "success": true, "elapsed_ms": started.elapsed().as_millis()
    }));
    Ok(())
}
