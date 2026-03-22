/// WhisperKit CoreML Benchmark
/// Tests whisper models (small, large-v3-turbo) against multilingual audio samples.
/// Measures WER and CER using the same ground truth as the Python benchmark.

import AVFoundation
import Foundation
import WhisperKit

func log(_ msg: String) {
    print(msg)
    fflush(stdout)
}

// MARK: - Configuration

struct Sample: Codable {
    let file: String
    let language: String
    let transcript: String
}

let benchmarkDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/../benchmark")

let modelsToTest: [(name: String, variant: String)] = [
    ("large-v3-turbo", "large-v3-v20240930"),
    ("small", "small"),
]

// MARK: - WER Calculation

func normalizeText(_ text: String) -> String {
    var t = text.lowercased()
    // Remove punctuation (keep letters, numbers, whitespace)
    t = t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0) }
        .map { String($0) }.joined()
    // Collapse whitespace
    t = t.split(separator: " ").joined(separator: " ")
    return t
}

func computeWER(reference: String, hypothesis: String) -> Double {
    let ref = reference.split(separator: " ").map(String.init)
    let hyp = hypothesis.split(separator: " ").map(String.init)
    guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }

    let m = ref.count, n = hyp.count
    var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
    for i in 0...m { dp[i][0] = i }
    for j in 0...n { dp[0][j] = j }
    for i in 1...m {
        for j in 1...n {
            if ref[i-1] == hyp[j-1] {
                dp[i][j] = dp[i-1][j-1]
            } else {
                dp[i][j] = 1 + min(dp[i-1][j], dp[i][j-1], dp[i-1][j-1])
            }
        }
    }
    return Double(dp[m][n]) / Double(m)
}

func computeCER(reference: String, hypothesis: String) -> Double {
    let ref = Array(reference)
    let hyp = Array(hypothesis)
    guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }

    let m = ref.count, n = hyp.count
    var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
    for i in 0...m { dp[i][0] = i }
    for j in 0...n { dp[0][j] = j }
    for i in 1...m {
        for j in 1...n {
            if ref[i-1] == hyp[j-1] {
                dp[i][j] = dp[i-1][j-1]
            } else {
                dp[i][j] = 1 + min(dp[i-1][j], dp[i][j-1], dp[i-1][j-1])
            }
        }
    }
    return Double(dp[m][n]) / Double(m)
}

// MARK: - Audio Loading

func loadWAV(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let frameCount = AVAudioFrameCount(file.length)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        return []
    }
    try file.read(into: buffer)

    // If already 16kHz mono float32, extract directly
    if format.sampleRate == 16000 && format.channelCount == 1 {
        guard let data = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }

    // Resample to 16kHz mono
    let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    // Downmix to mono if needed
    var inputBuffer = buffer
    if format.channelCount > 1, let src = buffer.floatChannelData {
        let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)!
        if let monoBuf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameCapacity),
           let dst = monoBuf.floatChannelData?[0] {
            monoBuf.frameLength = buffer.frameLength
            let channels = Int(format.channelCount)
            let scale = 1.0 / Float(channels)
            for i in 0..<Int(buffer.frameLength) {
                var sum: Float = 0
                for ch in 0..<channels { sum += src[ch][i] }
                dst[i] = sum * scale
            }
            inputBuffer = monoBuf
        }
    }

    guard let converter = AVAudioConverter(from: inputBuffer.format, to: targetFormat) else {
        guard let data = inputBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(inputBuffer.frameLength)))
    }

    let ratio = 16000.0 / inputBuffer.format.sampleRate
    let outFrames = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else { return [] }

    nonisolated(unsafe) var consumed = false
    nonisolated(unsafe) let inputRef = inputBuffer
    var convError: NSError?
    converter.convert(to: outBuf, error: &convError) { _, status in
        if consumed { status.pointee = .endOfStream; return nil }
        consumed = true
        status.pointee = .haveData
        return inputRef
    }

    guard let data = outBuf.floatChannelData else { return [] }
    return Array(UnsafeBufferPointer(start: data[0], count: Int(outBuf.frameLength)))
}

// MARK: - Main

struct Result: Codable {
    let model: String
    let language: String
    let file: String
    let wer: Double
    let cer: Double
    let elapsed: Double
    let ref: String
    let hyp: String
}

