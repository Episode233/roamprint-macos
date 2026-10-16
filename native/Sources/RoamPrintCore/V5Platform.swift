import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ClientIdentity: Sendable {
    public var ip: String
    public var mac: String
    public var host: String
    public init(ip: String, mac: String, host: String) {
        self.ip = ip; self.mac = mac; self.host = host
    }
}

public struct V5Storage: Sendable {
    public let id: Int
    public let type: Int
    public let host: String
    public let port: Int
    public let username: String
    public let encryptedPassword: String
    public let fileEncoding: Int
    public init(id: Int, type: Int, host: String, port: Int, username: String,
                encryptedPassword: String, fileEncoding: Int) {
        self.id = id; self.type = type; self.host = host; self.port = port
        self.username = username; self.encryptedPassword = encryptedPassword; self.fileEncoding = fileEncoding
    }
    func validate() throws {
        guard id > 0, [2, 6, 7].contains(type), [0, 1].contains(fileEncoding),
              !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
              !host.contains("/"), !host.contains("@"), (1...65535).contains(port) else {
            throw PrintError.protocolMismatch("平台返回的存储类型、文件编码或地址暂不支持。")
        }
    }
}

public protocol StorageUploading: Sendable {
    func upload(file: URL, storage: V5Storage, password: String, path: String) async throws
}

