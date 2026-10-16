import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
    func upload(_ request: URLRequest, file: URL) async throws -> HTTPResponse
}

/// Avoid implicit POST retries and forwarding credentials through redirects.
public final class URLSessionTransport: NSObject, HTTPTransport, @unchecked Sendable {
    private var storedSession: URLSession?
    private let sessionLock = NSLock()
    private var session: URLSession {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if let storedSession { return storedSession }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
        storedSession = session
        return session
    }
    public override init() { super.init() }
    deinit { storedSession?.invalidateAndCancel() }
    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PrintError.transport("服务器没有返回 HTTP 响应。") }
        return HTTPResponse(status: http.statusCode, body: body)
    }
    public func upload(_ request: URLRequest, file: URL) async throws -> HTTPResponse {
        let (body, response) = try await session.upload(for: request, fromFile: file)
        guard let http = response as? HTTPURLResponse else { throw PrintError.transport("上传没有返回 HTTP 响应。") }
        return HTTPResponse(status: http.statusCode, body: body)
    }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public enum WireEncoding {
    public static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(fields.keys.sorted().map { key in
            let value = fields[key]!
            return key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
    public static func request(url: URL, method: String = "POST", fields: [String: String]) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form(fields)
        return req
    }
}
