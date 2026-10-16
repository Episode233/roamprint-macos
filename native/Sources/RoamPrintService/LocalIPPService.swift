#if os(macOS)
import Foundation
import AppKit
import Network
import PDFKit
import RoamPrintCore

/// Per-user loopback capture daemon. It never connects to the enterprise platform.
final class LocalIPPService {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "RoamPrint.loopback")
    private let handler: IPPHandler
    private var connections: [UUID: IPPConnection] = [:]

    init() throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        let jobs = try JobQueue(root: support.appendingPathComponent("RoamPrint/jobs", isDirectory: true))
        handler = IPPHandler { data, title, settings in
            guard let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0 else {
                throw PrintError.invalidDocument("PDF 无法读取、已加密或没有可打印页面。")
            }
            var a3 = 0, a4 = 0, other = 0
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else {
                    throw PrintError.invalidDocument("PDF 页面无法读取。")
                }
                let bounds = page.bounds(for: .mediaBox)
                let short = min(bounds.width, bounds.height), long = max(bounds.width, bounds.height)
                if abs(short - 842) < 4 && abs(long - 1191) < 4 { a3 += 1 }
                else if abs(short - 595) < 4 && abs(long - 842) < 4 { a4 += 1 }
                else { other += 1 }
            }
            let incoming = jobs.root.appendingPathComponent(".incoming", isDirectory: true)
            try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let path = incoming.appendingPathComponent(UUID().uuidString + ".pdf")
            guard FileManager.default.createFile(atPath: path.path, contents: nil,
                                                attributes: [.posixPermissions: 0o600]) else {
                throw PrintError.queue("无法创建本地打印文档。")
            }
            defer { try? FileManager.default.removeItem(at: path) }
            let file = try FileHandle(forWritingTo: path)
            do { try file.write(contentsOf: data); try file.synchronize(); try file.close() }
            catch { try? file.close(); throw error }
            let info = DocumentInfo(title: title, pageCount: document.pageCount, a3Pages: a3,
                                    a4Pages: a4, otherPages: other, byteCount: Int64(data.count))
            let captured = try await jobs.add(source: path, info: info, settings: settings).id
            let app = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            if app.pathExtension == "app" {
                DispatchQueue.main.async {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    NSWorkspace.shared.openApplication(at: app, configuration: configuration, completionHandler: nil)
                }
            }
            return captured
        }
        let parameters = NWParameters.tcp
        // A required loopback endpoint prevents an accidental LAN-wide listener.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: 19963)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            guard self.connections.count < 8 else { connection.cancel(); return }
            let id = UUID()
            let client = IPPConnection(connection: connection, queue: self.queue, handler: self.handler) { [weak self] in
                self?.connections.removeValue(forKey: id)
            }
            self.connections[id] = client
            client.start()
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                FileHandle.standardError.write(Data("本地打印服务启动失败：\(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
    }
    static func run() throws {
        let service = try LocalIPPService()
        service.listener.start(queue: service.queue)
        withExtendedLifetime(service) { dispatchMain() }
    }
}

private final class IPPConnection {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: IPPHandler
    private let onClose: () -> Void
    private var framer = HTTPFramer()
    private var sentContinue = false
    private var closed = false
    private var timer: DispatchSourceTimer?
    init(connection: NWConnection, queue: DispatchQueue, handler: IPPHandler, onClose: @escaping () -> Void) {
        self.connection = connection; self.queue = queue; self.handler = handler; self.onClose = onClose
    }
    func start() {
        let timeout = DispatchSource.makeTimerSource(queue: queue)
        timeout.schedule(deadline: .now() + 60)
        timeout.setEventHandler { [weak self] in self?.close() }
        timer = timeout; timeout.resume()
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }
            else if case .cancelled = state { self?.close() }
        }
        connection.start(queue: queue)
        receive()
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] bytes, _, ended, error in
            guard let self, !self.closed else { return }
            do {
                if let bytes, let body = try self.framer.append(bytes) {
                    self.process(body)
                    return
                }
                if self.framer.expectsContinue && !self.sentContinue {
                    self.sentContinue = true
                    self.connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                }
                if ended || error != nil { self.close() } else { self.receive() }
            } catch { self.respond(status: 400, type: "text/plain", body: Data("Invalid request".utf8)) }
        }
    }
    private func process(_ body: Data) {
        let host = framer.headers["host"]?.lowercased() ?? ""
        guard framer.method == "POST", framer.path == "/ipp/print",
              ["127.0.0.1:19963", "127.0.0.1", "localhost:19963", "localhost"].contains(host),
              framer.headers["content-type"]?.lowercased().split(separator: ";").first == "application/ipp",
              framer.headers["origin"] == nil else {
            respond(status: 400, type: "text/plain", body: Data("Only local IPP requests are supported".utf8)); return
        }
        do {
            let request = try IPPMessage(data: body)
            Task {
                let response = await handler.handle(request)
                do {
                    let output = try response.encoded()
                    queue.async { [weak self] in self?.respond(status: 200, type: "application/ipp", body: output) }
                } catch {
                    queue.async { [weak self] in self?.respond(status: 500, type: "text/plain", body: Data()) }
                }
            }
        } catch { respond(status: 400, type: "text/plain", body: Data("Malformed IPP".utf8)) }
    }
    private func respond(status: Int, type: String, body: Data) {
        guard !closed else { return }
        let reason = status == 200 ? "OK" : status == 400 ? "Bad Request" : "Internal Server Error"
        var data = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in self?.close() })
    }
    private func close() {
        guard !closed else { return }
        closed = true; timer?.cancel(); timer = nil
        connection.cancel(); onClose()
    }
}
#endif