/// V5 wire fields recovered from the shipped client; see docs/protocol.md.
public enum V5Wire {
    public static let signingKey = "xz!@#$%^&&*()?"
    public static func signature(_ payload: String, key: String = signingKey) -> String {
        LegacyDigest.md5(Data((payload + "&" + key).utf8)).uppercased()
    }
    public static func request(url: URL, fields: [String: Any], token: String? = nil) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("XZSoft http client", forHTTPHeaderField: "User-Agent")
        if let token {
            guard !token.contains(where: { $0 == "\r" || $0 == "\n" }) else {
                throw PrintError.protocolMismatch("平台令牌格式无效。")
            }
            request.setValue(token, forHTTPHeaderField: "token")
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return request
    }
    public static func decode(_ response: HTTPResponse) throws -> [String: Any] {
        guard (200...299).contains(response.status) else {
            throw PrintError.transport("平台 HTTP 状态：\(response.status)。")
        }
        guard response.body.count <= 4 * 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let raw = object["Code"] ?? object["code"], let code = integer(raw) else {
            throw PrintError.protocolMismatch("平台响应不符合 V5 格式。")
        }
        guard code == 0 else {
            // Server messages can echo submitted secrets; keep raw responses out of journals/UI.
            throw PrintError.server(code, "请求被拒绝，请检查账号或平台设置。")
        }
        return object
    }
    static func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
           value.doubleValue.isFinite, value.doubleValue.rounded() == value.doubleValue,
           value.doubleValue >= Double(Int32.min), value.doubleValue <= Double(Int32.max) { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
    public static func createFields(job: PrintJob, credentials: Credentials, password: String,
                                    identity: ClientIdentity) -> [String: Any] {
        let s = job.settings
        return ["type": 4, "code": credentials.username, "pwd": password, "ischeckpwd": 1,
                "ip": identity.ip, "mac": identity.mac, "host": identity.host,
                "filename": job.document.submissionName, "projectid": 0,
                "directprintid": -1, "count": s.copies, "iscollate": s.collate ? 1 : 0,
                "direction": s.landscape ? 2 : 1, "doubleprint": s.duplex.rawValue,
                "color": s.color.rawValue, "papersize": s.paperCode, "papertype": s.paperName,
                "filesize": job.document.byteCount, "papersource": 1000, "pagetotal": job.document.pageCount,
                "a3pagecount": job.document.a3Pages, "a4pagecount": job.document.a4Pages,
                "otherpagecount": job.document.otherPages, "hbpages": 0,
                "colorpages": 0, "jobtype": 0, "comment": "",
                "signature": signature("type=4&code=\(credentials.username)&pwd=\(password)")]
    }
    public static func storages(_ response: [String: Any]) throws -> [V5Storage] {
        guard let list = response["List"] as? [[String: Any]], !list.isEmpty else {
            throw PrintError.protocolMismatch("平台未返回文件存储服务器。")
        }
        return try list.map { item in
            guard let id = integer(item["ID"]), let type = integer(item["StorageType"]),
                  let host = item["IP"] as? String, let port = integer(item["Port"]),
                  let user = item["UserName"] as? String, let pwd = item["Password"] as? String else {
                throw PrintError.protocolMismatch("存储配置字段不完整。")
            }
            let storage = V5Storage(id: id, type: type, host: host, port: port, username: user,
                                    encryptedPassword: pwd, fileEncoding: integer(item["FileEncType"]) ?? 0)
            return storage
        }
    }
}

import CoreFoundation

public actor V5Platform {
    private let configuration: ServerConfiguration
    private let transport: any HTTPTransport
    private let uploader: any StorageUploading
    private let identity: ClientIdentity?
    private var busy = false
    public init(configuration: ServerConfiguration, transport: any HTTPTransport = URLSessionTransport(),
                uploader: any StorageUploading = NativeCurlUploader(), identity: ClientIdentity? = nil) {
        self.configuration = configuration; self.transport = transport
        self.uploader = uploader; self.identity = identity
    }
    private func post(_ endpoint: String, _ fields: [String: Any], token: String? = nil) async throws -> [String: Any] {
        let request = try V5Wire.request(url: configuration.endpoint(endpoint), fields: fields, token: token)
        let context = "POST \(configuration.endpoint(endpoint).absoluteString)"
        do { return try V5Wire.decode(await transport.send(request)) }
        catch PrintError.server(let code, let message) { throw PrintError.server(code, "\(context)\n\(message)") }
        catch {
            let native = error as NSError
            throw PrintError.transport("\(context)\n\(native.domain) (\(native.code))：\(error.localizedDescription)")
        }
    }
    private func connect() async throws -> (token: String, storage: V5Storage, password: String) {
        guard configuration.generation == .v5 else { throw PrintError.invalidConfiguration("当前版本支持 V5 打印平台。") }
        let auth = try await post("getToken", ["type": 0, "client_id": "PrintSys",
            "client_secret": "5XQ+FS71Y0qUILpOcX/y3jEZ7ExHswblLWJ6IwoUv68=",
            "signature": V5Wire.signature("type=0")])
        guard let token = auth["data"] as? String, !token.isEmpty else {
            throw PrintError.protocolMismatch("平台没有返回 V5 访问令牌。")
        }
        let response = try await post("filestorage", ["type": 7, "signature": V5Wire.signature("type=7")], token: token)
        let candidates = try V5Wire.storages(response)
        guard let storage = candidates.first(where: { (try? $0.validate()) != nil }) else {
            throw PrintError.protocolMismatch("平台没有返回可用的 FTP 或 HTTP/HTTPS WebDAV 存储配置。")
        }
        let password = storage.encryptedPassword.isEmpty ? "" : try LegacyPassword.decrypt(storage.encryptedPassword)
        return (token, storage, password)
    }
    /// Reads client-token/storage configuration only; it never creates a print job or verifies a user password.
    public func checkConnection() async throws -> String {
        guard !busy else { throw PrintError.queue("另一个请求正在进行。") }
        busy = true
        defer { busy = false }
        let result = try await connect()
        let name = [2: "FTP", 6: "HTTP WebDAV", 7: "HTTPS WebDAV"][result.storage.type]!
        return "平台连接成功，已取得 \(name) 存储配置。\n尚未创建打印任务；账号和实际文件上传将在提交时验证。"
    }
    public func submit(job supplied: PrintJob, credentials: Credentials, queue: JobQueue) async throws {
        guard !busy else { throw PrintError.queue("另一个作业正在提交。") }
        guard configuration.generation == .v5, credentials.kind == .platform else {
            throw PrintError.invalidConfiguration("当前版本支持 V5 平台账号登录。")
        }
        guard !credentials.username.isEmpty, !credentials.password.isEmpty else {
            throw PrintError.invalidConfiguration("请输入打印账号和密码。")
        }
        busy = true
        defer { busy = false }
        var job = try await queue.get(supplied.id)
        guard [.queued, .failed].contains(job.state), job.serverJobID == nil else {
            throw PrintError.queue("请先查询平台中的原作业，不能重复创建。")
        }
        try job.settings.validate()
        let file = await queue.documentURL(job.id)
        try job.document.validateFilename()
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size == job.document.byteCount, size > 0, size <= 128 * 1024 * 1024 else {
            throw PrintError.invalidDocument("本地文档大小异常或超过 128 MB。")
        }
        job = try await queue.claimSubmission(job.id, server: configuration.baseURL, account: credentials.username)
        var remoteMayExist = false
        var encodedFile: URL?
        defer { if let encodedFile { try? FileManager.default.removeItem(at: encodedFile) } }
        do {
            let encrypted = try LegacyPassword.encrypt(credentials.password)
            let device = try identity ?? SystemIdentity.read(server: configuration.baseURL)
            let (token, storage, storagePassword) = try await connect()
            var source = file
            if storage.fileEncoding == 1 {
                source = file.deletingLastPathComponent().appendingPathComponent("upload.dat")
                encodedFile = source
                try ModifiedZIP.write(source: file, destination: source, name: job.document.submissionName)
            }
            remoteMayExist = true
            let created: [String: Any]
            do {
                created = try await post("print", V5Wire.createFields(job: job, credentials: credentials,
                    password: encrypted, identity: device), token: token)
            } catch PrintError.server(let code, let text) {
                // An explicit platform rejection establishes that creation did not succeed.
                remoteMayExist = false
                throw PrintError.server(code, text)
            }
            guard let id = V5Wire.integer(created["SubmitJobId"]), id > 0 else {
                throw PrintError.uncertain("平台创建响应未含有效作业号，请查询平台。")
            }
            job.serverJobID = String(id); job.state = .uploading
            try await queue.save(job)
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd"
            let suffix = storage.fileEncoding == 1 ? ".dat" : job.document.extensionSuffix
            let path = "/PrintDir/\(formatter.string(from: Date()))/{\(UUID().uuidString.lowercased())}\(suffix)"
            try await uploader.upload(file: source, storage: storage, password: storagePassword, path: path)
            job.state = .finalizing
            try await queue.save(job)
            _ = try await post("printfile", ["type": 6, "submitjobid": id, "filestorageid": storage.id,
                "jobpath": path, "state": 1, "upload_tip": "", "fileenctype": storage.fileEncoding,
                "code": credentials.username, "filename": job.document.submissionName,
                "signature": V5Wire.signature("type=6&submitjobid=\(id)")], token: token)
            job.state = .submitted; job.message = "已提交，请到打印机刷卡取件。"
            try await queue.save(job)
        } catch {
            job.state = remoteMayExist ? .uncertain : .failed
            job.message = remoteMayExist ? "平台可能已创建作业，请先查询平台，勿重复提交。\n\(error.localizedDescription)" : error.localizedDescription
            try await queue.save(job)
            throw remoteMayExist ? PrintError.uncertain(job.message!) : error
        }
    }
}