func runBenchmark() async throws {
    do {
        let samplesURL = benchmarkDir.appendingPathComponent("samples.json")
        let data = try Data(contentsOf: samplesURL)
        let samples = try JSONDecoder().decode([Sample].self, from: data)

        log("WhisperKit CoreML Benchmark")
        log("Loaded \(samples.count) samples from \(benchmarkDir.path)")
        log("Models: \(modelsToTest.map(\.name).joined(separator: ", "))")
        log(String(repeating: "=", count: 110))

        var allResults: [Result] = []

        for (modelName, variant) in modelsToTest {
            log("\n--- Model: \(modelName) (WhisperKit CoreML: \(variant)) ---")
            log("Loading model...")

            let loadStart = CFAbsoluteTimeGetCurrent()
            let config = WhisperKitConfig(
                model: variant,
                modelRepo: "argmaxinc/whisperkit-coreml",
                verbose: false,
                prewarm: true
            )
            let whisperKit = try await WhisperKit(config)
            let loadElapsed = CFAbsoluteTimeGetCurrent() - loadStart
            log("Model loaded in \(String(format: "%.1f", loadElapsed))s")

            let langMap = ["polish": "pl", "spanish": "es", "french": "fr", "german": "de", "english": "en"]

            for sample in samples {
                let wavFile = sample.file.replacingOccurrences(of: ".opus", with: ".wav")
                let wavURL = benchmarkDir.appendingPathComponent(wavFile)

                guard FileManager.default.fileExists(atPath: wavURL.path) else {
                    log("  [\(sample.language)] \(wavFile): MISSING")
                    continue
                }

                do {
                    let audioSamples = try loadWAV(wavURL)
                    guard !audioSamples.isEmpty else {
                        log("  [\(sample.language)] \(wavFile): EMPTY AUDIO")
                        continue
                    }

                    let langCode = langMap[sample.language] ?? sample.language
                    let options = DecodingOptions(
                        language: langCode,
                        wordTimestamps: false
                    )

                    let start = CFAbsoluteTimeGetCurrent()
                    let results = try await whisperKit.transcribe(audioArray: audioSamples, decodeOptions: options)
                    let elapsed = CFAbsoluteTimeGetCurrent() - start

                    let hypothesis = results.map { $0.text }.joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    let refNorm = normalizeText(sample.transcript)
                    let hypNorm = normalizeText(hypothesis)

                    let sampleWER = computeWER(reference: refNorm, hypothesis: hypNorm)
                    let sampleCER = computeCER(reference: refNorm, hypothesis: hypNorm)

                    allResults.append(Result(
                        model: modelName,
                        language: sample.language,
                        file: (wavFile as NSString).lastPathComponent,
                        wer: sampleWER,
                        cer: sampleCER,
                        elapsed: elapsed,
                        ref: String(refNorm.prefix(80)),
                        hyp: String(hypNorm.prefix(80))
                    ))

                    let werPct = String(format: "%.1f%%", sampleWER * 100)
                    let cerPct = String(format: "%.1f%%", sampleCER * 100)
                    log("  [\(sample.language)] \((wavFile as NSString).lastPathComponent): WER=\(werPct) CER=\(cerPct) (\(String(format: "%.1f", elapsed))s)")

                    if sampleWER > 0.5 {
                        log("    REF: \(String(refNorm.prefix(100)))")
                        log("    HYP: \(String(hypNorm.prefix(100)))")
                    }
                } catch {
                    log("  [\(sample.language)] \(wavFile): ERROR \(error)")
                }
            }
        }

        // Summary
        log("\n" + String(repeating: "=", count: 110))
        log("WHISPERKIT COREML BENCHMARK RESULTS")
        log(String(repeating: "=", count: 110))
        log(String(format: "%-20s %-10s %-18s %8s %8s %8s", "Model", "Language", "File", "WER%", "CER%", "Time(s)"))
        log(String(repeating: "-", count: 110))

        for r in allResults {
            log(String(format: "%-20s %-10s %-18s %7.1f%% %7.1f%% %7.1f",
                         r.model, r.language, r.file, r.wer * 100, r.cer * 100, r.elapsed))
        }

        // Per-model averages
        log(String(repeating: "-", count: 110))
        for (modelName, _) in modelsToTest {
            let modelResults = allResults.filter { $0.model == modelName }
            guard !modelResults.isEmpty else { continue }
            let avgWER = modelResults.map(\.wer).reduce(0, +) / Double(modelResults.count)
            let avgCER = modelResults.map(\.cer).reduce(0, +) / Double(modelResults.count)
            let avgTime = modelResults.map(\.elapsed).reduce(0, +) / Double(modelResults.count)
            log(String(format: "%-20s %-10s %-18s %7.1f%% %7.1f%% %7.1f",
                         modelName, "AVG", "", avgWER * 100, avgCER * 100, avgTime))
        }

        // Per-model per-language averages
        log("\n--- Average WER by Language ---")
        for (modelName, _) in modelsToTest {
            let modelResults = allResults.filter { $0.model == modelName }
            let langs = Set(modelResults.map(\.language)).sorted()
            for lang in langs {
                let langResults = modelResults.filter { $0.language == lang }
                let avgWER = langResults.map(\.wer).reduce(0, +) / Double(langResults.count)
                log(String(format: "  %-20s %-10s WER=%.1f%%", modelName, lang, avgWER * 100))
            }
        }

        // Save results
        let resultsURL = benchmarkDir.appendingPathComponent("coreml_results.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try encoder.encode(allResults)
        try jsonData.write(to: resultsURL)
        log("\nResults saved to \(resultsURL.path)")
    } catch {
        log("FATAL: \(error)")
        exit(1)
    }
}

// Catch segfaults
import Darwin
signal(SIGSEGV) { _ in
    let msg = "SEGFAULT caught! Check CoreML model compilation.\n"
    msg.withCString { ptr in _ = write(STDERR_FILENO, ptr, strlen(ptr)) }
    _exit(139)
}
signal(SIGBUS) { _ in
    let msg = "SIGBUS caught!\n"
    msg.withCString { ptr in _ = write(STDERR_FILENO, ptr, strlen(ptr)) }
    _exit(138)
}

// Top-level async entry point
Task {
    try await runBenchmark()
    exit(0)
}
dispatchMain()
