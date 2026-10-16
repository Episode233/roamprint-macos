import XCTest
@testable import RoamPrintCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private actor PlatformHTTP: HTTPTransport {
    var requests: [URLRequest] = []
    let failure: String?
    let encoding: Int
    let storageType: Int
    init(failure: String? = nil, encoding: Int = 0, storageType: Int = 6) {
        self.failure = failure; self.encoding = encoding; self.storageType = storageType
    }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        let name = request.url!.lastPathComponent
        if name == failure { throw PrintError.transport("Lost response") }
        if failure == "reject:" + name {
            return HTTPResponse(status: 200, body: Data("{\"Code\":403,\"Mess\":\"private-password-echo\"}".utf8))
        }
        let json: [String: Any]
        switch name {
        case "getToken": json = ["code": 0, "data": "fixture-token"]
        case "filestorage": json = ["Code": "0", "List": [["ID": 9, "StorageType": storageType,
            "IP": "10.1.8.5", "Port": 80, "UserName": "storage",
            "Password": try LegacyPassword.encrypt("storage-password"), "FileEncType": encoding]]]
        case "print": json = ["Code": "0", "SubmitJobId": 123]
        case "printfile": json = ["Code": "0"]
        default: throw PrintError.protocolMismatch("Unexpected endpoint")
        }
        return HTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: json))
    }
    func upload(_ request: URLRequest, file: URL) async throws -> HTTPResponse {
        XCTFail("Storage must use uploader, not enterprise POST transport")
        throw PrintError.transport("Unexpected upload")
    }
    func names() -> [String] { requests.map { $0.url!.lastPathComponent } }
    func request(_ index: Int) -> URLRequest { requests[index] }
}
private actor StorageRecorder: StorageUploading {
    var calls: [(String, Data, String)] = []
    func upload(file: URL, storage: V5Storage, password: String, path: String) async throws {
        XCTAssertEqual(storage.id, 9)
        calls.append((path, try Data(contentsOf: file), password))
    }
    func snapshots() -> [(String, Data, String)] { calls }
}

