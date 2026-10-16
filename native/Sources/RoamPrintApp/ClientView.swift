#if os(macOS)
import SwiftUI
import RoamPrintCore

struct ClientView: View {
    @ObservedObject var model: PrintModel
    @State private var isDropTargeted = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ZGCAxZGCIprinter").font(.title2.bold())
                Spacer()
                Button { model.importFiles() } label: { Label("导入文件", systemImage: "plus") }
                    .disabled(model.busy)
                Button("检测连接") { model.checkConnection() }.disabled(model.busy)
                Button { model.addToPrintMenu() } label: { Label("添加到打印菜单", systemImage: "printer") }
                    .disabled(model.busy)
                Button { model.openPlatform() } label: { Image(systemName: "globe") }
                    .help("打开打印平台")
            }.padding()
            Divider()
            HSplitView {
                List(selection: $model.selectedID) {
                    ForEach(model.jobs) { job in
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(job.document.title).lineLimit(1)
                                Text("\(job.document.pageDescription) · \(job.state.label)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button(role: .destructive) { model.remove(job) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .disabled(!model.canRemove(job))
                            .help("删除上传记录")
                            .accessibilityLabel("删除上传记录：\(job.document.title)")
                        }.padding(.vertical, 5).tag(job.id)
                        .contextMenu {
                            Button("删除上传记录", role: .destructive) { model.remove(job) }
                                .disabled(!model.canRemove(job))
                        }
                    }
                }
                .onDeleteCommand {
                    if let job = model.selectedJob { model.remove(job) }
                }
                .frame(minWidth: 250, idealWidth: 310)
                Group {
                    if let job = model.selectedJob {
                        JobDetailView(model: model, job: job).id(job.id)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "doc.badge.plus").font(.system(size: 38)).foregroundStyle(.secondary)
                            Text(model.jobs.isEmpty ? "尚无待提交文档" : "未选择文档").font(.title3)
                            Text(model.jobs.isEmpty
                                 ? "将文件拖到此窗口，或点击“导入文件”。\n也可从系统打印菜单选择“ZGCAxZGCIprinter”。"
                                 : "选择左侧记录查看详情，或拖入新文件。")
                                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                            Button("导入文件") { model.importFiles() }.disabled(model.busy)
                            Text("直接导入不限格式，按原文件提交；解析能力取决于打印平台。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(minWidth: 440)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("打印账号", text: $model.username).frame(width: 190).disabled(model.busy)
                    SecureField("密码", text: $model.password).frame(width: 190).disabled(model.busy)
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                    Button("提交并等待刷卡取件") { model.submit() }
                        .buttonStyle(.borderedProminent).disabled(!model.canSubmit)
                }
                HStack {
                    Toggle("记住登录信息", isOn: Binding(get: { model.rememberLogin }, set: { model.setRememberLogin($0) }))
                        .toggleStyle(.checkbox).disabled(model.busy)
                        .help("成功提交后保存，下次启动自动填写账号密码。")
                    Button("清除登录信息") { model.clearLogin() }.disabled(model.busy)
                }
                if let diagnostic = model.diagnostic {
                    HStack(alignment: .top) {
                        ScrollView { Text(diagnostic).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(maxHeight: 76)
                        Button("复制信息") { model.copyDiagnostic() }
                    }
                }
            }.padding()
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.importFiles(at: urls) != nil
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted && !model.busy {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .alert("打印提示", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("知道了", role: .cancel) { model.alert = nil }
        } message: { Text(model.alert ?? "") }
    }
}

private struct JobDetailView: View {
    @ObservedObject var model: PrintModel
    let job: PrintJob
    private var settings: Binding<PrintSettings> {
        Binding(get: { model.settings(for: job) }, set: { model.editSettings(job, settings: $0) })
    }
    private var editable: Bool { [.queued, .failed].contains(job.state) && !model.busy }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(job.document.title).font(.title2).textSelection(.enabled)
                Text("\(job.document.pageDescription) · \(ByteCountFormatter.string(fromByteCount: job.document.byteCount, countStyle: .file))")
                    .foregroundStyle(.secondary)
                Text(job.state.label).font(.headline)
                if let id = job.serverJobID { Text("平台作业编号：\(id)").font(.caption).textSelection(.enabled) }
                if let message = job.message { Text(message).foregroundStyle(.secondary).textSelection(.enabled) }
                if job.state == .uncertain {
                    Text("请先在平台核对这份文档的状态，避免重复提交。")
                    Button("打开打印平台核对") { model.openPlatform() }
                }
                Divider()
                Form {
                    Stepper("份数：\(settings.wrappedValue.copies)", value: settings.copies, in: 1...999)
                    Picker("颜色", selection: settings.color) {
                        Text("黑白").tag(PrintSettings.Color.gray)
                        Text("彩色").tag(PrintSettings.Color.color)
                    }
                    Picker("双面", selection: settings.duplex) {
                        Text("单面").tag(PrintSettings.Duplex.single)
                        Text("双面，长边翻转").tag(PrintSettings.Duplex.longEdge)
                        Text("双面，短边翻转").tag(PrintSettings.Duplex.shortEdge)
                    }
                    Picker("纸张", selection: settings.paperName) {
                        ForEach(["A4", "A3", "A5", "Letter", "Legal"], id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("逐份打印", isOn: settings.collate)
                    Toggle("横向", isOn: settings.landscape)
                }.disabled(!editable)
                HStack {
                    Button("打开文档") { model.preview(job) }
                    Spacer()
                    Button("删除上传记录", role: .destructive) { model.remove(job) }
                        .disabled(!model.canRemove(job))
                        .help("删除本地记录和缓存文件，保留原文件及平台上的作业。")
                }
            }.padding(24)
        }
    }
}

struct ConfigurationView: View {
    @ObservedObject var model: PrintModel
    @State private var address = ""
    var body: some View {
        Form {
            Text("打印平台").font(.headline)
            TextField("平台地址", text: $address)
            Text("可填写平台登录页地址。当前支持现有 V5 打印平台。")
                .font(.caption).foregroundStyle(.secondary)
            Button("保存") { model.saveConfiguration(address); address = model.configurationAddress }
                .disabled(model.busy)
            Text("勾选“记住登录信息”后，成功提交时将账号密码保存在 macOS 钥匙串，下次启动自动填写。")
                .font(.caption).foregroundStyle(.secondary)
        }.onAppear { address = model.configurationAddress }
    }
}
#endif
