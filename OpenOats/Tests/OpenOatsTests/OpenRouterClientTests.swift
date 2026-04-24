import XCTest
@testable import OpenOatsKit

final class OpenRouterClientTests: XCTestCase {
    func testPreflightErrorRequiresAPIKeyForOpenRouterHost() throws {
        let url = try XCTUnwrap(URL(string: "https://openrouter.ai/api/v1/chat/completions"))

        let error = OpenRouterClient.preflightError(for: url, apiKey: nil)

        guard case .missingAPIKey(let host)? = error else {
            return XCTFail("Expected missing API key error for OpenRouter host")
        }
        XCTAssertEqual(host, "openrouter.ai")
        XCTAssertEqual(error?.errorDescription, "OpenRouter API key required")
    }

    func testPreflightErrorAllowsOpenRouterHostWhenAPIKeyExists() throws {
        let url = try XCTUnwrap(URL(string: "https://openrouter.ai/api/v1/chat/completions"))

        let error = OpenRouterClient.preflightError(for: url, apiKey: "sk-or-v1-test")

        XCTAssertNil(error)
    }

    func testPreflightErrorDoesNotRequireAPIKeyForLocalOpenAICompatibleHost() throws {
        let url = try XCTUnwrap(URL(string: "http://localhost:11434/v1/chat/completions"))

        let error = OpenRouterClient.preflightError(for: url, apiKey: nil)

        XCTAssertNil(error)
    }

    func testPreflightErrorDoesNotRequireAPIKeyForRemoteCustomHost() throws {
        let url = try XCTUnwrap(URL(string: "https://api.example.com/v1/chat/completions"))

        let error = OpenRouterClient.preflightError(for: url, apiKey: nil)

        XCTAssertNil(error)
    }
}
