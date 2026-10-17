# 验证记录

最新验证日期：2026-10-17；以下历史记录保留各次实际验证日期。目标是 Apple Silicon 上保持“系统打印菜单 → 本地待提交 → 企业平台 → 刷卡释放”，不使用 Rosetta。

## 1.0.0 历次修改的旧代码审查

2026-10-17，[GitHub macOS 15 ARM64 构建 39000735253](https://github.com/Episode233/roamprint-macos/actions/runs/39000735253) 已成功，对应源码提交 `532fbc33bf196faa022d5222f3e97091182284ee`。[安装包](https://github.com/Episode233/roamprint-macos/actions/runs/39000735253/artifacts/12089181743) 仍为 `ZGCAxZGCI printer-1.0.0-arm64.pkg`；内部构建号保持 `3`。

本轮检查覆盖 17 个 Swift 源文件、C 协议依赖、资源、安装/构建脚本、工作流、测试及工作区交付物。删除了未调用的表单编码器、URLSession 上传入口、V6/域登录占位字段及检查、未读取的 IPP 捕获编号副本和刷新任务句柄；详情和逐项核对见 [旧代码检查](code-audit.md)。本地工作区的废弃 Web 原型及旧名称、旧版本构建包也已清理。

Linux 42 项核心测试通过。macOS 完整测试包含扩展的真实钥匙串测试：直接写入带 kind 字段的既有记录后，新实现仍可读取账号密码，并可继续更新和删除。5 项界面模型测试、真实 IPP/CUPS 打印、发布编译、ARM64 架构检查、签名校验、PKG 打包及产物上传均通过。

当前源码、工作区镜像和源码构建包同步，源码 ZIP 不含隐藏文件、PPD 或 Web 原型；刷卡任务参数 `directprintid=-1`、应用/队列显示名称、登录 service 和作业目录保持不变。本次未连接真实企业平台，现场刷卡结果仍不属于已验证范围。

## 1.0.0 清理旧 PPD 与参数兼容分支

2026-10-17，[GitHub macOS 15 ARM64 构建 38999830857](https://github.com/Episode233/roamprint-macos/actions/runs/38999830857) 已成功，对应源码提交 `a8a585f09ef4219652959eeeda3794fb1f3997f4`。[安装包](https://github.com/Episode233/roamprint-macos/actions/runs/38999830857/artifacts/12089150223) 仍为 `ZGCAxZGCI printer-1.0.0-arm64.pkg`，内部构建号仍为 `3`。

已删除旧 PPD 文件、旧队列迁移测试，以及 ColorModel、Duplex、PageSize、旧后端专有方向/逐份预设和 cups-pdf 类型的兼容解析。当前只使用标准 IPP 打印参数；文档原文件导入和企业平台提交流程保持原样。源码仓库及可见文件构建包均已检查不含 PPD 文件。

Linux 42 项核心测试通过。macOS 完整测试、release 编译、架构检查、签名校验和打包通过。真实 CUPS 测试确认无 PPD 的应用可完成免驱队列配置，默认参数、A3 彩色 3 份长边双面、2 份非逐份短边双面、选页及每页多版均正确进入本地待提交列表。安装命令无驱动弃用提示。

上述验证未连接企业内网，用户 macOS 27 与 Word/WPS 的现场打印及刷卡取件仍需验证。以下各节保留历史构建的实际结果。

## 1.0.0 免驱 IPP 迁移

2026-10-17，[GitHub macOS 15 ARM64 构建 38998616202](https://github.com/Episode233/roamprint-macos/actions/runs/38998616202) 已成功，对应源码提交 `69d892cc9d4dab379e3f57aa822fe29241684ba2`。[安装包](https://github.com/Episode233/roamprint-macos/actions/runs/38998616202/artifacts/12087942431) 为 `ZGCAxZGCI printer-1.0.0-arm64.pkg`；发布版本仍为 `1.0.0`，内部构建号仍为 `3`。

应用不再附带自定义 PPD，安装采用 `lpadmin -m everywhere`。Linux 42 项核心测试全部通过，包含嵌套 IPP 集合的独立字节级验证及五种纸型的能力/提交一致性检查。GitHub 完成 macOS 完整测试（含真实钥匙串与界面模型）、release 编译、ARM64 检查、签名校验和 PKG 打包。

新增 `tools/test-driverless-macos.py` 直接启动打包后的本地服务，并通过 macOS 真实 CUPS 队列验证：

- 新建免驱队列成功，命令输出不含驱动弃用提示，纸张、灰度/彩色和双面选项均可发现。
- 安装时的 A4、黑白、单面默认值正确；3 份、A3、彩色、长边双面保留到本地作业，PDF 未重复扩展为多份。
- 两页文档只选第 2 页时收到一页 PDF；每页两版时收到一页排版后的 PDF。
- 先用旧 PPD 创建测试队列并暂停一个作业，再原位升级为免驱队列：作业编号保留，恢复后成功进入待提交列表。
- 所有捕获均为本地 `queued`，无平台任务编号，测试不连接企业平台。

该次构建曾在 `tools/fixtures/legacy-capture.ppd` 保留旧 PPD 供迁移测试使用；该文件及迁移测试现已删除。该次测试构造旧队列时出现的弃用提示属于预期，安装脚本未使用该 PPD。原有 Swift 并发 Sendable 提醒仍在构建中出现，不影响本次验证通过。

用户升级后需再点一次“添加到打印菜单”。macOS 27 上的真实 Word/WPS 打印及内网刷卡取件尚待现场验证；不承诺未经测试的未来系统永久兼容。

## 1.0.0 打印菜单与导入交互修复

2026-10-16，[GitHub 构建 38873731293](https://github.com/Episode233/roamprint-macos/actions/runs/38873731293) 已通过，源码提交为 `9d9cc763bfaf051dc1bb2e868f8dc6dc8ea562b6`。版本和内部构建号保持不变；[本次安装包](https://github.com/Episode233/roamprint-macos/actions/runs/38873731293/artifacts/12034147884) 仍名为 `ZGCAxZGCIprinter-1.0.0-arm64.pkg`。

- 安装脚本移除了会触发开发工具安装的 `lipo` 调用；ARM64 架构检查继续在云端构建时执行。安装脚本通过 `bash -n`。
- 列表刷新保留空选择；删除选中项后不自动选中其余记录。列表行按钮、右键菜单和 Delete 键使用同一删除入口，文案统一为“删除上传记录”。
- 窗口接收本地文件 URL 的拖放，与文件选择器共用导入路径；多个文件保留原文件名及字节，文件夹单独报错，不阻止其余有效文件导入。
- Linux 41 项核心测试通过；macOS CI 的完整测试通过，包括新增的 5 项应用模型回归测试：取消选择后的多次刷新和新作业到达、删除非选中项、删除选中项、混合格式多文件导入、繁忙及待确认状态下的删除保护。测试使用临时队列和独立偏好设置，不读取用户登录信息。
- 云端 ARM64 编译、签名校验、PKG 打包及上传均通过。Finder 拖拽、列表按钮和键盘的实际界面操作，以及无开发工具的用户 Mac 上安装打印队列，仍需在目标设备确认；这些系统交互未由模型测试代替验证。

## 1.0.0 发布构建

2026-10-16，用户指定的 **1.0.0** 已通过 [GitHub macOS ARM64 构建 38863514286](https://github.com/Episode233/roamprint-macos/actions/runs/38863514286)，源码提交为 `dc62fbad25e34ba6de35a796252d9997eaef1bf7`。完整测试、发布编译、架构检查、应用签名校验、PKG 打包及上传均成功。[安装包](https://github.com/Episode233/roamprint-macos/actions/runs/38863514286/artifacts/12030575480) 中的文件为 `ZGCAxZGCIprinter-1.0.0-arm64.pkg`。本次只同步发布版本和版本管理约定；内部构建号保持原值，后续未经用户明确指定不自行升版。

下方保留此前各版本的实际验证记录。

## 已验证

Linux x86_64、Swift 6.2.4、包含系统 curl 的 Docker 环境中，`swift test` 共 **41 项测试通过，0 失败**。

| 范围 | 测试数 | 覆盖内容 |
| --- | ---: | --- |
| 系统 curl 上传 | 2 | 实际本地 WebDAV：MKCOL、PUT、1 MB 文档字节一致、含引号/反斜杠的密码、重定向和 503 终止上传 |
| 系统 curl FTP | 2 | 实际本地 FTP：登录凭据、缺失目录创建、被动数据连接、1 MB 文档字节一致、STOR 被拒绝时停止 |
| 完整网络提交 | 3 | 实际 URLSession 和 curl 连接本地 API/存储：取令牌、获取存储、创建、上传、确认；确认响应丢失时保留待确认状态，禁止重新创建；无 CORS 响应头的接口仍可原生访问，无 OPTIONS 预检和 Origin 请求头 |
| HTTP 帧解析 | 3 | 分段接收、Content-Length、chunked、100-continue、异常请求 |
| IPP 文档收集 | 8 | Print-Job、Create-Job/Send-Document、单次接收、纸张尺寸、Apple 方向/逐份打印预设到 V5 字段、不支持选项拒绝 |
| 本地持久队列 | 5 | 提交原子认领、异常记录保留、中断状态恢复、符号链接根目录拒绝、旧 PDF 元数据兼容、原文件名验证 |
| 密码和摘要 | 5 | 公开 Twofish 向量、独立 libgcrypt 样本、MD5 向量、UTF-8/填充/长度限制 |
| 记住登录信息 | 3 | 使用内存存储替身验证跨会话恢复、更新、清除、删除失败提示、平台隔离；普通偏好设置不含账号密码 |
| V5 提交流程 | 10 | 模拟企业平台验证请求顺序、漫游参数、响应丢失禁止重试、编码文件与 ZIP 内容恢复；Office/图片/未知后缀/无后缀的文件名及字节保留；连接检测不创建任务；错误地址和明确拒绝的状态分类 |

GitHub 的 **macOS 15 ARM64** runner 已完成实际 Apple SDK 编译和链接；[构建 38848133220](https://github.com/Episode233/roamprint-macos/actions/runs/38848133220) 的结论为 **success**，对应源码提交 `a88159830f36cea3a5ae34193d81c57456751e4f`。成功步骤包括：

- 完整 `swift test --arch arm64`，包括仅 macOS 执行的真实钥匙串新增、读取、更新、删除测试。工作流使用临时钥匙串和随机测试 service，无需用户打印凭据。
- 应用及本地收集服务的 release 编译，以及两个可执行文件的 `lipo -verify_arch arm64` 检查。
- 应用 ad-hoc 签名、`codesign --verify --deep --strict` 校验、PKG 打包和应用 ZIP 打包。
- 上传 [ZGCAxZGCIprinter-arm64](https://github.com/Episode233/roamprint-macos/actions/runs/38848133220/artifacts/12023682895)，包含 `ZGCAxZGCIprinter-0.2.1-arm64.pkg`、应用 ZIP 和 `SHA256SUMS`。产物保留 30 天。

修复了收集服务对 actor 隔离属性的访问，以及构建和安装脚本的 `lipo` 参数顺序。中文 ZIP 文件名测试在 macOS 使用系统 `ditto` 解压，在 Linux 使用系统 `unzip`；两者均检查原文件名和内容字节。

构建、安装、移除及应用启动安装的四个脚本通过 `bash -n`，工作流通过 actionlint 1.7.7 检查。工作流兼容展开源码和浏览器上传的 `RoamPrint-source.zip`；编译、测试诊断及失败日志末尾会显示在 Actions 注释中。默认应用为 ad-hoc 签名，未做 Apple 公证。0.2.1 产物未下载做独立二进制复核，也未在用户 Mac 上安装运行。用户提供的 0.2.0 截图已显示应用能够启动，并成功连接平台取得 FTP 存储配置；截图不包含实际提交或刷卡输出结果。

界面提供“添加到打印菜单”按钮，参数随提交保存；按钮启动终端安装的实际行为和 SwiftUI 交互仍需用户 Mac 验证。

REA 静态分析核对了原 Mac 主程序、密码库和打印后端。后端方向为纵向 1/横向 2，逐份打印为 0/1，文件大小按实际字节数提交。证据 ID 见 [协议记录](protocol.md)。原 Intel 软件未在此开发环境执行。

打印机名称按用户指定统一为 `ZGCAxZGCIprinter`，覆盖队列名称、显示名称、IPP 属性和界面提示。0.2.1 进一步统一窗口标题、应用名称、主程序名称及安装包名称；应用路径为 `/Applications/ZGCAxZGCIprinter.app`。

## 待验证

用户提供 macOS 27.0，并确认 Windows 提交后刷卡取件正常。云端构建已通过，但当前开发主机无法访问 `10.1.8.5`，也未在用户 Mac 上运行，因此以下事项尚无实际验证结果：

- macOS 27.0 上的 PKG 安装、应用启动和 SwiftUI、PDFKit、Network 的实际运行行为。
- 用户登录钥匙串中的应用授权，以及勾选记住并提交成功后退出重开能否恢复、清除后是否不再恢复；临时钥匙串读写测试已在 CI 通过。
- macOS 27.0 上新版免驱 IPP 队列及用户 LaunchAgent 的运行；用户此前已确认旧 PPD 队列可添加。
- macOS 27.0 上 Word/WPS 等应用的打印参数、页面范围和每页多版；macOS 15 的真实 CUPS 路径已通过，尚不能代替目标系统和具体应用的验证。
- 真实平台的登录、存储选择、FTP/HTTP/HTTPS WebDAV、FileEncType 1 解码、提交和现场刷卡释放。本地 FTP/HTTP 测试不证明企业服务器的配置兼容性。
- 直接上传 Office、图片和其他原文件后的平台格式识别、转换、计页及打印结果。已验证客户端保留原文件，不代表平台支持所有格式。

按 [安装与验收说明](install.md) 在目标 Mac 完成这些步骤后，才能认定端到端替代成功。
