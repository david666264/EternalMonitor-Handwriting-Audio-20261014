//! Stream: is it working, and how does an iPad connect?

use eframe::egui::{self, vec2, Align, Layout, RichText, Sense, Ui};

use super::icons::Icon;
use super::theme::*;
use super::widgets::{self, Tone, GAP};
use super::{
    friendly_codec, value_or_unknown, AnalyzerApp, ClientSnapshot, Copied, StatsSnapshot,
    StreamState, CAPTURE_AUTO_LABEL, CAPTURE_VIRTUAL_LABEL, CAPTURE_VIRTUAL_SENTINEL,
};
use crate::control::VddStatus;

impl AnalyzerApp {
    pub(super) fn stream_page(
        &mut self,
        ui: &mut Ui,
        snap: &StatsSnapshot,
        client: &ClientSnapshot,
    ) {
        self.notices(ui, snap);
        self.status_header(ui, snap, client);
        ui.add_space(GAP - 10.0);
        let wide = ui.available_width() >= 640.0;
        if wide {
            ui.columns(2, |cols| {
                let (left, right) = cols.split_at_mut(1);
                widgets::card_pair(
                    &mut left[0],
                    &mut right[0],
                    |ui| self.connect_card(ui, snap),
                    |ui| client_card(ui, client, snap.pipeline_running),
                );
            });
        } else {
            widgets::card().show(ui, |ui| {
                ui.set_width(ui.available_width());
                self.connect_card(ui, snap);
            });
            ui.add_space(GAP - 10.0);
            widgets::card().show(ui, |ui| {
                ui.set_width(ui.available_width());
                client_card(ui, client, snap.pipeline_running);
            });
        }
        ui.add_space(GAP - 10.0);
        self.status_rows(ui, snap);
    }

    /// Update, restart and fault notices, most urgent first.
    fn notices(&mut self, ui: &mut Ui, snap: &StatsSnapshot) {
        if let Some((title, body)) = usb_cable_notice(
            snap.usb_service_reachable,
            snap.usb_cabled_devices,
            snap.apple_devices_installed,
        ) {
            widgets::banner(ui, WARNING, Icon::Plug, title, body, 170.0, |ui| {
                apple_devices_action(ui, snap.apple_devices_installed);
            });
            ui.add_space(GAP - 10.0);
        }
        if snap.using_software_fallback {
            widgets::banner(
                ui,
                WARNING,
                Icon::Warning,
                "硬件编码器不可用，正在使用 CPU 编码（libx264）。",
                "延迟和 CPU 占用可能升高。请更新 NVIDIA、AMD 或 Intel 显卡驱动，再重启连接。",
                0.0,
                |_| {},
            );
            ui.add_space(GAP - 10.0);
        }
        // The user asked for the extended (virtual) display but it could not be brought up,
        // so capture silently fell back to the primary monitor. Say so.
        let vdd_status = *self.control.shared.vdd_status.lock();
        if matches!(vdd_status, VddStatus::Failed | VddStatus::TaskFailed) {
            let body = if vdd_status == VddStatus::TaskFailed {
                "显示器任务无法运行。请重新安装 EternalMonitor-Setup.exe 修复权限，再重启连接。复制日志可查看 Windows 错误。"
            } else {
                "显示器任务已运行，但显示器未及时出现。请检查 Windows 显示设置和驱动，再重启连接。"
            };
            let mut copy_logs = false;
            widgets::banner(
                ui,
                WARNING,
                Icon::Warning,
                "扩展显示器不可用，已改为镜像主屏。",
                body,
                110.0,
                |ui| {
                    copy_logs = widgets::button(ui, Tone::Secondary, Some(Icon::Logs), "复制日志")
                        .clicked();
                },
            );
            if copy_logs {
                if let Some(text) = crate::logging::session_log_text() {
                    self.copy(ui.ctx(), Copied::Logs, text);
                }
            }
            ui.add_space(GAP - 10.0);
        }
        self.restart_notice(ui);
        if self.settings_check_updates && !self.update_dismissed {
            let update = self.available_update.lock().clone();
            if let Some(version) = update {
                let mut dismiss = false;
                widgets::banner(
                    ui,
                    ACCENT,
                    Icon::Download,
                    &format!("EternalMonitor v{version} 已发布"),
                    "请同时更新电脑端和 iPad 端，两端需要使用相同版本。",
                    210.0,
                    |ui| {
                        dismiss = widgets::button(ui, Tone::Ghost, None, "忽略").clicked();
                        widgets::link(
                            ui,
                            "查看版本",
                            &format!(
                                "https://github.com/whoisaldo/EternalMonitor/releases/tag/v{version}"
                            ),
                        );
                    },
                );
                if dismiss {
                    self.update_dismissed = true;
                }
                ui.add_space(GAP - 10.0);
            }
        }
    }

