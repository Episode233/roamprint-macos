# Apple Silicon 安装与验证

项目替换 Intel 客户端的本地提交部分：macOS 打印菜单 → 本地待提交列表 → 企业平台 → 打印机刷卡取件。它不会向实体打印机直接发送打印数据。目标平台为 `http://10.1.8.5/xzentprint`，使用 V5 协议。

GitHub 的 macOS 15 ARM64 runner 已通过测试、发布编译、架构检查、应用签名校验及 PKG 打包，见 [成功构建记录](https://github.com/Episode233/roamprint-macos/actions/runs/38873731293)。可在最新成功的运行中下载 [ZGCAxZGCI printer-arm64](https://github.com/Episode233/roamprint-macos/actions/runs/38873731293/artifacts/12034147884)，解压后安装 `ZGCAxZGCI printer-1.0.0-arm64.pkg`。用户 macOS 27.0 上的安装、打印菜单及真实平台刷卡取件仍需现场验证。

## 用 GitHub 构建（本地无需开发环境）

现有 [roamprint-macos 仓库](https://github.com/Episode233/roamprint-macos) 已包含展开的源码和工作流，可直接进入 Actions 运行构建，无需重新上传。以下步骤用于在另一个仓库使用可见文件构建包：

1. 在 [GitHub 新建仓库](https://github.com/new)，勾选创建 README。
2. 解压 `ZGCAxZGCI printer-1.0.0-build-kit.zip`。在仓库选择 **Add file → Upload files**，将其中的 **RoamPrint-source.zip 原样上传到仓库根目录**并提交；不要解压内层源码 ZIP，也不要上传外层构建包。
3. 打开可见文件 **macos-build.yml** 并复制全部内容。在 GitHub 选择 **Add file → Create new file**，文件名填 `.github/workflows/macos.yml`，粘贴并提交。这是 GitHub 固定要求的工作流路径；通过网页创建，无需上传隐藏文件。
4. 提交工作流后，Actions 中的 **Build macOS ARM64** 会自动运行；也可点击 **Run workflow**。
5. 构建成功后打开对应运行，在 **Artifacts** 下载 **ZGCAxZGCI printer-arm64**，解压得到 `ZGCAxZGCI printer-1.0.0-arm64.pkg`，双击安装即可。也提供应用 ZIP 和 SHA256 校验文件；下载结果保留 30 天，过期可重新运行工作流。

构建包和内层源码 ZIP 均不包含隐藏文件。独立操作指南见 [构建包使用说明](macos-build-kit.md)。

工作流使用 GitHub 的 `macos-15` Apple Silicon runner，自带 Xcode 和 Swift，完成 ARM64 测试、构建、签名检查和 PKG 打包。钥匙串测试在 runner 上创建临时钥匙串；不需要上传你的打印账号密码。GitHub 无法替代企业内网的提交和刷卡验收。私有仓库的构建计入账户的 Actions 用量。

默认产物为本地 ad-hoc 签名，未做 Apple 公证。下载后如果 macOS 阻止打开，在“系统设置 → 隐私与安全性”中对已确认来源的安装包或应用选择“仍要打开”；不需要全局关闭系统安全设置。

如果构建失败，Actions 注释会显示 Swift 编译和测试诊断，以及构建日志的最后 30 行；完整日志可在 **ZGCAxZGCI printer-build-log** 下载。

## 在 Mac 本地构建（可选）

在安装了 Xcode Command Line Tools、Swift 6 或更新版本的 Mac 上，从仓库根目录运行：

```bash
bash scripts/build-macos.sh
```

输出 `dist/ZGCAxZGCI printer.app` 和 `dist/ZGCAxZGCI printer-1.0.0-arm64.pkg`。两个可执行文件都要求包含 ARM64 架构，不调用 Intel 客户端，不需要 Rosetta。默认使用 ad-hoc 本地签名；如有 Developer ID，可通过环境变量 `ROAMPRINT_SIGN_IDENTITY` 和 `ROAMPRINT_INSTALLER_IDENTITY` 设置 Application、Installer 身份，再完成 Apple 公证。脚本不会自动公证或上传文件。

## 安装并接入打印菜单

从旧名称版本升级时，先退出旧版应用。安装后打开 `/Applications/ZGCAxZGCI printer.app`，再点击一次“添加到打印菜单”，将本地收集服务更新为新版路径。确认新版正常后可将旧的 `/Applications/ZGCAxZGCIprinter.app` 或 `/Applications/RoamPrint.app` 移到废纸篓。已有作业目录、钥匙串 service 和应用标识保持不变。

安装脚本使用 macOS 自带工具，无需 Xcode 或 Command Line Tools。旧版触发的开发工具安装弹窗可取消；安装修复版后重新点击“添加到打印菜单”。

PKG 安装后打开 ZGCAxZGCI printer，点击“添加到打印菜单”，在打开的终端窗口输入管理员密码即可。此操作由当前登录用户启用本地打印服务。也可以从终端运行：

```bash
bash "/Applications/ZGCAxZGCI printer.app/Contents/Resources/install-local-printer.sh"
open "/Applications/ZGCAxZGCI printer.app"
```

脚本将用户 LaunchAgent 写入 `~/Library/LaunchAgents/org.local.roamprint.capture.plist`，并通过管理员授权的 `lpadmin -m everywhere` 添加“ZGCAxZGCI printer”。CUPS 不允许内部队列标识包含空格，因此内部标识继续使用 `ZGCAxZGCIprinter`。服务只监听 `127.0.0.1:19963`；队列地址为 `ipp://127.0.0.1:19963/ipp/print`。不会写入 `/usr/libexec/cups/backend` 等受保护目录。

当前使用免驱 IPP：macOS 从本地服务读取纸张、颜色和双面等能力，应用不再附带自定义 PPD，也不再用 `-P` 安装驱动。旧版升级后须再点一次“添加到打印菜单”，原位更新已有队列，保留队列标识和待处理任务。成功时显示“免驱 IPP”。这解决了旧安装方式的驱动弃用提示；未来 macOS 的兼容性仍需随系统更新验证。当前 CUPS 可能在内部生成配置文件，这是系统的实现细节。

本版本按单个登录用户设计。同一台 Mac 的快速用户切换、多用户同时登录尚未支持；这些场景不要启用此队列，以免作业进入另一用户的本地服务。企业平台访问需要连接相应内网，macOS 出现本地网络访问提示时，需要允许应用连接打印平台。

## 使用

没有文件时，导入区占满窗口内容区；导入文件后显示左右列表与详情。删除最后一条记录后自动恢复完整导入区。

1. 连接企业内网，在 ZGCAxZGCI printer 点击“检测连接”。成功表示已取得平台令牌和存储配置，不会创建打印任务，也不代表账号及文件上传已经验证。原生网络请求不受浏览器 CORS 限制；网络不通时仍会报错。
2. 从文档的 macOS 打印菜单选择“ZGCAxZGCI printer”，设置份数和双面等选项。Word、Excel、PPT 等由各自应用通过系统打印，不需要手动转换文件。收到后客户端会打开待提交界面。页面范围和每页多版尚需 Mac 实测；若收集服务拒绝这些选项，可先在来源应用生成已选好页面、完成排版的文档。
3. 也可以点击“导入文件”选择文档，或从 Finder 拖拽一个或多个文件到窗口；不限扩展名，保留原文件名和内容提交；单个文件最大 128 MB。Office、图片等原文件能否被平台处理，需要实际提交验证，客户端不自行转换。无法预先识别页数时显示“页数由平台识别”。
4. 在 ZGCAxZGCI printer 中检查待提交文档和打印参数，输入打印账号、密码，点击“提交并等待刷卡取件”。修改的参数会随提交一起保存，无需单独保存。默认勾选“记住登录信息”：成功提交后将账号密码存入当前用户的 macOS 钥匙串，下次启动自动填写。
5. 作业状态变为“已提交，请刷卡取件”后，到打印机刷卡释放。系统队列完成只表示文档已经进入本地待提交列表。

默认地址是 `http://10.1.8.5/xzentprint/services`。应用设置允许输入登录页地址 `http://10.1.8.5/xzentprint/Login.aspx`，会转换为服务地址。当前不提供 V6 平台选项。

取消“记住登录信息”会删除当前平台已保存的凭据，但本次运行仍可使用输入框中的账号密码；“清除登录信息”同时清空输入框。不同平台分别保存，切换平台不会带入旧平台的凭据。钥匙串读取或保存失败会显示提示，不会将密码改存到普通配置文件。记住账号密码不会自动提交文档，仍需点击提交并刷卡取件。

文档和作业日志保存在当前用户的 `~/Library/Application Support/RoamPrint/jobs`，兼容旧版 PDF 队列记录。提交成功不会立即删除文档。“删除上传记录”移除本地记录和缓存副本，保留导入前的原文件，不撤销平台作业。可以直接点击列表行右侧垃圾桶、使用右键菜单，或选中记录后按 Delete 键；右侧详情保留同名按钮。正在提交或结果待确认的记录暂不可删除。点击列表空白处取消选中后，刷新不会自动选回第一条；删除选中记录后也保持未选中状态。提交中断或平台响应无法确认时，标记为“结果待确认”；先登录平台核对，应用不会自动重试或重复创建作业。

连接和提交错误会显示在窗口中，可点击“复制信息”。API 网络错误包含请求地址及系统错误代码，不记录密码、令牌或完整请求正文。

## macOS 27.0 现场验收

- 用系统自带的 `file` 命令检查应用和服务的架构为 ARM64；确认未出现 Rosetta 安装要求。
- 用 Preview 的一页 PDF 测试打印菜单，确认作业进入本地列表、平台尚未出现作业。
- 手动提交后，核对平台账号、作业名称、份数、纸张、单双面和彩色设置；实体打印机在刷卡前保持未打印，刷卡后才输出。
- 分别测试双面、多份、页面范围、A3，以及重新登录后的服务自启动。
- 用文件选择器和 Finder 拖拽分别导入单个及多个文件，检查空白取消选中、列表删除和 Delete 键；确认删除只影响本地缓存，原文件仍在。
- 直接导入实际使用的 Office 和图片文件，核对平台处理结果及刷卡输出；原文件上传成功不等于格式解析成功。
- 勾选“记住登录信息”提交成功后退出并重新打开应用，检查自动填写；取消勾选或清除后重启，检查凭据不再恢复。
- 提交过程中断网络，核对待确认作业不会自动再提交。

本地服务日志位于 `~/Library/Logs/RoamPrint/`。诊断时不要共享账号密码、令牌或包含敏感文档的队列内容。

## 停用打印菜单接入

```bash
bash "/Applications/ZGCAxZGCI printer.app/Contents/Resources/remove-local-printer.sh"
```

这会卸载用户 LaunchAgent 和系统打印队列，保留本地文档。确认已经处理平台作业和本地文件后，再自行删除应用。
