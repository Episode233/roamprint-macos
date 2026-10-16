import XCTest
@testable import RoamPrintCore

final class IPPTests: XCTestCase {
    private actor Captures {
        var values: [(Data, String, PrintSettings)] = []
        func add(_ data: Data, _ title: String, _ settings: PrintSettings) -> UUID {
            values.append((data, title, settings)); return UUID()
        }
        func count() -> Int { values.count }
        func lastSettings() -> PrintSettings? { values.last?.2 }
    }
    private func request(_ operation: UInt16, _ attrs: [IPPAttribute] = [], document: Data = Data()) -> IPPMessage {
        IPPMessage(code: operation, requestID: 77, attributes: [
            .text("attributes-charset", "utf-8", tag: 0x47, group: 1),
            .text("attributes-natural-language", "en", tag: 0x48, group: 1),
            .text("printer-uri", IPPHandler.printerURI, tag: 0x45, group: 1)
        ] + attrs, document: document)
    }
    func testIPPContinuationValuesAndBinaryPDFRoundTrip() throws {
        let document = Data([0, 255, 10, 13, 3])
        let original = request(2, [.text("sides", "one-sided"), .text("sides", "two-sided-long-edge")], document: document)
        let decoded = try IPPMessage(data: original.encoded())
        XCTAssertEqual(decoded.requestID, 77)
        XCTAssertEqual(decoded.attributes, original.attributes)
        XCTAssertEqual(decoded.document, document)
    }
    func testInvalidIPPAndOversizeAttributesThrow() throws {
        XCTAssertThrowsError(try IPPMessage(data: Data([2, 0, 0, 2, 0, 0, 0, 1, 4, 0x44, 0, 0, 0, 1, 65, 3])))
        XCTAssertThrowsError(try request(2, [.text("job-name", String(repeating: "a", count: 65536))]).encoded())
        XCTAssertThrowsError(try IPPMessage(data: Data([2, 0, 0, 2, 0, 0, 0, 1, 0, 3])))
    }
    func testPrintJobCapturesSettingsWithoutSubmitting() async throws {
        let captures = Captures()
        let handler = IPPHandler { data, title, settings in await captures.add(data, title, settings) }
        let result = await handler.handle(request(2, [
            .text("document-format", "application/pdf", tag: 0x49, group: 1),
            .text("job-name", "测试文档", tag: 0x42, group: 1),
            .integer("copies", 3), .text("sides", "two-sided-long-edge"),
            .text("print-color-mode", "color"), .text("media", "iso_a3_297x420mm")
        ], document: Data("%PDF-1.7\nfixture".utf8)))
        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(result.value("job-state")?.integer, 9)
        let count = await captures.count(), settings = await captures.lastSettings()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(settings?.copies, 3)
        XCTAssertEqual(settings?.duplex, .longEdge)
        XCTAssertEqual(settings?.color, .color)
        XCTAssertEqual(settings?.paperName, "A3")
        let query = await handler.handle(request(9, [.integer("job-id", result.value("job-id")!.integer!, group: 1)]))
        XCTAssertEqual(query.value("job-state")?.integer, 9)
    }
    func testCreateJobRequiresFinalDocumentAndDoesNotAcceptTwice() async throws {
        let captures = Captures()
        let handler = IPPHandler { data, title, settings in await captures.add(data, title, settings) }
        let created = await handler.handle(request(5, [.integer("copies", 2)]))
        let id = created.value("job-id")!.integer!
        let incomplete = request(6, [.integer("job-id", id, group: 1), .boolean("last-document", false, group: 1)], document: Data("%PDF-fixture".utf8))
        let rejected = await handler.handle(incomplete)
        XCTAssertNotEqual(rejected.code, 0)
        let complete = request(6, [.integer("job-id", id, group: 1), .boolean("last-document", true, group: 1)], document: Data("%PDF-fixture".utf8))
        let accepted = await handler.handle(complete), repeated = await handler.handle(complete)
        XCTAssertEqual(accepted.code, 0)
        XCTAssertNotEqual(repeated.code, 0)
        let count = await captures.count()
        XCTAssertEqual(count, 1)
    }
    func testInvalidDocumentUnsupportedOptionsAndVersionDoNotCapture() async throws {
        let captures = Captures()
        let handler = IPPHandler { data, title, settings in await captures.add(data, title, settings) }
        let badPDF = await handler.handle(request(2, document: Data("not PDF".utf8)))
        let badCopies = await handler.handle(request(2, [.integer("copies", 0)], document: Data("%PDF-fixture".utf8)))
        let raster = await handler.handle(request(2, [.text("document-format", "image/pwg-raster", tag: 0x49, group: 1)], document: Data("%PDF-fixture".utf8)))
        var future = request(11); future.major = 3
        let unsupported = await handler.handle(future)
        XCTAssertNotEqual(badPDF.code, 0); XCTAssertNotEqual(badCopies.code, 0); XCTAssertNotEqual(raster.code, 0)
        XCTAssertEqual(unsupported.code, 0x0503)
        let count = await captures.count()
        XCTAssertEqual(count, 0)
    }
    func testNestedMediaCollectionMapsActualDimensions() async throws {
        let captures = Captures()
        let handler = IPPHandler { data, title, settings in await captures.add(data, title, settings) }
        let collection: [IPPAttribute] = [
            IPPAttribute(group: 2, tag: 0x34, name: "media-col", value: Data()),
            .text("media-col", "media-size", tag: 0x4a, group: 2),
            IPPAttribute(group: 2, tag: 0x34, name: "media-col", value: Data()),
            .text("media-col", "x-dimension", tag: 0x4a, group: 2),
            .integer("media-col", 21590, group: 2),
            .text("media-col", "y-dimension", tag: 0x4a, group: 2),
            .integer("media-col", 27940, group: 2),
            IPPAttribute(group: 2, tag: 0x37, name: "media-col", value: Data()),
            IPPAttribute(group: 2, tag: 0x37, name: "media-col", value: Data())
        ]
        let decoded = try IPPMessage(data: request(2, collection, document: Data("%PDF-fixture".utf8)).encoded())
        let result = await handler.handle(decoded)
        XCTAssertEqual(result.code, 0)
        let settings = await captures.lastSettings()
        XCTAssertEqual(settings?.paperName, "Letter")
    }
    func testApplePresetDirectionAndCollationReachEnterpriseFields() async throws {
        let captures = Captures()
        let handler = IPPHandler { data, title, settings in await captures.add(data, title, settings) }
        for (orientation, collate) in [(1, false), (2, true)] {
            let response = await handler.handle(request(2, [
                .text("com.apple.print.preset.Orientation..n.", String(orientation)),
                .boolean("com.apple.print.PrintSettings.PMCopyCollate..b.", collate)
            ], document: Data("%PDF-fixture".utf8)))
            XCTAssertEqual(response.code, 0)
            let settings = await captures.lastSettings()!
            let job = PrintJob(document: DocumentInfo(title: "fixture", pageCount: 1, byteCount: 12345), settings: settings)
            let fields = V5Wire.createFields(job: job, credentials: Credentials(username: "fixture", password: "unused"),
                password: "fixture-encrypted", identity: ClientIdentity(ip: "127.0.0.1", mac: "", host: "test"))
            XCTAssertEqual(fields["direction"] as? Int, orientation)
            XCTAssertEqual(fields["iscollate"] as? Int, collate ? 1 : 0)
            XCTAssertEqual(fields["filesize"] as? Int64, 12345)
            XCTAssertEqual(fields["directprintid"] as? Int, -1)
        }
        let malformed = await handler.handle(request(2, [.text("Collate", "unsupported")], document: Data("%PDF-fixture".utf8)))
        XCTAssertNotEqual(malformed.code, 0)
        let count = await captures.count()
        XCTAssertEqual(count, 2)
    }
    func testPrinterAdvertisesPDFAndCaptureOnlyOperations() async throws {
        let handler = IPPHandler { _, _, _ in XCTFail("query must not capture"); return UUID() }
        let result = await handler.handle(request(11))
        let decoded = try IPPMessage(data: result.encoded())
        XCTAssertEqual(decoded.code, 0)
        XCTAssertEqual(decoded.value("printer-uri-supported")?.string, IPPHandler.printerURI)
        XCTAssertEqual(decoded.value("document-format-default")?.string, "application/pdf")
        XCTAssertEqual(decoded.value("copies-supported")?.value, Data([0,0,0,1,0,0,3,231]))
    }
}
