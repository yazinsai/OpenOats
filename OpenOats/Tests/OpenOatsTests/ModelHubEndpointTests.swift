import XCTest
@testable import OpenOatsKit

final class ModelHubEndpointTests: XCTestCase {
    private let env = [
        "HF_ENDPOINT": "https://hf.example.com",
        "REGISTRY_URL": "https://registry.example.com",
        "MODEL_REGISTRY_URL": "https://model-registry.example.com",
    ]

    func testPrecedence() {
        XCTAssertEqual(ModelHubEndpoint.resolve(configured: "https://app.example.com", environment: env).source, .setting)
        XCTAssertEqual(ModelHubEndpoint.resolve(configured: "  ", environment: env).endpoint, "https://hf.example.com")
        var e = env
        e["HF_ENDPOINT"] = ""
        XCTAssertEqual(ModelHubEndpoint.resolve(configured: nil, environment: e).source, .registryURL)
        e["REGISTRY_URL"] = nil
        XCTAssertEqual(ModelHubEndpoint.resolve(configured: nil, environment: e).source, .modelRegistryURL)
        let fallback = ModelHubEndpoint.resolve(configured: "", environment: [:])
        XCTAssertEqual(fallback.endpoint, "https://huggingface.co")
        XCTAssertEqual(fallback.source, .defaultEndpoint)
    }

    func testNormalizesWhitespaceAndTrailingSlashes() {
        XCTAssertEqual(
            ModelHubEndpoint.resolve(configured: " https://hf-api.gitee.com// ", environment: [:]).endpoint,
            "https://hf-api.gitee.com"
        )
    }

    func testInvalidValueIsNotReplacedByOfficialHub() {
        let resolved = ModelHubEndpoint.resolve(configured: "not a url", environment: [:])
        XCTAssertEqual(resolved.endpoint, "not a url")
        XCTAssertNotNil(ModelHubEndpoint.validationError(resolved.endpoint))
    }

    func testValidation() {
        XCTAssertNil(ModelHubEndpoint.validationError(""))
        XCTAssertNil(ModelHubEndpoint.validationError("https://hf-api.gitee.com"))
        XCTAssertNil(ModelHubEndpoint.validationError("http://localhost:8080/hub"))
        XCTAssertNotNil(ModelHubEndpoint.validationError("ftp://mirror.example.com"))
        XCTAssertNotNil(ModelHubEndpoint.validationError("https://"))
        XCTAssertNotNil(ModelHubEndpoint.validationError("https://user:pass@mirror.example.com"))
        XCTAssertNotNil(ModelHubEndpoint.validationError("https://mirror.example.com?x=1"))
        XCTAssertNotNil(ModelHubEndpoint.validationError("https://mirror.example.com#frag"))
    }
}
