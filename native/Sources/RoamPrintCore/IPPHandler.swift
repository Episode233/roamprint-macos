import Foundation

/// Captures into a local queue only. It has no enterprise transport or credentials.
public actor IPPHandler {
    public typealias Capture = @Sendable (Data, String, PrintSettings) async throws -> UUID
    public static let printerURI = "ipp://127.0.0.1:19963/ipp/print"
    private struct LocalJob {
        var title: String
        var settings: PrintSettings
        var state: Int = 3
        var captured: UUID?
        let created = Date()
    }
    private let capture: Capture
    private var jobs: [Int: LocalJob] = [:]
    private var nextID = 1
    private let start = Date()
    public init(capture: @escaping Capture) { self.capture = capture }

    public func handle(_ request: IPPMessage) async -> IPPMessage {
        guard request.major == 1 && request.minor <= 1 || request.major == 2 && request.minor <= 0 else {
            return .response(to: request, status: 0x0503)
        }
        guard request.value("attributes-charset")?.string?.lowercased() == "utf-8" else {
            return .response(to: request, status: 0x040b)
        }
        // Retain completed local receipts for query support, without retaining their PDF bytes.
        jobs = jobs.filter { item in
            let age = Date().timeIntervalSince(item.value.created)
            return item.value.state == 5 || age < (item.value.state == 3 ? 300 : 86400)
        }
        switch request.code {
        case 0x000b: // Get-Printer-Attributes
            return .response(to: request, attributes: printerAttributes())
        case 0x0004: // Validate-Job
            do { _ = try settings(request); try format(request); return .response(to: request) }
            catch { return failure(request, status: 0x040b, error: error) }
        case 0x0002: // Print-Job
            guard !request.document.isEmpty else { return .response(to: request, status: 0x0400) }
            do {
                try format(request)
                let options = try settings(request)
                let id = try newJob(title: title(request), settings: options)
                return await accept(request, id: id)
            } catch { return failure(request, status: 0x040b, error: error) }
        case 0x0005: // Create-Job: one document per local job
            do {
                let id = try newJob(title: title(request), settings: try settings(request))
                return .response(to: request, attributes: jobAttributes(id))
            } catch { return failure(request, status: 0x040b, error: error) }
        case 0x0006: // Send-Document
            guard let id = jobID(request), let job = jobs[id] else { return .response(to: request, status: 0x0406) }
            guard job.state == 3 else { return .response(to: request, status: 0x0404) }
            guard request.value("last-document")?.value == Data([1]), !request.document.isEmpty else {
                return .response(to: request, status: 0x040b)
            }
            do { try format(request); return await accept(request, id: id) }
            catch { return failure(request, status: 0x040b, error: error) }
        case 0x0009: // Get-Job-Attributes
            guard let id = jobID(request), jobs[id] != nil else { return .response(to: request, status: 0x0406) }
            return .response(to: request, attributes: jobAttributes(id))
        case 0x0008: // Cancel-Job only before document capture
            guard let id = jobID(request), var job = jobs[id] else { return .response(to: request, status: 0x0406) }
            guard job.state == 3 else { return .response(to: request, status: 0x0404) }
            job.state = 7; jobs[id] = job
            return .response(to: request, attributes: jobAttributes(id))
        case 0x000a: // Get-Jobs; completed captures live in the application's queue
            return .response(to: request)
        default:
            return .response(to: request, status: 0x0501)
        }
    }
    private func title(_ request: IPPMessage) -> String {
        let text = request.value("job-name")?.string ?? "打印文档"
        return String(text.prefix(255))
    }
    private func jobID(_ request: IPPMessage) -> Int? {
        if let id = request.value("job-id")?.integer { return id }
        guard let uri = request.value("job-uri")?.string,
              uri.hasPrefix(Self.printerURI + "/jobs/") else { return nil }
        return Int(uri.split(separator: "/").last ?? "")
    }
    private func newJob(title: String, settings: PrintSettings) throws -> Int {
        guard jobs.count < 4096, jobs.values.filter({ $0.state == 3 || $0.state == 5 }).count < 128 else {
            throw PrintError.queue("本地待接收作业过多，请稍后重试。")
        }
        let id = nextID; nextID += 1
        jobs[id] = LocalJob(title: title, settings: settings)
        return id
    }
    private func accept(_ request: IPPMessage, id: Int) async -> IPPMessage {
        guard var job = jobs[id] else { return .response(to: request, status: 0x0406) }
        guard request.document.count <= HTTPFramer.maxBodyBytes,
              request.document.prefix(5) == Data("%PDF-".utf8) else {
            job.state = 8; jobs[id] = job
            return failure(request, status: 0x040a, error: PrintError.invalidDocument("只接收 PDF 文档。"))
        }
        job.state = 5; jobs[id] = job
        do {
            let captured = try await capture(request.document, job.title, job.settings)
            job.captured = captured; job.state = 9; jobs[id] = job
            return .response(to: request, attributes: jobAttributes(id))
        } catch {
            job.state = 8; jobs[id] = job
            return failure(request, status: 0x0500, error: error)
        }
    }
    private func failure(_ request: IPPMessage, status: UInt16, error: Error) -> IPPMessage {
        .response(to: request, status: status, attributes: [
            .text("status-message", String(error.localizedDescription.prefix(512)), tag: 0x41, group: 1)
        ])
    }
    private func format(_ request: IPPMessage) throws {
        if let raw = request.value("document-format")?.string,
           !["application/pdf", "application/octet-stream"].contains(raw) {
            throw PrintError.invalidDocument("本地收集队列只支持 PDF，不能接收该文档格式。")
        }
        if let compression = request.value("compression")?.string, compression != "none" {
            throw PrintError.invalidDocument("不支持压缩的打印数据。")
        }
    }
    private func settings(_ request: IPPMessage) throws -> PrintSettings {
        var result = PrintSettings()
        if let attr = request.value("copies") {
            guard let copies = attr.integer else { throw PrintError.invalidDocument("份数格式错误。") }
            result.copies = copies
        }
        if let color = request.value("print-color-mode")?.string {
            switch color {
            case "monochrome": result.color = .gray
            case "color": result.color = .color
            default: throw PrintError.invalidDocument("不支持的颜色参数。")
            }
        }
        if let sides = request.value("sides")?.string {
            switch sides {
            case "one-sided": result.duplex = .single
            case "two-sided-long-edge": result.duplex = .longEdge
            case "two-sided-short-edge": result.duplex = .shortEdge
            default: throw PrintError.invalidDocument("不支持的单双面参数。")
            }
        }
        if let handling = request.value("multiple-document-handling")?.string {
            guard ["single-document", "separate-documents-collated-copies", "separate-documents-uncollated-copies"].contains(handling) else {
                throw PrintError.invalidDocument("不支持的份数排列方式。")
            }
            result.collate = handling != "separate-documents-uncollated-copies"
        }
        if let collate = request.value("sheet-collate")?.string {
            guard ["collated", "uncollated"].contains(collate) else {
                throw PrintError.invalidDocument("不支持的份数排列方式。")
            }
            result.collate = collate == "collated"
        }
        if let attr = request.value("orientation-requested") {
            guard let orientation = attr.integer, (3...6).contains(orientation) else {
                throw PrintError.invalidDocument("不支持的打印方向。")
            }
            result.landscape = orientation == 4 || orientation == 5
        }
        var requestedMedia = request.value("media")?.string
        if requestedMedia == nil, request.value("media-col") != nil {
            var member = "", width: Int?, height: Int?
            for attr in request.attributes where attr.name == "media-col" {
                if attr.tag == 0x4a { member = attr.string ?? "" }
                else if attr.tag == 0x21 {
                    if member == "x-dimension" { width = attr.integer }
                    if member == "y-dimension" { height = attr.integer }
                }
            }
            switch (width, height) {
            case (21000?, 29700?): requestedMedia = "iso_a4_210x297mm"
            case (29700?, 42000?): requestedMedia = "iso_a3_297x420mm"
            case (14800?, 21000?): requestedMedia = "iso_a5_148x210mm"
            case (21590?, 27940?): requestedMedia = "na_letter_8.5x11in"
            case (21590?, 35560?): requestedMedia = "na_legal_8.5x14in"
            default: throw PrintError.invalidDocument("不支持的纸型尺寸。")
            }
        }
        if let media = requestedMedia {
            let map: [String: (Int, String)] = [
                "iso_a4_210x297mm": (9, "A4"), "iso_a3_297x420mm": (8, "A3"),
                "iso_a5_148x210mm": (11, "A5"), "na_letter_8.5x11in": (1, "Letter"),
                "na_legal_8.5x14in": (5, "Legal")
            ]
            guard let paper = map[media] else { throw PrintError.invalidDocument("不支持的纸型。") }
            result.paperCode = paper.0; result.paperName = paper.1
        }
        // These options would change content and cannot silently be discarded.
        if let ranges = request.value("page-ranges"), ranges.value.count != 0 {
            throw PrintError.invalidDocument("请让 macOS 先生成所选页面的 PDF，再发送到收集队列。")
        }
        if let nup = request.value("number-up")?.integer, nup != 1 {
            throw PrintError.invalidDocument("请让 macOS 先完成每页多版排版。")
        }
        try result.validate()
        return result
    }
    private func jobAttributes(_ id: Int) -> [IPPAttribute] {
        guard let job = jobs[id] else { return [] }
        return [
            .integer("job-id", id, group: 2),
            .text("job-uri", Self.printerURI + "/jobs/\(id)", tag: 0x45, group: 2),
            .text("job-printer-uri", Self.printerURI, tag: 0x45, group: 2),
            .text("job-name", job.title, tag: 0x42, group: 2),
            .integer("job-state", job.state, tag: 0x23, group: 2),
            .text("job-state-reasons", job.state == 9 ? "job-completed-successfully" : job.state == 7 ? "job-canceled-by-user" : job.state == 8 ? "aborted-by-system" : "none", group: 2),
            .text("job-state-message", job.state == 9 ? "Captured locally. Submit in ZGCAxZGCI printer, then release by card." : "Receiving local PDF", tag: 0x41, group: 2)
        ]
    }
    private func printerAttributes() -> [IPPAttribute] {
        var result: [IPPAttribute] = [
            .text("printer-uri-supported", Self.printerURI, tag: 0x45),
            .text("uri-authentication-supported", "none"), .text("uri-security-supported", "none"),
            .text("printer-name", "ZGCAxZGCI printer", tag: 0x42),
            .text("printer-info", "ZGCAxZGCI printer", tag: 0x41),
            .text("printer-make-and-model", "ZGCAxZGCI printer", tag: 0x41),
            .text("printer-location", "Submit in the app, then release by card", tag: 0x41),
            .text("printer-uuid", "urn:uuid:9cf94258-91cc-4d48-87d8-e68293124fd0", tag: 0x45),
            .integer("printer-state", 3, tag: 0x23), .text("printer-state-reasons", "none"),
            .boolean("printer-is-accepting-jobs", true), .integer("queued-job-count", jobs.values.filter { $0.state == 3 || $0.state == 5 }.count),
            .integer("printer-up-time", Int(Date().timeIntervalSince(start))),
            .text("charset-configured", "utf-8", tag: 0x47), .text("charset-supported", "utf-8", tag: 0x47),
            .text("natural-language-configured", "en", tag: 0x48), .text("generated-natural-language-supported", "en", tag: 0x48),
            .text("document-format-default", "application/pdf", tag: 0x49),
            .text("document-format-supported", "application/pdf", tag: 0x49),
            // Advertising vnd.cups-pdf makes macOS treat us as a remote CUPS
            // scheduler and skip local PDF layout. We only receive final PDF.
            .text("compression-supported", "none"), .boolean("color-supported", true),
            .integer("copies-default", 1),
            .integer("orientation-requested-default", 3, tag: 0x23),
            .text("media-default", "iso_a4_210x297mm"),
            .text("sides-default", "one-sided"), .text("print-color-mode-default", "monochrome"),
            .text("multiple-document-handling-default", "separate-documents-collated-copies"),
            .text("sheet-collate-default", "collated"),
            .boolean("multiple-document-jobs-supported", false),
            .boolean("page-ranges-supported", false), .integer("number-up-supported", 1),
            .integer("number-up-default", 1),
            .resolution("printer-resolution-default", dpi: 300),
            .resolution("printer-resolution-supported", dpi: 300),
            .integer("print-quality-default", 4, tag: 0x23),
            .integer("print-quality-supported", 4, tag: 0x23)
        ]
        var range = Data(); range.appendUInt32(1); range.appendUInt32(999)
        result.append(IPPAttribute(group: 4, tag: 0x33, name: "copies-supported", value: range))
        var sizeRange = Data(); sizeRange.appendUInt32(0); sizeRange.appendUInt32(128 * 1024)
        result.append(IPPAttribute(group: 4, tag: 0x33, name: "job-k-octets-supported", value: sizeRange))
        for version in ["1.0", "1.1", "2.0"] { result.append(.text("ipp-versions-supported", version)) }
        for op in [2, 4, 5, 6, 8, 9, 10, 11] { result.append(.integer("operations-supported", op, tag: 0x23)) }
        let papers = [("iso_a4_210x297mm", 21000, 29700), ("iso_a3_297x420mm", 29700, 42000),
                      ("iso_a5_148x210mm", 14800, 21000), ("na_letter_8.5x11in", 21590, 27940),
                      ("na_legal_8.5x14in", 21590, 35560)]
        for paper in papers { result.append(.text("media-supported", paper.0)) }
        for paper in papers { result.append(.text("media-ready", paper.0)) }
        let margins = ["media-bottom-margin", "media-left-margin", "media-right-margin", "media-top-margin"]
        for member in ["media-size"] + margins { result.append(.text("media-col-supported", member)) }
        // This is a virtual PDF destination: physical printer margins are applied
        // by the enterprise platform, not by the local capture service.
        for margin in margins { result.append(.integer(margin + "-supported", 0)) }
        for paper in papers {
            result += IPPAttribute.collection("media-size-supported", members: [
                [.integer("x-dimension", paper.1)], [.integer("y-dimension", paper.2)]
            ])
        }
        for attribute in ["media-col-database", "media-col-ready", "media-col-default"] {
            for paper in (attribute == "media-col-default" ? Array(papers.prefix(1)) : papers) {
                let size = IPPAttribute.collection("media-size", members: [
                    [.integer("x-dimension", paper.1)], [.integer("y-dimension", paper.2)]
                ])
                result += IPPAttribute.collection(attribute, members: [size] + margins.map { [.integer($0, 0)] })
            }
        }
        for attribute in ["copies", "document-format", "job-name", "media", "media-col", "sides",
                          "print-color-mode", "multiple-document-handling", "orientation-requested",
                          "printer-resolution", "print-quality"] {
            result.append(.text("job-creation-attributes-supported", attribute))
        }
        for side in ["one-sided", "two-sided-long-edge", "two-sided-short-edge"] { result.append(.text("sides-supported", side)) }
        for color in ["monochrome", "color"] { result.append(.text("print-color-mode-supported", color)) }
        for collation in ["collated", "uncollated"] { result.append(.text("sheet-collate-supported", collation)) }
        for handling in ["separate-documents-collated-copies", "separate-documents-uncollated-copies"] {
            result.append(.text("multiple-document-handling-supported", handling))
        }
        for orientation in 3...6 { result.append(.integer("orientation-requested-supported", orientation, tag: 0x23)) }
        return result
    }
}
