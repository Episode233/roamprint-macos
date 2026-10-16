# V5 兼容协议与证据

此实现针对用户提供的 `10.1.8.5/xzentprint` 平台。Windows 包配置选用 V5。静态协议分析来自原 Mac 主程序、公共库及打印后端，未运行原程序、未向真实平台提交打印作业。测试使用模拟企业平台、实际 URLSession 对接的本地 API，以及实际系统 curl 对接的本地 FTP/WebDAV 服务器，不代表真实平台已经验收。

## 工件与证据

主程序 SHA256：`a261b39f448ef39f20ab0ce4c24d322a2c42d2c5160f47d6d06c3fde6d2ee5cf`。

REA 完整证据包保存在工作区 `analysis/protocol/main-evidence.json`、`library-evidence.json`、`verification-evidence.json` 和 `backend-evidence.json`。较大的函数通过 retained evidence 分页读取；相应请求及原始返回在 `analysis/protocol/rea-session/` 和 `rea-backend-session/`。`macho_inspect.py` 汇编、常量读取为补充离线证据，不伪称 REA 运行结果。便携源码包不包含原版二进制和大型证据包。

| 行为 | REA Evidence ID | 结论类型 |
| --- | --- | --- |
| `/getToken` 请求及原客户端 ID/secret | `ev_2d20b7729791ac4d386c7e646da19c3d2fe0c93ffe0f12f8b5f9863b0b10162f` | 静态观察 |
| token 在响应 `data` 字符串 | `ev_03c3893382e6892a466c0f192f9c6936d82cc4bacc6ccc1d5607a92fcdeead41` | 静态观察 |
| 同时发送 `token` 与 `Authorization: Bearer` | `ev_ae6e7d1e0010869ddb696cf03af76b7b7f1c4537c06916b161411eb8023b07b2` | 静态观察 |
| JSON POST，Content-Type charset UTF-8 | `ev_2225e3f05b0d09ab570fde531ab2460c7674a5d52ca81e1ee645e2fff95bebe9` | 静态观察 |
| 签名为 MD5(payload + `&` + key) | `ev_c7aaf7866179c33a14c43ac4e43dc01467275f265dd5c7e7f63b6c3e0cac3cfc` | 静态观察 |
| MD5 输出大写十六进制 | `ev_e252187a9496d68672fe4ced67ff1d3717457431ef81cefc7904f3480052999c` | 静态观察 |
| 默认 WebserviceKey 读取和解码 | `ev_bd18ccac98f284389bee1efde204852640038405b25dd2a3eb16525afe5f6571`、`ev_2f26f72d5e78ec4d8703f17ea59c992d0758b0240df217285ad111992a9b5ef0` | 静态 + 常量计算 |
| `/filestorage` type 7 与 List 字段 | `ev_4c725b09c7132ab1328bd2c43e91b6026c4f53c936285f66af1a068bb97ccb73`、`ev_8a0b8391f8a40750474f4827d9bec8201fa7563752917273ea3c82235bc427e0` | 静态观察 |
| `/print` type 4 创建字段 | `ev_05d302770e4b6f014d72d757d00badd696d2876929975bd1aa08de2fb6236a4f` | 静态观察 |
| directprintid 默认 -1，ischeckpwd 默认 1 | `ev_d5d6326029d6c82c1369774ee636ced76d6bec5d6771a2d2a9f5a9110bbc27a4` | 静态观察 |
| UUID 文件路径、StorageType 2/6/7、FileEncType 0/1、finalize 字段 | `ev_419bcccc14965b5fda4b8037a31328bc029ba4124e5749058a4a789f54e8454f` | 静态观察 |
| FileEncType 缺省 0 | `ev_71ac6b50fedce5837ba26a405605335a7f1d55c677a50682fe19f9cb9c3cca70` | 静态观察 |
| 密码编码及随机混淆 | `ev_46be9d56c39b44d68d7221bd38c02b3b926e6a746140d9c17190baf51b64559a`、`ev_b43e56fb248772815604664e0c18fd5fd5fd5fbfba7d6c6f32bd5343c7b86234` | 静态观察 |
| 存储密码 decryptPwd 使用相同 key、128 bits、DeCryptPWD(-1) | `ev_78759b8b421041fb74f1baa93b46529550ce7843314b2b1620f235a454f48aa7` | 静态观察 |
| Twofish key 前 16 bytes 按 little-endian uint32 读取 | `ev_e40a13c08545454e3e4ff2ee24e850dbc1cea1411a06e02bb0db04398b4b0db6` | 静态观察 |
| FileEncType 1 是 ZIP，首四字节改为 0 | `ev_167d9f9238e6cbcc8d0e198a03067edd259ccda2870e9100795620c2595861b6` | 静态 + 汇编参数核对 |
| `/printfile` 返回及成功状态 | `ev_84e0955be39dd62d4d882e29c5d3ae8664854150c20986e3f734706215d08f06` | 静态观察 |
| Mac 方向预设 1/2、PMCopyCollate 的 false→0/其余→1 | `ev_afbaf0afaf46293b53187deddf6e50dab1a3797d352917a3eb9dececada8570c` | 静态 + 字符串常量核对 |
| 后端 PJI 写入 orientation、collate、file_size | `ev_31b8455e4dd00b921d49234d1d484f30f297501f8d103e7d7f4039f3488d43f0` | 静态观察 |
| file_size 为写入文件的实际字节数，无 KB 换算 | `ev_5c1df3fc6cb5b0730ab2647d3a2ecefd46968b7169e0c408fb747749a83fa057` | 静态观察 |

