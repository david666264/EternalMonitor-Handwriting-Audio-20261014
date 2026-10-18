@preconcurrency import AVFoundation
import Combine
import Foundation

enum MicrophonePermission { case undetermined, granted, denied }
protocol MicrophonePermissionProviding {
    var permission: MicrophonePermission { get }
    func request(_ completion: @escaping (Bool) -> Void)
}
private struct NativeMicrophonePermission: MicrophonePermissionProviding {
    var permission: MicrophonePermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        default: return .undetermined
        }
    }
    func request(_ completion: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission(completionHandler: completion)
    }
}

enum MicrophoneRelayStatus: Equatable {
    case off, waitingUSB, permissionRequired, requestingPermission, denied
    case unsupported, reconnectRequired, starting, recording, interrupted, failed
    var description: String {
        switch self {
        case .off: return "已关闭"
        case .waitingUSB: return "等待 USB 画面连接"
        case .permissionRequired: return "点开关以允许使用麦克风"
        case .requestingPermission: return "等待麦克风授权"
        case .denied: return "未获麦克风权限；画面和电脑声音不受影响"
        case .unsupported: return "当前电脑端不支持麦克风，请更新电脑端"
        case .reconnectRequired: return "需要重新连接以启用麦克风"
        case .starting: return "正在启用麦克风与回声消除"
        case .recording: return "麦克风已开启 · 仅通过 USB 传输"
        case .interrupted: return "系统暂时中断麦克风"
        case .failed: return "麦克风暂不可用，请关闭后重新开启"
        }
    }
}

/// A visible, opt-in source. Negotiation, USB, app foreground and permission
/// must all agree before any engine input is opened. This changes no Windows
/// default microphone and performs no ASR/model work on the iPad.
@MainActor
final class MicrophoneRelayController: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var status: MicrophoneRelayStatus = .off
    @Published private(set) var inputLevel = 0.0
    var onNeedsReconnect: (() -> Void)?
    private struct Session {
        let id: UInt32
        let isUSB: Bool
        let hostCaps: UInt16
        let requested: Bool
        let send: MicrophoneUplink.BatchTransport
    }
    private var session: Session?
    private var foreground = true
    private var captureRunning = false
    private var captureGeneration: UInt64 = 0
    private var permissionRequest: UUID?
    private let capture: MicrophoneCaptureDeviceProtocol
    private let permissions: MicrophonePermissionProviding
    private let defaults: UserDefaults?
    private let uplink = MicrophoneUplink()
    private let level = MicrophoneInputLevel()
    private var levelTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(capture: MicrophoneCaptureDeviceProtocol? = nil,
        permissions: MicrophonePermissionProviding? = nil, defaults: UserDefaults? = .standard) {
        self.capture = capture ?? MicrophoneCaptureDevice()
        self.permissions = permissions ?? NativeMicrophonePermission()
        self.defaults = defaults
        enabled = defaults?.bool(forKey: "sendIPadMicrophone") ?? false
        status = enabled ? .waitingUSB : .off
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: nil) { [weak self] notice in
            let began = (notice.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                == AVAudioSession.InterruptionType.began.rawValue
            Task { @MainActor in
                guard let self, self.enabled else { return }
                if began { self.stopCapture(); self.status = .interrupted }
                else { self.reconcile(allowPermissionRequest: false) }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: nil) { [weak self] notice in
            let reason = (notice.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            guard reason == .newDeviceAvailable || reason == .oldDeviceUnavailable else { return }
            Task { @MainActor in
                guard let self, self.enabled, self.foreground, self.captureRunning else { return }
                self.stopCapture()
                self.reconcile(allowPermissionRequest: false)
            }
        })
    }

    deinit {
        levelTimer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        defaults?.set(value, forKey: "sendIPadMicrophone")
        if !value { permissionRequest = nil; stopCapture(); status = .off }
        else { reconcile(allowPermissionRequest: true) }
    }

    func configureSession(sessionId: UInt32, isUSB: Bool, hostCaps: UInt16, requested: Bool,
        sendBatch: @escaping MicrophoneUplink.BatchTransport) {
        stopCapture()
        session = Session(id: sessionId, isUSB: isUSB, hostCaps: hostCaps, requested: requested, send: sendBatch)
        reconcile(allowPermissionRequest: false)
    }

    func stopSession(backgrounded: Bool = false) {
        if backgrounded { foreground = false }
        session = nil
        stopCapture()
        status = enabled ? .waitingUSB : .off
    }

    func handleForeground() {
        foreground = true
        reconcile(allowPermissionRequest: false)
    }

    private func reconcile(allowPermissionRequest: Bool) {
        guard enabled else { status = .off; return }
        guard foreground else { stopCapture(); status = .waitingUSB; return }
        switch permissions.permission {
        case .denied:
            stopCapture(); status = .denied; return
        case .undetermined:
            stopCapture()
            guard allowPermissionRequest else { status = .permissionRequired; return }
            guard permissionRequest == nil else { return }
            let request = UUID()
            permissionRequest = request
            status = .requestingPermission
            permissions.request { [weak self] granted in
                Task { @MainActor in
                    guard let self, self.permissionRequest == request else { return }
                    self.permissionRequest = nil
                    if granted { self.reconcile(allowPermissionRequest: true) }
                    else { self.stopCapture(); self.status = .denied }
                }
            }
            return
        case .granted: break
        }
        guard let session, session.id != 0, session.isUSB else {
            stopCapture(); status = .waitingUSB; return
        }
        guard session.hostCaps & HelloAck.hostCapMicrophone != 0 else {
            stopCapture(); status = .unsupported; return
        }
        guard session.requested else {
            stopCapture(); status = .reconnectRequired
            if allowPermissionRequest { onNeedsReconnect?() }
            return
        }
        guard !captureRunning else { return }
        captureRunning = true
        captureGeneration &+= 1
        let generation = captureGeneration
        status = .starting
        uplink.start(sessionId: session.id, sendBatch: session.send)
        capture.start(onPCM: { [uplink, level] pcm, timestamp in
            level.offer(pcm)
            uplink.offer(pcm: pcm, timestampUs: timestamp)
        }, onError: { [weak self] in
            Task { @MainActor in
                guard let self, self.captureGeneration == generation else { return }
                self.stopCapture(); self.status = .failed
            }
        }, completion: { [weak self] result in
            Task { @MainActor in
                guard let self, self.captureGeneration == generation, self.enabled, self.foreground else { return }
                switch result {
                case .success:
                    self.status = .recording
                    self.startLevelTimer()
                case .failure:
                    self.stopCapture(); self.status = .failed
                }
            }
        })
    }

    private func stopCapture() {
        captureGeneration &+= 1
        captureRunning = false
        // Close network acceptance before waiting on engine teardown.
        uplink.stop()
        capture.stop()
        levelTimer?.invalidate(); levelTimer = nil
        inputLevel = 0
    }

    private func startLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.status == .recording else { return }
                self.inputLevel = self.level.value
            }
        }
    }
}

private final class MicrophoneInputLevel: @unchecked Sendable {
    private let lock = NSLock()
    private var rms = 0.0
    func offer(_ pcm: Data) {
        var sum = 0.0
        let count = pcm.count / 2
        guard count > 0 else { return }
        pcm.withUnsafeBytes { raw in
            for index in 0..<count {
                let sample = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32768
                sum += sample * sample
            }
        }
        lock.lock(); rms = sqrt(sum / Double(count)); lock.unlock()
    }
    var value: Double { lock.lock(); defer { lock.unlock() }; return min(1, rms * 5) }
}
