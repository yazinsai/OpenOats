import XCTest
@testable import OpenOatsKit

final class VoyageClientTests: XCTestCase {
    func testDescribeHTTPErrorMapsBilling429ToActionableMessage() {
        let data = #"{"detail":"You have not yet added your payment method in the billing page and will not be able to make requests"}"#
            .data(using: .utf8)!

        let error = VoyageClient.describeHTTPError(statusCode: 429, data: data)

        XCTAssertEqual(error.message, "Add a payment method in Voyage AI billing to enable knowledge base indexing.")
        XCTAssertFalse(error.retryable)
    }

    func testDescribeHTTPErrorKeepsGeneric429Retryable() {
        let data = #"{"detail":"Rate limit exceeded"}"#.data(using: .utf8)!

        let error = VoyageClient.describeHTTPError(statusCode: 429, data: data)

        XCTAssertEqual(error.message, "Voyage AI is rate limiting requests. Try again in a moment.")
        XCTAssertTrue(error.retryable)
    }

    func testDescribeHTTPErrorParsesJSONDetailWithoutRawBlob() {
        let data = #"{"detail":"Bad request payload"}"#.data(using: .utf8)!

        let error = VoyageClient.describeHTTPError(statusCode: 400, data: data)

        XCTAssertEqual(error.message, "Bad request payload")
        XCTAssertFalse(error.retryable)
    }
}
