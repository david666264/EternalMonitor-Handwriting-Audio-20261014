@preconcurrency import AVFoundation

protocol AudioOutputDevice: AnyObject {
    func start(pcm: AudioPCMBuffer) throws
    func stop(deactivate: Bool)
    func setGraphFailureHandler(_ handler: @escaping (Error) -> Void)
}

extension AudioOutputDevice {
    // Existing output mocks/adapters need no new state or behavior.
    func setGraphFailureHandler(_ handler: @escaping (Error) -> Void) {}
}

/// Session and engine operations belong to the player's output queue. They can
/// wait on the audio service, so packet decoding must not share that queue.
final class AudioOutput: AudioOutputDevice {
    private let token = UUID()
    private let coordinator: AudioSessionCoordinator
    private var graphFailureHandler: ((Error) -> Void)?

    init(coordinator: AudioSessionCoordinator = .shared) { self.coordinator = coordinator }

    func setGraphFailureHandler(_ handler: @escaping (Error) -> Void) { graphFailureHandler = handler }

    func start(pcm: AudioPCMBuffer) throws {
        try coordinator.startPlayback(token: token, pcm: pcm, onFailure: { [weak self] error in
            self?.graphFailureHandler?(error)
        })
    }

    func stop(deactivate: Bool) {
        coordinator.stopPlayback(token: token, deactivate: deactivate)
    }
}
