# CATunnel — Coding Agent Tunnel

[![构建与预览验证](https://github.com/YusenHou519/CATunnel/actions/workflows/validate.yml/badge.svg)](https://github.com/YusenHou519/CATunnel/actions/workflows/validate.yml)

[English](README.en.md)

轻量级原生 macOS 菜单栏应用，让远端工具通过 SSH 反向隧道使用 Mac 上的本地 HTTP 代理。

```text
远端工具 → 服务器回环代理端口 → SSH 隧道 → Mac 本地代理 → 外网
```

## 当前阶段

这是 0.6.0（build 4）的独立源码预览版。本地预览包使用 ad-hoc 签名，
尚未制作经过 Developer ID 签名及 Apple 公证的公开发行版。
正常首次启动为空列表，可新增、编辑、删除任意数量的服务器。
只有离线演示预置 A、B 两个示例；`.example` 主机仅作占位，填写真实主机前无法建立真实连接。
界面目前为中文。

应用管理自己创建的 SSH 连接。需要用户已有本地代理；应用不会修改 SSH、shell、
编辑器或远端工具的代理配置，也不会让已打开的远端终端自动切换代理。

## 预览版下载

在 [GitHub 预发布页面](https://github.com/YusenHou519/CATunnel/releases/tag/v0.6.0-preview.1)
下载与你的 Mac 匹配的 ZIP：Apple Silicon 选择 `arm64`，Intel 选择 `x86_64`。

预览包使用 ad-hoc 签名，尚未经过 Developer ID 签名或 Apple 公证，macOS 可能阻止直接打开。
当前适合开发者试用；验证范围与已知限制见预发布说明。

### 安装与首次打开

1. 从上面的项目 Release 页面下载对应架构的 `.zip`，无需下载源码包或构建信息 JSON。
2. 双击 ZIP 解压，将 `CATunnel.app` 拖入“应用程序”文件夹。
3. 在“应用程序”中双击 `CATunnel.app`。若被 macOS 阻止，请按下一节处理。
4. 启动后，点击屏幕顶部菜单栏中的双向箭头圆形图标，展开 CATunnel 面板。
   正常启动不会自动弹出主窗口，也不显示 Dock 图标。
5. 首次使用时，点击“使用引导”，准备本地代理和 SSH 连接，再添加自己的服务器。

### 首次打开被 macOS 阻止时

如果提示无法验证开发者，或 Apple 无法检查 App 是否包含恶意软件，且你已确认下载来源可信，
可按 [Apple 官方说明](https://support.apple.com/zh-cn/102445)为这个 App 单独允许打开：

1. 先尝试双击 `CATunnel.app`，在拦截提示中选择“完成”或“取消”。
2. 打开 **系统设置 → 隐私与安全性**，向下找到“安全性”区域中 CATunnel 被阻止的提示。
3. 点击 **仍要打开**，按系统要求认证，并在再次确认时选择“打开”。不同 macOS 版本的按钮文字可能略有差异。
4. 允许后，再从菜单栏图标打开面板。系统会为这个 App 保存例外，后续通常可直接启动。

若没有“仍要打开”，先重新尝试打开 App，再回到上述设置；受单位管理的 Mac 可能限制此操作，
需要联系管理员。此流程只允许指定 App，无需关闭整个系统的 Gatekeeper。

**如果提示“已损坏”“将损坏你的电脑”或检测到恶意软件，不要把它当成普通的未公证提示。**
停止打开，记录完整提示、macOS 版本和下载包名称，并向项目提交 Issue 排查。

以上是 Apple 提供的通用打开流程。当前预览包尚未完成全新 Mac／账户下、通过浏览器下载后的
Gatekeeper 安装实测；构建与 ZIP 校验通过不代表所有 Mac 均可按此流程成功打开。
已验证范围见[验证记录](docs/VALIDATION.md#clean-configuration-versus-a-clean-mac)。

## 环境要求

- 构建目标：macOS 13+；构建需要 Xcode 或 Command Line Tools 提供 Swift 5.9+。
  Swift 包没有外部依赖。
- 真实连接：Linux 服务器，需要 OpenSSH、`ss`、`curl`，以及 Mac 上可用的
  HTTP 或兼容 HTTP 的 mixed 代理端口。
- SSH：主机指纹已存在于 `known_hosts`，使用默认密钥文件、可用的 SSH agent，
  或在编辑器中指定私钥文件。加密密钥需要先加载到 agent，供应用非交互认证使用。
  应用严格验证主机指纹，不自动接受未知主机。

最低构建目标不代表所有系统和架构均已实测；已验证环境及待验项目见
[验证记录](docs/VALIDATION.md)。

暂不支持 SSH 别名、跳板机、交互式密码、IPv6 SSH 主机地址及应用内
首次信任主机。连接使用 `-F /dev/null`，不继承 `~/.ssh/config`。

## 构建与离线检查

克隆公开源码仓库：

```bash
git clone https://github.com/YusenHou519/CATunnel.git
cd CATunnel
```

然后在仓库根目录执行：

```bash
bash scripts/check.sh
bash scripts/build-app.sh
```

前者运行 `TunnelCoreChecks` 离线检查程序，当前测试入口不是 `swift test`。
后者生成 `dist/CATunnel.app` 并验证本机 ad-hoc 签名，不会启动应用。
产物针对构建机器的架构，不是通用架构安装包。

如需保留当前 `dist/CATunnel.app`，可将新包输出到独立目录：

```bash
CATUNNEL_OUTPUT_DIR="$PWD/verification/build" bash scripts/build-app.sh
```

仅当受限开发环境无法嵌套运行 SwiftPM 清单沙箱时，可给上述命令加上
`CATUNNEL_DISABLE_SWIFTPM_SANDBOX=1`。默认构建保留 SwiftPM 的沙箱行为。

以下命令需要已登录的 macOS 图形会话，请分开执行：

```bash
./dist/CATunnel.app/Contents/MacOS/CATunnel --demo
./dist/CATunnel.app/Contents/MacOS/CATunnel --ui-check "$PWD/verification/ui/report.json"
```

演示及界面检查均使用模拟数据，不建立 SSH 连接，不读取或保存日常应用设置。
界面检查会自动退出，报告与预览图写入被 Git 忽略的 `verification/`。
核心离线检查会创建自己的短时本地子进程和临时文件。

## 隔离集成测试与预览打包

以下集成测试会在回环地址启动临时 SSH 服务，使用临时密钥和独立主机信任文件，
不连接已配置服务器、不使用个人代理。macOS 测试环境通过真实监听查询适配 Linux
的 `ss` 检查；它不能替代真实 Linux 部署验证。

```bash
bash scripts/check-integration.sh
bash scripts/package-release.sh
```

打包产物位于 `verification/release/`，不会替换已有的 `dist/CATunnel.app`。
发布步骤和解压验证命令见 [发布文档](docs/RELEASING.md)。工程提供 GitHub Actions
构建检查配置；本地通过不代表云端 CI 已运行。安装验证范围和剩余限制见
[验证记录](docs/VALIDATION.md)。

## 使用方式

1. 打开 `dist/CATunnel.app`，点击菜单栏图标。
2. 点击“添加服务器”或上方 **+**，填写显示名称、主机、SSH 用户和端口、本机代理端口、服务器回环端口；按需选择私钥文件。
3. 在编辑器中点击“检查连接准备”，保存后手动开启对应隧道，再按需检测网站。
4. 让需要联网的远端程序显式使用界面给出的代理地址。

例如服务器端口为 `17892` 时，其代理地址为 `http://127.0.0.1:17892`。
连接或检测中的配置需要先停止才能编辑、删除。删除前会请求确认，只移除本地条目。
删除当前服务器后会选择相邻条目，删除最后一个后恢复空列表；其他服务器的连接和检测不受影响。
每台服务器的连接、检测与日志互相独立，服务器较多时顶部标签可横向滚动。
关闭面板不会停止隧道；退出应用会停止它自己创建的连接。支持临时网络错误后的自动重连，
尚未设置登录自启。可在面板设置中调整宽度与字号。

## 首次使用引导与 SSH 准备

从面板或服务器概览打开“使用引导”，按步骤准备本机 HTTP/mixed 代理、确认 SSH
访问，再让远端程序使用隧道代理地址。引导不会执行命令或修改远端工具配置。

编辑器中的“检查连接准备”需要主动点击，与网站检测分开，分别检查：

- Mac 的 `127.0.0.1` 对应端口是否接受 TCP 连接。端口可达不代表 HTTP 代理一定可用。
- 指定密钥文件是否可访问，仅检查文件属性，不读取私钥内容。
- 严格验证主机指纹的非交互 SSH 认证是否成功。
- 服务器是否具备 `ss` 和 `curl`。

此 SSH 检查只执行只读依赖命令，不建立反向转发或复用其他应用的控制连接，不访问外部网站。
修改表单或关闭编辑器会取消检查并清除旧结果；保存服务器不会自动连接。

未知或变化的主机指纹仍会阻止连接。可复制编辑器提供的终端验证命令，独立核对指纹后自行执行；
应用不会替你接受指纹或修改 `known_hosts`。加密密钥请先在终端加载到 SSH agent。
CATunnel 只保存选择的文件路径，不导入密钥内容，也不保存口令。

## 检测和数据

检测由用户主动触发，依次提供 OpenAI API、Claude 网络、Claude API、Google 的结果，
可按服务器选择是否向 Net.Coffee 查询 Claude 出口公网 IP 的风险信息。详细端点见[英文 README](README.en.md#network-checks-and-data)。
该开关默认关闭；开启后，下次主动检测才会将出口公网 IP 提交给 Net.Coffee。
关闭时仍保留 Claude 网络连通性与出口 IP，评分显示为跳过，不请求 Net.Coffee。
检测不发送 API Key、Cookie 或模型提示词，没有埋点或遥测。

API 返回未认证的 HTTP 401 可以证明网络可达，不代表账号登录或模型调用成功。
信任分仅供参考；网段缓存会明确标注，不当作单个 IP 的实时结果。
第三方接口失效不会断开已建立的 SSH 隧道。

应用使用独立配置目录：

```text
~/Library/Application Support/CATunnel/profiles.json
~/Library/Application Support/CATunnel/ui-preferences.json
```

开发版标识为 `local.catunnel.CATunnel`，不会导入其他应用的设置。
SSH 控制套接字位于私有临时目录，最近日志和检测结果仅保存在内存中。
不保存密码、私钥或 API 凭据。

服务器配置采用带版本号的 JSON：

```json
{"version": 1, "profiles": []}
```

兼容此前的数组格式，仅在主动保存配置变更时升级。重复 ID 和冲突的服务器端口会被拒绝。
缺少 `identityFile` 字段时使用默认密钥/agent，缺少 `assessIPRisk` 时默认关闭第三方评分。
配置无法读取、内容损坏或版本不受支持时，界面会提示错误并阻止写入，保留原文件；
修复后重启应用可重新加载。仅首次打开应用不会创建服务器配置文件。

**本地服务器列表与远端工具配置互相独立。** 新增、编辑、删除条目都不会修改服务器上的
`.codex`、`.claude` 或 shell 配置。未来正式切换代理时，再按远端程序的启动方式配置其代理使用。

## 开发与许可证

源码结构、开发约定见 [CONTRIBUTING.md](CONTRIBUTING.md)，后续计划见
[ROADMAP.md](ROADMAP.md)。采用 [MIT 许可证](LICENSE)，设计参考见
[ACKNOWLEDGMENTS.md](ACKNOWLEDGMENTS.md)。
