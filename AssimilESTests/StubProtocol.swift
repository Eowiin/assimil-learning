import Foundation

/// Répond à la place du réseau. Un gestionnaire par nom d'hôte : deux suites qui
/// tournent en même temps ne se marchent pas dessus, tant qu'elles prennent des
/// hôtes différents.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (Int, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func session(host: String, _ handler: @escaping Handler) -> URLSession {
        lock.withLock { handlers[host] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.lock.withLock { Self.handlers[request.url?.host() ?? ""] }
        do {
            guard let handler else { throw URLError(.cannotFindHost) }
            // Le corps d'une requête n'arrive ici que sous forme de flux.
            var request = request
            if request.httpBody == nil, let stream = request.httpBodyStream {
                request.httpBody = Data(reading: stream)
            }
            let (code, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension Data {
    init(reading stream: InputStream) {
        self.init()
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            append(buffer, count: count)
        }
    }
}
