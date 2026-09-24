import XCTest
@testable import OpenOatsKit

final class OpenRouterClientTests: XCTestCase {
    func testChatCompletionsURLNormalizesBaseURLs() {
        func url(_ base: String) -> String? { OpenRouterClient.chatCompletionsURL(from: base)?.absoluteString }
        XCTAssertEqual(url("http://localhost:4000"), "http://localhost:4000/v1/chat/completions")
        XCTAssertEqual(url("https://api.openai.com/v1/"), "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(url("https://api.openai.com/v1/chat/completions"), "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(url("https://openrouter.ai/api"), "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(
            url("https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"),
            "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
        )
        XCTAssertNil(url("not a url"))
    }

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

    func testAnthropicMessagesURLNormalizesBaseURL() {
        XCTAssertEqual(
            OpenRouterClient.anthropicMessagesURL(from: "https://api.anthropic.com")?.absoluteString,
            "https://api.anthropic.com/v1/messages"
        )
        XCTAssertEqual(
            OpenRouterClient.anthropicMessagesURL(from: "https://api.anthropic.com/v1")?.absoluteString,
            "https://api.anthropic.com/v1/messages"
        )
        XCTAssertEqual(
            OpenRouterClient.anthropicMessagesURL(from: "https://proxy.example.com/anthropic/v1/messages")?.absoluteString,
            "https://proxy.example.com/anthropic/v1/messages"
        )
    }

    func testAnthropicMessagesURLRejectsInvalidBaseURL() {
        XCTAssertNil(OpenRouterClient.anthropicMessagesURL(from: "not a url"))
    }

    // MARK: - Non-streaming completion decoding