    pub(super) fn restart_notice(&mut self, ui: &mut Ui) {
        if !self.restart_pending {
            return;
        }
        let mut restart = false;
        widgets::banner(
            ui,
            ACCENT,
            Icon::Refresh,
            "重启连接以应用更改",
            "显示器和编码器更改会在重启连接后生效，iPad 会自动重新连接。",
            140.0,
            |ui| {
                restart = widgets::button(ui, Tone::Primary, None, "立即重启").clicked();
            },
        );
        if restart {
            self.restart_stream();
        }
        ui.add_space(GAP - 10.0);
    }

    fn status_header(&mut self, ui: &mut Ui, snap: &StatsSnapshot, client: &ClientSnapshot) {
        let state = StreamState::of(snap, client);
        let device = client
            .info
            .as_ref()
            .map(|i| i.device_name.clone())
            .unwrap_or_default();
        let (title, subtitle) = match state {
            StreamState::Off => (
                "连接已停止".to_string(),
                "开始连接后，iPad 即可接入。".to_string(),
            ),
            StreamState::Ready => (
                "等待 iPad 连接".to_string(),
                "在 iPad 上打开 EternalMonitor 并选择这台电脑。".to_string(),
            ),
            StreamState::Streaming => {
                let (w, h) = snap.capture_resolution;
                let mut parts = vec![client.link_name().to_string()];
                if w > 0 && h > 0 {
                    parts.push(format!("{w} × {h}"));
                }
                parts.push(format!("{} fps", self.control.shared.effective_fps()));
                parts.push(friendly_codec(&snap.codec_name));
                (format!("正在连接 {device}"), parts.join("  ·  "))
            }
        };

        widgets::card().show(ui, |ui| {
            ui.set_width(ui.available_width());
            let width = ui.available_width();
            let mut action = None;
            ui.allocate_ui_with_layout(
                vec2(width, 48.0),
                Layout::left_to_right(Align::Center),
                |ui| {
                    ui.spacing_mut().item_spacing.x = 14.0;
                    let (glyph, _) = ui.allocate_exact_size(vec2(44.0, 44.0), Sense::hover());
                    let color = state.color();
                    ui.painter().circle(
                        glyph.center(),
                        22.0,
                        mix(
                            SURFACE,
                            color,
                            if state == StreamState::Off { 6 } else { 10 },
                        ),
                        egui::Stroke::new(1.0, mix(SURFACE, color, 24)),
                    );
                    widgets::status_dot(ui, glyph.center(), color, 6.0, state.dot());

                    let buttons_width = if state == StreamState::Off {
                        170.0
                    } else {
                        210.0
                    };
                    let text_width = (ui.available_width() - buttons_width).max(160.0);
                    ui.allocate_ui_with_layout(
                        vec2(text_width, 48.0),
                        Layout::top_down(Align::Min),
                        |ui| {
                            ui.spacing_mut().item_spacing.y = 2.0;
                            ui.add_space(3.0);
                            ui.add(
                                egui::Label::new(
                                    RichText::new(title)
                                        .family(semibold())
                                        .size(18.0)
                                        .color(TEXT),
                                )
                                .truncate(),
                            );
                            ui.add(egui::Label::new(muted(subtitle)).truncate());
                        },
                    );
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        if snap.pipeline_running {
                            if widgets::button(ui, Tone::Danger, Some(Icon::Stop), "停止").clicked()
                            {
                                action = Some(HeaderAction::Stop);
                            }
                            if widgets::button(ui, Tone::Secondary, Some(Icon::Refresh), "重启")
                                .on_hover_text(
                                    "重新启动采集和编码，iPad 会自动重新连接。",
                                )
                                .clicked()
                            {
                                action = Some(HeaderAction::Restart);
                            }
                        } else if widgets::button(
                            ui,
                            Tone::Primary,
                            Some(Icon::Play),
                            "开始连接",
                        )
                        .clicked()
                        {
                            action = Some(HeaderAction::Start);
                        }
                    });
                },
            );

            if state == StreamState::Streaming {
                ui.add_space(14.0);
                widgets::divider(ui);
                ui.add_space(14.0);
                let latency = client
                    .report
                    .as_ref()
                    .filter(|r| r.e2e_latency_ms_x10 > 0)
                    .map(|r| format!("{:.0}", f64::from(r.e2e_latency_ms_x10) / 10.0))
                    .unwrap_or_else(|| format!("{:.0}", snap.latency_ms));
                ui.columns(4, |cols| {
                    widgets::metric(
                        &mut cols[0],
                        "帧率",
                        &format!("{:.0}", snap.capture_fps),
                        "fps",
                        22.0,
                    )
                    .on_hover_text("这台电脑每秒采集的画面帧数。");
                    widgets::metric(&mut cols[1], "延迟", &latency, "ms", 22.0)
                        .on_hover_text("从电脑采集画面到 iPad 显示画面的时间。");
                    widgets::metric(
                        &mut cols[2],
                        "码率",
                        &format!("{:.1}", snap.bandwidth_mbps),
                        "Mbps",
                        22.0,
                    )
                    .on_hover_text("每秒发送到 iPad 的视频数据量，会随网络状况调整。");
                    widgets::metric(
                        &mut cols[3],
                        "编码耗时",
                        &format!("{:.1}", snap.encode_time_us as f64 / 1000.0),
                        "ms",
                        22.0,
                    )
                    .on_hover_text("编码器压缩每帧画面所需的时间。");
                });
            }

            match action {
                Some(HeaderAction::Stop) => self.control.request_stop(),
                Some(HeaderAction::Start) => self.control.request_start(),
                Some(HeaderAction::Restart) => self.restart_stream(),
                None => {}
            }
        });
    }

    fn connect_card(&mut self, ui: &mut Ui, snap: &StatsSnapshot) {
        // detect_local_ip() reports "unknown:<port>" when no LAN adapter is up.
        let online = !snap.listen_addr.is_empty() && !snap.listen_addr.starts_with("unknown");
        let mut open_qr = false;
        widgets::card_header(ui, "连接 iPad", |ui| {
            open_qr =
                widgets::button_ex(ui, Tone::Secondary, Some(Icon::Qr), "二维码", online, 0.0)
                    .clicked();
        });
        widgets::paragraph(
            ui,
            muted("在 iPad 上打开 EternalMonitor 并选择这台电脑，或点击扫码。USB 连接会自动配对。"),
        );
        ui.add_space(8.0);

        let (code, pairing_required) = {
            let pairing = self.control.shared.pairing.lock();
            (format!("{:06}", pairing.code()), pairing.required)
        };
        let code = format!("{} {}", &code[..3], &code[3..]);
        let mut copy = false;
        let mut rotate = false;
        let copied = self.recently_copied(Copied::Address);
        if online {
            value_block(ui, "地址", &snap.listen_addr, |ui| {
                let (icon, tip) = if copied {
                    (Icon::Check, "已复制")
                } else {
                    (Icon::Copy, "复制地址")
                };
                copy = widgets::icon_button(ui, icon, tip).clicked();
            });
        } else {
            ui.label(overline("地址"));
            widgets::paragraph(
                ui,
                RichText::new(
                    "未找到网络。请让电脑连接 Wi-Fi 或以太网，或使用 USB 数据线。",
                )
                .size(SMALL)
                .color(WARNING),
            );
        }
        ui.add_space(4.0);
        if pairing_required {
            value_block(ui, "配对码", &code, |ui| {
                rotate = widgets::icon_button(ui, Icon::Refresh, "生成新码").clicked();
            });
        } else {
            ui.label(overline("配对码"));
            ui.label(muted("关闭配对时无需配对码。"));
        }
        if copy && online {
            self.copy(ui.ctx(), Copied::Address, snap.listen_addr.clone());
        }
        if rotate {
            self.new_pairing_code();
        }
        if open_qr {
            self.open_qr(snap);
        }
        if let Some(error) = &self.settings_error {
            ui.add(egui::Label::new(RichText::new(error).size(SMALL).color(DANGER)).wrap());
        }
    }

    fn status_rows(&mut self, ui: &mut Ui, snap: &StatsSnapshot) {
        widgets::list_card().show(ui, |ui| {
            ui.set_width(ui.available_width());

            // Pairing
            let required = self.control.shared.pairing.lock().required;
            let mut require = required;
            widgets::icon_row(
                ui,
                Icon::Lock,
                if required { ACCENT } else { TEXT_MUTED },
                "配对",
                if required {
                    "新 iPad 通过 Wi-Fi 连接时只需输入一次配对码，USB 连接无需配对码。"
                } else {
                    "已关闭，同一网络内的任何 iPad 均可免码连接。"
                },
                64.0,
                |ui| {
                    widgets::toggle(ui, &mut require, "要求配对");
                },
            );
            if require != required {
                self.set_require_pairing(require);
            }
            widgets::divider(ui);

            // USB
            let usb = usb_summary(
                snap.usb_service_reachable,
                snap.usb_devices,
                &snap.usb_link_state,
                snap.usb_cabled_devices,
                snap.apple_devices_installed,
            );
            let usb_color = if usb.available { ACCENT } else { TEXT_MUTED };
            let (usb_text, usb_badge) = (usb.text, usb.badge);
            widgets::icon_row(
                ui,
                Icon::Plug,
                usb_color,
                "USB 连接",
                &usb_text,
                if snap.usb_service_reachable {
                    110.0
                } else {
                    170.0
                },
                |ui| {
                    if snap.usb_service_reachable {
                        widgets::badge(ui, usb_badge, usb_color);
                    } else {
                        apple_devices_action(ui, snap.apple_devices_installed);
                    }
                },
            );
            widgets::divider(ui);

            // Audio
            let enabled = self
                .control
                .shared
                .audio_enabled
                .load(std::sync::atomic::Ordering::SeqCst);
            let mut audio_on = enabled;
            let (audio_text, audio_color) = audio_summary(&snap.audio, enabled);
            widgets::icon_row(
                ui,
                Icon::Speaker,
                audio_color,
                "电脑声音",
                &audio_text,
                64.0,
                |ui| {
                    widgets::toggle(ui, &mut audio_on, "传输电脑声音");
                },
            );
            if audio_on != enabled {
                self.set_stream_audio(audio_on);
            }
            widgets::divider(ui);

            // Display
            let description = match self.settings_capture_display.as_str() {
                "" => "将主屏画面镜像到 iPad。".to_string(),
                s if s == CAPTURE_VIRTUAL_SENTINEL => match *self.control.shared.vdd_status.lock() {
                    VddStatus::Active => {
                        "扩展显示器已开启，将窗口拖过主屏边缘即可移入。"
                            .to_string()
                    }
                    VddStatus::Failed | VddStatus::TaskFailed => {
                        "扩展显示器未能启动，已改为镜像主屏。"
                            .to_string()
                    }
                    _ => "为 iPad 添加第二块显示器，在 iPad 连接后出现。"
                        .to_string(),
                },
                name => format!("镜像 {}。", name.rsplit('\\').next().unwrap_or(name)),
            };
            widgets::icon_row(
                ui,
                Icon::Display,
                TEXT_MUTED,
                "显示器",
                &description,
                250.0,
                |ui| {
                    self.display_picker(ui, 250.0);
                },
            );
        });
    }

    /// Mirror / extend / specific monitor. Shared with Settings.
    pub(super) fn display_picker(&mut self, ui: &mut Ui, width: f32) {
        let outputs = self.available_outputs.clone();
        let current = self.settings_capture_display.clone();
        let selected_text = if current.is_empty() {
            CAPTURE_AUTO_LABEL.to_string()
        } else if current == CAPTURE_VIRTUAL_SENTINEL {
            CAPTURE_VIRTUAL_LABEL.to_string()
        } else if let Some(o) = outputs.iter().find(|o| o.device_name == current) {
            super::format_output_label(o)
        } else {
            format!(
                "{}（未连接）",
                current.rsplit('\\').next().unwrap_or(&current)
            )
        };
        let mut choice = current.clone();
        widgets::combo(ui.id().with("capture-display"), &selected_text, width).show_ui(ui, |ui| {
            ui.set_min_width(width);
            if ui
                .selectable_label(choice.is_empty(), CAPTURE_AUTO_LABEL)
                .clicked()
            {
                choice = String::new();
            }
            // Managed virtual display — created on demand, removed when not in use.
            if ui
                .selectable_label(choice == CAPTURE_VIRTUAL_SENTINEL, CAPTURE_VIRTUAL_LABEL)
                .clicked()
            {
                choice = CAPTURE_VIRTUAL_SENTINEL.to_string();
            }
            if !outputs.is_empty() {
                ui.separator();
            }
            for o in &outputs {
                if ui
                    .selectable_label(choice == o.device_name, super::format_output_label(o))
                    .clicked()
                {
                    choice = o.device_name.clone();
                }
            }
        });
        if choice != current {
            self.set_capture_display(choice);
        }
    }
}

