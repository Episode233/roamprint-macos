#if os(macOS)
import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import RoamPrintCore

@MainActor
final class PrintModel: ObservableObject {
    @Published var jobs: [PrintJob] = []
    @Published var selectedID: UUID?
    @Published var username = ""
    @Published var password = ""
    @Published private(set) var rememberLogin = true
    @Published var busy = false
    @Published private var draftSettings: [UUID: PrintSettings] = [:]
    @Published var alert: String?
    @Published var diagnostic: String?
    @Published private(set) var configuration: ServerConfiguration?
    private var queue: JobQueue?
    private var refreshTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    private let rememberedLogin = RememberedLogin(store: KeychainLoginStore())

    var configurationAddress: String {
        configuration?.baseURL.absoluteString ?? "http://10.1.8.5/xzentprint/services"
    }
    var selectedJob: PrintJob? { jobs.first { $0.id == selectedID } }
    var canSubmit: Bool {
        guard let job = selectedJob else { return false }
        return !busy && configuration != nil && queue != nil && job.serverJobID == nil &&
            !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !password.isEmpty && [.queued, .failed].contains(job.state)
    }

    init() {
        do {
            let address = defaults.string(forKey: "platformAddress") ?? "http://10.1.8.5/xzentprint/services"
            configuration = try Self.configuration(from: address)
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true)
            queue = try JobQueue(root: support.appendingPathComponent("RoamPrint/jobs", isDirectory: true))
        } catch { alert = error.localizedDescription }
        restoreLogin()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.queue?.recoverInterrupted() } catch { self.alert = error.localizedDescription }
            while !Task.isCancelled {
                await self.reload()
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
            }
        }
    }

    static func configuration(from input: String) throws -> ServerConfiguration {
        guard var components = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw PrintError.invalidConfiguration("请输入有效的平台地址。")
        }
        guard components.query == nil, components.fragment == nil else {
            throw PrintError.invalidConfiguration("请输入不带查询参数的平台地址。")
        }
        var parts = components.path.split(separator: "/").map(String.init)
        if parts.last?.lowercased() == "login.aspx" { parts.removeLast() }
        if parts.last?.lowercased() != "services" { parts.append("services") }
        components.path = "/" + parts.joined(separator: "/")
        guard let url = components.url else { throw PrintError.invalidConfiguration("请输入有效的平台地址。") }
        return try ServerConfiguration(baseURL: url, generation: .v5)
    }

    func saveConfiguration(_ address: String) {
        guard !busy else { return }
        do {
            let value = try Self.configuration(from: address)
            let changed = configuration != value
            configuration = value
            defaults.set(value.baseURL.absoluteString, forKey: "platformAddress")
            if changed { restoreLogin() }
        } catch { alert = error.localizedDescription }
    }

    private func restoreLogin() {
        username = ""; password = ""
        guard let server = configuration?.baseURL else { return }
        rememberLogin = rememberedLogin.isEnabled(for: server)
        do {
            if let credentials = try rememberedLogin.restore(for: server) {
                username = credentials.username; password = credentials.password
            }
        } catch { alert = error.localizedDescription }
    }

    func setRememberLogin(_ enabled: Bool) {
        guard !busy, let server = configuration?.baseURL else { return }
        do {
            try rememberedLogin.setEnabled(enabled, for: server)
            rememberLogin = enabled
        } catch { alert = error.localizedDescription }
    }

    func clearLogin() {
        guard !busy else { return }
        username = ""; password = ""
        guard let server = configuration?.baseURL else { return }
        do {
            try rememberedLogin.setEnabled(false, for: server)
            rememberLogin = false
        } catch { alert = error.localizedDescription }
    }

    func reload() async {
        guard let queue else { return }
        do {
            jobs = try await queue.list()
            if !jobs.contains(where: { $0.id == selectedID }) { selectedID = jobs.first?.id }
        } catch { if alert == nil { alert = error.localizedDescription } }
    }

    func importFiles() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "选择待打印文件，保留原文件提交。单个文件最大 128 MB。"
        panel.prompt = "加入待提交列表"
        guard panel.runModal() == .OK, let queue else { return }
        let urls = panel.urls
        busy = true
        Task {
            defer { busy = false }
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size > 0, size <= 128 * 1024 * 1024 else {
                        throw PrintError.invalidDocument("\(url.lastPathComponent)：请选择非空文件，单个文件最大 128 MB。")
                    }
                    var pages = 0
                    if url.pathExtension.lowercased() == "pdf", let pdf = PDFDocument(url: url), !pdf.isLocked {
                        pages = pdf.pageCount
                    }
                    let info = DocumentInfo(title: url.lastPathComponent, pageCount: pages,
                                            byteCount: Int64(size), filename: url.lastPathComponent)
                    let job = try await queue.add(source: url, info: info, settings: PrintSettings())
                    selectedID = job.id
                } catch { alert = error.localizedDescription }
            }
            await reload()
        }
    }

    func checkConnection() {
        guard !busy, let configuration else { return }
        busy = true
        diagnostic = "正在检测 \(configuration.baseURL.absoluteString)…"
        Task {
            defer { busy = false }
            do { diagnostic = try await V5Platform(configuration: configuration).checkConnection() }
            catch { diagnostic = error.localizedDescription; alert = error.localizedDescription }
        }
    }

    func copyDiagnostic() {
        guard let text = diagnostic ?? alert else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func settings(for job: PrintJob) -> PrintSettings {
        draftSettings[job.id] ?? job.settings
    }

    func editSettings(_ job: PrintJob, settings: PrintSettings) {
        guard !busy, [.queued, .failed].contains(job.state) else { return }
        var value = settings
        value.paperCode = ["A4": 9, "A3": 8, "A5": 11, "Letter": 1, "Legal": 5][value.paperName] ?? 9
        draftSettings[job.id] = value
    }

    func submit() {
        guard canSubmit, let configuration, let queue, let job = selectedJob else { return }
        let settings = settings(for: job)
        let credentials = Credentials(username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
        busy = true
        Task {
            defer { busy = false }
            do {
                try await queue.updateSettings(job.id, settings: settings)
                draftSettings.removeValue(forKey: job.id)
                let platform = V5Platform(configuration: configuration)
                try await platform.submit(job: job, credentials: credentials, queue: queue)
                diagnostic = "\(job.document.title) 已提交，请到打印机刷卡取件。"
                do { try rememberedLogin.save(credentials, for: configuration.baseURL) }
                catch { alert = "文档已提交，但登录信息未能保存。\(error.localizedDescription)" }
            } catch { diagnostic = error.localizedDescription; alert = error.localizedDescription }
            await reload()
        }
    }

    func remove(_ job: PrintJob) {
        guard let queue else { return }
        Task {
            do {
                try await queue.remove(job.id)
                draftSettings.removeValue(forKey: job.id)
                await reload()
            }
            catch { alert = error.localizedDescription }
        }
    }

    func preview(_ job: PrintJob) {
        guard let queue else { return }
        Task { NSWorkspace.shared.open(await queue.documentURL(job.id)) }
    }

    func openPlatform() {
        guard let base = configuration?.baseURL else { return }
        NSWorkspace.shared.open(base.deletingLastPathComponent().appendingPathComponent("Login.aspx"))
    }

    func addToPrintMenu() {
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("add-to-print-menu.command"),
              FileManager.default.isExecutableFile(atPath: script.path) else {
            alert = "请使用构建脚本生成的 RoamPrint.app 添加打印队列。"
            return
        }
        if !NSWorkspace.shared.open(script) { alert = "无法打开打印队列安装程序。" }
    }
}
#endif
