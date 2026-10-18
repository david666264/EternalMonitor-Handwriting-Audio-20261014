import SwiftUI
import UIKit

struct MicrophoneSettingsSection: View {
    @ObservedObject var controller: MicrophoneRelayController
    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { controller.enabled }, set: { controller.setEnabled($0) })) {
                Label("iPad 麦克风", systemImage: "mic")
                    .font(.app(16, relativeTo: .body))
                    .foregroundStyle(Theme.text)
            }
            .accessibilityIdentifier("settings.iPadMicrophone")
            Label(controller.status.description,
                systemImage: controller.status == .recording ? "mic.fill" : "mic.slash")
                .font(.app(13, relativeTo: .footnote))
                .foregroundStyle(controller.status == .recording ? Theme.accent : Theme.textMuted)
                .accessibilityIdentifier("settings.microphoneStatus")
            if controller.status == .recording {
                ProgressView(value: controller.inputLevel)
                    .tint(Theme.accent)
                    .accessibilityLabel("麦克风输入电平")
                    .accessibilityIdentifier("settings.microphoneLevel")
            }
            if controller.status == .denied {
                Button("前往系统设置允许麦克风") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .accessibilityIdentifier("settings.microphonePermission")
            }
        } header: {
            Text("iPad 麦克风")
                .font(.app(12, .medium, relativeTo: .caption))
                .foregroundStyle(Theme.textFaint)
        } footer: {
            Text("开启后会申请麦克风权限，只在当前 USB 画面连接中传输声音。切到后台、断开或关闭开关后停止；电脑声音可继续播放。由 Amadeus 选择当前识别源，不改变电脑的默认麦克风。")
                .font(.app(12, relativeTo: .footnote))
                .foregroundStyle(Theme.textMuted)
        }
        .listRowBackground(Theme.surfaceRaised)
    }
}

/// The live view always exposes one visible control; detailed permission and
/// negotiation explanations stay in Settings rather than covering the canvas.
struct MicrophoneToolbarButton: View {
    @ObservedObject var controller: MicrophoneRelayController
    @Environment(\.horizontalSizeClass) private var sizeClass
    var body: some View {
        Button { controller.setEnabled(!controller.enabled) } label: {
            HStack(spacing: 6) {
                Image(systemName: controller.enabled ? "mic.fill" : "mic.slash")
                    .font(.system(size: 14, weight: .medium))
                if sizeClass != .compact {
                    Text(controller.enabled ? "关麦" : "麦克风")
                        .font(.app(14, .semibold, relativeTo: .subheadline))
                }
            }
            .frame(minWidth: 28, minHeight: 28)
        }
        .buttonStyle(PillButtonStyle(
            foreground: controller.enabled ? Theme.onAccent : Theme.text,
            fill: controller.enabled ? Theme.accent : Color.white.opacity(0.08)))
        .accessibilityLabel("iPad 麦克风")
        .accessibilityValue("\(controller.enabled ? "开" : "关")，\(controller.status.description)")
        .accessibilityIdentifier("display.microphone")
        .help(controller.status.description)
    }
}
