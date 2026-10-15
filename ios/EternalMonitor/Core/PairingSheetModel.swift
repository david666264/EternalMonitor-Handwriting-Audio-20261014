import Foundation
import Combine

@MainActor
final class PairingSheetModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published var code = ""
    @Published private(set) var error: String?
    @Published private(set) var submitting = false
    @Published private(set) var blockedUntil: Date?

    func reject(_ status: HelloStatus, now: Date = Date()) {
        if status == .rateLimited {
            blockedUntil = now.addingTimeInterval(60)
            error = "尝试次数过多，请稍后重试。"
        } else if submitting {
            error = "配对码不匹配，请核对电脑上的数字后重试。"
        }
        submitting = false
    }

    func remaining(at now: Date) -> Int {
        max(0, Int(ceil(blockedUntil?.timeIntervalSince(now) ?? 0)))
    }

    func submit(now: Date = Date()) -> UInt32? {
        guard !submitting, remaining(at: now) == 0 else { return nil }
        guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }), let number = UInt32(code) else {
            error = "请输入电脑上显示的完整六位配对码。"
            return nil
        }
        error = nil
        submitting = true
        return number
    }

    func timedOut() {
        submitting = false
        error = "电脑未响应，请检查连接后重试。"
    }
}
