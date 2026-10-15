import SwiftUI

struct PairingSheet: View {
    @ObservedObject var model: PairingSheetModel
    let submit: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 64, height: 64)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Theme.accent.opacity(0.1))
                        )
                        .accessibilityHidden(true)

                    VStack(spacing: 8) {
                        Text("与电脑配对")
                            .font(.app(24, .semibold, relativeTo: .title2))
                            .foregroundStyle(Theme.text)
                        Text("输入电脑端 EternalMonitor 显示的六位配对码。每台电脑只需配对一次。")
                            .font(.app(15, relativeTo: .body))
                            .foregroundStyle(Theme.textMuted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    TextField("000000", text: $model.code, prompt: Text("000000").foregroundStyle(Theme.textFaint.opacity(0.6)))
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .autocorrectionDisabled()
                        .font(.appMono(34, medium: true, relativeTo: .largeTitle))
                        .tracking(10)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: 320, minHeight: 72)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Theme.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(model.error == nil ? (focused ? Theme.accent : Theme.borderStrong) : Theme.danger, lineWidth: 1.5)
                        )
                        .focused($focused)
                        .onChange(of: model.code) { _, code in
                            // Digits only, at most six.
                            let digits = String(code.filter(\.isNumber).prefix(6))
                            if digits != code { model.code = digits }
                        }
                        .accessibilityLabel("配对码")
                        .accessibilityIdentifier("pairing.code")

                    if let error = model.error {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .accessibilityHidden(true)
                            Text(error)
                                .multilineTextAlignment(.leading)
                                .accessibilityIdentifier("pairing.error")
                        }
                        .font(.app(14, relativeTo: .callout))
                        .foregroundStyle(Theme.danger)
                        .frame(maxWidth: 360)
                    }

                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = model.remaining(at: context.date)
                        Button(action: submit) {
                            HStack(spacing: 10) {
                                if model.submitting {
                                    ProgressView().tint(Theme.onAccent)
                                }
                                Text(remaining > 0 ? "请在 \(remaining) 秒后重试" : "配对 iPad")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .frame(maxWidth: 320)
                        .disabled(model.submitting || remaining > 0)
                        .accessibilityIdentifier("pairing.submit")
                    }

                    Text("找不到配对码？请查看电脑端 EternalMonitor 的「连接」页面，也可以改用 USB 数据线连接。")
                        .font(.app(13, relativeTo: .footnote))
                        .foregroundStyle(Theme.textFaint)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.canvas.ignoresSafeArea())
            .navigationTitle("与电脑配对")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: cancel)
                        .foregroundStyle(Theme.text)
                        .accessibilityIdentifier("pairing.cancel")
                }
            }
            .tint(Theme.accent)
            .accessibilityIdentifier("pairing.sheet")
            .onAppear { focused = true }
        }
        .presentationBackground(Theme.canvas)
    }
}
