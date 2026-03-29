import FluidAudio
import Foundation

/// Manages LS-EEND speaker diarization for system audio.
/// Wraps the FluidAudio LSEENDDiarizer and provides speaker attribution
/// for transcribed segments by querying the diarizer timeline.
actor DiarizationManager {
    private nonisolated(unsafe) let diarizer = LSEENDDiarizer()
    private var isInitialized = false

    /// Load the LS-EEND model for the given variant. Must be called before feedAudio/dominantSpeaker.
    func load(variant: LSEENDVariant = .dihard3) async throws {
        Log.diarization.info("Loading LS-EEND model (variant: \(variant.rawValue, privacy: .public))")
        try await diarizer.initialize(variant: variant)
        isInitialized = true
        Log.diarization.info("LS-EEND model loaded")
    }

    /// Feed audio samples to the diarizer. Samples should be at 16kHz mono Float32.
    /// Uses addAudio + process for streaming (does not reset state between calls).
    func feedAudio(_ samples: [Float]) throws {
        guard isInitialized else { return }
        try diarizer.addAudio(samples, sourceSampleRate: 16000)
        _ = try diarizer.process()
    }

    /// Returns the dominant speaker for a given time range in seconds.
    /// Queries the DiarizerTimeline and finds which speaker has the most
    /// speech frames overlapping [startTime, endTime].
    func dominantSpeaker(from startTime: TimeInterval, to endTime: TimeInterval) -> Speaker {
        let timeline = diarizer.timeline
        let speakers = timeline.speakers

        guard !speakers.isEmpty else { return .them }

        var bestSpeaker: Int = 0
        var bestOverlap: Float = 0

        let queryStart = Float(startTime)
        let queryEnd = Float(endTime)

        for (index, speaker) in speakers {
            let allSegments = speaker.finalizedSegments + speaker.tentativeSegments
            var overlap: Float = 0

            for segment in allSegments {
                let overlapStart = max(segment.startTime, queryStart)
                let overlapEnd = min(segment.endTime, queryEnd)
                if overlapEnd > overlapStart {
                    overlap += overlapEnd - overlapStart
                }
            }

            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSpeaker = index
            }
        }

        guard bestOverlap > 0 else { return .them }

        // If only one speaker was detected in the entire session, fall back to .them
        // for backward compatibility (no point labeling "Speaker 1" when there's only one).
        let activeSpeakers = speakers.values.filter { $0.hasSegments }
        if activeSpeakers.count <= 1 {
            return .them
        }

        // Map diarizer speaker index to Speaker enum
        // Index 0 → .remote(1), index 1 → .remote(2), etc.
        return .remote(bestSpeaker + 1)
    }

    /// Finalize the diarization session (flush tentative segments).
    func finalize() {
        guard isInitialized else { return }
        do {
            try diarizer.finalizeSession()
        } catch {
            Log.diarization.error("Failed to finalize LS-EEND session: \(error, privacy: .public)")
        }
    }

    /// Reset the diarizer state for a new session.
    func reset() {
        guard isInitialized else { return }
        diarizer.reset()
    }
}
