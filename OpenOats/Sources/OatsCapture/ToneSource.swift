import Foundation
import OatsCore

/// Deterministic test capture (`oats record --fake-source`, the app with `OATS_FAKE_CAPTURE=1`): a 440 Hz tone on the Mic track and 660 Hz on the System track, in real time.
/// `stop()` delivers the tail since the last tick, so both tracks last exactly as long as the recording ran.
public final class ToneSource: CaptureSource, @unchecked Sendable {
    private let queue = DispatchQueue(label: "oats.tone")
    private lazy var timer = DispatchSource.makeTimerSource(queue: queue)
    private var deliver: (@Sendable (CapturedAudio) -> Void)?
    private var begin = 0.0
    private var sent = 0

    public init() {}

    public func start(_ deliver: @escaping @Sendable (CapturedAudio) -> Void) throws {
        queue.sync {
            self.deliver = deliver
            begin = ProcessInfo.processInfo.systemUptime
        }
        timer.schedule(deadline: .now(), repeating: 0.1)
        timer.setEventHandler { [self] in tick() }
        timer.resume()
    }

    public func stop() {
        queue.sync {
            timer.cancel()
            tick()
            deliver = nil
        }
    }

    private func tick() {
        guard let deliver else { return }
        let due = Int((ProcessInfo.processInfo.systemUptime - begin) * TrackAudio.sampleRate)
        guard due > sent else { return }
        for (track, hz) in [(Track.mic, 440.0), (.system, 660.0)] {
            let samples = (sent..<due).map { Int16(sin(2 * .pi * hz * Double($0) / TrackAudio.sampleRate) * 8000) }
            deliver(CapturedAudio(track: track, samples: samples, hostTime: begin + Double(sent) / TrackAudio.sampleRate))
        }
        sent = due
    }
}
