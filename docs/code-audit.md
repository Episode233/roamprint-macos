# 历次修改的旧代码检查

检查日期：2026-10-17。范围为当前 macOS 客户端的全部源码模块、资源、安装与构建脚本、GitHub 工作流、测试及工作区交付文件。结合调用关系、打包清单和测试核对，不以名称包含 `Legacy`、`RoamPrint` 或 `PDF` 判断是否废弃。

## 本次确认并删除

| 残留 | 判断依据 | 处理 |
| --- | --- | --- |
| `WireEncoding` 表单编码器 | 无调用；V5 实际使用 `V5Wire.request` 生成 JSON 请求 | 删除整段实现 |
| `HTTPTransport.upload` 和 URLSession 文件上传实现 | 无生产调用；文件实际由 `NativeCurlUploader` 上传，测试替身也只会拒绝该入口 | 删除协议方法、实现及测试替身方法 |
| URLSessionTransport 的 NSObject 基类 | 重定向回调由单独的 RejectRedirects 对象处理，传输类不使用 NSObject 功能 | 去除继承与 super 初始化 |
| V6 协议选择和域登录类型 | UI 固定使用 V5 平台账号；其余类型没有实现，只进入拒绝分支 | 删除枚举、占位字段和不可达检查；配置只保留平台地址，凭据只保留账号密码 |
| IPP 捕获后的 UUID 副本 | 仅写入 `LocalJob.captured`，从未读取；实际作业已由 JobQueue 持久化 | 删除字段和不使用的返回值传递 |
| 刷新任务句柄 | 只赋值，从未查询、等待或取消；任务本身仍用于刷新列表 | 删除句柄，保留刷新任务 |
| 工作区 Web 原型 | 已切换为原生客户端，不在 Swift 包、构建清单或当前工作流中 | 删除 index.html、两份 Web 测试及 docs/web.md |
| 旧名称、旧版本源码构建包 | dist 中的重复历史生成物，不是当前交付 | 删除旧目录及 ZIP，保留当前 1.0.0 构建包；历史验证记录保留 |

## 之前要求的修改逐项核对

| 要求 | 当前实现及检查结果 |
| --- | --- |
| M 系列原生客户端，不使用 Rosetta | SwiftUI、Network、PDFKit 与源码编译的 C 模块；构建检查两个可执行文件的 ARM64 架构，不打包 Intel 客户端 |
| 系统打印菜单与刷卡取件 | `lpadmin -m everywhere` → 本地 IPP → JobQueue → 客户端确认 → V5 提交；`directprintid=-1` 保持漫游作业 |
| 移除 PPD 依赖及旧分支 | 当前资源、源码包和安装脚本无 PPD 文件或 `lpadmin -P`；旧参数兼容解析和旧 PPD 测试已在前次清理 |
| 不限 PDF、支持拖拽 | 文件选择和 Finder 拖拽都调用 `PrintModel.importFiles(at:)`；原文件名与字节保留，无另一个旧导入器 |
| 空白选择不跳回首项 | reload 只清除已经不存在的选择，不自动选首项；模型测试覆盖轮询及外部捕获新作业 |
| 快捷删除、统一文案 | 行按钮、右键、Delete 键及详情按钮共用 remove；详情按钮是当前有效入口，不是重复实现 |
| 无文件时完整导入区 | jobs.isEmpty 时直接显示共享 importPlaceholder；有记录才构造 HSplitView |
| 记住登录信息 | RememberedLogin → KeychainLoginStore；无普通文件密码存储。此次扩展真实钥匙串测试，验证去掉 kind 字段后仍可读取已保存记录 |
| 名称和固定版本 | 显示名称 `ZGCAxZGCI printer`；内部队列名 `ZGCAxZGCIprinter`；版本 `1.0.0`、内部构建号 `3` |
| 云端构建、用户无需开发工具 | Swift/lipo 只在构建中运行；运行时安装脚本调用系统工具。当前仍支持用户要求的不含隐藏文件源码构建包 |

## 保留且仍在使用

- `LegacyPassword`、MD5、Twofish、ModifiedZIP：V5 登录请求、签名、存储密码解码及 FileEncType=1 上传均有实际调用；已有协议向量、FTP/WebDAV 和提交集成测试覆盖。名称中的 Legacy 指企业平台协议，不代表废弃实现。
- 系统打印接收 PDF 与原文件导入：前者接收 macOS 完成排版后的结果，后者保留原格式，服务于不同入口。DocumentInfo 未指定 filename 的路径仍由当前 IPP 服务使用。
- `RoamPrint/jobs`、钥匙串 service、应用标识和 LaunchAgent 标识：当前程序仍读写，保持这些标识可继续读取已有登录和作业；这些标识指向同一套当前实现，并非附带第二套旧客户端。
- 错误提示、提交中断保护、移除队列脚本和当前测试入口：分别服务于故障诊断、防止重复任务、停用服务及云端验证，均有当前入口。
- 原始安装包、逆向分析资料和历史验证记录：作为输入证据保留，不属于当前应用源码，也不进入源码构建包或应用资源。

验证结果及本次可下载安装包见 [验证记录](validation.md)。真实企业平台与用户 macOS 27 的现场行为仍需现场验证；本次检查不把云端测试等同于现场刷卡成功。
