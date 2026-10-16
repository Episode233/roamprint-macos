# 验证记录

验证日期：2026-10-16。目标是 Apple Silicon 上保持“系统打印菜单 → 本地待提交 → 企业平台 → 刷卡释放”，不使用 Rosetta。

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

GitHub 的 **macOS 15 ARM64** runner 已完成实际 Apple SDK 编译和链接；[构建 38847016854](https://github.com/Episode233/roamprint-macos/actions/runs/38847016854) 的结论为 **success**，对应源码提交 `d9ebe718edb700bfe156c3419856ec5b50bd2d86`。成功步骤包括：

- 完整 `swift test --arch arm64`，包括仅 macOS 执行的真实钥匙串新增、读取、更新、删除测试。工作流使用临时钥匙串和随机测试 service，无需用户打印凭据。
- 应用及本地收集服务的 release 编译，以及两个可执行文件的 `lipo -verify_arch arm64` 检查。
- 应用 ad-hoc 签名、`codesign --verify --deep --strict` 校验、PKG 打包和应用 ZIP 打包。
- 上传 [RoamPrint-arm64](https://github.com/Episode233/roamprint-macos/actions/runs/38847016854/artifacts/12023915945)，包含 `RoamPrint-0.2.0-arm64.pkg`、应用 ZIP 和 `SHA256SUMS`。产物保留 30 天。

修复了收集服务对 actor 隔离属性的访问，以及构建和安装脚本的 `lipo` 参数顺序。中文 ZIP 文件名测试在 macOS 使用系统 `ditto` 解压，在 Linux 使用系统 `unzip`；两者均检查原文件名和内容字节。

构建、安装、移除及应用启动安装的四个脚本通过 `bash -n`，工作流通过 actionlint 1.7.7 检查。工作流兼容展开源码和浏览器上传的 `RoamPrint-source.zip`；编译、测试诊断及失败日志末尾会显示在 Actions 注释中。默认应用为 ad-hoc 签名，未做 Apple 公证。此次未下载产物做独立二进制复核，也未在用户 Mac 上安装运行。

界面提供“添加到打印菜单”按钮，参数随提交保存；按钮启动终端安装的实际行为和 SwiftUI 交互仍需用户 Mac 验证。

REA 静态分析核对了原 Mac 主程序、密码库和打印后端。后端方向为纵向 1/横向 2，逐份打印为 0/1，文件大小按实际字节数提交。证据 ID 见 [协议记录](protocol.md)。原 Intel 软件未在此开发环境执行。

打印机名称按用户指定统一为 `ZGCAxZGCIprinter`，覆盖队列名称、显示名称、IPP 属性和界面提示。本次命名修改已检查安装/移除脚本、界面语法及分发包内容。

## 待验证

用户提供 macOS 27.0，并确认 Windows 提交后刷卡取件正常。云端构建已通过，但当前开发主机无法访问 `10.1.8.5`，也未在用户 Mac 上运行，因此以下事项尚无实际验证结果：

- macOS 27.0 上的 PKG 安装、应用启动和 SwiftUI、PDFKit、Network 的实际运行行为。
- 用户登录钥匙串中的应用授权，以及勾选记住并提交成功后退出重开能否恢复、清除后是否不再恢复；临时钥匙串读写测试已在 CI 通过。
- macOS 27.0 对项目 PPD、CUPS 队列及用户 LaunchAgent 的支持。
- macOS 打印菜单传递的实际 PDF、份数、页面范围和每页多版；后两项如未预先排版会被收集器拒绝。
- 真实平台的登录、存储选择、FTP/HTTP/HTTPS WebDAV、FileEncType 1 解码、提交和现场刷卡释放。本地 FTP/HTTP 测试不证明企业服务器的配置兼容性。
- 直接上传 Office、图片和其他原文件后的平台格式识别、转换、计页及打印结果。已验证客户端保留原文件，不代表平台支持所有格式。

按 [安装与验收说明](install.md) 在目标 Mac 完成这些步骤后，才能认定端到端替代成功。
