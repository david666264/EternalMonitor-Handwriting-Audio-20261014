use super::page_stream::{audio_summary, usb_cable_notice, usb_summary};
use super::*;

#[test]
fn audio_row_reports_rate_and_keeps_failure_separate_from_video() {
    let mut audio = crate::audio::AudioStats::started("USB Audio Device");
    audio.kbps = 128.0;
    audio.packets_per_sec = 50.0;

    let (text, color) = audio_summary(&audio, true);
    assert!(text.contains("USB Audio Device"), "{text}");
    assert!(
        text.contains("128 kbps") && text.contains("50 包/秒"),
        "{text}"
    );
    assert_eq!(color, ACCENT);

    audio.stopped("Unavailable");
    audio.error = Some("Output was removed".into());
    let (text, color) = audio_summary(&audio, true);
    assert!(
        text.contains("Output was removed") && text.contains("画面传输仍继续"),
        "{text}"
    );
    assert!(!text.contains("128 kbps"), "{text}");
    assert_eq!(color, WARNING);

    audio.error = None;
    let (text, _) = audio_summary(&audio, false);
    assert!(text.starts_with("已关闭"), "{text}");

    let (text, color) = audio_summary(&crate::audio::AudioStats::default(), true);
    assert_eq!(text, "iPad 连接后开始传输。");
    assert_eq!(color, TEXT_MUTED);
}

#[test]
fn usb_row_shows_install_hint_only_when_the_service_is_unavailable() {
    let missing = usb_summary(false, 2, "Connected", 0, false);
    assert!(!missing.available);
    assert_eq!(missing.badge, "不可用");
    assert!(missing
        .text
        .contains("请从 Microsoft Store 安装 Apple Devices 应用以使用 USB。"));

    let connected = usb_summary(true, 1, "Connected", 0, false);
    assert!(connected.available);
    assert_eq!(connected.badge, "已连接");
    assert!(!connected.text.contains("安装"));

    // "Waiting for an iPad" must never become a whole label: UI Automation
    // reads that exact name as "no iPad connected".
    let idle = usb_summary(true, 0, "Waiting for an iPad", 0, false);
    assert_eq!(idle.badge, "就绪");
    assert_ne!(idle.text, "等待 iPad 连接");
    assert!(idle.text.contains("请插入 iPad 数据线"), "{}", idle.text);

    let app_closed = usb_summary(true, 1, "Waiting for the iPad app", 0, false);
    assert!(
        app_closed.text.contains("打开 EternalMonitor"),
        "{}",
        app_closed.text
    );

    let unknown = usb_summary(true, 2, "Waiting for direct test listener", 0, false);
    assert_eq!(
        unknown.text,
        "Waiting for direct test listener · 已插入 2 台设备"
    );
}

#[test]
fn usb_row_says_to_open_or_install_apple_devices() {
    let closed = usb_summary(false, 0, "Apple device service unavailable", 0, true);
    assert!(!closed.available);
    assert!(
        closed.text.starts_with("请打开 Apple Devices"),
        "{}",
        closed.text
    );

    let plugged_closed = usb_summary(false, 0, "Apple device service unavailable", 1, true);
    assert!(
        plugged_closed
            .text
            .contains("iPad 已插线。请打开 Apple Devices"),
        "{}",
        plugged_closed.text
    );

    let plugged_missing = usb_summary(false, 0, "Apple device service unavailable", 1, false);
    assert!(
        plugged_missing.text.contains("尚未安装")
            && plugged_missing.text.contains("Microsoft Store"),
        "{}",
        plugged_missing.text
    );
}

#[test]
fn cable_notice_appears_only_for_a_plugged_in_ipad_without_the_service() {
    assert_eq!(usb_cable_notice(true, 1, true), None);
    assert_eq!(usb_cable_notice(false, 0, false), None);

    let (title, body) = usb_cable_notice(false, 1, true).unwrap();
    assert!(title.contains("Apple Devices 尚未运行"), "{title}");
    assert!(body.contains("保持它运行"), "{body}");

    let (title, body) = usb_cable_notice(false, 2, false).unwrap();
    assert!(title.contains("尚未安装 Apple Devices"), "{title}");
    assert!(body.contains("Microsoft Store"), "{body}");
}

#[test]
fn codec_names_read_as_codec_and_engine() {
    assert_eq!(friendly_codec("h264_nvenc"), "H.264 · NVENC");
    assert_eq!(friendly_codec("hevc_amf"), "HEVC · AMF");
    assert_eq!(friendly_codec("h264_qsv"), "H.264 · Quick Sync");
    assert_eq!(friendly_codec("libx264"), "H.264 · CPU");
    assert_eq!(friendly_codec("libx265"), "HEVC · CPU");
    assert_eq!(friendly_codec("h264_videotoolbox"), "H.264 · VideoToolbox");
    assert_eq!(friendly_codec(""), "正在检测编码器");
    assert_eq!(friendly_codec("mystery"), "mystery");
}

#[test]
fn uptime_switches_to_hours_after_an_hour() {
    assert_eq!(format_uptime(0.0), "0m 00s");
    assert_eq!(format_uptime(75.4), "1m 15s");
    assert_eq!(format_uptime(3.0 * 3600.0 + 125.0), "3h 02m");
}

#[test]
fn state_colors_mix_toward_the_accent() {
    assert_eq!(mix(SURFACE, ACCENT, 0), SURFACE);
    assert_eq!(mix(SURFACE, ACCENT, 100), ACCENT);
    let halfway = mix(Color32::BLACK, Color32::WHITE, 50);
    assert_eq!((halfway.r(), halfway.g(), halfway.b()), (128, 128, 128));
}

#[test]
fn chart_steps_are_round_numbers() {
    for (value, step) in [
        (0.3, 0.5),
        (0.75, 1.0),
        (1.2, 2.0),
        (2.1, 2.5),
        (3.0, 5.0),
        (7.0, 10.0),
        (12.0, 20.0),
        (15.0, 20.0),
        (26.0, 50.0),
    ] {
        let got = widgets::nice_step(value);
        assert!((got - step).abs() < 1e-4, "{value} -> {got}, want {step}");
    }
}