final class V5PlatformTests: XCTestCase {
    func fixture() async throws -> (URL, JobQueue, PrintJob) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.pdf")
        let bytes = Data("%PDF-1.4\nfixture".utf8)
        try bytes.write(to: source)
        let queue = try JobQueue(root: root.appendingPathComponent("jobs"))
        let job = try await queue.add(source: source,
            info: DocumentInfo(title: "测试", pageCount: 2, byteCount: Int64(bytes.count)),
            settings: PrintSettings(copies: 3, color: .color, duplex: .longEdge))
        return (root, queue, job)
    }
    private func platform(_ http: PlatformHTTP, _ uploader: StorageRecorder) throws -> V5Platform {
        V5Platform(configuration: try ServerConfiguration(baseURL: URL(string: "http://10.1.8.5/xzentprint/services")!, generation: .v5),
            transport: http, uploader: uploader, identity: ClientIdentity(ip: "10.1.8.20", mac: "aa:bb:cc:dd:ee:ff", host: "fixture-mac"))
    }
    func testSuccessfulSubmissionPreservesCardReleaseAndPrivateSource() async throws {
        let (root, queue, job) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let http = PlatformHTTP(), uploader = StorageRecorder()
        let client = try platform(http, uploader)
        try await client.submit(job: job, credentials: Credentials(username: "alice", password: "secret"), queue: queue)
        let names = await http.names()
        XCTAssertEqual(names, ["getToken", "filestorage", "print", "printfile"])
        let create = await http.request(2)
        let fields = try JSONSerialization.jsonObject(with: create.httpBody!) as! [String: Any]
        XCTAssertEqual(fields["directprintid"] as? Int, -1)
        XCTAssertEqual(fields["ischeckpwd"] as? Int, 1)
        XCTAssertEqual(fields["count"] as? Int, 3)
        XCTAssertEqual(fields["doubleprint"] as? Int, 2)
        XCTAssertEqual(fields["papersize"] as? Int, 9)
        XCTAssertEqual(fields["papersource"] as? Int, 1000)
        XCTAssertEqual(try LegacyPassword.decrypt(fields["pwd"] as! String), "secret")
        XCTAssertEqual(create.value(forHTTPHeaderField: "token"), "fixture-token")
        XCTAssertEqual(create.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        let calls = await uploader.snapshots()
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].0.hasPrefix("/PrintDir/"))
        XCTAssertTrue(calls[0].0.hasSuffix("}.pdf"))
        XCTAssertEqual(calls[0].2, "storage-password")
        let finish = await http.request(3)
        let finalized = try JSONSerialization.jsonObject(with: finish.httpBody!) as! [String: Any]
        XCTAssertEqual(finalized["jobpath"] as? String, calls[0].0)
        XCTAssertEqual(finalized["submitjobid"] as? Int, 123)
        XCTAssertEqual(finalized["state"] as? Int, 1)
        let saved = try await queue.get(job.id)
        XCTAssertEqual(saved.state, .submitted)
        let doc = await queue.documentURL(job.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: doc.path))
        let journal = try String(contentsOf: doc.deletingLastPathComponent().appendingPathComponent("job.json"), encoding: .utf8)
        XCTAssertFalse(journal.contains("secret")); XCTAssertFalse(journal.contains("fixture-token"))
        do { try await client.submit(job: job, credentials: Credentials(username: "alice", password: "secret"), queue: queue); XCTFail("must not submit twice") }
        catch { }
        let after = await http.names()
        XCTAssertEqual(after, names)
    }
    func testLostCreateOrFinalizeResponseNeverRetries() async throws {
        for endpoint in ["print", "printfile"] {
            let (root, queue, job) = try await fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let http = PlatformHTTP(failure: endpoint), uploader = StorageRecorder()
            let client = try platform(http, uploader)
            do { try await client.submit(job: job, credentials: Credentials(username: "alice", password: "secret"), queue: queue); XCTFail("must throw") }
            catch { }
            let saved = try await queue.get(job.id)
            XCTAssertEqual(saved.state, .uncertain)
            let calls = await http.names()
            XCTAssertEqual(calls.filter { $0 == endpoint }.count, 1)
            do { try await client.submit(job: job, credentials: Credentials(username: "alice", password: "secret"), queue: queue); XCTFail("must not retry") }
            catch { }
            let after = await http.names()
            XCTAssertEqual(after, calls)
        }
    }
    func testUnsupportedStorageFailsBeforeCreation() async throws {
        let (root, queue, job) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let http = PlatformHTTP(encoding: 99), uploader = StorageRecorder()
        do { try await platform(http, uploader).submit(job: job, credentials: Credentials(username: "alice", password: "secret"), queue: queue); XCTFail("unsupported encoding") }
        catch { }
        let calls = await http.names()
        XCTAssertEqual(calls, ["getToken", "filestorage"])
        let saved = try await queue.get(job.id)
        XCTAssertEqual(saved.state, .failed)
    }
    func testEncodedDocumentUploadUsesDATAndFinalizesEncoding() async throws {
        let (root, queue, job) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let http = PlatformHTTP(encoding: 1), uploader = StorageRecorder()
        try await platform(http, uploader).submit(job: job,
            credentials: Credentials(username: "alice", password: "secret"), queue: queue)
        let calls = await uploader.snapshots()
        XCTAssertTrue(calls[0].0.hasSuffix("}.dat"))
        XCTAssertEqual(calls[0].1.prefix(4), Data([0, 0, 0, 0]))
        let finish = await http.request(3)
        let fields = try JSONSerialization.jsonObject(with: finish.httpBody!) as! [String: Any]
        XCTAssertEqual(fields["fileenctype"] as? Int, 1)
        let source = await queue.documentURL(job.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.deletingLastPathComponent().appendingPathComponent("upload.dat").path))
    }
    func testModifiedZIPDecodesWithSystemZIPReader() throws {
        let bytes = Data("%PDF-1.4\nTest binary \u{0} content".utf8)
        var zip = try ModifiedZIP.encode(bytes, name: "document.pdf")
        XCTAssertEqual(zip.prefix(4), Data([0, 0, 0, 0]))
        XCTAssertEqual(ModifiedZIP.crc32(Data("123456789".utf8)), 0xcbf43926)
        zip.replaceSubrange(0..<4, with: [0x50, 0x4b, 3, 4])
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: path) }
        try zip.write(to: path)
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", path.path, "document.pdf"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let extracted = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(extracted, bytes)
    }
    func testSignatureUsesRecoveredKeyAndUppercaseMD5() {
        XCTAssertEqual(V5Wire.signature("type=0"), "06C230B9A6086C1C834C262DBA0F17CB")
    }
    func testOriginalFilesPreserveNamesSuffixesAndBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try JobQueue(root: root)
        let bytes = Data([0x50, 0x4b, 3, 4, 0, 255, 128, 13, 10])
        for name in ["报告.doc", "报告.docx", "预算.xls", "预算.xlsx", "演示.ppt", "演示.PPTX", "照片.jpg", "图片.png", "未知.xyz", "无后缀"] {
            let source = root.appendingPathComponent(name)
            try bytes.write(to: source)
            let info = DocumentInfo(title: name, pageCount: 0, byteCount: Int64(bytes.count), filename: name)
            let job = try await queue.add(source: source, info: info, settings: PrintSettings())
            let stored = await queue.documentURL(job.id)
            XCTAssertEqual(try Data(contentsOf: stored), bytes)
            XCTAssertEqual(stored.pathExtension, source.pathExtension)
            let http = PlatformHTTP(), uploader = StorageRecorder()
            try await platform(http, uploader).submit(job: job, credentials: Credentials(username: "alice", password: "secret"), queue: queue)
            let create = await http.request(2), finish = await http.request(3)
            for request in [create, finish] {
                let fields = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                XCTAssertEqual(fields["filename"] as? String, name)
            }
            let fields = try JSONSerialization.jsonObject(with: create.httpBody!) as! [String: Any]
            XCTAssertEqual(fields["pagetotal"] as? Int, 0)
            XCTAssertEqual(fields["directprintid"] as? Int, -1)
            let uploads = await uploader.snapshots()
            XCTAssertEqual(uploads.first?.1, bytes)
            XCTAssertTrue(uploads[0].0.hasSuffix("}" + info.extensionSuffix))
        }
    }
    func testEncodedOriginalFileKeepsItsNameInsideArchive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try JobQueue(root: root)
        let bytes = Data([0x50, 0x4b, 0, 255, 0, 13, 10]), name = "预算.xlsx"
        let source = root.appendingPathComponent(name)
        try bytes.write(to: source)
        let job = try await queue.add(source: source,
            info: DocumentInfo(title: name, pageCount: 0, byteCount: Int64(bytes.count), filename: name), settings: PrintSettings())
        let http = PlatformHTTP(encoding: 1), uploader = StorageRecorder()
        try await platform(http, uploader).submit(job: job, credentials: Credentials(username: "alice", password: "secret"), queue: queue)
        let uploads = await uploader.snapshots()
        var zip = uploads[0].1
        XCTAssertTrue(uploads[0].0.hasSuffix("}.dat"))
        zip.replaceSubrange(0..<4, with: [0x50, 0x4b, 3, 4])
        let archive = root.appendingPathComponent("restored.zip")
        try zip.write(to: archive)
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path, name]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let extracted = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(extracted, bytes)
    }
    func testConnectionCheckAcceptsFTPAndCreatesNoJob() async throws {
        let http = PlatformHTTP(storageType: 2), uploader = StorageRecorder()
        let result = try await platform(http, uploader).checkConnection()
        XCTAssertTrue(result.contains("FTP"))
        XCTAssertTrue(result.contains("尚未创建"))
        let requests = await http.names(), uploads = await uploader.snapshots()
        XCTAssertEqual(requests, ["getToken", "filestorage"])
        XCTAssertTrue(uploads.isEmpty)
        let request = await http.request(0)
        XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
    }
    func testDiagnosticsNameFailedEndpointAndServerRejectionStaysRetryable() async throws {
        let broken = PlatformHTTP(failure: "getToken")
        do { _ = try await platform(broken, StorageRecorder()).checkConnection(); XCTFail("must fail") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("/getToken"))
            XCTAssertTrue(error.localizedDescription.contains("Lost response"))
        }
        let (root, queue, job) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let rejected = PlatformHTTP(failure: "reject:print"), uploader = StorageRecorder()
        do { try await platform(rejected, uploader).submit(job: job, credentials: Credentials(username: "alice", password: "secret"), queue: queue); XCTFail("must reject") }
        catch {
            guard case PrintError.server(let code, _) = error else { return XCTFail("must preserve server rejection") }
            XCTAssertEqual(code, 403)
            XCTAssertFalse(error.localizedDescription.contains("private-password-echo"))
        }
        let saved = try await queue.get(job.id), uploads = await uploader.snapshots()
        XCTAssertEqual(saved.state, .failed)
        XCTAssertNil(saved.serverJobID)
        XCTAssertTrue(uploads.isEmpty)
    }
}
