import XCTest
@testable import RoamPrintCore
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// An actual loopback HTTP server exercises the system curl binary and its config parser.
final class LoopbackHTTPServer: @unchecked Sendable {
    struct Request {
        let method: String
        let target: String
        let headers: [String: String]
        var authorization: String? { headers["authorization"] }
        let body: Data
    }
    let port: Int
    private let descriptor: Int32
    private let lock = NSLock()
    private var captured: [Request] = []
    private var serverError: String?
    private let statuses: [Int]
    private let responseBodies: [Data]
    private let dropResponses: Set<Int>
    private let done: XCTestExpectation
    init(statuses: [Int], responseBodies: [Data] = [], dropResponses: Set<Int> = [], done: XCTestExpectation) throws {
        self.statuses = statuses; self.responseBodies = responseBodies
        self.dropResponses = dropResponses; self.done = done
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw PrintError.transport("test socket creation failed") }
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); throw PrintError.transport("test bind failed") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard result == 0 else { close(fd); throw PrintError.transport("test getsockname failed") }
        port = Int(UInt16(bigEndian: address.sin_port)); descriptor = fd
    }
    func start() {
        DispatchQueue.global().async { [self] in
            defer { close(descriptor); done.fulfill() }
            do {
                for (index, status) in statuses.enumerated() {
                    try readable(descriptor)
                    let client = accept(descriptor, nil, nil)
                    guard client >= 0 else { throw PrintError.transport("test accept failed") }
                    defer { close(client) }
                    #if canImport(Darwin)
                    var one: Int32 = 1
                    _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                    #endif
                    let request = try receive(client)
                    lock.lock(); captured.append(request); lock.unlock()
                    if dropResponses.contains(index) { continue }
                    let body = responseBodies.indices.contains(index) ? responseBodies[index] : Data()
                    var response = "HTTP/1.1 \(status) Test\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
                    if status == 302 { response += "Location: http://127.0.0.1:\(port)/redirect\r\n" }
                    response += "\r\n"
                    try write(client, Data(response.utf8) + body)
                }
            } catch {
                lock.lock(); serverError = error.localizedDescription; lock.unlock()
            }
        }
    }
    func snapshot() -> ([Request], String?) {
        lock.lock(); defer { lock.unlock() }
        return (captured, serverError)
    }
    private func readable(_ fd: Int32) throws {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 15000) == 1, descriptor.revents & Int16(POLLIN) != 0 else {
            throw PrintError.transport("test server receive timed out")
        }
    }
    private func write(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                #if canImport(Darwin)
                let sent = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                #else
                let sent = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, Int32(MSG_NOSIGNAL))
                #endif
                guard sent > 0 else { throw PrintError.transport("test server send failed") }
                offset += sent
            }
        }
    }
    private func receive(_ fd: Int32) throws -> Request {
        var bytes = Data(), chunk = [UInt8](repeating: 0, count: 65536)
        func readMore() throws {
            try readable(fd)
            let count = recv(fd, &chunk, chunk.count, 0)
            guard count > 0, bytes.count + count <= 2 * 1024 * 1024 else {
                throw PrintError.transport("test request incomplete")
            }
            bytes.append(contentsOf: chunk[..<count])
        }
        while bytes.range(of: Data("\r\n\r\n".utf8)) == nil { try readMore() }
        let boundary = bytes.range(of: Data("\r\n\r\n".utf8))!
        let lines = String(decoding: bytes[..<boundary.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3 else { throw PrintError.transport("test bad request") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { throw PrintError.transport("test bad header") }
            headers[String(parts[0]).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        let count = headers["content-length"].flatMap(Int.init) ?? 0
        if headers["expect"]?.lowercased() == "100-continue" {
            try write(fd, Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }
        while bytes.count < boundary.upperBound + count { try readMore() }
        return Request(method: String(first[0]), target: String(first[1]), headers: headers,
                       body: Data(bytes[boundary.upperBound..<boundary.upperBound + count]))
    }
}

final class CurlUploadTests: XCTestCase {
    private func source() throws -> (URL, Data) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + " quoted \"文档.pdf")
        var data = Data("%PDF-1.7\n".utf8)
        data.append(Data(repeating: 0x9f, count: 1024 * 1024))
        try data.write(to: url)
        return (url, data)
    }
    private func storage(port: Int) -> V5Storage {
        V5Storage(id: 7, type: 6, host: "127.0.0.1", port: port, username: "storage-user",
                  encryptedPassword: "unused-by-uploader", fileEncoding: 0)
    }
    func testActualWebDAVRequestsPreserveBytesAndQuotedPassword() async throws {
        let complete = expectation(description: "WebDAV server completed")
        let server = try LoopbackHTTPServer(statuses: [405, 201, 201], done: complete)
        server.start()
        let (file, bytes) = try source()
        defer { try? FileManager.default.removeItem(at: file) }
        let password = "quote\"slash\\ with space&:!"
        var uploadError: Error?
        do {
            try await NativeCurlUploader().upload(file: file, storage: storage(port: server.port),
                password: password, path: "/PrintDir/20261013/{fixture}.pdf")
        } catch { uploadError = error }
        await fulfillment(of: [complete], timeout: 20)
        XCTAssertNil(uploadError)
        let (requests, error) = server.snapshot()
        XCTAssertNil(error)
        XCTAssertEqual(requests.map(\.method), ["MKCOL", "MKCOL", "PUT"])
        XCTAssertEqual(requests.map(\.target), ["/PrintDir", "/PrintDir/20261013", "/PrintDir/20261013/%7Bfixture%7D.pdf"])
        let basic = "Basic " + Data(("storage-user:" + password).utf8).base64EncodedString()
        XCTAssertTrue(requests.allSatisfy { $0.authorization == basic })
        XCTAssertEqual(requests.last?.body, bytes)
    }
    func testStorageFailureAndRedirectDoNotUploadOrRetry() async throws {
        for status in [302, 503] {
            let complete = expectation(description: "single rejected request")
            let server = try LoopbackHTTPServer(statuses: [status], done: complete)
            server.start()
            let (file, _) = try source()
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                try await NativeCurlUploader().upload(file: file, storage: storage(port: server.port),
                    password: "secret", path: "/PrintDir/20261013/{fixture}.pdf")
                XCTFail("rejected MKCOL must prevent PUT")
            } catch { XCTAssertTrue(error.localizedDescription.contains(String(status))) }
            await fulfillment(of: [complete], timeout: 20)
            let (requests, error) = server.snapshot()
            XCTAssertNil(error)
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.method, "MKCOL")
        }
    }
}
