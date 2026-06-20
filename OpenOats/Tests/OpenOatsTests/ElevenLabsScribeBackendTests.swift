import XCTest
@testable import OpenOatsKit

final class ElevenLabsScribeBackendTests: XCTestCase {

    private let boundary = "TEST-BOUNDARY"

    func testKeytermsEmittedAsSeparateMultipartParts() {
        let body = ElevenLabsScribeBackend.buildMultipartBody(
            boundary: boundary,
            wavData: Data(),
            languageCode: "en",
            keyterms: ["Alpha", "Beta Bravo", "Gamma"],
            removeFillerWords: false
        )
        let text = String(data: body, encoding: .utf8) ?? ""

        let values = extractMultipartValues(text, fieldName: "keyterms")
        XCTAssertEqual(values, ["Alpha", "Beta Bravo", "Gamma"],
                       "keyterms must be emitted as one multipart part per term")

        // Regression guard: earlier code sent a single JSON-array value.
        // That shape makes ElevenLabs Scribe reject every request with HTTP 400
        // "Some keyword contains invalid characters".
        XCTAssertFalse(text.contains("[\"Alpha\",\"Beta Bravo\",\"Gamma\"]"),
                       "body must not contain JSON-array keyterms literal")
    }

    func testKeytermsOmittedWhenEmpty() {
        let body = ElevenLabsScribeBackend.buildMultipartBody(
            boundary: boundary,
            wavData: Data(),
            languageCode: "en",
            keyterms: [],
            removeFillerWords: false
        )
        let text = String(data: body, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("name=\"keyterms\""),
                       "no keyterms part when vocabulary is empty")
    }

    func testDiarizeFlagIsSentOnlyWhenRequested() {
        let diarizedBody = ElevenLabsScribeBackend.buildMultipartBody(
            boundary: boundary,
            wavData: Data(),
            languageCode: "en",
            keyterms: [],
            removeFillerWords: false,
            diarize: true
        )
        let plainBody = ElevenLabsScribeBackend.buildMultipartBody(
            boundary: boundary,
            wavData: Data(),
            languageCode: "en",
            keyterms: [],
            removeFillerWords: false,
            diarize: false
        )

        XCTAssertEqual(
            extractMultipartValues(String(data: diarizedBody, encoding: .utf8) ?? "", fieldName: "diarize"),
            ["true"]
        )
        XCTAssertFalse((String(data: plainBody, encoding: .utf8) ?? "").contains("name=\"diarize\""))
    }

    func testTranscriptResponseBuildsDiarizedSpeakerSegments() throws {
        let response = """
        {
          "text": "Hello there. Yes.",
          "words": [
            { "text": "Hello", "start": 0.0, "end": 0.3, "type": "word", "speaker_id": "speaker_0" },
            { "text": "there", "start": 0.3, "end": 0.7, "type": "word", "speaker_id": "speaker_0" },
            { "text": ".", "start": 0.7, "end": 0.75, "type": "spacing", "speaker_id": "speaker_0" },
            { "text": "Yes", "start": 1.0, "end": 1.4, "type": "word", "speaker_id": "speaker_1" },
            { "text": ".", "start": 1.4, "end": 1.45, "type": "spacing", "speaker_id": "speaker_1" }
          ]
        }
        """

        let result = try ElevenLabsScribeBackend.parseTranscriptResponse(Data(response.utf8))

        XCTAssertEqual(result.text, "Hello there. Yes.")
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments[0].speaker, .remote(1))
        XCTAssertEqual(result.segments[0].text, "Hello there.")
        XCTAssertEqual(result.segments[0].startTime, 0.0)
        XCTAssertEqual(result.segments[0].endTime, 0.75)
        XCTAssertEqual(result.segments[1].speaker, .remote(2))
        XCTAssertEqual(result.segments[1].text, "Yes.")
        XCTAssertEqual(result.segments[1].startTime, 1.0)
        XCTAssertEqual(result.segments[1].endTime, 1.45)
    }

    // Extracts values for every multipart part matching `name="<fieldName>"`.
    // Assumes the appendMultipart format used by ElevenLabsScribeBackend:
    //   --<boundary>\r\n
    //   Content-Disposition: form-data; name="<fieldName>"\r\n
    //   \r\n
    //   <value>\r\n
    private func extractMultipartValues(_ body: String, fieldName: String) -> [String] {
        let marker = "Content-Disposition: form-data; name=\"\(fieldName)\"\r\n\r\n"
        var values: [String] = []
        var cursor = body.startIndex
        while let headerRange = body.range(of: marker, range: cursor..<body.endIndex) {
            let valueStart = headerRange.upperBound
            if let terminator = body.range(of: "\r\n--", range: valueStart..<body.endIndex) {
                values.append(String(body[valueStart..<terminator.lowerBound]))
                cursor = terminator.upperBound
            } else {
                break
            }
        }
        return values
    }
}
