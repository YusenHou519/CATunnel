# 固定入口实验原型

这个原型用于验证：**旧 SSH 会话还占着端口时，新的连接能否立即接管同一个代理入口。**
此目录保留独立 Python 命令行参考实现。CATunnel 当前源码另已接入默认关闭的界面开关，
客户端与 Mac 网关使用原生 Swift；两者共用本目录的远端 `relay.py` 协议。
应用仅在显式点击“安装并启用”后部署远端程序；源码构建不会自动替换已安装应用或改写日常配置。
应用可填写已有远端 Python 3.9+ 的绝对路径；安装、二次验证和后续连接控制均使用同一解释器。
留空仍用 `python3`，无需激活环境或升级系统 Python；此选项只属于原生应用，独立参考客户端未增加解释器选择参数。

## 工作方式

原有方式由每次 SSH 连接直接申请固定入口，例如服务器的 `127.0.0.1:17892`。
服务器还没有发现旧连接已断开时，新连接就无法再次申请这个端口。

原型把它拆成两层：

```text
服务器上的程序
    │ 始终使用同一个入口，例如 127.0.0.1:17892
    ▼
远端转接程序（持续持有入口）
    │ 只把新请求送到当前通过验证的通道
    ▼
本次 SSH 动态分配的端口（每次重连重新申请）
    │ SSH 加密通道
    ▼
Mac 上的网关 → 已有的本地代理 → 网络
```

例如旧通道还占着 `42001`，新连接可以获得 `42002`。转接程序确认新通道确实
通向本次连接的 Mac 网关，而且本地代理能够接受 TCP 连接，再把入口切过去。
旧通道无需先释放 `42001`，也不需要根据端口号去杀远端进程。

每次连接有自己的代次和凭据。迟到的旧连接续期、释放和切换请求不能撤销新连接。
旧客户端掉线后自动重连，也会检查入口是否已被另一客户端接管；已经被接管就停止。
当前连接要定期续期；连接失效或租约过期后，入口继续监听，但新请求会尽快失败，
避免一直送入失效通道。健康检查使用每次连接独有的 HMAC 密钥，不访问外部网站。

## 文件

- `relay.py`：远端固定入口、私有控制 socket、代次与租约、健康验证和转发。
- `install.py`：显式安装到当前 SSH 用户私有目录、校验文件和后台存活；不使用 sudo 或配置系统服务。
- `gateway.py`：Mac 侧健康验证及到本地代理的透明 TCP 转发。
- `client.py`：严格校验主机密钥的 SSH 连接、动态端口申请、切换、续期和重连。
- `tests/`：隔离的单元与异步网络测试。
- `PROTOCOL.md`：两端的消息、边界和接口约定。
- `../../scripts/check-fixed-entry.py`：临时真实 SSH 环境下的故障模拟入口。
- `../../Sources/TunnelCore/FixedEntryProtocol.swift`、`FixedEntryGateway.swift`：原生客户端协议与网关；
  实际连接由已有的 `TunnelController` 管理。

## 本地验证

从 CATunnel 仓库根目录执行，使用 Python 3.9 或更新版本，无额外 Python 依赖：

```sh
python3 -m unittest discover -s experimental/fixed_entry/tests
python3 scripts/check-fixed-entry.py --output /tmp/catunnel-fixed-entry-report.json
```

验证当前应用实际使用的原生 Swift 控制器路径：

```sh
swift build --product FixedEntryIntegrationChecks
python3 scripts/check-fixed-entry.py \
  --binary "$(swift build --show-bin-path)/FixedEntryIntegrationChecks" \
  --output /tmp/catunnel-fixed-entry-swift-report.json
```

此模式同时运行固定入口连接和旧格式配置解码后的直连对照，包含手动停止、
睡眠/唤醒回调、关闭自动重连、远端程序缺失与端口不匹配验证。Python 只负责
创建隔离环境和注入故障，连接、租约及恢复均由 `TunnelController` 执行。

验证应用实际使用的安装器及安装后的原生连接：

```sh
swift build --product FixedEntryInstallIntegrationChecks
python3 scripts/check-fixed-entry-install.py \
  --binary "$(swift build --show-bin-path)/FixedEntryInstallIntegrationChecks" \
  --output /tmp/catunnel-fixed-entry-install-report.json
```

安装模拟把远端 HOME 固定在临时目录，只允许执行本次打包的安装脚本与测试命令。
它验证真实 SSH 上传、上传连接退出后的后台存活、幂等复用、活动入口与外来监听保护、
取消后重试、主机指纹和缺失 Python 错误、文件版本冲突以及另一条连接持续可用。
解释器选择用例注入默认 Python 版本过低的失败，再以临时路径指向本机已有 Python，
验证安装、二次状态检查、连接与续期、停止和重新连接都使用指定解释器。此用例不安装旧版 Python。
`build-app.sh` 将这两个 Python 文件复制到应用资源并签名；直接 `swift run CATunnel`
不包含这些安装资源，测试安装界面需使用完整应用包。

集成测试需要当前机器的 OpenSSH 客户端、sshd、ssh-keygen 和进程/监听检查工具。
它只连接临时的本机 SSH 服务，生成临时密钥和 known_hosts，使用临时 HTTP 服务
模拟本地代理。不会使用真实服务器、用户 SSH 密钥或正在工作的本地代理。

模拟过程：先确认两条独立入口都能收到各自的准确 HTTP 响应；然后丢弃其中一条
旧 SSH 通道的数据，并保留服务器侧连接及其动态监听端口；让该客户端重连；
验证固定入口转向新通道时旧监听确实仍然存在，另一条健康连接也继续工作。
最后验证主动停止后不再重连，并清理测试拥有的进程、端口及临时密钥。

这是 SSH 数据通道故障模拟，**不是让 Mac 实际休眠**；它验证的 HTTP 服务在本机，
不代表公网网站、真实服务器 SSH 策略或实际代理软件已经通过验证。

## 当前边界

- Mac 睡着或本地代理停止时，固定入口仍可存在，但无法通过 Mac 上网。
- 已建立的 TCP 请求不会搬到新通道，切换时可能断开；调用方仍需重试。
- 固定入口只能在转接程序正常运行期间持有，不是操作系统层面的永久预留。
- 所有转发监听仅绑定 IPv4 回环地址，不提供公网代理入口。
- 控制目录必须属于当前账号、权限为 `0700`，不能是符号链接。同一 Unix 账号
  下的恶意程序不在本原型隔离范围内；不同客户端也没有独立账号级访问控制。
- 正常退出会清理自己的控制 socket 和状态文件。遇到强制终止留下的未知残留时，
  原型会拒绝启动，需人工确认残留归属；尚未实现无人值守的崩溃恢复或开机常驻。
- 动态远端转发需要服务器 SSH 策略允许。原型不会修改 `sshd_config` 或绕过限制。
- 如果申请新代次时响应丢失，无法确认该代次属于谁，原型会保守停止，需显式重新
  连接；它不会在归属不明时反复争抢入口。
- CATunnel 的开关默认关闭，保存不会连接。按钮只启用当前编辑草稿，需显式保存。
  安装目录为 `~/.catunnel/fixed-entry/<端口>/`；不会替换其他版本或配置开机自启。
  卸载、服务监管、Linux 实机验证和兼容性验证
  仍是后续工作；隔离检查通过不等于已部署或生产可用。

精确的协议与限制见 [PROTOCOL.md](PROTOCOL.md)。
