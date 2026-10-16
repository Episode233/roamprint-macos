import Foundation

public struct CurlResult: Sendable {
    public let exitCode: Int32
    public let responseCode: Int
    public init(exitCode: Int32, responseCode: Int) {
        self.exitCode = exitCode; self.responseCode = responseCode
    }
}

public protocol CurlExecuting: Sendable {
    func execute(configuration: Data) async throws -> CurlResult
}

/// macOS supplies this executable as native system software. The same path supports Linux integration tests.
public struct SystemCurlExecutor: CurlExecuting {
    public init() {}
    public func execute(configuration: Data) async throws -> CurlResult {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            // -q must be first: ignore curlrc overrides of retries, redirects or logging.
            process.arguments = ["-q", "--config", "-"]
            let stdin = Pipe(), stdout = Pipe()
            process.standardInput = stdin; process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            try process.run()
            do {
                try stdin.fileHandleForWriting.write(contentsOf: configuration)
                try stdin.fileHandleForWriting.close()
            } catch {
                process.terminate(); process.waitUntilExit()
                throw PrintError.transport("上传进程输入失败。")
            }
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CurlResult(exitCode: process.terminationStatus,
                              responseCode: Int(String(decoding: output, as: UTF8.self)) ?? 0)
        }.value
    }
}

/// Uses Apple's native curl. Secrets are passed on stdin, never as command arguments.
public struct NativeCurlUploader: StorageUploading {
    private let executor: any CurlExecuting
    public init(executor: any CurlExecuting = SystemCurlExecutor()) { self.executor = executor }
    public func upload(file: URL, storage: V5Storage, password: String, path: String) async throws {
        try storage.validate()
        guard path.hasPrefix("/PrintDir/"), !path.contains(".."), !storage.username.contains(":") else {
            throw PrintError.protocolMismatch("上传路径或存储账号无效。")
        }
        var parts = URLComponents()
        parts.scheme = storage.type == 2 ? "ftp" : storage.type == 7 ? "https" : "http"
        parts.host = storage.host; parts.port = storage.port; parts.path = path
        guard let url = parts.url else { throw PrintError.protocolMismatch("存储 URL 无效。") }
        let user = storage.username + ":" + password
        if storage.type == 2 {
            _ = try await run(config: ["url": url.absoluteString, "user": user, "upload-file": file.path],
                              flags: ["ftp-create-dirs"], acceptable: nil)
        } else {
            var directory = ""
            for segment in path.split(separator: "/").dropLast() {
                directory += "/" + segment
                parts.path = directory
                guard let directoryURL = parts.url else { throw PrintError.protocolMismatch("存储目录无效。") }
                _ = try await run(config: ["url": directoryURL.absoluteString, "user": user,
                                         "request": "MKCOL"], flags: [], acceptable: [200, 201, 204, 405])
            }
            _ = try await run(config: ["url": url.absoluteString, "user": user, "upload-file": file.path],
                              flags: [], acceptable: Array(200...299))
        }
    }
    static func quote(_ value: String) throws -> String {
        guard !value.contains("\0"), !value.contains("\r"), !value.contains("\n") else {
            throw PrintError.protocolMismatch("上传参数包含不支持的字符。")
        }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    private func run(config: [String: String], flags: [String], acceptable: [Int]?) async throws -> Int {
        var lines = ["silent", "connect-timeout = 15", "max-time = 300", "retry = 0",
                     "output = \"/dev/null\"", "write-out = \"%{http_code}\"", "globoff"]
        for key in config.keys.sorted() { lines.append(key + " = " + (try Self.quote(config[key]!))) }
        lines += flags
        let input = Data((lines.joined(separator: "\n") + "\n").utf8)
        let result = try await executor.execute(configuration: input)
        guard result.exitCode == 0 else {
            throw PrintError.transport("文件上传失败（curl \(result.exitCode)）。")
        }
        if let acceptable, !acceptable.contains(result.responseCode) {
            throw PrintError.transport("存储服务器返回 HTTP \(result.responseCode)。")
        }
        return result.responseCode
    }
}

public enum SystemIdentity {
    public static func read(server: URL) throws -> ClientIdentity {
        #if os(macOS)
        guard let host = server.host, !host.hasPrefix("-"), !host.contains(where: { $0.isWhitespace }) else {
            throw PrintError.invalidConfiguration("平台地址无法用于网络路由查询。")
        }
        func output(_ executable: String, _ args: [String]) throws -> String {
            let p = Process(), pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: executable); p.arguments = args
            p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw PrintError.transport("无法确定访问平台的网络接口。") }
            return String(decoding: data, as: UTF8.self)
        }
        let route = try output("/sbin/route", ["-n", "get", host])
        guard let row = route.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("interface:") }),
              let interface = row.split(separator: ":").last?.trimmingCharacters(in: .whitespaces),
              !interface.isEmpty else { throw PrintError.transport("无法确定访问平台的网络接口。") }
        let config = try output("/sbin/ifconfig", [interface])
        func field(_ label: String) -> String? {
            for row in config.split(separator: "\n") {
                let fields = row.split(whereSeparator: { $0.isWhitespace })
                if fields.first == Substring(label), fields.count > 1 { return String(fields[1]) }
            }
            return nil
        }
        guard let ip = field("inet") else { throw PrintError.transport("平台网络接口没有 IPv4 地址。") }
        return ClientIdentity(ip: ip, mac: field("ether") ?? "", host: ProcessInfo.processInfo.hostName)
        #else
        throw PrintError.transport("请在 macOS 上提交，或为测试注入网络身份。")
        #endif
    }
}
