@preconcurrency import AVFoundation

protocol AudioOutputDevice: AnyObject {
    func start(pcm: AudioPCMBuffer) throws
    func stop(deactivate: Bool)
}

/// Session and engine operations belong to the player's output queue. They can
/// wait on the audio service, so packet decoding must not share that queue.
final class AudioOutput: AudioOutputDevice {
    private let token = UUID()
    private let coordinator: AudioSessionCoordinator

    init(coordinator: AudioSessionCoordinator = .shared) { self.coordinator = coordinator }

    func start(pcm: AudioPCMBuffer) throws {
        try coordinator.startPlayback(token: token, pcm: pcm)
    }

    func stop(deactivate: Bool) {
        coordinator.stopPlayback(token: token, deactivate: deactivate)
    }
}
