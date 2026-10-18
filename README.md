![CATunnel 封面](docs/assets/catunnel-cover-v1.png)

# CATunnel — Coding Agent Tunnel

[![构建与预览验证](https://github.com/YusenHou519/CATunnel/actions/workflows/validate.yml/badge.svg)](https://github.com/YusenHou519/CATunnel/actions/workflows/validate.yml)

[English](README.en.md) · [使用指南](docs/USAGE.md) · [Agent 指南](AGENTS.md)

轻量级原生 macOS 菜单栏应用，让远端 Codex、Claude 等工具通过 SSH 隧道使用 Mac 上的本地代理。

`远端工具 → 服务器回环端口 → SSH 隧道 → Mac 本地代理 → 外网`

## 功能

- **多服务器管理**：新增、编辑、删除服务器，通过顶部页签切换。
- **隧道控制**：独立连接状态、意外断开后自动重连、按服务器选择启动后自动连接。
- **网络检测**：OpenAI API、Claude、Google 连通性；可选 Net.Coffee 出口 IP 评分。
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