enum HeaderAction {
    Start,
    Stop,
    Restart,
}

/// Overline label, a large monospaced value and trailing controls.
fn value_block(ui: &mut Ui, label: &str, value: &str, controls: impl FnOnce(&mut Ui)) {
    ui.vertical(|ui| {
        ui.spacing_mut().item_spacing.y = 2.0;
        ui.label(overline(label));
        ui.horizontal(|ui| {
            ui.spacing_mut().item_spacing.x = 8.0;
            let max_text = (ui.available_width() - 40.0).max(60.0);
            ui.scope(|ui| {
                ui.set_max_width(max_text);
                ui.add(egui::Label::new(mono(value, 19.0)).truncate());
            });
            controls(ui);
        });
    });
}

fn client_card(ui: &mut Ui, client: &ClientSnapshot, streaming: bool) {
    let link = client.link_name();
    widgets::card_header(ui, "已连接的 iPad", |ui| {
        if client.info.is_some() {
            widgets::badge(ui, link, ACCENT);
        }
    });
    let Some(info) = &client.info else {
        if streaming {
            widgets::empty_state(
                ui,
                Icon::Tablet,
                "等待 iPad 连接",
                "连接后会立即显示在这里。",
            );
        } else {
            widgets::empty_state(
                ui,
                Icon::Tablet,
                "尚未连接 iPad",
                "先开始连接，再从 iPad 接入。",
            );
        }
        return;
    };
    ui.add_space(2.0);
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = 10.0;
        let (rect, _) = ui.allocate_exact_size(vec2(18.0, 36.0), Sense::hover());
        super::icons::paint(
            ui.painter(),
            egui::Rect::from_center_size(rect.center(), vec2(18.0, 18.0)),
            Icon::Tablet,
            TEXT_MUTED,
        );
        ui.vertical(|ui| {
            ui.spacing_mut().item_spacing.y = 1.0;
            ui.add(egui::Label::new(strong(info.device_name.clone())).truncate());
            let (w, h) = info.screen_px;
            ui.label(faint(format!("{w} × {h} · {} Hz", info.refresh_hz)));
        });
    });
    ui.add_space(6.0);
    let Some(r) = client.report.as_ref() else {
        ui.label(muted("等待 iPad 发送首次测量数据。"));
        return;
    };
    let total = f64::from(r.frags_received) + f64::from(r.frags_repaired) + f64::from(r.frags_lost);
    let percent = |part: u32| {
        if total > 0.0 {
            100.0 * f64::from(part) / total
        } else {
            0.0
        }
    };
    let latency = if r.e2e_latency_ms_x10 == 0 {
        "测量中".to_string()
    } else {
        format!("{:.1} ms", f64::from(r.e2e_latency_ms_x10) / 10.0)
    };
    let rows = [
        (
            "往返耗时",
            format!("{:.1} ms", f64::from(r.rtt_ms_x10) / 10.0),
        ),
        ("端到端延迟", latency),
        (
            "解码帧率",
            format!("{:.1} fps", f64::from(r.decode_fps_x10) / 10.0),
        ),
        ("未恢复丢包", format!("{:.2}%", percent(r.frags_lost))),
        (
            "已恢复分片",
            format!("{:.2}%", percent(r.frags_repaired)),
        ),
        ("音频缓冲", format!("{} ms", r.audio_buffer_ms)),
    ];
    ui.columns(2, |cols| {
        for (i, (label, value)) in rows.iter().enumerate() {
            let ui = &mut cols[i % 2];
            ui.spacing_mut().item_spacing.y = 1.0;
            ui.label(RichText::new(*label).size(CAPTION).color(TEXT_FAINT));
            ui.label(mono(value.clone(), 15.0));
            ui.add_space(8.0);
        }
    });
}

