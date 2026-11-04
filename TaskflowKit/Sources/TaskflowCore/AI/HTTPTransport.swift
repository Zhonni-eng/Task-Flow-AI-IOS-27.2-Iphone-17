// One HTTP request with a JSON answer - a port of requestJson in providers/shared.cjs. Never follows
// redirects (the key must not be forwarded to another address), aborts after the timeout, limits the
// body size, and maps failures to app codes only (never to response text).
import Foundation

public struct HTTPRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public enum TransportError: Error, Sendable {
    case timeout
    case network
}

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// URLSession without caches, cookies or credential storage; redirects are refused.
public final class URLSessionTransport: NSObject, HTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    public override init() {}

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.httpBody = request.body
        do {
            let (data, response) = try await session.data(for: urlRequest)
            return HTTPResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        } catch let error as URLError where error.code == .timedOut {
            throw TransportError.timeout
        } catch {
            throw TransportError.network
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

enum HTTPJSON {
    /// { json } for 2xx JSON, otherwise an app code - TIMEOUT, NETWORK, an HTTP-status code, or MALFORMED.
    static func request(_ transport: HTTPTransport, url: URL, method: String = "GET", headers: [String: String] = [:], body: JSONValue? = nil, rawBody: Data? = nil, contentType: String? = nil, timeout: TimeInterval) async -> Swift.Result<JSONValue, AICode> {
        var allHeaders = ["accept": "application/json"]
        if body != nil { allHeaders["content-type"] = "application/json" }
        if let contentType { allHeaders["content-type"] = contentType }
        for (key, value) in headers { allHeaders[key] = value }
        let response: HTTPResponse
        do {
            response = try await transport.send(HTTPRequest(url: url, method: method, headers: allHeaders, body: body.map { $0.serialized() } ?? rawBody, timeout: timeout))
        } catch TransportError.timeout {
            return .failure(.timeout)
        } catch {
            return .failure(.network)
        }
        if (300..<400).contains(response.status) { return .failure(.providerError) }
        if !(200..<300).contains(response.status) { return .failure(WirePlan.code(forStatus: response.status)) }
        if response.body.count > WirePlan.maxBodyChars * 4 { return .failure(.malformed) }
        guard let json = try? JSONValue.parse(response.body) else { return .failure(.malformed) }
        return .success(json)
    }

    static func url(_ text: String) -> URL? { URL(string: text) }

    static func pathComponent(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}
