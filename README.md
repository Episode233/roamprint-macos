# ZGCAxZGCIprinter

为 Apple Silicon（M 系列芯片）重写的原生企业漫游打印客户端，使用 SwiftUI 和可移植 C 源码，构建为 ARM64，无需 Rosetta。

当前发布版本为 **1.0.0**；仅在用户明确指定新版本号时修改，日常修复和重新构建不自动升版。

`macOS 打印菜单 → 客户端确认参数 → 提交企业平台 → 到打印机刷卡取件`

默认平台：`http://10.1.8.5/xzentprint/services`。

## 功能

- 添加“ZGCAxZGCIprinter”系统打印队列，在 Word、Excel、PPT 等应用中直接使用 macOS 打印菜单。
- 设置份数、颜色、单双面、纸张、方向和逐份打印；提交到平台后刷卡释放。
- 默认记住登录信息，成功提交后保存到 macOS 钥匙串，下次启动自动填写。
- 支持选择文件或从 Finder 拖拽文件到窗口导入，不限扩展名，保留原文件名及内容；平台能否处理相应格式仍需内网实测。单个文件最大 128 MB。
- 列表支持直接点击垃圾桶、右键或 Delete 键删除上传记录；点击空白取消选择后，刷新会保持未选中状态。
- 保留本地待提交列表、显示连接和提交错误、复制诊断信息；提交结果不明时保留作业，避免重复创建。
- 使用原客户端的 V5 提交流程，支持 FTP、HTTP/HTTPS WebDAV 和原文件编码。

这里复现的是原 Mac 客户端的核心打印流程，界面和本地收集服务重新实现。域登录、二维码登录、扫描下载、消息中心和自动更新等附加模块未实现。

## GitHub 云端构建，无需本地开发环境

现有仓库已成功完成 [macOS ARM64 构建](https://github.com/Episode233/roamprint-macos/actions/runs/38863514286)。可在最新成功的运行中下载 [ZGCAxZGCIprinter-arm64 安装包](https://github.com/Episode233/roamprint-macos/actions/runs/38863514286/artifacts/12030575480)，解压后安装 `ZGCAxZGCIprinter-1.0.0-arm64.pkg`。下载需登录 GitHub，产物保留 30 天；过期后可在 Actions 重新运行构建。现有仓库直接维护展开的源码，无需再上传源码 ZIP。

如需在另一个仓库使用可见文件构建包：

交付文件 `ZGCAxZGCIprinter-1.0.0-build-kit.zip` 及其中的源码 ZIP 均不含隐藏文件。

1. 解压构建包，将其中的 **RoamPrint-source.zip 原样上传**到 GitHub 仓库根目录，不要解压这个内层 ZIP。
2. 在 GitHub 网页选择 **Add file → Create new file**，文件名填 `.github/workflows/macos.yml`，粘贴可见文件 **macos-build.yml** 的全部内容并提交。此路径由 GitHub 固定要求，在网页创建即可，无需上传本地隐藏文件。
3. 打开 **Actions → Build macOS ARM64**，构建成功后下载 **ZGCAxZGCIprinter-arm64**，解压得到 `ZGCAxZGCIprinter-1.0.0-arm64.pkg`。

完整步骤见 [构建包使用说明](docs/macos-build-kit.md)。安装后打开应用，点击“添加到打印菜单”完成队列设置。本地无需安装 Xcode、Swift、Homebrew 或 Node。

## 验证状态

已完成源码和云端构建配置，**41 项核心测试通过，0 失败**，覆盖真实 URLSession 请求、系统 curl 的 FTP/WebDAV 上传、原文件保留、刷卡任务参数和登录记忆逻辑。已验证原生请求可访问没有 CORS 响应头的测试接口。

2026-10-16，GitHub 的 macOS 15 ARM64 runner 已通过完整测试（含真实钥匙串测试）、发布编译、ARM64 架构检查、应用签名校验和 PKG 打包，安装包已上传。用户 macOS 27.0 上的安装、打印菜单和内网刷卡流程仍需实测。默认应用采用 ad-hoc 签名，未做 Apple 公证。

- [安装、使用与验收](docs/install.md)
- [V5 协议与 REA 证据](docs/protocol.md)
- [验证记录](docs/validation.md)
- 源码：`native/`

维护者可在有 Swift 6 和系统 curl 的环境中运行 `cd native && swift test`；Linux 也可使用：

```bash
docker build -f tools/Dockerfile.swift-tests -t roamprint-swift-tests tools
docker run --rm -v "$PWD/native:/work" roamprint-swift-tests
```

第三方密码源码和许可保存在 `native/Sources/LegacyCrypto/`，安装包附带 `ThirdPartyNotices.txt`。未打包原 Intel 可执行文件或库。
