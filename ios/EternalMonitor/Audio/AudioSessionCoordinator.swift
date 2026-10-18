@preconcurrency import AVFoundation
import Foundation

protocol DuplexAudioHardware: AnyObject {
    func rebuild(playback: AudioPCMBuffer?, microphone: MicrophoneCaptureProcessor?) throws
    func shutdown(deactivate: Bool)
}

/// The only AVAudioSession/AVAudioEngine owner. Playback and microphone have
/// independent leases, so AudioOutput.start cannot change an active recording
/// session to playback-only, and stopping capture cannot deactivate TTS.
final class AudioSessionCoordinator: @unchecked Sendable {
    static let shared = AudioSessionCoordinator()
    private let queue = DispatchQueue(label: "EternalMonitor.audio.session", qos: .userInitiated)
    private let hardware: DuplexAudioHardware
    private var playback: (token: UUID, pcm: AudioPCMBuffer, onFailure: ((Error) -> Void)?)?
    private var microphone: (token: UUID, processor: MicrophoneCaptureProcessor)?

    init(hardware: DuplexAudioHardware? = nil) { self.hardware = hardware ?? NativeDuplexAudioHardware() }

    func startPlayback(token: UUID, pcm: AudioPCMBuffer, onFailure: ((Error) -> Void)? = nil) throws {
        try queue.sync {
            let previous = playback
            playback = (token, pcm, onFailure)
            do { try rebuild() }
            catch {
                playback = previous
                rebuildRemainingOrReportFailure()
                throw error
            }
        }
    }

    func stopPlayback(token: UUID, deactivate: Bool) {
        queue.sync {
            guard playback?.token == token else {
                if deactivate, playback == nil, microphone == nil { hardware.shutdown(deactivate: true) }
                return
            }
            playback = nil
            if microphone != nil { rebuildRemainingOrReportFailure() }
            else { hardware.shutdown(deactivate: deactivate) }
        }
    }

    func startMicrophone(token: UUID, processor: MicrophoneCaptureProcessor) throws {
        try queue.sync {
            let previous = microphone
            microphone = (token, processor)
            do { try rebuild() }
            catch {
                microphone = previous
                // AEC/recording failure must leave an existing speaker lease
                // usable; raw, unprocessed microphone is never a fallback.
                rebuildRemainingOrReportFailure()
                throw error
            }
        }
    }

    func stopMicrophone(token: UUID) {
        queue.sync {
            guard microphone?.token == token else { return }
            microphone = nil
            if playback != nil { rebuildRemainingOrReportFailure() }
            else { hardware.shutdown(deactivate: true) }
        }
    }

    private func rebuild() throws {
        if playback == nil, microphone == nil { hardware.shutdown(deactivate: true) }
        else { try hardware.rebuild(playback: playback?.pcm, microphone: microphone?.processor) }
    }

    /// A lease is a request, not proof that a hardware graph survived. Notify
    /// whichever consumer remains if its rebuild fails; their existing stop
    /// paths release the same lease. Never silently retain a dead graph.
    private func rebuildRemainingOrReportFailure() {
        do { try rebuild() }
        catch {
            hardware.shutdown(deactivate: true)
            playback?.onFailure?(error)
            microphone?.processor.fail()
        }
    }
}

enum MicrophoneAudioError: LocalizedError {
    case unavailable, conversion
    var errorDescription: String? {
        switch self {
        case .unavailable: return "麦克风或回声消除暂不可用，请换回 iPad 麦克风后重试。"
        case .conversion: return "麦克风格式无法转换，请重新开启麦克风。"
        }
    }
}

/// Playback and capture must share the actual I/O engine for Apple's voice
/// processor to receive the PC/TTS render reference used by echo cancellation.
private final class NativeDuplexAudioHardware: DuplexAudioHardware {
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var active = false

    func rebuild(playback: AudioPCMBuffer?, microphone: MicrophoneCaptureProcessor?) throws {
        shutdown(deactivate: false)
        let session = AVAudioSession.sharedInstance()
        if microphone != nil {
            let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetooth]
            if session.category != .playAndRecord || session.mode != .voiceChat || session.categoryOptions != options {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
            }
        } else if session.category != .playback || session.mode != .default {
            try session.setCategory(.playback, mode: .default)
        }
        if session.preferredSampleRate != 48_000 { try session.setPreferredSampleRate(48_000) }
        if abs(session.preferredIOBufferDuration - 0.01) > 0.0001 { try session.setPreferredIOBufferDuration(0.01) }
        if !active { try session.setActive(true) }
        active = true
        let output = AVAudioEngine()
        do {
            if microphone != nil {
                try output.inputNode.setVoiceProcessingEnabled(true)
                guard output.inputNode.isVoiceProcessingEnabled else { throw MicrophoneAudioError.unavailable }
                output.inputNode.isVoiceProcessingInputMuted = false
                output.inputNode.isVoiceProcessingAGCEnabled = true
                output.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
                throw MicrophoneAudioError.unavailable
            }
            let source = AVAudioSourceNode(format: format) { silence, _, frameCount, list in
                let buffers = UnsafeMutableAudioBufferListPointer(list)
                if let playback {
                    playback.render(frames: Int(frameCount), buffers: buffers, nowUs: ControlChannel.clientNowUs())
                    silence.pointee = false
                } else {
                    for buffer in buffers {
                        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                    }
                    silence.pointee = true
                }
                return noErr
            }
            output.attach(source)
            output.connect(source, to: output.mainMixerNode, format: format)
            if let microphone {
                let input = output.inputNode
                let inputFormat = input.outputFormat(forBus: 0)
                guard inputFormat.channelCount > 0, (8_000...192_000).contains(inputFormat.sampleRate) else {
                    throw MicrophoneAudioError.unavailable
                }
                input.installTap(onBus: 0, bufferSize: 960, format: inputFormat) { [weak microphone] buffer, _ in
                    let now = ControlChannel.clientNowUs()
                    let duration = UInt64(Double(buffer.frameLength) / buffer.format.sampleRate * 1_000_000)
                    microphone?.offer(buffer, timestampUs: now >= duration ? now - duration : 0)
                }
                tapInstalled = true
            }
            output.prepare()
            try output.start()
            engine = output
        } catch {
            if tapInstalled { output.inputNode.removeTap(onBus: 0); tapInstalled = false }
            output.stop()
            throw error
        }
    }

    func shutdown(deactivate: Bool) {
        if let engine {
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
        }
        tapInstalled = false
        engine = nil
        if deactivate, active {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            active = false
        }
    }
}
