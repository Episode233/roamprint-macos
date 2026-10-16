import XCTest
@testable import RoamPrintCore
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Minimal real FTP endpoint, including missing directories and a passive data connection.
private final class LocalFTPServer: @unchecked Sendable {
    struct Snapshot {
        var commands: [String] = []
        var username = ""
        var password = ""
        var path = ""
        var bytes = Data()
        var error: String?
    }
    let port: Int
    private let listener: Int32
    private let done: XCTestExpectation
    private let rejectStore: Bool
    private let lock = NSLock()
    private var result = Snapshot()

    init(done: XCTestExpectation, rejectStore: Bool = false) throws {
        self.done = done; self.rejectStore = rejectStore
        (listener, port) = try Self.listen()
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return result
    }
    func start() {
        DispatchQueue.global().async { [self] in
            var observation = Snapshot()
            defer {
                close(listener)
                lock.lock(); result = observation; lock.unlock()
                done.fulfill()
            }
            do { try serve(&observation) }
            catch { observation.error = error.localizedDescription }
        }
    }
    private static func listen() throws -> (Int32, Int) {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw PrintError.transport("FTP fixture socket failed") }
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, DarwinOrGlibcListen(fd, 4) == 0 else {
            close(fd); throw PrintError.transport("FTP fixture bind failed")
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard status == 0 else { close(fd); throw PrintError.transport("FTP fixture port failed") }
        return (fd, Int(UInt16(bigEndian: address.sin_port)))
    }
    private func acceptConnection(_ fd: Int32) throws -> Int32 {
        try readable(fd)
        let client = accept(fd, nil, nil)
        guard client >= 0 else { throw PrintError.transport("FTP fixture accept failed") }
        #if canImport(Darwin)
        var one: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        return client
    }
    private func readable(_ fd: Int32) throws {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 15000) == 1,
              descriptor.revents & Int16(POLLIN | POLLHUP) != 0 else {
            throw PrintError.transport("FTP fixture receive timed out")
        }
    }
    private func reply(_ fd: Int32, _ text: String) throws {
        try Data((text + "\r\n").utf8).withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                #if canImport(Darwin)
                let count = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                #else
                let count = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, Int32(MSG_NOSIGNAL))
                #endif
                guard count > 0 else { throw PrintError.transport("FTP fixture send failed") }
                offset += count
            }
        }
    }
    private func line(_ fd: Int32) throws -> String? {
        var bytes = Data(), byte: UInt8 = 0
        while bytes.count < 2048 {
            try readable(fd)
            let count = recv(fd, &byte, 1, 0)
            if count == 0 { return nil }
            guard count == 1 else { throw PrintError.transport("FTP fixture command failed") }
            bytes.append(byte)
            if bytes.suffix(2) == Data([13, 10]) { return String(decoding: bytes.dropLast(2), as: UTF8.self) }
        }
        throw PrintError.transport("FTP fixture command too long")
    }
    private func serve(_ observation: inout Snapshot) throws {
        let control = try acceptConnection(listener)
        defer { close(control) }
        var passive: Int32?
        defer { if let passive { close(passive) } }
        var directories: Set<String> = ["/"]
        var cwd = "/"
        try reply(control, "220 Local FTP test")
        while let line = try line(control) {
            let components = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let verb = String(components[0]), value = components.count == 2 ? String(components[1]) : ""
            observation.commands.append(verb)
            let path = value.hasPrefix("/") ? value : cwd + value
            switch verb {
            case "USER": observation.username = value; try reply(control, "331 Password required")
            case "PASS": observation.password = value; try reply(control, "230 Logged in")
            case "PWD": try reply(control, "257 \"\(cwd)\" is current directory")
            case "CWD":
                if directories.contains(path) {
                    cwd = path.hasSuffix("/") ? path : path + "/"
                    try reply(control, "250 Directory changed")
                } else { try reply(control, "550 Directory missing") }
            case "MKD": directories.insert(path); try reply(control, "257 Directory created")
            case "TYPE": try reply(control, "200 Transfer type accepted")
            case "EPSV", "PASV":
                if let passive { close(passive) }
                let (fd, port) = try Self.listen(); passive = fd
                try reply(control, verb == "EPSV" ? "229 Entering Extended Passive Mode (|||\(port)|)" :
                    "227 Entering Passive Mode (127,0,0,1,\(port / 256),\(port % 256))")
            case "STOR":
                observation.path = path
                if rejectStore { try reply(control, "550 Upload rejected"); return }
                guard let passive else { throw PrintError.transport("FTP fixture has no data socket") }
                try reply(control, "150 Open data connection")
                let dataSocket = try acceptConnection(passive)
                defer { close(dataSocket) }
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    try readable(dataSocket)
                    let count = recv(dataSocket, &buffer, buffer.count, 0)
                    if count == 0 { break }
                    guard count > 0, observation.bytes.count + count <= 2 * 1024 * 1024 else {
                        throw PrintError.transport("FTP fixture data failed")
                    }
                    observation.bytes.append(contentsOf: buffer[..<count])
                }
                try reply(control, "226 Transfer complete")
            case "QUIT": try reply(control, "221 Goodbye"); return
            default: try reply(control, "502 Command unsupported")
            }
        }
    }
}

// Qualify the POSIX function separately from the fixture's listen() factory.
private func DarwinOrGlibcListen(_ fd: Int32, _ backlog: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.listen(fd, backlog)
    #else
    return Glibc.listen(fd, backlog)
    #endif
}

final class FTPUploadTests: XCTestCase {
    func testActualFTPCreatesDirectoriesAndPreservesBytesAndCredentials() async throws {
        try await exercise(rejectStore: false)
    }
    func testRejectedFTPStoreDoesNotRetry() async throws {
        try await exercise(rejectStore: true)
    }
    private func exercise(rejectStore: Bool) async throws {
        let complete = expectation(description: "FTP session completed")
        let server = try LocalFTPServer(done: complete, rejectStore: rejectStore)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + " 文档.pdf")
        let bytes = Data("%PDF-1.7\n".utf8) + Data(repeating: 0xff, count: 1024 * 1024)
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let password = "quote\"slash\\ with space&:!"
        let storage = V5Storage(id: 2, type: 2, host: "127.0.0.1", port: server.port,
            username: "storage-user", encryptedPassword: "unused", fileEncoding: 0)
        server.start()
        var uploadError: Error?
        do {
            try await NativeCurlUploader().upload(file: file, storage: storage, password: password,
                path: "/PrintDir/20261013/{fixture}.pdf")
        } catch { uploadError = error }
        await fulfillment(of: [complete], timeout: 20)
        let observation = server.snapshot()
        XCTAssertNil(observation.error)
        XCTAssertEqual(observation.username, "storage-user")
        XCTAssertEqual(observation.password, password)
        XCTAssertEqual(observation.path, "/PrintDir/20261013/{fixture}.pdf")
        XCTAssertEqual(observation.commands.filter { $0 == "MKD" }.count, 2)
        XCTAssertEqual(observation.commands.filter { $0 == "STOR" }.count, 1)
        if rejectStore {
            XCTAssertNotNil(uploadError)
            XCTAssertTrue(observation.bytes.isEmpty)
        } else {
            XCTAssertNil(uploadError)
            XCTAssertEqual(observation.bytes, bytes)
        }
    }
}
