![CATunnel 封面](docs/assets/catunnel-cover-v1.png)

# CATunnel — Coding Agent Tunnel

[![构建与预览验证](https://github.com/YusenHou519/CATunnel/actions/workflows/validate.yml/badge.svg)](https://github.com/YusenHou519/CATunnel/actions/workflows/validate.yml)

[English](README.en.md) · [使用指南](docs/USAGE.md) · [Agent 指南](AGENTS.md)

轻量级原生 macOS 菜单栏应用，让远端 Codex、Claude 等工具通过 SSH 隧道使用 Mac 上的本地代理。

`远端工具 → 服务器回环端口 → SSH 隧道 → Mac 本地代理 → 外网`

## 功能

- **多服务器管理**：新增、编辑、删除服务器，通过顶部页签切换。
- **隧道控制**：独立连接状态、意外断开后自动重连、按服务器选择启动后自动连接。
- **恢复选项（当前源码）**：睡眠前关闭自有 SSH、唤醒后恢复符合条件的连接；可选每 60 秒持续重试转发冲突，默认关闭。
- **固定入口（当前源码，实验性）**：可选远端转接程序维持入口端口，支持在应用内“安装并启用”，并选择服务器上已有的 Python。
- **网络检测**：OpenAI API、Claude、Google 连通性；可选 Net.Coffee 评分和 Ping0 IP 类型、风控值、共享人数查询。
- **原生菜单栏体验**：登录时启动、面板宽度与字号调整、首次使用引导。

CATunnel 需要已有的本地 HTTP/mixed 代理；开启隧道不会自动修改远端工具的代理配置。

## 界面预览

实际界面的离线截图，服务器和检测结果均为示例。点击可看原图。

| 菜单栏主面板 | 启动与外观设置 |
| :---: | :---: |
| <a href="docs/assets/screenshots/menu-panel.png"><img src="docs/assets/screenshots/menu-panel.png" width="260" alt="CATunnel 主面板：服务器切换、隧道开关与网络检测"></a> | <a href="docs/assets/screenshots/settings.png"><img src="docs/assets/screenshots/settings.png" width="260" alt="CATunnel 设置：登录启动、自动连接、面板宽度与字号"></a> |

<details>
<summary>更多界面：服务器配置与首次使用引导</summary>

| 服务器配置 | 首次使用引导 |
| :---: | :---: |
| <a href="docs/assets/screenshots/server-editor.png"><img src="docs/assets/screenshots/server-editor.png" width="380" alt="CATunnel 服务器配置：SSH 地址、用户、密钥与代理端口"></a> | <a href="docs/assets/screenshots/getting-started.png"><img src="docs/assets/screenshots/getting-started.png" width="380" alt="CATunnel 首次使用引导"></a> |

</details>

## 安装与快速开始

从 [GitHub Releases](https://github.com/YusenHou519/CATunnel/releases) 下载预览包：
Apple Silicon 选择 **arm64**，Intel 选择 **x86_64**。解压后将 CATunnel.app 放入“应用程序”，打开菜单栏图标。

当前版本为 **0.6.0-preview.2（build 5）**，界面为中文。预览包尚未经过 Apple 公证；
若 macOS 阻止打开，请参照[安装说明](docs/USAGE.md)，无需关闭系统安全保护。

**环境**：Mac 上有 HTTP/mixed 代理；Linux 服务器具备 SSH、ss 和 curl，支持密钥登录及反向转发。
应用构建目标为 macOS 13+，已验证环境与限制见[验证记录](docs/VALIDATION.md)。

1. 启动 Mac 本地代理，确认其 HTTP/mixed 端口。
2. 在 CATunnel 点击 **＋**，填写服务器地址、SSH 用户、密钥及两端端口。
3. 按引导核实 SSH 主机指纹，点击 **检查连接准备**；通过后保存并开启隧道。
4. 将远端工具指向服务器上的代理地址，例如 `http://127.0.0.1:17892`。

`7890`（Mac 代理）和 `17892`（服务器入口）是默认示例端口，可按需调整。
首次启动服务器列表为空。详细配置、检查命令和排障见[使用指南](docs/USAGE.md)。

目前不支持 SSH 别名、ProxyJump、交互式密码登录和 IPv6 主机地址。
API 可达不等于账号或模型可用；IP 评分默认关闭，仅供参考。
Ping0 查询已加入当前源码，尚未包含在上述预览下载包中；使用公开网页，页面变化或访问受限时会显示查询失败。

## 固定入口模式（实验性）

此功能**默认关闭**，已加入当前源码，尚未包含在 `v0.6.0-preview.2` 下载包中；
使用前请按[贡献指南](CONTRIBUTING.md)构建当前源码。旧配置继续使用常规 SSH 反向转发。

开启后，远端转接程序在运行期间维持固定的回环入口，例如 `127.0.0.1:17892`。
每次 SSH 连接使用独立的临时后端端口，验证新通道后才切换转发目标；
这样重连时即使旧 SSH 会话仍占着原来的临时端口，也无需先结束旧会话。

1. 停止需要修改的服务器连接，打开该服务器的编辑窗口，确认“服务器代理端口”。
2. 服务器需已有 **Python 3.9+**。在 **“远端 Python 路径（可选）”** 中填写其可执行文件的绝对路径，
   例如 `/opt/tools/bin/python3`；留空使用远端默认 `python3`。填写的是服务器上的路径，
   不支持 `~/` 或 `conda activate` 等命令。固定入口开关关闭时也可以填写。
3. 点击 **“安装并启用”**。应用通过 SSH 将转接程序安装到当前账号的
   `~/.catunnel/fixed-entry/<端口>/`，启动后再通过独立 SSH 请求确认它持续运行。
   无需预先打开固定入口开关。
4. 成功后，应用自动填入程序及运行目录路径，并打开**当前表单**的固定入口开关。
   点击 **“保存”**，再手动开启隧道；仅安装成功或保存设置不会自动连接。

安装、验证以及后续连接、续期和释放均使用同一个 Python 选择。
应用不升级系统 Python、不下载依赖、不使用 sudo，也不修改 SSH 或 shell 配置。
取消安装只停止本机等待，远端操作可能已完成；再次点击会检查并复用兼容且空闲的已有安装。
端口被占用、入口正在使用或存在无法确认的安装文件时，会保留现场并提示错误。

目前不配置服务器开机自启；服务器正常重启后，可再次点击按钮启动已有安装。
Mac 休眠期间不能通过它联网，已有 TCP 请求也不会迁移到新通道；这不保证所有休眠重连都能立即恢复。
详细配置、手动部署和限制见[使用指南](docs/USAGE.md)。

## TODO

- [ ] 英文界面。
- [ ] SSH 别名与跳板机支持。
- [ ] 配置导入、导出与迁移方案。
- [ ] Homebrew 安装与更新体验。

优先级、待设计事项和验收清单见 [ROADMAP.md](ROADMAP.md)。项目通过 GitHub 发布，无 App Store 上架计划。

## 文档与贡献

| 文档 | 内容 |
| --- | --- |
| [使用指南](docs/USAGE.md) | 安装、SSH 准备、代理配置、启动设置与排障 |
| [AGENTS.md](AGENTS.md) | 给 AI Agent 的配置格式、命令、验证与操作约定 |
| [贡献指南](CONTRIBUTING.md) | 源码构建、离线演示、测试与项目结构 |
| [验证记录](docs/VALIDATION.md) / [发布说明](docs/RELEASING.md) | 已验证范围与打包流程 |
| [更新日志](CHANGELOG.md) | 版本变更 |

欢迎通过 [Issues](https://github.com/YusenHou519/CATunnel/issues) 反馈问题或提出功能建议。

[MIT License](LICENSE) · [致谢](ACKNOWLEDGMENTS.md)