pub(super) struct UsbSummary {
    pub text: String,
    pub badge: &'static str,
    pub available: bool,
}

/// Opens Apple Devices when it is installed, otherwise links to its Store page.
fn apple_devices_action(ui: &mut Ui, installed: bool) {
    if installed {
        if widgets::button(ui, Tone::Primary, None, "打开 Apple Devices").clicked() {
            crate::transport::apple_usb::open_apple_devices();
        }
    } else {
        widgets::link(
            ui,
            "获取 Apple Devices",
            crate::transport::apple_usb::APPLE_DEVICES_STORE_URL,
        );
    }
}

/// The Stream page notice for an iPad on the cable that Windows cannot reach
/// because Apple Devices is not running or not installed.
pub(super) fn usb_cable_notice(
    reachable: bool,
    cabled: usize,
    installed: bool,
) -> Option<(&'static str, &'static str)> {
    if reachable || cabled == 0 {
        return None;
    }
    Some(if installed {
        (
            "iPad 已插线，但 Apple Devices 尚未运行",
            "EternalMonitor 通过 Apple Devices 使用 USB 连接 iPad。请打开并保持它运行，可以最小化。Wi-Fi 连接无需运行它。",
        )
    } else {
        (
            "iPad 已插线，但尚未安装 Apple Devices",
            "EternalMonitor 使用 USB 连接需要免费的 Apple Devices 应用。请从 Microsoft Store 安装，打开并保持运行。Wi-Fi 连接无需它。",
        )
    })
}

