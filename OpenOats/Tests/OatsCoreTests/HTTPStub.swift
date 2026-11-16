import Foundation

/// Seam 3 HTTP stub: a URLSession whose requests go to `respond` instead of the network.
/// Each stub gets its own host, so tests using it can run in parallel.
final class StubHTTP: @unchecked Sendable {
    typealias Respond = @Sendable (URLRequest, Int) throws -> (Int, [String: String], Data)
    let host = "\(UUID().uuidString.lowercased()).test"
    let respond: Respond
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { _requests } }
    var base: String { "https://\(host)/v1" }

    /// `respond(request, attempt)` returns status, headers and body; throw a `URLError` to simulate a dropped connection.
    init(_ respond: @escaping Respond) {
        self.respond = respond
        StubProtocol.lock.withLock { StubProtocol.stubs[host] = self }
    }

    deinit { StubProtocol.lock.withLock { StubProtocol.stubs[host] = nil } }

    var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    fileprivate func handle(_ request: URLRequest) throws -> (Int, [String: String], Data) {
        let attempt = lock.withLock { _requests.append(request); return _requests.count }
        return try respond(request, attempt)
    }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var stubs: [String: StubHTTP] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            stream.open()
            while case let n = stream.read(&buffer, maxLength: buffer.count), n > 0 { body.append(buffer, count: n) }
            stream.close()
            request.httpBody = body
        }
        let stub = Self.lock.withLock { Self.stubs[request.url?.host ?? ""] }
        do {
            guard let stub else { throw URLError(.cannotFindHost) }
            let (status, headers, data) = try stub.handle(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

