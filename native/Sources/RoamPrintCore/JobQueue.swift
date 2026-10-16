import Foundation

/// Durable private queue. Network operations do not delete the source document.
public actor JobQueue {
    public let root: URL
    private let fm = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    public init(root: URL) throws {
        self.root = root
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try fm.createDirectory(at: root, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let attributes = try fm.attributesOfItem(atPath: root.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw PrintError.queue("本地作业目录必须为普通目录。")
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
    private func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func documentURL(_ id: UUID) -> URL {
        folder(id).appendingPathComponent((try? get(id).document.localFilename) ?? "document.pdf")
    }
    public func add(source: URL, info: DocumentInfo, settings: PrintSettings) throws -> PrintJob {
        try settings.validate()
        try info.validateFilename()
        let properties = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.pageCount >= 0, info.byteCount > 0, info.byteCount <= 128 * 1024 * 1024,
              properties.isRegularFile == true, Int64(properties.fileSize ?? 0) == info.byteCount else {
            throw PrintError.invalidDocument("请选择非空文件，单个文件最大 128 MB，文件大小须与本地记录一致。")
        }
        let job = PrintJob(document: info, settings: settings)
        // Publish the directory only after document and manifest are durable.
        let directory = root.appendingPathComponent(".pending-" + job.id.uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let doc = directory.appendingPathComponent(info.localFilename)
            try fm.copyItem(at: source, to: doc)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: doc.path)
            let handle = try FileHandle(forWritingTo: doc)
            try handle.synchronize()
            try handle.close()
            let manifest = directory.appendingPathComponent("job.json")
            try encoder.encode(job).write(to: manifest, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
            let journal = try FileHandle(forWritingTo: manifest)
            try journal.synchronize(); try journal.close()
            try fm.moveItem(at: directory, to: folder(job.id))
            return job
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }
    public func save(_ job: PrintJob) throws {
        let target = folder(job.id).appendingPathComponent("job.json")
        try encoder.encode(job).write(to: target, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let handle = try FileHandle(forWritingTo: target)
        try handle.synchronize()
        try handle.close()
    }
    public func get(_ id: UUID) throws -> PrintJob {
        try decoder.decode(PrintJob.self, from: Data(contentsOf: folder(id).appendingPathComponent("job.json")))
    }
    public func list() throws -> [PrintJob] {
        let dirs = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var result: [PrintJob] = []
        for dir in dirs where UUID(uuidString: dir.lastPathComponent) != nil {
            do {
                let job = try decoder.decode(PrintJob.self, from: Data(contentsOf: dir.appendingPathComponent("job.json")))
                guard job.id.uuidString == dir.lastPathComponent else { throw PrintError.queue("作业编号不匹配。") }
                result.append(job)
            } catch {
                // Preserve damaged journals and PDFs. One damaged entry must not hide other jobs.
                var damaged = PrintJob(document: DocumentInfo(title: "本地作业记录损坏", pageCount: 0,
                    byteCount: 0), settings: PrintSettings(), id: UUID(uuidString: dir.lastPathComponent)!)
                damaged.state = .uncertain
                damaged.message = "本地记录无法读取，文档已保留。请检查平台并联系管理员。"
                result.append(damaged)
            }
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }
    public func recoverInterrupted() throws {
        for var job in try list() where job.state.inFlight {
            job.state = .uncertain
            job.message = "上次提交被中断。请先在平台检查该文档，避免重复提交。"
            try save(job)
        }
    }
    /// Read and transition without an actor suspension; two windows cannot create the same remote job.
    public func claimSubmission(_ id: UUID, server: URL, account: String) throws -> PrintJob {
        var job = try get(id)
        guard [.queued, .failed].contains(job.state), job.serverJobID == nil else {
            throw PrintError.queue("该作业已开始提交，请先查询平台中的结果。")
        }
        job.state = .preparing; job.serverURL = server; job.submitAccount = account; job.message = nil
        try save(job)
        return job
    }
    public func updateSettings(_ id: UUID, settings: PrintSettings) throws {
        var job = try get(id)
        guard job.state == .queued || job.state == .failed else { throw PrintError.queue("该作业已开始提交，不能更改参数。") }
        try settings.validate()
        job.settings = settings
        try save(job)
    }
    public func remove(_ id: UUID) throws {
        let job = try get(id)
        guard !job.state.inFlight, job.state != .uncertain else {
            throw PrintError.queue("请先确认平台上的提交结果，再处理本地文档。")
        }
        try fm.removeItem(at: folder(id))
    }
}
