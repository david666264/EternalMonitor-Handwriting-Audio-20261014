import Foundation

/// USB-only microphone uplink: PCM16LE, mono 16 kHz, exactly 20 ms/frame.
/// This is independent of keyboard msgSeq and downlink Opus/audioSeq.
struct MicrophoneHeader: Equatable {
    static let size = 24
    static let samplesPerFrame = 320
    static let payloadSize = samplesPerFrame * 2
    static let endFlag: UInt8 = 1
    var sessionId: UInt32
    var microphoneSeq: UInt32
    var captureTimestampUs: UInt64
    var isEnd = false

    func encode(pcm: Data) -> Data? {
        guard sessionId != 0, pcm.count == (isEnd ? 0 : Self.payloadSize) else { return nil }
        var output = Data(capacity: Self.size + pcm.count)
        output.appendMicrophoneLE(Wire.magic)
        output.append(Wire.version)
        output.append(Wire.PacketType.microphone.rawValue)
        output.append(isEnd ? Self.endFlag : 0)
        output.append(0)
        output.appendMicrophoneLE(UInt16(pcm.count))
        output.appendMicrophoneLE(sessionId)
        output.appendMicrophoneLE(microphoneSeq)
        output.appendMicrophoneLE(captureTimestampUs)
        output.append(pcm)
        return output
    }

    static func decode(_ datagram: Data) -> (header: MicrophoneHeader, payloadRange: Range<Data.Index>)? {
        guard datagram.count >= size, datagram.count <= size + payloadSize else { return nil }
        let header: MicrophoneHeader? = datagram.withUnsafeBytes { raw in
            guard UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: 0, as: UInt16.self)) == Wire.magic,
                  raw[2] == Wire.version, raw[3] == Wire.PacketType.microphone.rawValue,
                  raw[4] & ~endFlag == 0, raw[5] == 0 else { return nil }
            let payloadLength = Int(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: 6, as: UInt16.self)))
            let isEnd = raw[4] & endFlag != 0
            guard payloadLength == datagram.count - size,
                  payloadLength == (isEnd ? 0 : payloadSize) else { return nil }
            let session = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
            guard session != 0 else { return nil }
            return MicrophoneHeader(sessionId: session,
                microphoneSeq: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self)),
                captureTimestampUs: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: 16, as: UInt64.self)), isEnd: isEnd)
        }
        guard let header else { return nil }
        return (header, datagram.index(datagram.startIndex, offsetBy: size)..<datagram.endIndex)
    }
}

private extension Data {
    mutating func appendMicrophoneLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
