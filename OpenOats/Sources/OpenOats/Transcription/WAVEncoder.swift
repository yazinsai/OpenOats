import Foundation

/// Encodes raw Float32 PCM samples into WAV (RIFF/WAVE/PCM16) format.
enum WAVEncoder {
    /// Encodes mono Float32 samples at the given sample rate into a WAV Data blob.
    ///
    /// - Parameters:
    ///   - samples: Float32 audio samples, expected in -1.0...1.0.
    ///   - sampleRate: Sample rate in Hz (default 16000).
    /// - Returns: WAV data with a 44-byte header followed by PCM16 samples.
    static func encode(samples: [Float], sampleRate: Int = 16000) -> Data {
        let dataSize = samples.count * 2           // 2 bytes per Int16 sample
        let fileSize = 36 + dataSize               // header remainder + data chunk

        var data = Data(capacity: 44 + dataSize)

        // RIFF chunk
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46])      // "RIFF"
        data.append(littleEndian: UInt32(fileSize))
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45])      // "WAVE"

        // fmt sub-chunk
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])      // "fmt "
        data.append(littleEndian: UInt32(16))                   // sub-chunk size
        data.append(littleEndian: UInt16(1))                    // PCM format
        data.append(littleEndian: UInt16(1))                    // mono
        data.append(littleEndian: UInt32(sampleRate))           // sample rate
        data.append(littleEndian: UInt32(sampleRate * 2))       // byte rate (sr * channels * bps/8)
        data.append(littleEndian: UInt16(2))                    // block align
        data.append(littleEndian: UInt16(16))                   // bits per sample

        // data sub-chunk
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61])      // "data"
        data.append(littleEndian: UInt32(dataSize))

        // PCM16 samples
        for sample in samples {
            let clamped = sample.clamped(to: -1.0 ... 1.0)
            let pcm: Int16 = clamped < 0
                ? Int16(clamped * 32768)
                : Int16(clamped * 32767)
            data.append(littleEndian: pcm)
        }

        return data
    }
}

// MARK: - Private helpers

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { self.append(contentsOf: $0) }
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