    private func completionData(message: String) -> Data {
        Data(#"{"choices": [{"message": \#(message)}]}"#.utf8)
    }

    func testCompletionTextReturnsContentForNormalResponse() throws {
        let data = completionData(message: #"{"role": "assistant", "content": "Meeting notes"}"#)

        XCTAssertEqual(try OpenRouterClient.completionText(from: data), "Meeting notes")
    }

    func testCompletionTextPrefersContentWhenReasoningAlsoPresent() throws {
        let data = completionData(
            message: #"{"role": "assistant", "content": "Final notes", "reasoning": "thinking..."}"#
        )

        XCTAssertEqual(try OpenRouterClient.completionText(from: data), "Final notes")
    }

    func testCompletionTextThrowsForNullContentWithReasoning() {
        // mlx_lm.server + Qwen3 with thinking enabled: content is null and the
        // whole response lands in `reasoning`. This used to fail JSON decoding.
        let data = completionData(
            message: #"{"role": "assistant", "content": null, "reasoning": "Okay, the user wants..."}"#
        )

        XCTAssertThrowsError(try OpenRouterClient.completionText(from: data)) { error in
            guard case OpenRouterClient.OpenRouterError.reasoningOnlyResponse = error else {
                return XCTFail("Expected reasoningOnlyResponse, got \(error)")
            }
            let description = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(description.contains("only reasoning output"), "Unhelpful description: \(description)")
            XCTAssertTrue(description.contains("Thinking mode"), "Unhelpful description: \(description)")
            XCTAssertTrue(description.contains("token budget"), "Unhelpful description: \(description)")
        }
    }

    func testCompletionTextThrowsForEmptyContentWithReasoning() {
        let data = completionData(
            message: #"{"role": "assistant", "content": "", "reasoning": "Okay, the user wants..."}"#
        )

        XCTAssertThrowsError(try OpenRouterClient.completionText(from: data)) { error in
            guard case OpenRouterClient.OpenRouterError.reasoningOnlyResponse = error else {
                return XCTFail("Expected reasoningOnlyResponse, got \(error)")
            }
        }
    }

    func testCompletionTextThrowsForWhitespaceOnlyContentWithReasoning() {
        // Untrimmed emptiness checks let a "\n" content field pass as an answer.
        let data = completionData(
            message: #"{"role": "assistant", "content": "\n", "reasoning": "Okay, the user wants..."}"#
        )

        XCTAssertThrowsError(try OpenRouterClient.completionText(from: data)) { error in
            guard case OpenRouterClient.OpenRouterError.reasoningOnlyResponse = error else {
                return XCTFail("Expected reasoningOnlyResponse, got \(error)")
            }
        }
    }

    func testCompletionTextReturnsContentUntrimmedWhenItIsNotBlank() throws {
        let data = completionData(message: #"{"role": "assistant", "content": "  Meeting notes\n"}"#)

        XCTAssertEqual(try OpenRouterClient.completionText(from: data), "  Meeting notes\n")
    }

    func testCompletionTextThrowsEmptyResponseForNullContentWithoutReasoning() {
        let data = completionData(message: #"{"role": "assistant", "content": null}"#)

        XCTAssertThrowsError(try OpenRouterClient.completionText(from: data)) { error in
            guard case OpenRouterClient.OpenRouterError.emptyResponse = error else {
                return XCTFail("Expected emptyResponse, got \(error)")
            }
            let description = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(description.contains("Empty response"), "Unhelpful description: \(description)")
        }
    }

    func testCompletionTextThrowsEmptyResponseWhenThereAreNoChoices() {
        let data = Data(#"{"choices": []}"#.utf8)

        XCTAssertThrowsError(try OpenRouterClient.completionText(from: data)) { error in
            guard case OpenRouterClient.OpenRouterError.emptyResponse = error else {
                return XCTFail("Expected emptyResponse, got \(error)")
            }
        }
    }

    // MARK: - Streaming completion outcome

    func testStreamOutcomeFlagsReasoningOnlyStream() {
        var outcome = OpenRouterClient.StreamOutcome()
        outcome.record(content: nil, reasoning: "Okay, the user wants")
        outcome.record(content: "", reasoning: " a summary...")

        XCTAssertTrue(outcome.isReasoningOnly)
    }

    func testStreamOutcomeIsNotReasoningOnlyWhenContentArrives() {
        var outcome = OpenRouterClient.StreamOutcome()
        outcome.record(content: nil, reasoning: "Okay, the user wants")
        outcome.record(content: "## Summary", reasoning: nil)

        XCTAssertFalse(outcome.isReasoningOnly)
    }

    func testStreamOutcomeIsNotReasoningOnlyForAnOrdinaryStream() {
        var outcome = OpenRouterClient.StreamOutcome()
        outcome.record(content: "## Summary", reasoning: nil)
        outcome.record(content: "\n- point", reasoning: nil)

        XCTAssertFalse(outcome.isReasoningOnly)
        XCTAssertTrue(outcome.sawContent)
        XCTAssertFalse(outcome.sawReasoning)
    }

    func testStreamOutcomeIgnoresEmptyDeltas() {
        var outcome = OpenRouterClient.StreamOutcome()
        outcome.record(content: "", reasoning: "")

        XCTAssertFalse(outcome.isReasoningOnly)
        XCTAssertFalse(outcome.sawContent)
        XCTAssertFalse(outcome.sawReasoning)
    }

    // MARK: - HTTP error detail

    func testErrorDetailReadsOllamaStyleStringErrorField() throws {
        let data = Data(#"{"error":"model 'qwen3' not found, try pulling it first"}"#.utf8)
        XCTAssertEqual(
            OpenRouterClient.errorDetail(from: data),
            "model 'qwen3' not found, try pulling it first"
        )
    }

    func testErrorDetailReadsOpenAIStyleNestedErrorMessage() throws {
        let data = Data(#"{"error":{"message":"The model does not exist","type":"invalid_request_error"}}"#.utf8)
        XCTAssertEqual(OpenRouterClient.errorDetail(from: data), "The model does not exist")
    }

    func testErrorDetailFallsBackToRawBodyForNonJSON() throws {
        let data = Data("404 page not found".utf8)
        XCTAssertEqual(OpenRouterClient.errorDetail(from: data), "404 page not found")
    }

    func testErrorDetailReturnsNilForEmptyBody() throws {
        XCTAssertNil(OpenRouterClient.errorDetail(from: Data()))
        XCTAssertNil(OpenRouterClient.errorDetail(from: Data("   \n  ".utf8)))
    }

    func testErrorDetailTruncatesLongBodies() throws {
        let long = String(repeating: "a", count: 900)
        let detail = try XCTUnwrap(OpenRouterClient.errorDetail(from: Data(long.utf8)))
        XCTAssertEqual(detail.count, 301)
        XCTAssertTrue(detail.hasSuffix("\u{2026}"))
    }

    func testErrorDetailCollapsesNewlines() throws {
        let data = Data("first line\nsecond line".utf8)
        XCTAssertEqual(OpenRouterClient.errorDetail(from: data), "first line second line")
    }

    func testHTTPErrorDescriptionAppendsServerDetail() throws {
        let error = OpenRouterClient.OpenRouterError.httpError(
            404,
            host: "localhost",
            detail: "model 'qwen3' not found"
        )
        XCTAssertEqual(
            error.errorDescription,
            "Local LLM API error (HTTP 404): model 'qwen3' not found"
        )
    }

    func testHTTPErrorDescriptionUnchangedWithoutDetail() throws {
        let error = OpenRouterClient.OpenRouterError.httpError(500, host: "openrouter.ai")
        XCTAssertEqual(error.errorDescription, "OpenRouter API error (HTTP 500)")
    }
}
