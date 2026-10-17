# ZGCAxZGCI printer Apple Silicon 构建包

用于 M 系列 Mac，原生 ARM64，无需 Rosetta。本地不用安装 Xcode、Swift、Homebrew 或 Node。

## 包里有哪些文件

解压外层 `ZGCAxZGCI printer-1.0.0-build-kit.zip`，打开 `ZGCAxZGCI printer-macos-arm64` 文件夹，里面只有四个普通可见文件：

| 文件 | 用途 |
| --- | --- |
| RoamPrint-source.zip | 原样上传到 GitHub，由云端解压编译 |
| macos-build.yml | 工作流内容，在 GitHub 网页复制粘贴 |
| 使用说明.md | 本说明，无需上传 |
| SHA256SUMS | 文件校验值，无需上传 |

外层构建包和内层源码 ZIP 都不含隐藏文件。

## 在 GitHub 生成安装包

现有 [roamprint-macos 仓库](https://github.com/Episode233/roamprint-macos) 已成功构建，可在最新成功的运行中下载 [ZGCAxZGCI printer-arm64](https://github.com/Episode233/roamprint-macos/actions/runs/38998616202/artifacts/12087942431)，或进入 Actions 重新运行。下载需登录 GitHub，产物保留 30 天。现有仓库直接维护展开的源码，无需上传本构建包。

以下步骤用于将构建包上传到另一个仓库：

1. 打开 https://github.com/new，创建仓库，勾选 **Add a README file**。
2. 在仓库的 **Code → Add file → Upload files** 上传 **RoamPrint-source.zip**，点击 **Commit changes**。这个 ZIP 要直接出现在仓库根目录，**不要解压它，也不要上传外层 build-kit ZIP**。
3. 用文本编辑器打开 **macos-build.yml**，复制全部内容。回到 GitHub，选择 **Add file → Create new file**，文件名完整填写：

   ```text
   .github/workflows/macos.yml
   ```

   将工作流内容粘贴到正文，点击 **Commit changes**。GitHub 只在这个固定目录识别工作流；这里是在网页创建文件，不需要上传任何本地隐藏文件。

4. 进入 **Actions → Build macOS ARM64**。提交工作流后会自动开始；未自动开始时点击 **Run workflow → Run workflow**。
5. 等运行变绿，打开该次运行，在底部 **Artifacts** 下载 **ZGCAxZGCI printer-arm64**。解压得到 **ZGCAxZGCI printer-1.0.0-arm64.pkg**，双击安装。

若运行变红，查看 Actions 注释中的 Swift 诊断和失败日志末尾，或下载 **ZGCAxZGCI printer-build-log** 查看完整日志。构建时不需要填写或上传打印账号密码。

以后更新源码，只需用同名 `RoamPrint-source.zip` 覆盖仓库根目录里的旧文件并提交，就会再次构建。如新版也修改了工作流，再用新版 `macos-build.yml` 内容更新网页上的工作流文件。

## 安装后怎么用

1. 连接企业内网，打开 ZGCAxZGCI printer，点击“检测连接”。默认地址已设置为 `http://10.1.8.5/xzentprint/services`。
2. 点击“添加到打印菜单”，在弹出的终端窗口按提示输入 Mac 管理员密码。随后可在打印菜单中选择“ZGCAxZGCI printer”。从旧驱动版本升级时也需再点击一次，将已有队列原位更新为免驱 IPP；成功时显示“免驱 IPP”。
3. 在 Word、Excel、PPT 等应用中使用系统打印菜单，或者在 ZGCAxZGCI printer 中点击“导入文件”、将 Finder 文件拖到窗口。直接导入不限扩展名，保留原文件提交；具体格式是否能处理取决于平台。单个文件最大 128 MB。
4. 检查打印参数，输入打印账号密码，点击“提交并等待刷卡取件”。默认勾选“记住登录信息”，成功提交后保存到 macOS 钥匙串，下次自动填写。
5. 显示“已提交，请刷卡取件”后，去打印机刷卡取件。

列表行右侧垃圾桶、右键菜单及 Delete 键均可“删除上传记录”，保留原文件和平台作业。点击空白取消选中后，列表刷新不会自动重新选中。添加打印菜单无需安装开发工具。

检测连接只获取令牌和存储配置，不创建任务；账号及实际上传在提交时验证。发生错误时可点击“复制信息”；状态为“结果待确认”的任务，应先到平台核对，避免重复提交。

## 当前验证状态

Linux 42 项核心测试已通过。2026-10-17 的 [GitHub macOS 15 ARM64 构建](https://github.com/Episode233/roamprint-macos/actions/runs/38998616202) 也已通过完整测试（含真实钥匙串测试）、发布编译、架构检查、应用签名校验、PKG 打包及产物上传。真实 CUPS 测试还验证了免驱队列、打印参数、选页、每页多版和旧队列迁移。用户 macOS 27.0 上的新版免驱接入和内网刷卡取件仍需实测。此构建包提供源码和配置，实际 `.pkg` 可从上述成功构建下载。

默认应用使用 ad-hoc 签名，安装包未做 Apple 公证。若 macOS 拦截已确认来源的下载文件，可在“系统设置 → 隐私与安全性”中选择“仍要打开”。无需全局关闭系统安全设置。
