@preconcurrency import AVFoundation
import OatsCore
import os

/// Converts capture buffers to 16 kHz mono and stamps each chunk with the host time of its first sample.
final class Resampler: @unchecked Sendable {
    private static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: TrackAudio.sampleRate, channels: 1, interleaved: false)!
    private let track: Track
    private let deliver: @Sendable (CapturedAudio) -> Void
    private var converter: AVAudioConverter?

    init(_ track: Track, _ deliver: @escaping @Sendable (CapturedAudio) -> Void) {
        self.track = track
        self.deliver = deliver
    }

    /// `hostTime` in mach host ticks, 0 if unknown. Called on one capture thread at a time.
    func convert(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        let rate = buffer.format.sampleRate
        guard buffer.frameLength > 0, rate > 0 else { return }
        let start = hostTime > 0 ? AVAudioTime.seconds(forHostTime: hostTime)
            : ProcessInfo.processInfo.systemUptime - Double(buffer.frameLength) / rate
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: Self.target)
            converter?.downmix = true
            converter?.primeMethod = .none
        }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * TrackAudio.sampleRate / rate) + 64
        guard let converter, let out = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: capacity) else { return }
        nonisolated(unsafe) var fed = false
        _ = converter.convert(to: out, error: nil) { _, status in
            status.pointee = fed ? .noDataNow : .haveData
            defer { fed = true }
            return fed ? nil : buffer
        }
        guard out.frameLength > 0, let data = out.floatChannelData else { return }
        deliver(CapturedAudio(track: track, floats: Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength))), hostTime: start))
    }
}

/// When a track last delivered audio (or was rebuilt), in `systemUptime` seconds, and whether it ever delivered.
final class Activity: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (last: ProcessInfo.processInfo.systemUptime, delivered: false))
    func touch(delivered: Bool = true) {
        state.withLock { $0 = (ProcessInfo.processInfo.systemUptime, $0.delivered || delivered) }
    }
    var age: TimeInterval { ProcessInfo.processInfo.systemUptime - state.withLock { $0.last } }
    var delivered: Bool { state.withLock { $0.delivered } }
}
