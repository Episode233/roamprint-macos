#if os(macOS)
import XCTest
import RoamPrintCore
@testable import RoamPrintApp

private struct EmptyCredentialStore: LoginCredentialStoring {
    func read(for platform: String) throws -> Credentials? { nil }
    func save(_ credentials: Credentials, for platform: String) throws {}
    func delete(for platform: String) throws {}
}

@MainActor
final class PrintModelTests: XCTestCase {
    private func fixture() throws -> (URL, JobQueue, PrintModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let queue = try JobQueue(root: root.appendingPathComponent("jobs"))
        let suite = "RoamPrint.AppTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let model = PrintModel(queue: queue, defaults: defaults,
                               credentialStore: EmptyCredentialStore(), refreshAutomatically: false)
        return (root, queue, model)
    }

    private func source(in root: URL, name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("Original file: \(name)".utf8).write(to: url)
        return url
    }

    func testClearedSelectionSurvivesPollingAndNewCapturedJobs() async throws {
        let (root, queue, model) = try fixture()
        let source = try source(in: root, name: "report.docx")
        let importing = try XCTUnwrap(model.importFiles(at: [source]))
        await importing.value
        let imported = try XCTUnwrap(model.selectedJob)

        // Clicking blank list space clears the binding. Both ordinary refreshes
        // and an incoming job from another process must preserve that choice.
        model.selectedID = nil
        await model.reload()
        let captured = try await queue.add(source: source, info: imported.document, settings: PrintSettings())
        await model.reload()
        await model.reload()
        XCTAssertNil(model.selectedID)
        XCTAssertNil(model.selectedJob)
        XCTAssertEqual(Set(model.jobs.map(\.id)), Set([imported.id, captured.id]))

        model.selectedID = imported.id
        await model.reload()
        XCTAssertEqual(model.selectedID, imported.id)
    }

    func testRowDeletionKeepsAnotherSelectionAndTheOriginalFiles() async throws {
        let (root, queue, model) = try fixture()
        let first = try source(in: root, name: "first.docx")
        let second = try source(in: root, name: "second.png")
        let importing = try XCTUnwrap(model.importFiles(at: [first, second]))
        await importing.value
        let firstJob = try XCTUnwrap(model.jobs.first { $0.document.filename == "first.docx" })
        let secondJob = try XCTUnwrap(model.selectedJob)
        let cachedFirst = await queue.documentURL(firstJob.id)
        let deleting = try XCTUnwrap(model.remove(firstJob))
        await deleting.value
        await model.reload()

        XCTAssertEqual(model.selectedID, secondJob.id)
        XCTAssertEqual(model.jobs.map(\.id), [secondJob.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cachedFirst.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertFalse(model.busy)
    }

    func testDeletingSelectedRowDoesNotSelectTheRemainingRow() async throws {
        let (root, _, model) = try fixture()
        let first = try source(in: root, name: "first.docx")
        let second = try source(in: root, name: "second.png")
        let importing = try XCTUnwrap(model.importFiles(at: [first, second]))
        await importing.value
        let selected = try XCTUnwrap(model.selectedJob)
        let deleting = try XCTUnwrap(model.remove(selected))
        await deleting.value
        await model.reload()

        XCTAssertEqual(model.jobs.count, 1)
        XCTAssertEqual(model.jobs.first?.document.filename, "first.docx")
        XCTAssertNil(model.selectedID)
        XCTAssertNil(model.selectedJob)
    }

    func testDroppedURLsPreserveOriginalFormatsAndSkipDirectories() async throws {
        let (root, queue, model) = try fixture()
        let directory = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let urls = try ["预算.xlsx", "photo.png", "no-extension"].map { try source(in: root, name: $0) }
        let importing = try XCTUnwrap(model.importFiles(at: [directory] + urls))
        await importing.value

        XCTAssertEqual(Set(model.jobs.compactMap(\.document.filename)), Set(urls.map(\.lastPathComponent)))
        XCTAssertTrue(model.alert?.contains("文件夹") == true)
        for job in model.jobs {
            let original = root.appendingPathComponent(try XCTUnwrap(job.document.filename))
            let cached = await queue.documentURL(job.id)
            XCTAssertEqual(try Data(contentsOf: cached), try Data(contentsOf: original))
        }
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.importFiles(at: [URL(string: "https://example.com/document.docx")!]))
    }

    func testBusyAndUncertainJobsCannotBeDeletedFromTheList() async throws {
        let (root, queue, model) = try fixture()
        let source = try source(in: root, name: "report.docx")
        let importing = try XCTUnwrap(model.importFiles(at: [source]))
        await importing.value
        var job = try XCTUnwrap(model.selectedJob)
        model.busy = true
        XCTAssertNil(model.remove(job))
        XCTAssertNil(model.importFiles(at: [source]))
        model.busy = false
        job.state = .uncertain
        job.serverJobID = "pending-result"
        try await queue.save(job)
        await model.reload()
        XCTAssertFalse(model.canRemove(job))
        XCTAssertNil(model.remove(job))
        let remaining = try await queue.list()
        XCTAssertEqual(remaining.map(\.id), [job.id])
    }
}
#endif
