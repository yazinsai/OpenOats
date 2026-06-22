import Foundation
import os

/// Shared acoustic echo suppression logic.
/// Detects when mic (YOU) utterances are echoes of system (THEM) audio based on
/// Jaccard word-set similarity and substring containment.
enum AcousticEchoFilter {
    struct Match: Equatable {
        let timeDelta: TimeInterval
        let similarity: Double
    }

    enum TimeDirection {
        case micAfterRemote
        case either
    }

    static let defaultWindow: TimeInterval = 1.75
    static let defaultSimilarityThreshold = 0.78
    static let defaultMinimumWordCount = 4
    static let defaultMinimumCharacterCount = 20

    /// Suppress mic records that are acoustic echoes of system records.
    /// Modifies `micRecords` in place, removing entries that match.
    static func suppress(
        micRecords: inout [SessionRecord],
        against sysRecords: [SessionRecord],
        window: TimeInterval = defaultWindow,
        similarityThreshold: Double = defaultSimilarityThreshold,
        minimumWordCount: Int = defaultMinimumWordCount,
        minimumCharacterCount: Int = defaultMinimumCharacterCount
    ) {
        micRecords.removeAll { micRecord in
            for sysRecord in sysRecords.reversed() {
                guard let match = match(
                    micText: micRecord.text,
                    remoteText: sysRecord.text,
                    micTimestamp: micRecord.timestamp,
                    remoteTimestamp: sysRecord.timestamp,
                    window: window,
                    similarityThreshold: similarityThreshold,
                    minimumWordCount: minimumWordCount,
                    minimumCharacterCount: minimumCharacterCount,
                    direction: .micAfterRemote
                ) else { continue }

                let dtFormatted = String(format: "%.2f", match.timeDelta)
                let simFormatted = String(format: "%.2f", match.similarity)
                let micSnippet = String(micRecord.text.prefix(80))
                let sysSnippet = String(sysRecord.text.prefix(80))
                Log.echo.info(
                    "Suppressed mic record as echo dt=\(dtFormatted, privacy: .public) sim=\(simFormatted, privacy: .public) mic='\(micSnippet, privacy: .private)' sys='\(sysSnippet, privacy: .private)'"
                )
                return true
            }
            return false
        }
    }

    static func match(
        micText: String,
        remoteText: String,
        micTimestamp: Date,
        remoteTimestamp: Date,
        window: TimeInterval = defaultWindow,
        similarityThreshold: Double = defaultSimilarityThreshold,
        minimumWordCount: Int = defaultMinimumWordCount,
        minimumCharacterCount: Int = defaultMinimumCharacterCount,
        direction: TimeDirection = .micAfterRemote
    ) -> Match? {
        let timeDelta = micTimestamp.timeIntervalSince(remoteTimestamp)
        switch direction {
        case .micAfterRemote:
            guard timeDelta >= 0, timeDelta <= window else { return nil }
        case .either:
            guard abs(timeDelta) <= window else { return nil }
        }

        guard let similarity = textSimilarityIfEcho(
            micText,
            remoteText,
            similarityThreshold: similarityThreshold,
            minimumWordCount: minimumWordCount,
            minimumCharacterCount: minimumCharacterCount
        ) else { return nil }

        return Match(timeDelta: timeDelta, similarity: similarity)
    }

    static func textSimilarityIfEcho(
        _ firstText: String,
        _ secondText: String,
        similarityThreshold: Double = defaultSimilarityThreshold,
        minimumWordCount: Int = defaultMinimumWordCount,
        minimumCharacterCount: Int = defaultMinimumCharacterCount
    ) -> Double? {
        let first = TextSimilarity.normalizedText(firstText)
        let second = TextSimilarity.normalizedText(secondText)
        guard isEligible(first, minimumWordCount: minimumWordCount, minimumCharacterCount: minimumCharacterCount),
              isEligible(second, minimumWordCount: minimumWordCount, minimumCharacterCount: minimumCharacterCount) else {
            return nil
        }

        let similarity = TextSimilarity.jaccard(first, second)
        let containsOther = first.contains(second) || second.contains(first)
        return similarity >= similarityThreshold || containsOther ? similarity : nil
    }

    private static func isEligible(
        _ normalizedText: String,
        minimumWordCount: Int,
        minimumCharacterCount: Int
    ) -> Bool {
        let wordCount = normalizedText.split(separator: " ").count
        return wordCount >= minimumWordCount || normalizedText.count >= minimumCharacterCount
    }
}
