import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                // Keep Frame Rate, Play PC audio and Allow USB within the first
                // screen of the sheet; UI tests toggle them without scrolling.
                Section {
                    Picker(selection: $settings.targetFPS) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                        Text("120 fps").tag(120)
                    } label: {
                        rowLabel("帧率", "speedometer")
                    }
                    .accessibilityIdentifier("settings.targetFPS")
                    .accessibilityValue("\(settings.targetFPS) fps")

                    Toggle(isOn: $settings.playPCaudio) {
                        rowLabel("播放电脑声音", "speaker.wave.2")
                    }
                    .accessibilityIdentifier("settings.playPCaudio")

                    Toggle(isOn: $settings.showHUD) {
                        rowLabel("显示传输统计", "gauge.with.dots.needle.33percent")
                    }

                    Toggle(isOn: $settings.keepScreenAwake) {
                        rowLabel("保持屏幕常亮", "sun.max")
                    }
                } header: {
                    sectionHeader("画面与声音")
                } footer: {
                    footnote("帧率在下次连接时生效。轻点画面可显示或隐藏控制栏。")
                }
                .listRowBackground(Theme.surfaceRaised)

                Section {
                    Toggle(isOn: $settings.allowUSB) {
                        rowLabel("允许 USB 连接", "cable.connector")
                    }
                    .accessibilityIdentifier("settings.allowUSB")

                    Toggle(isOn: $settings.autoReconnect) {
                        rowLabel("自动重新连接", "arrow.triangle.2.circlepath")
                    }

                    Toggle(isOn: $settings.autoResumeOnForeground) {
                        rowLabel("切回应用后恢复连接", "arrow.uturn.forward")
                    }
                } header: {
                    sectionHeader("连接")
                }
                .listRowBackground(Theme.surfaceRaised)

                Section {
                    Toggle(isOn: $settings.controlPC) {
                        rowLabel("控制电脑", "hand.point.up.left")
                    }
                    Picker(selection: $settings.commandAsControl) {
                        Text("Ctrl").tag(true)
                        Text("Win").tag(false)
                    } label: {
                        rowLabel("⌘ 键映射为", "command")
                    }
                    .accessibilityIdentifier("settings.commandMapping")
                } header: {
                    sectionHeader("触控与键盘")
                } footer: {
                    footnote(
                        "轻点为单击，拖动可移动，双指可滚动，长按为右键。"
                            + "也支持键盘、触控板和 Apple Pencil。此设置在下次连接时生效。"
                            + "开启「控制电脑」后，三指轻点可显示控制栏。先点电脑画面中的文本框，再打开「键盘」；用键盘上的地球键切换中文拼音或手写。若没有中文，请先在 iPad「设置 > 通用 > 键盘」中添加。"
                    )
                }
                .listRowBackground(Theme.surfaceRaised)

                Section {
                    Toggle(isOn: $settings.drawingMode) {
                        rowLabel("画笔模式", "pencil.tip")
                    }
                    .accessibilityIdentifier("settings.drawingMode")
                    .onChange(of: settings.drawingMode) { _, enabled in
                        if enabled { settings.allowUSB = true }
                    }
                    if connectionManager.state == .connected {
                        infoRow("画笔", connectionManager.sessionHasPen ? "Windows Ink 已就绪" : "此主机不支持", "pencil")
                        infoRow("画笔模式", connectionManager.sessionDrawingMode ? "已开启" : "已关闭", "hand.draw")
                    }
                } header: {
                    sectionHeader("Apple Pencil")
                } footer: {
                    footnote("画笔模式会忽略手指在画布上的触碰。手写时仍可播放电脑声音，也可在连接中切换声音。通过 USB 连接时，画笔模式会请求 iPad 的最高帧率，但不超过电脑端设置的上限。画笔模式在下次连接时生效。"
                        + "在 Clip Studio Paint 中请选择「偏好设置 > 数位板 > Tablet PC」。压感需要支持压感的 Apple Pencil；USB-C 版 Apple Pencil 不支持压感。")
                }
                .listRowBackground(Theme.surfaceRaised)

                // Live values from HELLO_ACK, refreshed by heartbeats.
                Section {
                    if let host = connectionManager.hostInfo,
                       let config = connectionManager.hostStreamConfig {
                        infoRow("主机", host.hostName, "desktopcomputer")
                        infoRow(
                            "分辨率",
                            "\(config.width) × \(config.height) · \(config.fps) fps",
                            "rectangle.on.rectangle"
                        )
                        infoRow(
                            "编码格式",
                            config.codec == StreamConfig.codecHEVC ? "HEVC (H.265)" : "H.264",
                            "cpu"
                        )
                        infoRow(
                            "码率",
                            String(format: "%.1f Mbps", Double(config.bitrateBps) / 1_000_000.0),
                            "chart.bar"
                        )
                        infoRow("电脑声音", audioDescription, "speaker.wave.2")
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("电脑声音")
                            .accessibilityValue(audioDescription)
                            .accessibilityIdentifier("settings.hostAudio")
                    } else {
                        infoRow("主机", "未连接", "desktopcomputer")
                    }
                } header: {
                    sectionHeader("已连接的主机")
                } footer: {
                    footnote("分辨率、编码格式和码率请在电脑端 EternalMonitor 中设置。")
                }
                .listRowBackground(Theme.surfaceRaised)

                Section {
                    Button(role: .destructive) {
                        connectionManager.forgetPairedHosts()
                    } label: {
                        Text("忘记已配对的电脑")
                            .font(.app(16, .medium, relativeTo: .body))
                            .foregroundStyle(Theme.danger)
                    }
                    .accessibilityIdentifier("settings.forgetPairings")
                } header: {
                    sectionHeader("配对")
                } footer: {
                    footnote("下次通过 Wi-Fi 连接时，需要重新输入对应电脑的六位配对码。")
                }
                .listRowBackground(Theme.surfaceRaised)

                Section {
                    HStack(spacing: 14) {
                        LogoMark(size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("EternalMonitor")
                                .font(.app(16, .semibold, relativeTo: .headline))
                                .foregroundStyle(Theme.text)
                            Text("版本 \(appVersion)")
                                .font(.app(13, relativeTo: .footnote))
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                    .padding(.vertical, 4)
                    creditLink("开发者", "github.com/whoisaldo", symbol: "person", url: "https://github.com/whoisaldo")
                    creditLink("源代码", "EternalMonitor", symbol: "chevron.left.forwardslash.chevron.right", url: "https://github.com/whoisaldo/EternalMonitor")
                    creditLink("联系开发者", "aliyounes@eternalreverse.com", symbol: "envelope", url: "mailto:aliyounes@eternalreverse.com")
                } header: {
                    sectionHeader("关于")
                } footer: {
                    footnote("由 Ali Younes（@whoisaldo）开发，使用 Geist 字体。")
                }
                .listRowBackground(Theme.surfaceRaised)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.canvas.ignoresSafeArea())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .font(.app(16, .semibold, relativeTo: .body))
                        .foregroundStyle(Theme.accent)
                        .accessibilityIdentifier("settings.done")
                }
            }
            .toolbarBackground(Theme.canvas, for: .navigationBar)
            .tint(Theme.accent)
        }
        .presentationBackground(Theme.canvas)
    }

    private func rowLabel(_ title: String, _ symbol: String) -> some View {
        Label {
            Text(title)
                .font(.app(16, relativeTo: .body))
                .foregroundStyle(Theme.text)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(Theme.textMuted)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.app(12, .medium, relativeTo: .caption))
            .tracking(1.1)
            .foregroundStyle(Theme.textFaint)
    }

    private var audioDescription: String {
        if !settings.playPCaudio { return "已静音" }
        if let error = connectionManager.audioStats.error { return error }
        guard connectionManager.audioStats.playing else { return "暂不可用" }
        return "Opus 128 kbps，缓冲 \(connectionManager.audioStats.targetMs) ms"
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.app(13, relativeTo: .footnote))
            .foregroundStyle(Theme.textFaint)
    }

    private func infoRow(_ title: String, _ value: String, _ symbol: String) -> some View {
        HStack {
            rowLabel(title, symbol)
            Spacer()
            Text(value)
                .font(.app(15, relativeTo: .callout))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private func creditLink(_ title: String, _ value: String, symbol: String, url: String) -> some View {
        if let destination = URL(string: url) {
            Link(destination: destination) {
                HStack {
                    rowLabel(title, symbol)
                    Spacer()
                    Text(value)
                        .font(.app(15, relativeTo: .callout))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                }
            }
        }
    }
}
