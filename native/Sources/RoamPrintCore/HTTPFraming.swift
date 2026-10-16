import Foundation

/// A single bounded HTTP/1 request. Every connection closes after its response.
public struct HTTPFramer {
    public static let maxBodyBytes = 128 * 1024 * 1024
    private var buffer = Data()
    public private(set) var method: String?
    public private(set) var path: String?
    public private(set) var headers: [String: String] = [:]
    public private(set) var expectsContinue = false
    public private(set) var complete = false
    private var length: Int?
    private var chunked = false
    private var chunkSize: Int?
    private var decoded = Data()
    public init() {}
    public mutating func append(_ bytes: Data) throws -> Data? {
        guard !complete, bytes.count <= Self.maxBodyBytes + 65536 - buffer.count else {
            throw PrintError.invalidDocument("HTTP 请求超过限制。")
        }
        buffer.append(bytes)
        if method == nil {
            guard let delimiter = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                guard buffer.count <= 32768 else { throw PrintError.invalidDocument("HTTP 请求头过大。") }
                return nil
            }
            guard delimiter.lowerBound <= 32768,
                  let text = String(data: buffer[..<delimiter.lowerBound], encoding: .ascii) else {
                throw PrintError.invalidDocument("HTTP 请求头无效。")
            }
            let lines = text.components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
            guard first.count == 3, first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0",
                  !first[0].isEmpty, first[1].hasPrefix("/") else {
                throw PrintError.invalidDocument("HTTP 请求行无效。")
            }
            method = String(first[0]); path = String(first[1])
            let token = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
            for line in lines.dropFirst() {
                guard let split = line.firstIndex(of: ":"), split != line.startIndex else {
                    throw PrintError.invalidDocument("HTTP 请求头无效。")
                }
                let rawKey = String(line[..<split])
                guard rawKey.unicodeScalars.allSatisfy({ token.contains($0) }) else {
                    throw PrintError.invalidDocument("HTTP 请求头名称无效。")
                }
                let key = rawKey.lowercased()
                guard headers[key] == nil else { throw PrintError.invalidDocument("HTTP 请求头重复。") }
                headers[key] = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
            }
            if let transfer = headers["transfer-encoding"] {
                guard transfer.lowercased() == "chunked", headers["content-length"] == nil else {
                    throw PrintError.invalidDocument("HTTP 分块编码无效。")
                }
                chunked = true
            } else {
                guard let raw = headers["content-length"], !raw.isEmpty,
                      raw.utf8.allSatisfy({ (48...57).contains($0) }),
                      let count = Int(raw), count <= Self.maxBodyBytes else {
                    throw PrintError.invalidDocument("HTTP 请求长度无效。")
                }
                length = count
            }
            if let expect = headers["expect"] {
                guard expect.lowercased() == "100-continue" else {
                    throw PrintError.invalidDocument("HTTP Expect 不支持。")
                }
                expectsContinue = true
            }
            buffer = Data(buffer[delimiter.upperBound...])
        }
        if !chunked {
            guard let count = length, buffer.count >= count else { return nil }
            guard buffer.count == count else { throw PrintError.invalidDocument("每个连接只接受一个请求。") }
            complete = true; return buffer
        }
        while true {
            if chunkSize == nil {
                guard let end = buffer.range(of: Data("\r\n".utf8)) else {
                    guard buffer.count < 1024 else { throw PrintError.invalidDocument("HTTP 分块头无效。") }
                    return nil
                }
                guard end.lowerBound < 1024,
                      let line = String(data: buffer[..<end.lowerBound], encoding: .ascii) else {
                    throw PrintError.invalidDocument("HTTP 分块头无效。")
                }
                let rawSize = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                guard !rawSize.isEmpty, rawSize.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                      let count = Int(rawSize, radix: 16), count <= Self.maxBodyBytes - decoded.count else {
                    throw PrintError.invalidDocument("HTTP 分块大小无效。")
                }
                chunkSize = count; buffer = Data(buffer[end.upperBound...])
            }
            guard let count = chunkSize else { return nil }
            if count == 0 {
                if buffer.starts(with: [13, 10]) {
                    guard buffer.count == 2 else { throw PrintError.invalidDocument("每个连接只接受一个请求。") }
                    complete = true; return decoded
                }
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    guard buffer.count <= 32768 else { throw PrintError.invalidDocument("HTTP 尾部过大。") }
                    return nil
                }
                guard end.upperBound == buffer.count, end.lowerBound <= 32768,
                      let trailer = String(data: buffer[..<end.lowerBound], encoding: .ascii),
                      trailer.components(separatedBy: "\r\n").allSatisfy({ line in
                          guard let colon = line.firstIndex(of: ":") else { return false }
                          let key = line[..<colon].lowercased()
                          return !key.isEmpty && !["content-length", "transfer-encoding", "host"].contains(key)
                      }) else { throw PrintError.invalidDocument("HTTP 尾部无效。") }
                complete = true; return decoded
            }
            guard buffer.count >= count + 2 else { return nil }
            guard buffer[count] == 13, buffer[count + 1] == 10 else {
                throw PrintError.invalidDocument("HTTP 分块结束标记错误。")
            }
            decoded.append(buffer[..<count]); buffer = Data(buffer[(count + 2)...]); chunkSize = nil
        }
    }
}
