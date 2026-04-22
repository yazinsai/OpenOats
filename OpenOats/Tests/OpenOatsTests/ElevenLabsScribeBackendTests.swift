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