/// What the USB row says. The Apple Devices hint appears only when Apple's
/// device service cannot be reached.
pub(super) fn usb_summary(
    reachable: bool,
    devices: usize,
    link_state: &str,
    cabled: usize,
    installed: bool,
) -> UsbSummary {
    if !reachable {
        let text = match (cabled > 0, installed) {
            (true, true) => "iPad 已插线。请打开 Apple Devices 并保持运行，以使用有线连接。",
            (true, false) => "iPad 已插线，但尚未安装 Apple Devices。请从 Microsoft Store 获取它以使用 USB。",
            (false, true) => "请打开 Apple Devices 以使用 USB，并在连接期间保持它运行。",
            (false, false) => "请从 Microsoft Store 安装 Apple Devices 应用以使用 USB。",
        };
        return UsbSummary {
            text: text.into(),
            badge: "不可用",
            available: false,
        };
    }
    let (text, badge) = match link_state {
        "Connected" => (
            "iPad 正在通过数据线连接。".to_string(),
            "已连接",
        ),
        "Waiting for the iPad app" => (
            "iPad 已插线，请在 iPad 上打开 EternalMonitor 进行连接。".to_string(),
            "就绪",
        ),
        "Waiting for an iPad" => (
            "请插入 iPad 数据线以通过 USB 连接。".to_string(),
            "就绪",
        ),
        "Checking Apple device service" => (
            "正在检查 Apple 设备服务…".to_string(),
            "检查中",
        ),
        other => {
            let plugged = match devices {
                0 => "未插入 iPad".to_string(),
                1 => "已插入 1 台设备".to_string(),
                n => format!("已插入 {n} 台设备"),
            };
            (format!("{other} · {plugged}"), "就绪")
        }
    };
    UsbSummary {
        text,
        badge,
        available: true,
    }
}

