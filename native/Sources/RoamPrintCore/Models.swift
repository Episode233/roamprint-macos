import Foundation

public enum PlatformGeneration: String, Codable, CaseIterable, Sendable {
    case v5, v6
}

public struct ServerConfiguration: Codable, Equatable, Sendable {
    public var baseURL: URL
    public var generation: PlatformGeneration
    public init(baseURL: URL, generation: PlatformGeneration) throws {
        guard ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""),
              baseURL.host != nil, baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else {
            throw PrintError.invalidConfiguration("请输入完整的 http 或 https 平台地址。")
        }
        self.baseURL = baseURL
        self.generation = generation
    }
    public func endpoint(_ path: String) -> URL {
        baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}

public enum LoginKind: Int, Codable, CaseIterable, Sendable {
    case platform = 0, domain = 1
}

/// Credentials never appear in a job journal; the UI can opt to save them in the OS keychain.
public struct Credentials: Sendable {
    public let username: String
    public let password: String
    public let kind: LoginKind
    public init(username: String, password: String, kind: LoginKind = .platform) {
        self.username = username
        self.password = password
        self.kind = kind
    }
}

public struct PrintSettings: Codable, Equatable, Sendable {
    public enum Color: Int, Codable, CaseIterable, Sendable { case gray = 1, color = 2 }
    public enum Duplex: Int, Codable, CaseIterable, Sendable { case single = 1, longEdge = 2, shortEdge = 3 }
    public var copies: Int
    public var color: Color
    public var duplex: Duplex
    public var collate: Bool
    public var landscape: Bool
    public var paperCode: Int
    public var paperName: String
    public init(copies: Int = 1, color: Color = .gray, duplex: Duplex = .single,
                collate: Bool = true, landscape: Bool = false, paperCode: Int = 9, paperName: String = "A4") {
        self.copies = copies
        self.color = color
        self.duplex = duplex
        self.collate = collate
        self.landscape = landscape
        self.paperCode = paperCode
        self.paperName = paperName
    }
    public func validate() throws {
        guard (1...999).contains(copies) else { throw PrintError.invalidDocument("份数必须在 1 到 999 之间。") }
    }
}

public struct DocumentInfo: Codable, Equatable, Sendable {
    public var title: String
    /// Nil in older journals and system-print captures, whose local format is PDF.
    public var filename: String?
    public var pageCount: Int
    public var a3Pages: Int
    public var a4Pages: Int
    public var otherPages: Int
    public var byteCount: Int64
    public init(title: String, pageCount: Int, a3Pages: Int = 0, a4Pages: Int = 0,
                otherPages: Int = 0, byteCount: Int64, filename: String? = nil) {
        self.title = title
        self.filename = filename
        self.pageCount = pageCount
        self.a3Pages = a3Pages
        self.a4Pages = a4Pages
        self.otherPages = otherPages
        self.byteCount = byteCount
    }
    public var submissionName: String { filename ?? title + ".pdf" }
    public var extensionSuffix: String {
        guard let filename else { return ".pdf" }
        guard let dot = filename.lastIndex(of: "."), dot != filename.startIndex else { return "" }
        return String(filename[dot...])
    }
    public var localFilename: String {
        // A damaged manifest must never make a document URL escape its job directory.
        guard (try? validateFilename()) != nil else { return "document.invalid" }
        return "document" + extensionSuffix
    }
    public var pageDescription: String { pageCount > 0 ? "\(pageCount) 页" : "页数由平台识别" }
    public func validateFilename() throws {
        guard let filename else { return }
        guard !filename.isEmpty, filename.utf8.count <= 65535, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains("\\"),
              !filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PrintError.invalidDocument("文件名包含不支持的字符，请重命名后导入。")
        }
    }
}

public struct PrintJob: Codable, Identifiable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case queued, preparing, uploading, finalizing, submitted, failed, uncertain
        public var label: String {
            switch self {
            case .queued: return "待提交"
            case .preparing: return "正在提交作业信息"
            case .uploading: return "正在上传文档"
            case .finalizing: return "正在确认上传"
            case .submitted: return "已提交，请刷卡取件"
            case .failed: return "提交失败"
            case .uncertain: return "结果待确认，请查询平台"
            }
        }
        public var inFlight: Bool { [.preparing, .uploading, .finalizing].contains(self) }
    }
    public var id: UUID
    public var createdAt: Date
    public var document: DocumentInfo
    public var settings: PrintSettings
    public var state: State
    public var serverJobID: String?
    public var serverURL: URL?
    public var submitAccount: String?
    public var message: String?
    public init(document: DocumentInfo, settings: PrintSettings, id: UUID = UUID()) {
        self.id = id
        self.createdAt = Date()
        self.document = document
        self.settings = settings
        self.state = .queued
    }
}

public enum PrintError: LocalizedError, Sendable {
    case invalidConfiguration(String), invalidDocument(String), protocolMismatch(String)
    case server(Int, String), transport(String), uncertain(String), queue(String)
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let s), .invalidDocument(let s), .protocolMismatch(let s),
             .transport(let s), .uncertain(let s), .queue(let s): return s
        case .server(let code, let text): return "平台返回错误 \(code)：\(text)"
        }
    }
}
