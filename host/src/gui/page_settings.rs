//! Settings, grouped by what they change.

use eframe::egui::{self, pos2, vec2, Align, Color32, Layout, Rect, RichText, Sense, Ui};

use super::page_performance::page_header;
use super::theme::*;
use super::widgets::{self, Tone, GAP};
use super::{AnalyzerApp, StatsSnapshot, CAPTURE_VIRTUAL_SENTINEL, ENCODER_CHOICES};
use crate::encoder::input::EncoderInput;

impl AnalyzerApp {
    pub(super) fn settings_page(&mut self, ui: &mut Ui, snap: &StatsSnapshot) {
        page_header(ui, "设置", "更改会自动保存。", |_| {});
        self.restart_notice(ui);

        // ── Display ─────────────────────────────────────────────────────────
        widgets::section_label(ui, "显示器");
        widgets::list_card().show(ui, |ui| {
            ui.set_width(ui.available_width());
            let mut refresh = false;
            widgets::setting_row(
                ui,
                "要传输的显示器",
                "镜像已有显示器，或将 Windows 扩展到 iPad；虚拟显示器仅在传输时存在。",
                300.0,
                |ui| {
                    refresh = widgets::icon_button(ui, super::icons::Icon::Refresh, "刷新显示器").clicked();
                    self.display_picker(ui, 250.0);
                },
            );
            if refresh {
                self.refresh_outputs();
            }
            widgets::divider(ui);
            let mut vdd_match = self.settings_vdd_match;
            let extending = self.settings_capture_display == CAPTURE_VIRTUAL_SENTINEL;
            widgets::setting_row(
                ui,
                "匹配 iPad 分辨率",
                if extending {
                    "让扩展显示器匹配 iPad 屏幕尺寸和刷新率。"
                } else {
                    "用于扩展模式，让虚拟显示器匹配 iPad 屏幕尺寸。"
                },
                64.0,
                |ui| {
                    widgets::toggle(ui, &mut vdd_match, "让扩展显示器匹配 iPad 分辨率");
                },
            );
            if vdd_match != self.settings_vdd_match {
                self.set_vdd_match(vdd_match);
            }
        });
        ui.add_space(GAP - 6.0);

        // ── Video quality ───────────────────────────────────────────────────
        widgets::section_label(ui, "画面质量");
        widgets::list_card().show(ui, |ui| {
            ui.set_width(ui.available_width());
            let mut fps = self.settings_fps_target;
            widgets::setting_row(
                ui,
                "帧率",
                "iPad 可以请求更低帧率。帧率越高越流畅，也会占用更多带宽。",
                230.0,
                |ui| {
                    widgets::segmented(ui, &mut fps, &[(30, "30"), (60, "60"), (90, "90"), (120, "120")]);
                },
            );
            self.set_fps(fps);
            widgets::divider(ui);

            let mut bitrate = self.settings_bitrate_mbps;
            widgets::setting_row(
                ui,
                "最高码率",
                "网络繁忙时，传输码率会在此上限内自动调整。",
                290.0,
                |ui| {
                    ui.add_sized(
                        vec2(64.0, 24.0),
                        egui::Label::new(mono(format!("{bitrate:.0} Mbps"), 13.0)),
                    );
                    widgets::slider(ui, &mut bitrate, 4.0..=50.0, 1.0, 210.0, "最高码率");
                },
            );
            if bitrate != self.settings_bitrate_mbps {
                self.set_bitrate_mbps(bitrate);
            }
            widgets::divider(ui);

            let mut hevc = self.settings_hevc_enabled;
            widgets::setting_row(
                ui,
                "优先使用 HEVC (H.265)",
                "实验功能：iPad 支持时，同一码率下画面更清晰。显卡不支持 HEVC 编码时使用 H.264。",
                64.0,
                |ui| {
                    widgets::toggle(ui, &mut hevc, "iPad 支持时优先使用 HEVC (H.265)");
                },
            );
            if hevc != self.settings_hevc_enabled {
                self.set_hevc(hevc);
            }
        });
        ui.add_space(GAP - 6.0);

        // ── Audio ───────────────────────────────────────────────────────────
        widgets::section_label(ui, "声音");
        widgets::list_card().show(ui, |ui| {
            ui.set_width(ui.available_width());
            let enabled = self
                .control
                .shared
                .audio_enabled
                .load(std::sync::atomic::Ordering::SeqCst);
            let mut audio = enabled;
            widgets::setting_row(
                ui,
                "传输电脑声音",
                "在 iPad 上播放电脑声音。声音失败时仍继续传输画面。",
                64.0,
                |ui| {
                    widgets::toggle(ui, &mut audio, "传输电脑声音");
                },
            );
            if audio != enabled {
                self.set_stream_audio(audio);
            }
        });
        ui.add_space(GAP - 6.0);

        // ── Network ─────────────────────────────────────────────────────────
        widgets::section_label(ui, "网络");
        widgets::list_card().show(ui, |ui| {
            ui.set_width(ui.available_width());
            let mut packet = self.settings_packet_size;
            widgets::setting_row(
                ui,
                "数据包大小",
                "通过 Tailscale 或其他 VPN 连接时使用 1200；多数家庭网络适合 1400。",
                150.0,
                |ui| {
                    ui.add(
                        egui::DragValue::new(&mut packet)
                            .range(576..=1400)
                            .speed(4.0)
                            .suffix(" 字节"),
                    );
                },
            );
            if packet != self.settings_packet_size {
                self.set_packet_size(packet);
            }
        });
        ui.add_space(GAP - 6.0);

        // ── Encoder ─────────────────────────────────────────────────────────
        widgets::section_label(ui, "编码器");
        widgets::list_card().show(ui, |ui| {
            ui.set_width(ui.available_width());
            let detected = super::friendly_codec(&snap.codec_name);
            let mut choice = self.settings_encoder_choice.clone();
            widgets::setting_row(
                ui,
                "编码器",
                &format!("自动选择合适的硬件编码器。当前使用：{detected}。"),
                200.0,
                |ui| {
                    widgets::combo("encoder-override", &choice_label(&choice), 190.0).show_ui(
                        ui,
                        |ui| {
                            for (label, _) in ENCODER_CHOICES {
                                if ui
                                    .selectable_label(choice == *label, choice_label(label))
                                    .clicked()
                                {
                                    choice = (*label).to_string();
                                }
                            }
                        },
                    );
                },
            );
            if choice != self.settings_encoder_choice {
                self.set_encoder_choice(&choice);
            }
            widgets::divider(ui);

            let mut input = self.settings_encoder_input;
            widgets::setting_row(
                ui,
                "编码输入格式",
                "交给编码器的像素格式。重启传输后生效。",
                230.0,
                |ui| {
                    widgets::segmented(
                        ui,
                        &mut input,
                        &[
                            (EncoderInput::Auto, "自动"),
                            (EncoderInput::Bgra, "BGRA"),
                            (EncoderInput::Yuv420, "YUV420"),
                        ],
                    );
                },
            );
            if input != self.settings_encoder_input {
                self.set_encoder_input(input);
            }
        });
        ui.add_space(GAP - 6.0);

        // ── Security ────────────────────────────────────────────────────────
        widgets::section_label(ui, "安全");
        widgets::list_card().show(ui, |ui| {
            ui.set_width(ui.available_width());
            let required = self.control.shared.pairing.lock().required;
            let mut require = required;
            widgets::setting_row(
                ui,
                "要求配对",
                "新的 iPad 通过 Wi-Fi 连接时需输入“连接”页显示的配对码。USB 不需要配对码。",
                64.0,
                |ui| {
                    widgets::toggle(ui, &mut require, "要求配对");
                },
            );
            if require != required {
                self.set_require_pairing(require);
            }
            widgets::divider(ui);
            let mut forget = false;
            widgets::setting_row(
                ui,
                "忘记所有 iPad",
                "生成新的配对密钥。所有 iPad 都需要重新配对。",
                170.0,
                |ui| {
                    forget = widgets::button(ui, Tone::Danger, None, "忘记所有 iPad").clicked();
                },
            );
            if forget {
                self.forget_all_ipads();
            }
            if let Some(error) = &self.settings_error {
                ui.add(egui::Label::new(RichText::new(error).size(SMALL).color(DANGER)).wrap());
                ui.add_space(10.0);
            }
        });
        ui.add_space(GAP - 6.0);

        // ── General ─────────────────────────────────────────────────────────
        widgets::section_label(ui, "常规");
        widgets::list_card().show(ui, |ui| {
            ui.set_width(ui.available_width());
            if cfg!(windows) {
                let mut boot = self.settings_start_on_boot;
                widgets::setting_row(
                    ui,
                    "随 Windows 启动",
                    "登录 Windows 时打开 EternalMonitor，方便 iPad 随时连接。",
                    64.0,
                    |ui| {
                        widgets::toggle(ui, &mut boot, "随 Windows 启动");
                    },
                );
                if boot != self.settings_start_on_boot {
                    self.set_start_on_boot(boot);
                }
                widgets::divider(ui);
            }
            let mut updates = self.settings_check_updates;
            widgets::setting_row(
                ui,
                "检查更新",
                "每天向 GitHub 查询一次新版本。",
                64.0,
                |ui| {
                    widgets::toggle(ui, &mut updates, "每天检查更新");
                },
            );
            if updates != self.settings_check_updates {
                self.set_check_updates(updates);
            }
        });
        ui.add_space(GAP - 6.0);

        // ── About ───────────────────────────────────────────────────────────
        widgets::section_label(ui, "关于");
        widgets::card().show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.horizontal(|ui| {
                ui.spacing_mut().item_spacing.x = 14.0;
                let (rect, _) = ui.allocate_exact_size(vec2(44.0, 44.0), Sense::hover());
                if let Some((_, texture)) = &self.logo {
                    ui.painter().image(
                        texture.id(),
                        rect,
                        Rect::from_min_max(pos2(0.0, 0.0), pos2(1.0, 1.0)),
                        Color32::WHITE,
                    );
                }
                ui.vertical(|ui| {
                    ui.spacing_mut().item_spacing.y = 2.0;
                    ui.label(heading("EternalMonitor"));
                    ui.label(muted(format!(
                        "版本 {} · 原作者 Ali Younes (@whoisaldo) · 中文界面",
                        env!("CARGO_PKG_VERSION")
                    )));
                });
            });
            ui.add_space(10.0);
            ui.horizontal_wrapped(|ui| {
                ui.spacing_mut().item_spacing.x = 18.0;
                widgets::link(ui, "github.com/whoisaldo", "https://github.com/whoisaldo");
                widgets::link(ui, "源代码", "https://github.com/whoisaldo/EternalMonitor");
                widgets::link(ui, "aliyounes@eternalreverse.com", "mailto:aliyounes@eternalreverse.com");
            });
            ui.add_space(6.0);
            ui.with_layout(Layout::left_to_right(Align::Min), |ui| {
                ui.add(
                    egui::Label::new(faint(
                        "使用 Vercel 的 Geist 与 Geist Mono 字体（SIL 开放字体许可 1.1）；中文使用本机 Windows 字体。",
                    ))
                    .wrap(),
                );
            });
        });
    }
}

fn choice_label(label: &str) -> String {
    match label {
        "Auto" => "自动选择".into(),
        "NVENC" => "NVIDIA NVENC".into(),
        "AMF" => "AMD AMF".into(),
        "QSV" => "Intel Quick Sync".into(),
        "x264" => "x264 (CPU)".into(),
        other => other.into(),
    }
}