/// What the audio row says, and its tint. An audio failure never claims the
/// video stopped.
pub(super) fn audio_summary(
    audio: &crate::audio::AudioStats,
    enabled: bool,
) -> (String, egui::Color32) {
    if let Some(error) = &audio.error {
        return (
            format!("音频不可用：{error}。画面传输仍继续。请关闭再开启“传输电脑声音”以重试。"),
            WARNING,
        );
    }
    if !enabled {
        return (
            "已关闭，iPad 不会播放这台电脑的声音。".into(),
            TEXT_MUTED,
        );
    }
    if audio.status == "Streaming" {
        let device = if audio.device.is_empty() {
            "电脑声音"
        } else {
            audio.device.as_str()
        };
        return (
            format!(
                "正在传输 {device} · Opus {:.0} kbps · {:.0} 包/秒",
                audio.kbps, audio.packets_per_sec
            ),
            ACCENT,
        );
    }
    // The audio stage's idle status names the protocol, not the device.
    if audio.status == "Waiting for client" {
        return ("iPad 连接后开始传输。".into(), TEXT_MUTED);
    }
    if audio.device.is_empty() {
        (display_audio_status(&audio.status).to_string(), TEXT_MUTED)
    } else {
        (format!("{} · {}", display_audio_status(&audio.status), audio.device), TEXT_MUTED)
    }
}

// Translate presentation only; engine and transport state keys stay stable.
fn display_audio_status(status: &str) -> &str {
    match status {
        "Stopped" => "已停止",
        "Unavailable" => "不可用",
        "Off" => "已关闭",
        other => value_or_unknown(other),
    }
}
