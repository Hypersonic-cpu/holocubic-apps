# Firmware 1.213 与 macOS 的周期性断连

2026-11-09 真机诊断。根因边界已定位，连接稳定性修复尚未完成。

## 直接证据

Mac 的应用日志证明 `auth`、`auth_ok`、`auth_confirm` 已成功往返；随后收到取消订阅回调。该回调本身不能说明谁主动断开。

macOS `bluetoothd` 的系统日志给出了直接原因：

```text
22:43:26.757 Attempting to find all services on device
22:43:56.802 Timeout waiting for ATT response, forcing a disconnect,
  AttOpcode: Read By Group Type Request, AttHandle: 0x0001,
  requestPduLength: 7 (status=65535)
22:43:57.055 LE Link disconnected ... reason 734 ... localRole=Peripheral
```

同一超时还发生在 22:37:18、22:39:38、22:42:05 和 22:42:57。
设备端收到 disconnect status 531，符合 Mac 主动终止连接的观察。

因此，Mac 虽然是 GAP Peripheral / 应用 GATT Server，系统仍向 ESP32 发起反向 GATT 服务发现。Firmware 1.213 没有及时回应这条 ATT 请求，Mac 在 30 秒事务超时后强制断开。应用认证成功与该反向查询是独立的过程。

## 能确定与不能确定的内容

- 能确定：Mac 因这条 ATT 请求未获响应而强制断连；不是仅凭断连数值猜测。
- 不能确定：没有固件 BLE 初始化源码，不能断言具体哪个编译配置或处理函数有误。
- 公开 Lua BLE API 和 Host ABI 仅暴露 GATT client；均没有 ATT server 请求处理、原始 ATT 收发或 GATT server 注册接口。
- 当前工作区没有 Firmware 1.213 的完整构建源码。`esp32-viper` 不是此固件 BLE host 实现。
- 未发现 CoreBluetooth 公开接口可以禁止系统反向服务发现。重连、心跳、Token 改动不能补答此请求。

## 真正的修复要求

固件须处理入站 ATT 服务发现请求并及时回应。优先启用最小 ATT/GATT server 与标准 GAP/GATT 服务；无需给 Lua 增加自定义 GATT server API，也无需改变应用传输角色。检查 `Read By Group Type` 等请求处理，以及在找不到服务时返回规范 ATT Error Response 的路径。不能只忽略请求。

参考本机 ESP-IDF v5.3.2 的 NimBLE `ble_att_svr_rx_read_group_type()`：关闭对应处理功能时可能直接返回 `BLE_HS_ENOTSUP`。这只是排查方向，尚未证明 Firmware 1.213 使用了该配置。

用户当前不能修改固件：不刷写设备、不改系统蓝牙配置。HTTP 保留。另一条需要额外硬件的候选方案是外置 USB BLE 适配器与独立用户态蓝牙栈，避免由 macOS `bluetoothd` 管理此链路；该方案尚未实现或验证。

## 已完成的应用侧改进

- Mac 仅广播控制服务 UUID，去掉占用传统广播载荷的本地名称。
- 双向认证确认完成后才标记 Authorized。
- 过滤无关或已失效的 disconnect 回调。

以上改进不等于修复本文件记录的 ATT 超时。不得把短暂 Authorized 或请求入队当作稳定 BLE 连接验收通过。

后续验收：连续空闲至少 5 分钟无 ATT 超时；BLE Only 模式重复状态查询和按键 ACK 成功；断连后重连；HTTP 回归。当前这些稳定性验收未通过。

## 2026-11-09 快速恢复缓解（用户取消抓包任务后）

ATT 抓包已取消；本节测量来自 macOS 应用的统一日志，并非原始 HCI/ATT 抓包。

部署版本 0.1.3：

- 已授权会话意外断开后，等待约 100 ms 即尝试连接最近认证的地址；不先扫描、不使用指数退避。检查周期 100 ms。
- 地址只保留内存中，认证时间超过 60 秒不使用快路径。最多尝试五次直连（含第一次），每次失败后约 100 ms 开始下一次；五次耗尽或缓存地址过期后恢复正常扫描/退避，不无限高频重试过期随机地址。
- 每次仍完整发现 GATT 并重新认证，避免 Mac 重启后复用过期句柄。
- 扫描使用 60 ms interval / 30 ms window，开启 active scan，以改善后备发现。
- 通过现有 `ble.config({mtu=247})` 请求较大 MTU；通知载荷仍限制在 Host 的 244 字节事件范围。配置失败时保留默认 MTU。
- 不预先定时断开，不建立第二条并行链路，不引入断连期间积压的按键队列。
- Mac 将状态刷新延后到 @Published 状态已存入后，修复顶部状态比 BLE 状态慢一拍。

测量（本地时间；disconnect → Central confirmed BLE authentication）：

| 配置 | 断开 | 重新认证完成 | 恢复耗时 |
| --- | --- | --- | --- |
| 快速直连、原 MTU | 23:20:19.780 | 23:20:23.714 | 3.934 s |
| 快速直连、原 MTU | 23:20:50.380 | 23:20:54.460 | 4.080 s |
| 快速直连、MTU 247 | 23:21:47.859 | 23:21:50.059 | 2.200 s |
| 快速直连、MTU 247 | 23:22:18.575 | 23:22:20.609 | 2.034 s |
| 快速直连、MTU 247、最终 Mac 构建 | 23:23:15.976 | 23:23:18.308 | 2.332 s |

这些是恢复认证耗时，不代表窗口内每个时刻都能控制，也不代表 0.1 秒恢复。已观察多个循环，但未达到连续连接 60 秒。

最终 Mac GUI 在 BLE Only 模式下发送 Left、Right，均显示 Device received it（应用层 ACK）；没有人工屏幕位移确认。HTTP 认证状态接口返回 200 / ok=true，设备报告 sta_connected=true、前台 Launcher。DevRun 源码逐字节恢复；临时 API 枚举和设备诊断日志文件已删除。Lua 语法检查与 macOS Debug 构建通过。未刷固件、未修改 Wi-Fi 配置。由于仍有约 2 秒空窗，本次暂不提交 Git commit。