## 线协议

API 基址为 `/xzentprint/services`，全部 POST JSON。响应兼容 `Code` 字符串或 `code` 整数，0 表示成功；原错误文本键为 `Mess`/`msg`（具体大小写以原返回为准）。新实现只显示错误代码，避免服务器回显密码被写入日志。

1. `/getToken`：`type=0`，`client_id=PrintSys`，原包内的 client secret，签名 payload `type=0`。
2. `/filestorage`：`type=7`，签名 payload `type=7`。返回顶层 `List`：ID、StorageType、IP、Port、UserName、Password、FileEncType 等。
3. `/print`：`type=4`，账号、原格式加密密码、打印参数和客户端网络身份。签名 payload `type=4&code=<账号>&pwd=<密文>`。响应顶层 `SubmitJobId`。
4. 上传到选中的存储：2 为 FTP；6 为 HTTP WebDAV；7 为 HTTPS WebDAV。原客户端从本地作业路径读取后缀，拼接 `/PrintDir/yyyyMMdd/{uuid}.<后缀>`。新实现的系统打印作业通常为 `.pdf`；直接导入保留原文件名、后缀和内容，无后缀时不强行补 `.pdf`。FileEncType 1 使用 `.dat`，其中 ZIP 条目保留文档名。保留后缀不能证明服务器能够转换任意原文档格式。存储密码通过原 `CPWDCry::decryptPwd` 格式解码。WebDAV 先创建目录后 PUT；FTP 创建缺失目录。
5. `/printfile`：`type=6`，submitjobid、filestorageid、jobpath、state=1、upload_tip、fileenctype、code、filename。签名 payload `type=6&submitjobid=<id>`。成功后 UI 提示刷卡取件。

V5 默认 key 为 `xz!@#$%^&&*()?`。原程序先解码 `SRNyJUAWdipHVBkZQGw=`，再与 `1iSec2Star3` 循环 XOR 得到它。这个 key 来自原客户端，不是用户账号密码；企业若修改了服务器 key，此版本会被拒绝，需要补充对应配置。密码使用 Twofish128 ECB；输入 key 原始字节 `b5000000c7000000c2000000bc000000`。新实现通过公开 Twofish 向量及独立 libgcrypt 样本核对，但没有执行原程序端到端密码验证。

份数、单双面、纸型、彩色值来自原包 `Library/Printers/xzvp/printer_param.json`。纸张代码 A4=9、A3=8、A5=11、Letter=1、Legal=5；颜色黑白=1/彩色=2；单双面=1/2/3；自动纸盒=1000。原 Mac 后端将 `com.apple.print.preset.Orientation..n.` 的 1 写成纵向 1，其余写成横向 2；将 `com.apple.print.PrintSettings.PMCopyCollate..b.` 的 false 写成 0，其余写成 1。新 IPP 接收器兼容这两个名称，并拒绝格式异常的值。标准 IPP 方向、sheet-collate 参数仍优先。file_size 直接累计保存的字节数，创建接口原样改名为 filesize；新实现也按字节提交。原 Mac 创建流程的 A3/A4/其他页数、黑白页数、彩色页数及 jobtype 均固定 0。新实现提交已识别的 A3/A4/其他页数，其余仍为 0；无法识别的原文件页数为 0，交由平台处理，实际行为需内网验证。

## 新实现选择与未验证边界

- **固定 directprintid=-1**，无实体打印机直打选项。本地 IPP 只接收 PDF，不自动访问企业平台。
- 本地文件 128 MB 上限，密码 UTF-8 最多 255 bytes，拒绝 NUL。账号密码不写作业记录；勾选“记住登录信息”时，成功提交后存入 macOS 钥匙串，按平台分别读取。普通偏好设置只存记住开关。
- FileEncType 1 使用标准 ZIP stored method 后改写首四字节，已用系统 ZIP 阅读器验证内容恢复；原程序使用 ZipCompress，真实平台是否要求特定压缩方法仍需现场验证。
- 当前选取服务器返回列表中第一台支持的存储。未复刻 ClientIpRange 的优先级和多存储重试；多存储部署需进一步验证。
- 原程序会在部分 token 错误下刷新重试，并记录上传失败状态。此版不自动重试创建/确认请求，也不自动重新创建已分配作业号的任务；任何无法确认的结果都保留文档并要求查询平台。
- 当前仅 V5 平台账号；域登录、项目计费、二维码、V6、消息通知及强制更新未实现，用户提供的 Windows 配置未要求这些功能。
- 本地 IPP 不宣称 IPP Everywhere 认证，使用项目 PPD。显式的 page-ranges 或 number-up>1 尚拒绝，避免把未排版的整份 PDF 当作用户选择的页面提交。macOS 是否提前应用这些设置必须实际验证。
- macOS 27 的 CUPS/PPD 支持、Network/PDFKit/SwiftUI 的实际 ARM64 构建、内网授权、提交和刷卡取件仍未验证。此开发主机不能访问 `10.1.8.5`。
