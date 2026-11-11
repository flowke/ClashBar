# 服务状态

独立面板保留 Google、GitHub、YouTube 三个内置服务；自建服务保存在工作目录的 `state/service-status.json`。只有自建项可删除，结果仅在本次应用会话内保留。损坏的存储文件会明确报错，不会被空列表覆盖。

## 测量语义

- 当前线路通过正在运行的本地核心的 HTTP / mixed / SOCKS 入口发出请求，遵循核心当前模式与规则。通过基线连接 ID、源端口、目标主机和开始时间联合匹配 `/connections`。只展示观察到的策略链；短连接未被捕获时显示“线路无法确认”。不会拿界面选中节点代替实际线路。
- 直连对照使用临时目录中的独立 Mihomo，仅包含 `DIRECT`。从系统硬件网络服务确认物理接口及该服务的 DNS；通过 `interface-name` 和 DNS 的 `#interface` 绑定出站接口。Mihomo 在 Darwin 上通过 `IP_BOUND_IF` / `IPV6_BOUND_IF` 实现接口绑定，避免再次进入 TUN 路由。不会修改正式核心的配置、模式、节点或系统代理。
- 管理核心可能带有 setuid 权限；直连辅助核心执行私有副本，权限为 `0700`，不继承 setuid。该进程不启用 TUN、控制 API、provider 或持久化选择。
- 无法确认硬件接口、硬件 DNS、可用核心或本地代理入口时明确报告无法检测。远程核心无法从本机完成同一网络下的对照，不伪装成本地结果。
- 两次测量都对完整 URL 发出独立 GET 请求；不跟随跳转，不带登录信息。请求限制为 8 秒，连接限制为 4 秒，并限制响应体大小。耗时为首个 HTTP 响应的时间；无响应时显示总耗时。403 / 429 单独显示访问受限，其他 HTTP 错误与连接、TLS、超时分开。

## 生命周期与结果有效性

取消会停止尚未结束的 curl，等待直连核心清理完成后才允许再次检测。离开页面取消本轮，已完成结果保留；退出应用时同步停止检测子进程。

应用状态观察与只读核心快照共同检测模式、节点选择、规则、provider 版本、配置和物理网络变化。页面可见时每 2 秒核对快照，检测前后另做核对；变化后将旧结果标为待重新检测。无法读取快照时明确标记配置无法核对，不阻止独立直连请求完成。

## 验证

```sh
swift build
CLASHBAR_TEST_MIHOMO=/absolute/path/to/mihomo swift test
CLASHBAR_SERVICE_SCREENSHOT_DIR=/tmp/service-status-screenshots \
  swift test --filter ServiceStatusRenderingTests
```

真实核心集成测试使用独立临时核心和本地 HTTP 服务，覆盖 REJECT 与 DIRECT 对照、403 / 429、完整路径及查询参数、观察到的多级策略链、未知线路、取消和配置不变。不会改变正在运行的用户核心。

需要实测当前核心及公网服务时显式启用：

```sh
CLASHBAR_TEST_MIHOMO=/absolute/path/to/mihomo \
CLASHBAR_SERVICE_LIVE_CONFIG=/absolute/path/to/active-config.yaml \
CLASHBAR_SERVICE_LIVE_CONTROLLER=127.0.0.1:9090 \
  swift test --filter ServiceStatusIntegrationTests/testLiveBuiltInServicesWithoutChangingCore
```

该测试读取配置中的认证信息，不输出认证信息；输出 TUN 状态及各项测量摘要。公网结果由当前网络决定。集成测试不自动开启 TUN；TUN 开启后的实际出口与不同 VPN / 网络组合仍需在相应环境验证。

接口绑定能力参照 Mihomo 的 [Darwin dialer](https://github.com/MetaCubeX/mihomo/blob/Meta/component/dialer/bind_darwin.go)。当前支持可确认的 Ethernet / Wi-Fi 物理服务及其单播 DNS；仅有本地 DNS stub、fake-IP 或 link-local DNS 时会明确报告无法检测。
