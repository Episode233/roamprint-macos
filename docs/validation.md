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

macOS 专用界面、收集服务、上传器、IPP 参数及新增测试通过 `swiftc -frontend -parse -target arm64-apple-macosx13.0`。这是语法检查，**没有使用 Apple SDK 做 API 类型检查或链接**。构建、安装、移除及应用启动安装的四个脚本通过 `bash -n`。界面已改为参数随提交保存，并提供“添加到打印菜单”按钮；按钮启动终端安装的实际行为和 SwiftUI 绑定仍需 Mac 验证。

新增 KeychainLoginStore 和登录界面也通过 ARM64 目标语法检查。另有 1 项仅 macOS 执行的真实钥匙串新增、读取、更新、删除测试，使用随机测试 service，不触碰实际登录条目；当前 Linux 上未执行，不计入上述 41 项。

GitHub Actions 的 `Build macOS ARM64` 工作流使用 `macos-15` ARM64 runner，并通过 actionlint 1.7.7 检查。支持从仓库根目录的 `RoamPrint-source.zip` 解压后构建，用户无需上传隐藏目录。工作流在临时钥匙串中运行上述真实钥匙串测试，调用同一 Mac 构建脚本，上传 PKG、应用 ZIP、SHA256 和构建日志。目前尚无 GitHub 运行记录，不能据配置文件认定 Mac 构建或测试已经成功。

REA 静态分析核对了原 Mac 主程序、密码库和打印后端。后端方向为纵向 1/横向 2，逐份打印为 0/1，文件大小按实际字节数提交。证据 ID 见 [协议记录](protocol.md)。原 Intel 软件未在此开发环境执行。

## 待验证

用户提供 macOS 27.0，并确认 Windows 提交后刷卡取件正常。当前开发主机无法访问 `10.1.8.5`，也没有 macOS 主机或 Apple SDK，因此以下事项尚无实际验证结果：

- ARM64 Mac 编译、PKG 生成和安装，SwiftUI、PDFKit、Network API 的兼容性。
- macOS 钥匙串实际读写，以及勾选记住并提交成功后退出重开能否恢复、清除后是否不再恢复。
- macOS 27.0 对项目 PPD、CUPS 队列及用户 LaunchAgent 的支持。
- macOS 打印菜单传递的实际 PDF、份数、页面范围和每页多版；后两项如未预先排版会被收集器拒绝。
- 真实平台的登录、存储选择、FTP/HTTP/HTTPS WebDAV、FileEncType 1 解码、提交和现场刷卡释放。本地 FTP/HTTP 测试不证明企业服务器的配置兼容性。
- 直接上传 Office、图片和其他原文件后的平台格式识别、转换、计页及打印结果。已验证客户端保留原文件，不代表平台支持所有格式。

按 [安装与验收说明](install.md) 在目标 Mac 完成这些步骤后，才能认定端到端替代成功。
