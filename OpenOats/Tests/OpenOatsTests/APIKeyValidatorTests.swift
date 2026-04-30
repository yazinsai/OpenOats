import XCTest
@testable import OpenOatsKit

final class APIKeyValidatorTests: XCTestCase {
    func testValidateElevenLabsKeyRejectsEmptyKey() async {
        let result = await APIKeyValidator.validateElevenLabsKey(" \n ")

        XCTAssertEqual(result, .invalid(message: "API key is empty"))
    }

    func testValidationResultTreatsSuccessAsValid() {
        let response = makeResponse(statusCode: 200)

        let result = APIKeyValidator.validationResult(for: response, authFailureMessage: "bad key")

        XCTAssertEqual(result, .valid)
    }

    func testValidationResultTreatsAuthFailureAsInvalid() {
        let response = makeResponse(statusCode: 401)

        let result = APIKeyValidator.validationResult(for: response, authFailureMessage: "bad key")

        XCTAssertEqual(result, .invalid(message: "bad key"))
    }

    func testValidationResultTreatsUnexpectedStatusAsNetworkError() {
        let response = makeResponse(statusCode: 500)

        let result = APIKeyValidator.validationResult(for: response, authFailureMessage: "bad key")

        XCTAssertEqual(result, .networkError(message: "Unexpected status: 500"))
    }

    private func makeResponse(statusCode: Int) -> URLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.elevenlabs.io/v1/voices")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}
