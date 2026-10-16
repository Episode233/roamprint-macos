# RoamPrint Apple Silicon 构建包

用于 M 系列 Mac，原生 ARM64，无需 Rosetta。本地不用安装 Xcode、Swift、Homebrew 或 Node。

## 包里有哪些文件

解压外层 `RoamPrint-0.2.0-build-kit.zip`，打开 `RoamPrint-macos-arm64` 文件夹，里面只有四个普通可见文件：

| 文件 | 用途 |
| --- | --- |
| RoamPrint-source.zip | 原样上传到 GitHub，由云端解压编译 |
| macos-build.yml | 工作流内容，在 GitHub 网页复制粘贴 |
| 使用说明.md | 本说明，无需上传 |
| SHA256SUMS | 文件校验值，无需上传 |

外层构建包和内层源码 ZIP 都不含隐藏文件。

## 在 GitHub 生成安装包

1. 打开 https://github.com/new，重新创建仓库，可继续命名为 `roamprint-macos`，勾选 **Add a README file**。
2. 在仓库的 **Code → Add file → Upload files** 上传 **RoamPrint-source.zip**，点击 **Commit changes**。这个 ZIP 要直接出现在仓库根目录，**不要解压它，也不要上传外层 build-kit ZIP**。
3. 用文本编辑器打开 **macos-build.yml**，复制全部内容。回到 GitHub，选择 **Add file → Create new file**，文件名完整填写：

   ```text
   .github/workflows/macos.yml
   ```

   将工作流内容粘贴到正文，点击 **Commit changes**。GitHub 只在这个固定目录识别工作流；这里是在网页创建文件，不需要上传任何本地隐藏文件。

4. 进入 **Actions → Build macOS ARM64**。提交工作流后会自动开始；未自动开始时点击 **Run workflow → Run workflow**。
5. 等运行变绿，打开该次运行，在底部 **Artifacts** 下载 **RoamPrint-arm64**。解压得到 **RoamPrint-0.2.0-arm64.pkg**，双击安装。

若运行变红，打开失败步骤查看错误，或下载 **RoamPrint-build-log**。构建时不需要填写或上传打印账号密码。

以后更新源码，只需用同名 `RoamPrint-source.zip` 覆盖仓库根目录里的旧文件并提交，就会再次构建。如新版也修改了工作流，再用新版 `macos-build.yml` 内容更新网页上的工作流文件。

## 安装后怎么用

1. 连接企业内网，打开 RoamPrint，点击“检测连接”。默认地址已设置为 `http://10.1.8.5/xzentprint/services`。
2. 点击“添加到打印菜单”，在弹出的终端窗口按提示输入 Mac 管理员密码。这一步只需设置一次，随后可在打印菜单中选择“ZGCAxZGCIprinter”，名称按用户指定设置。
3. 在 Word、Excel、PPT 等应用中使用系统打印菜单，或者在 RoamPrint 中点击“导入文件”。直接导入不限扩展名，保留原文件提交；具体格式是否能处理取决于平台。单个文件最大 128 MB。
4. 检查打印参数，输入打印账号密码，点击“提交并等待刷卡取件”。默认勾选“记住登录信息”，成功提交后保存到 macOS 钥匙串，下次自动填写。
5. 显示“已提交，请刷卡取件”后，去打印机刷卡取件。

检测连接只获取令牌和存储配置，不创建任务；账号及实际上传在提交时验证。发生错误时可点击“复制信息”；状态为“结果待确认”的任务，应先到平台核对，避免重复提交。

## 当前验证状态

41 项核心测试已通过；GitHub 工作流已通过静态检查。当前开发环境是 Linux，尚未执行真实 Mac 编译、安装和内网刷卡测试。此包是云端构建所需的源码和配置，实际 `.pkg` 由上述 GitHub 构建生成。

默认应用使用 ad-hoc 签名，安装包未做 Apple 公证。若 macOS 拦截已确认来源的下载文件，可在“系统设置 → 隐私与安全性”中选择“仍要打开”。无需全局关闭系统安全设置。
