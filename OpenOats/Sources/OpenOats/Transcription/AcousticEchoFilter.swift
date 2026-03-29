import Foundation
import os

/// Shared acoustic echo suppression logic.
/// Detects when mic (YOU) utterances are echoes of system (THEM) audio based on
/// Jaccard word-set similarity and substring containment.
enum AcousticEchoFilter {

    /// Suppress mic records that are acoustic echoes of system records.
    /// Modifies `micRecords` in place, removing entries that match.
    static func suppress(
        micRecords: inout [SessionRecord],
        against sysRecords: [SessionRecord],
        window: TimeInterval = 1.75,
        similarityThreshold: Double = 0.78,
        minimumWordCount: Int = 4,
        minimumCharacterCount: Int = 20
    ) {
        micRecords.removeAll { micRecord in
            let normalizedYou = TextSimilarity.normalizedText(micRecord.text)
            guard isEligible(normalizedYou, minimumWordCount: minimumWordCount, minimumCharacterCount: minimumCharacterCount) else {
                return false
            }

            for sysRecord in sysRecords.reversed() {
                let timeDelta = micRecord.timestamp.timeIntervalSince(sysRecord.timestamp)
                guard timeDelta >= 0 else { continue }
                guard timeDelta <= window else { break }

                let normalizedThem = TextSimilarity.normalizedText(sysRecord.text)
                guard isEligible(normalizedThem, minimumWordCount: minimumWordCount, minimumCharacterCount: minimumCharacterCount) else {
                    continue
                }

                let similarity = TextSimilarity.jaccard(normalizedYou, normalizedThem)
                let containsOther =
                    normalizedYou.contains(normalizedThem) ||
                    normalizedThem.contains(normalizedYou)

                if similarity >= similarityThreshold || containsOther {
                    let dtFormatted = String(format: "%.2f", timeDelta)
                    let simFormatted = String(format: "%.2f", similarity)
                    let micSnippet = String(micRecord.text.prefix(80))
                    let sysSnippet = String(sysRecord.text.prefix(80))
                    Log.echo.info(
                        "Suppressed mic record as echo dt=\(dtFormatted, privacy: .public) sim=\(simFormatted, privacy: .public) mic='\(micSnippet, privacy: .private)' sys='\(sysSnippet, privacy: .private)'"
                    )
                    return true
                }
            }
            return false
        }
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
