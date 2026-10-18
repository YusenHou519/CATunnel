# 贡献指南 · Contributing

欢迎提交小范围、可复现的修复或功能提案。新功能先参考 [开发计划](ROADMAP.md)，
较大改动请先通过 [Issue](https://github.com/YusenHou519/CATunnel/issues) 说明需求。

## 开发环境

- macOS，安装 Xcode 或 Command Line Tools，提供 Swift 5.9+。
- Swift 包无外部依赖，声明的部署目标为 macOS 13；最低系统实测范围见
  [验证记录](docs/VALIDATION.md)。
- UI 检查需要已登录的 macOS 图形会话。隔离 SSH 检查另需系统 OpenSSH、
  `lsof`、Python 3，以及本地端口监听权限。

## 获取源码与构建

```bash
git clone https://github.com/YusenHou519/CATunnel.git
cd CATunnel
bash scripts/check.sh
CATUNNEL_OUTPUT_DIR="$PWD/verification/dev-build" bash scripts/build-app.sh
```

以上命令均在仓库根目录执行。`check.sh` 运行 `TunnelCoreChecks` 离线检查程序；
当前测试入口不是 `swift test`。它使用临时文件和本地子进程，不连接 SSH 或外部网站。

构建产物为 `verification/dev-build/CATunnel.app`，仅针对当前机器架构；
构建脚本执行 ad-hoc 签名和验证，不安装或启动应用。保留以往验证产物时，
请改用新的输出目录。未指定 `CATUNNEL_OUTPUT_DIR` 时，默认输出到 `dist/`。

SwiftPM 缓存位于仓库内 `.build/`。仅在受限环境不能嵌套运行清单沙箱时，
才为构建或检查命令设置 `CATUNNEL_DISABLE_SWIFTPM_SANDBOX=1`；正常环境保持默认沙箱。

## 离线演示与界面检查

先运行离线演示，手动观察菜单栏面板和服务器切换：

```bash
./verification/dev-build/CATunnel.app/Contents/MacOS/CATunnel --demo
```

演示退出后，再单独运行自动界面检查：

```bash
./verification/dev-build/CATunnel.app/Contents/MacOS/CATunnel \
  --ui-check "$PWD/verification/dev-ui/report.json"
```

这两种模式使用模拟状态和隔离设置，不读取、保存日常配置或建立真实 SSH 隧道。
界面检查完成后自动退出；报告和截图写入 Git 忽略的 `verification/`。
直接执行上述开发包，可避免系统选择已经安装的应用副本。

## 隔离集成检查与打包

需要验证 SSH 行为时，显式运行：

```bash
bash scripts/check-integration.sh --output "$PWD/verification/dev-integration/report.json"
```

该脚本启动临时回环 SSH 服务，使用临时密钥与独立信任文件，验证真实转发和清理。
它不使用个人服务器、SSH agent 或代理，也不会修改日常 `known_hosts`。
macOS 测试使用监听查询适配 Linux `ss`；通过不代表真实 Linux 部署已验证。

需要修改打包或 ZIP 校验逻辑时，再运行：

```bash
bash scripts/check-release-verifier.sh
bash scripts/package-release.sh
```

预览包默认写入新的 `verification/release/` 子目录，不替换 `dist/CATunnel.app`。
完整打包、签名选项和解压检查命令见 [发布文档](docs/RELEASING.md)；
各类检查的适用范围见 [验证记录](docs/VALIDATION.md)。这些脚本不会发布 GitHub Release。

## 项目结构

| 路径 | 内容 |
| --- | --- |
| `Sources/TunnelCore/` | 配置模型、SSH 进程与隧道状态、网络诊断 |
| `Sources/CATunnel/` | 菜单栏 UI、设置、应用生命周期与离线界面检查 |
| `Tests/TunnelCoreTests/` | 核心离线检查可执行程序 |
| `Tests/TunnelIntegrationChecks/` | 隔离 SSH 集成检查可执行程序 |
| `Resources/` | 应用元数据 |
| `scripts/` | 构建、验证、打包及本地 SSH 测试环境 |
| `docs/` | 使用、配置、发布、验证文档与公开素材 |

## 提交约定

- 保持隧道归属、网络诊断与 UI 展示的职责分离，优先小改动。
- 行为变化增加对应检查；只改文档时检查链接、示例和表述，无需重新构建应用。
- 默认检查保持离线；真实 SSH 测试只能操作专门为验证创建的连接。
- 严格验证 SSH 主机指纹和 TLS，只终止应用拥有的子进程；
  不修改现有应用、系统代理或服务器上的工具配置来让测试通过。
- 示例使用文档地址或 `.example` 域名，不提交个人主机、密钥、凭据、
  真实连接截图或未经脱敏的日志。生成产物留在被忽略的目录。
- 区分 SSH 状态、HTTP 连通性、IP 风险参考和实际账号访问；
  未认证的 HTTP 响应不能证明登录或模型调用成功。
- 不添加遥测或静默开启外部请求；新增检测需说明端点和发送的数据。
- PR 说明具体问题、行为变化、已运行的检查及未验证范围。
