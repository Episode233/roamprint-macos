import XCTest
@testable import RoamPrintCore

final class JobQueueTests: XCTestCase {
    func testCorruptRecordDoesNotHideGoodJobAndInterruptedWorkStaysUncertain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try JobQueue(root: root)
        let source = root.appendingPathComponent("source.pdf")
        try Data("%PDFfixture".utf8).write(to: source)
        var job = try await queue.add(source: source,
            info: DocumentInfo(title: "recover", pageCount: 1, byteCount: 11), settings: PrintSettings())
        job.state = .finalizing; job.serverJobID = "12"
        try await queue.save(job)
        let corrupt = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: false)
        try Data("{".utf8).write(to: corrupt.appendingPathComponent("job.json"))
        try await queue.recoverInterrupted()
        let items = try await queue.list()
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.state == .uncertain })
        XCTAssertEqual(items.first { $0.id == job.id }?.serverJobID, "12")
        XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.appendingPathComponent("job.json").path))
    }
    func testQueueRejectsSymlinkRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let real = root.appendingPathComponent("real"), alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        XCTAssertThrowsError(try JobQueue(root: alias))
    }
    func testSubmissionClaimCanOnlySucceedOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try JobQueue(root: root)
        let source = root.appendingPathComponent("source.pdf")
        try Data("%PDFfixture".utf8).write(to: source)
        let job = try await queue.add(source: source, info: DocumentInfo(title: "claim", pageCount: 1, byteCount: 11), settings: PrintSettings())
        let server = URL(string: "http://10.1.8.5/xzentprint/services")!
        _ = try await queue.claimSubmission(job.id, server: server, account: "alice")
        do { _ = try await queue.claimSubmission(job.id, server: server, account: "bob"); XCTFail("cannot claim twice") }
        catch { }
        let saved = try await queue.get(job.id)
        XCTAssertEqual(saved.submitAccount, "alice")
    }
    func testLegacyDocumentMetadataStillUsesPDFWithoutMigration() throws {
        let legacy = Data("{\"title\":\"legacy\",\"pageCount\":1,\"a3Pages\":0,\"a4Pages\":1,\"otherPages\":0,\"byteCount\":11}".utf8)
        let info = try JSONDecoder().decode(DocumentInfo.self, from: legacy)
        XCTAssertNil(info.filename)
        XCTAssertEqual(info.localFilename, "document.pdf")
        XCTAssertEqual(info.submissionName, "legacy.pdf")
        XCTAssertEqual(info.extensionSuffix, ".pdf")
    }
    func testImportedNamesCannotEscapeJobDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try JobQueue(root: root)
        let source = root.appendingPathComponent("source")
        try Data([1]).write(to: source)
        for name in ["../escape.docx", "x/evil", "x\\evil", "a\u{0}b", ".", "..", ""] {
            let info = DocumentInfo(title: name, pageCount: 0, byteCount: 1, filename: name)
            XCTAssertEqual(info.localFilename, "document.invalid")
            do { _ = try await queue.add(source: source, info: info, settings: PrintSettings()); XCTFail("bad filename") }
            catch { }
        }
        let jobs = try await queue.list()
        XCTAssertTrue(jobs.isEmpty)
    }
}
