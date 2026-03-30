import XCTest
@testable import OpenOatsKit

final class WAVEncoderTests: XCTestCase {

    func testEmptyInputProducesValidHeader() {
        let wav = WAVEncoder.encode(samples: [])
        XCTAssertEqual(wav.count, 44)
        // "RIFF" magic
        XCTAssertEqual(wav[0], 0x52)
        XCTAssertEqual(wav[1], 0x49)
        XCTAssertEqual(wav[2], 0x46)
        XCTAssertEqual(wav[3], 0x46)
        // "WAVE" magic
        XCTAssertEqual(wav[8],  0x57)
        XCTAssertEqual(wav[9],  0x41)
        XCTAssertEqual(wav[10], 0x56)
        XCTAssertEqual(wav[11], 0x45)
    }

    func testSampleCountMatchesDataChunkSize() {
        let samples: [Float] = [0.0, 0.5, -0.5, 1.0, -1.0]
        let wav = WAVEncoder.encode(samples: samples)
        let expected = 44 + samples.count * 2
        XCTAssertEqual(wav.count, expected)
    }

    func testSampleRateEncodedCorrectly() {
        let sampleRate: Int = 16000
        let wav = WAVEncoder.encode(samples: [], sampleRate: sampleRate)
        // Bytes 24-27: sample rate as UInt32 LE
        let encoded = UInt32(wav[24])
            | (UInt32(wav[25]) << 8)
            | (UInt32(wav[26]) << 16)
            | (UInt32(wav[27]) << 24)
        XCTAssertEqual(encoded, UInt32(sampleRate))
    }

    func testClampingOutOfRangeValues() {
        let samples: [Float] = [2.0, -2.0]
        let wav = WAVEncoder.encode(samples: samples)
        // Bytes 44-45: first sample (2.0 clamped to 1.0 -> Int16.max = 32767)
        let s0 = Int16(bitPattern: UInt16(wav[44]) | (UInt16(wav[45]) << 8))
        XCTAssertEqual(s0, Int16.max)
        // Bytes 46-47: second sample (-2.0 clamped to -1.0 -> Int16.min = -32768)
        let s1 = Int16(bitPattern: UInt16(wav[46]) | (UInt16(wav[47]) << 8))
        XCTAssertEqual(s1, Int16.min)
    }
}
