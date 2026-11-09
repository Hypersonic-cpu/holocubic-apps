# Clocteck HTTP + BLE 双传输控制实施计划

## 0. 目标与约束

### 目标

为现有 Clocteck 控制系统增加 BLE 通信方式，同时保持现有 HTTP 功能完全兼容。

最终实现：

- MacCtrlHTTP 支持 HTTP、BLE、Auto 三种传输模式。
- MacBook 作为 BLE Peripheral / GATT Server，Clocteck ESP32-S3 作为 BLE Central / GATT Client。
- Clocteck 自动连接已配置的 MacCtrlHTTP，接收控制指令。
- BLE 和 HTTP 共用 ActionCtrlHTTP 的 FIFO、按键时序、请求去重和 Controller Publisher。
- MacBook 连接 `XJTU_STU` 时，无需与 Clocteck 建立 Wi-Fi 局域网连接，也可以通过 BLE 控制 Launcher、2048 等兼容应用。
- BLE 连接断开后自动重连，不影响 HTTP 控制。

### 严格约束

1. **禁止修改 `wifi_guide`、Wi-Fi 配网流程及已有配网图片。**
2. 尽量不修改 Clocteck Firmware，不增加 `.so`，优先使用现有 Lua BLE API。
3. 不修改 Launcher、2048 或其他前台应用。
4. 保留现有 HTTP API、Token、配置和所有已验证行为。
5. 不恢复或重新安装 `hidpad`。用户已确认该服务退出，不需要为了 BLE 方案重新引入它。
6. 目前局域网可以通过 `CUBIC_IP=clocteck-cubic.local` 访问。将其作为开发、部署、测试和恢复通道。
7. 第一版采用**明文静态调试密钥**，不生成随机密钥，不实现加密传输。
8. 密钥必须由用户自行编辑、保存、替换。不要仅硬编码在源代码中。
9. 不修改校园网登录流程，不使用 MAC 地址克隆。
10. 不在尚未验证通信可靠性的情况下停用 HTTP 通道。
11. 不把 WidgetKit、小组件 BLE 后台控制或任意 HTTP API 代理纳入第一版。
12. 每个阶段都执行测试，并在通过后提交独立的 Git Commit。

参考：

- `https://github.com/Hypersonic-cpu/holocubic-apps`
- `ActionCtrlHTTP/docs/SERVICE_DESIGN.md`
- `ActionCtrlHTTP/package/main.lua`
- `https://github.com/clocteck/holocubic-apps/blob/main/README_LUA.md`
- `https://github.com/clocteck/holocubic-apps/blob/main/README_HOST_ABI.md`

---

## Step 1 — 检查工作区及当前实现

- [ ] 检查 Clocteck 和 MacCtrlHTTP 两个项目的实际目录、Git 状态、当前分支、未提交修改和构建方式。

Clocteck：

- 阅读最新 `ActionCtrlHTTP/package/main.lua`、`app.info`、README 及设计文档。
- 确认 `controller.publish("ble-main")`、FIFO、去重、QueueCapacity、Key Delay 和状态 API 的实际实现。
- 确认固件 BLE API、IPC API 和后台 Service 生命周期。
- 确认当前没有占用 BLE Controller 或 `ble-main` 的其他 Service。不得仅凭服务名称推断其运行状态。
- 确认现有 BLE API 支持扫描、连接、GATT 发现、Notify 订阅、Write 和断线回调。

macOS：

- 检查 `MacCtrlHTTPApp.swift`、`ControlPanelView.swift`、现有网络客户端、设置持久化以及实际构建工程。
- 确认应用是否启用 App Sandbox、蓝牙权限及代码签名配置。
- 确认当前 HTTP 功能和小组件构建不会受到新模块影响。

建立 HTTP 基线：

```bash
export CUBIC_IP=clocteck-cubic.local

curl -v --connect-timeout 5 \
  "http://${CUBIC_IP}/api/system/state"
```

使用已经配置的 HTTP Token 验证：

```bash
curl -sS \
  -H "X-ActionCtrl-Token: ${ACTIONCTRL_TOKEN}" \
  "http://${CUBIC_IP}/remote/api/v1/status"
```

`ACTIONCTRL_TOKEN` 使用现有值，不覆盖，不重新生成。

**验收：** 现有 HTTP 控制正常，记录初始状态。为两个工作区创建功能分支（建议 `feat/ble-dual-transport`），但不要覆盖或提交无关的已有修改。

---

## Step 2 — 先固定 BLE 协议与配置格式

- [ ] 创建双方共同遵守的 BLE 协议规范，确定 UUID、消息格式、密钥、ACK 和错误处理。

在 Clocteck 仓库增加：

`docs/BLE_CONTROL_PROTOCOL.md`

协议使用固定 UUID：

| 用途                      | UUID                                   |
| ----------------------- | -------------------------------------- |
| Control Service         | `7d5e9a00-4eb4-47d1-b591-cc6e7ef6a100` |
| Command Characteristic  | `7d5e9a01-4eb4-47d1-b591-cc6e7ef6a100` |
| Response Characteristic | `7d5e9a02-4eb4-47d1-b591-cc6e7ef6a100` |

定义：

- Command：Mac → Clocteck，GATT Notify。
- Response：Clocteck → Mac，GATT Write With Response。
- Mac 同时只服务一台经过认证的 Clocteck，避免多个 Central 共享命令队列。
- 协议带版本号，初始为 v1。

### 消息类型

至少包含：

- `auth`：发送调试密钥，建立当前 BLE 会话的应用级授权状态。
- `auth_ok` / `auth_failed`：认证结果。
- `tap`：模拟单次按键。
- `status`：查询 ActionCtrlHTTP 状态。
- `ack`：应用层命令接受或拒绝结果。
- `error`：协议、通信或内部错误。

`tap` 消息语义与现有 HTTP 完全一致：

```json
{
  "type": "tap",
  "button": "up",
  "request_id": "mac-ble-000001"
}
```

ACK 至少包含：

```json
{
  "type": "ack",
  "request_id": "mac-ble-000001",
  "ok": true,
  "queued": true
}
```

必须定义非法命令、未授权、重复命令、队列已满、Controller Busy、Service 不可用等错误。

### GATT 分片

不要假设一个 JSON 消息可以放进单个 BLE Notification。

第一版使用简单分片协议：

- 每个分片有 magic、version、message ID、fragment index、fragment count。
- 支持默认 ATT MTU 为 23 时的 20-byte 数据负载。
- 分片头建议为 6 bytes，剩余空间用于消息内容。
- 根据协商 MTU 和对端允许的数据长度动态决定分片大小。
- 对同一逻辑消息完成重组后才解析 JSON。
- 设置单条消息上限，例如 1024 bytes。
- 支持分片超时、乱序/缺失检查、重复消息处理和连接断开时清理缓冲区。
- Mac Notification 发送队列必须处理 `updateValue()` 返回 false 时的背压，等待 ready 回调继续发送。
- Clocteck 的 Write With Response 需要等待 GATT 写完成事件，不能无限制连续发送。

第一阶段仅支持少量控制 JSON，不实现大文件传输。

### 手动密钥

调试阶段统一使用：

`clocteck-ble-debug-2026`

两个设备上的配置必须完全一致，区分大小写。

认证流程采用：

1. Mac 开始广播。
2. Clocteck 连接并订阅 Command。
3. Clocteck 通过 Response Characteristic 将 `auth` 消息发给 Mac。
4. Mac 比较接收到的 Token 与本地配置。
5. 一致时向该 Central 发送 `auth_ok`。
6. Clocteck 进入 Authorized 状态。
7. 此后才允许 `tap`、`status` 等控制消息。

这是调试级共享口令校验，不声称提供抗窃听、抗重放或真正的双向加密身份认证。

**Commit（Clocteck）：** `docs(ble): define control transport protocol and debug configuration`

---

## Step 3 — 新增 Clocteck ActionCtrlBLE Service

- [ ] 新建独立 `ActionCtrlBLE` App，并实现基本生命周期、BLE 初始化、扫描、连接和 GATT 发现。

目录：

```text
holocubic-apps/
└── ActionCtrlBLE/
    ├── README.md
    └── package/
        ├── app.info
        ├── main.lua
        └── config.example.json
```

`app.info` 应包含：

- `kind = service`
- `autostart_service = true`
- 独立的 Service ID
- 合适的版本号和描述

`main.lua` 至少负责：

- 读取配置。
- 初始化 `ble`。
- 注册 BLE IRQ。
- 扫描目标 Service UUID。
- 连接 Mac。
- 发现 Command / Response Characteristic。
- 找到 CCCD 并订阅 Notify。
- 管理连接状态、超时及清理。
- 在 Service 停止时释放 BLE 会话和内部资源。

连接状态建议：

`Disabled → Scanning → Connecting → Discovering → Subscribed → Authorizing → Ready`

另外提供 `Disconnected` 和 `Error` 状态。

BLE 扫描、连接和重连必须由后台 Service 管理，不依赖前台 App。

不得将 ActionCtrlBLE 设为 `ble-main` Publisher，避免与 ActionCtrlHTTP 发生所有权冲突。

---

## Step 4 — macOS 增加最小 GATT Peripheral

- [ ] 在 MacCtrlHTTP 中创建独立的 CoreBluetooth 模块，先完成最小 BLE 广播和连接验证。

建议增加：

```text
Transport/
    BLETransport.swift
    BLEPeripheralManager.swift
    BLEProtocol.swift
```

根据当前项目实际目录调整，不强制重构整个项目。

使用：

- `CBPeripheralManager`
- `CBMutableService`
- `CBMutableCharacteristic`
- `CBPeripheralManagerDelegate`

实现：

- 检测蓝牙权限和设备状态。
- 注册固定 UUID 的 GATT Service。
- 广播 Service UUID。
- 记录已订阅的 Central。
- 通过 Notify 发送消息。
- 接收 Write With Response。
- 实现发送队列与背压。
- 停止应用时释放 BLE 资源。

设置必要的 Bluetooth Usage Description，并根据实际 Sandbox 配置补齐授权。

不要改动现有 HTTP 请求逻辑，也不要要求用户先输入 Clocteck IP 才能启用 BLE。

### 第一次联调

在 Mac 上启动广播，在 Clocteck 启动 ActionCtrlBLE。

观察：

- Clocteck 能否发现 Mac。
- 是否收到连接完成事件。
- GATT Service 和 Characteristic 是否发现成功。
- Notify 是否成功订阅。
- 双方能否收发测试消息。
- ActionCtrlBLE 是否能重新连接。
- 现有 HTTP API 是否仍然正常。

若发现固件 BLE API 存在实际限制，先定位和记录，不要直接开始修改 Firmware。

**Commit（macOS）：** `feat(ble): implement GATT peripheral foundation`

**Commit（Clocteck）：** `feat(ble): add ActionCtrlBLE background service`

---

## Step 5 — 实现明文调试密钥的持久化与认证

- [ ] 在两端实现独立、可手动管理的 BLE 调试配置，并接入 Step 2 定义的认证消息。

### Clocteck 存储

路径：

`/sd/data/blebridge/config.json`

内容：

```json
{
  "enabled": true,
  "device_name": "Clocteck",
  "token": "clocteck-ble-debug-2026",
  "auto_connect": true
}
```

### macOS 存储

建议：

`~/Library/Application Support/MacCtrlHTTP/ble.json`

内容：

```json
{
  "enabled": true,
  "token": "clocteck-ble-debug-2026",
  "advertise_on_launch": true
}
```

要求：

- 两边均使用明文 JSON。
- 不自动产生随机密钥。
- 提供示例文件。
- 首次使用可以通过示例配置初始化。
- 用户可直接编辑配置文件，修改 Token 后重启对应 Service/App 生效。
- 可以增加 `Reload Configuration` 功能，但不是第一版必需。
- 两个真实配置文件不提交 Git。
- `.gitignore` 必须排除实际包含密钥的文件。
- 不在日志中输出 Token 全文。
- 不修改既有 HTTP Token。
- 不修改 Clocteck 的 `/sd/apps/settings.json`。

连接成功不等于认证成功。只有收到 `auth_ok` 且双方状态一致后，Mac 才能向该设备发送控制命令。

失败情况需要有独立状态，例如 `Auth Failed`。

**测试：**

- 相同 Token → Authorized。
- 不同 Token → 拒绝控制。
- 修改 Token 并重新启动 → 新 Token 生效。
- 未认证情况下发送控制命令 → 不执行按键。

**Commit（两端分别提交）：** `feat(ble): add editable plaintext debug authentication`

---

## Step 6 — 改造 ActionCtrlHTTP，抽取统一命令入口

- [ ] 修改 `ActionCtrlHTTP/package/main.lua`，使 HTTP 和 IPC 能够复用完全相同的按键处理逻辑。

当前 HTTP Handler 已包含：

- JSON 解码。
- Button 合法性检查。
- `request_id` 去重。
- QueueCapacity 检查。
- `ble-main` 所有权检查。
- FIFO 入队。
- 接受结果构造。

将这些逻辑抽取为统一的内部入口，例如：

`accept_tap(command)`

原 HTTP Handler 只负责：

`HTTP Auth → HTTP Decode → accept_tap() → HTTP Response`

新增 IPC Handler 负责：

`IPC Decode → accept_tap() → IPC Response`

内部返回结构必须一致。

### IPC Endpoint

建议：

- 命令端点：`actionctrlhttp-command`
- ActionCtrlBLE 回复端点：`blebridge-response`

IPC Topic：

- `tap`
- `status`
- `result`

IPC 调用必须支持请求 ID 和关联回复。

**重要：`ipc.send()` 返回成功，只能表示消息已交给 IPC，不等于 ActionCtrlHTTP 已接受指令。**

ActionCtrlBLE 必须收到 ActionCtrlHTTP 的实际结果后，才能通过 BLE 回复 ACK。

保留原有：

- HTTP Token 验证。
- HTTP 202 / 400 / 401 / 409 / 429 等行为。
- FIFO 和去重逻辑。
- QueueCapacity、Key Delay 等已有配置能力。
- 120 ms 按下时间及当前已验证的点击时序，除非代码现状已调整。
- `controller.publish("ble-main")`。
- Service 重启和资源释放行为。

不要创建第二套按键队列或第二个 Controller Publisher。

### 测试

- HTTP 发送 `up`，操作正常。
- IPC 发送 `up`，操作正常。
- HTTP 与 IPC 交替发送，不发生状态冲突。
- 相同 `request_id` 通过两种通道重复发送，只执行一次。
- 队列已满时返回一致的错误。
- 兼容已有 HTTP 状态响应。

**Commit（Clocteck）：** `refactor(actionctrl): share command engine between HTTP and IPC`

---

## Step 7 — 将 ActionCtrlBLE 接入 ActionCtrlHTTP

- [ ] 让 ActionCtrlBLE 把通过 BLE 接收的 `tap`、`status` 指令交给 ActionCtrlHTTP，并将真实结果回传给 Mac。

流程：

`BLE Notify → ActionCtrlBLE → IPC → ActionCtrlHTTP → IPC Result → BLE GATT Write → Mac`

要求：

- 只有 Authorized 状态允许发送控制指令。
- 所有接收数据进行格式检查。
- 实现超时与错误映射。
- 回复中保留 `request_id`。
- 不因为短时 BLE 断线停止 ActionCtrlHTTP。
- BLE 重连不清空 ActionCtrlHTTP 的正常队列。
- Service 停止时清理待回复请求。
- 请求重试必须使用原 `request_id`，避免重复执行。

建议先支持：

`up / down / left / right / a / b / menu / select / home`

再实现 `status`。

### 真机验证

通过 macOS BLE 调试功能发送 `up`，在 Clocteck Launcher 上确认只移动一次。

然后测试：

- 连续不同方向键。
- 连续相同方向键。
- 启动 2048。
- 2048 中控制方向。
- Home 返回 Launcher。
- 同时发送 HTTP + BLE。
- BLE 断开时 HTTP 继续正常工作。

**Commit（Clocteck）：** `feat(ble): route BLE commands through ActionCtrlHTTP IPC`

---

## Step 8 — macOS 集成 HTTP/BLE 双传输

- [ ] 在 MacCtrlHTTP 中抽象控制传输接口，接入 BLETransport，保留原有所有 HTTP 功能。

建议模块：

```text
Transport/
    ControlTransport.swift
    HTTPTransport.swift
    BLETransport.swift
    BLEPeripheralManager.swift
    BLEProtocol.swift
    TransportManager.swift
```

如项目已有类似结构，应复用，不要制造重复模块。

统一提供：

- `tap(button)`
- `fetchStatus()`
- 连接状态
- 错误状态
- 取消与超时处理

### 传输模式

**HTTP Only**

仅使用原来的 HTTP。

**BLE Only**

仅使用 BLE，不通过 Clocteck IP 发送按键。

**Auto**

优先使用可用的 HTTP；HTTP 不可用时使用已授权的 BLE。

Auto 不能每次点击都等待很长的 HTTP 超时。应该主动维护两条链路的状态，快速选择当前可用通道。

对请求完成状态不确定的情况，使用同一个 `request_id` 重试，不能生成新 ID 导致重复按键。

### 界面修改

在现有设置区增加：

- `CONTROL TRANSPORT`：Auto / HTTP / BLE。
- HTTP 状态。
- BLE 状态。
- BLE Token 设置入口或配置文件位置说明。
- BLE Advertising 开关。

BLE 状态至少区分：

- Disabled
- Advertising
- Connected
- Authorizing
- Ready
- Disconnected
- Error

保持既有方向键、A/B/Home、BUFFER SIZE、KEY DELAY、Device IP、HTTP Token 及其原有保存行为不变。

注意：本阶段不修改 WidgetKit 的传输逻辑；小组件原有 HTTP 行为需要继续可用，BLE 不自动成为 WidgetKit 后台可用的通道。

**Commit（macOS）：** `feat(mac): integrate selectable HTTP and BLE control transports`

---

## Step 9 — 实现自动重连和异常恢复

- [ ] 完成 BLE 两端的状态机健壮性与重连流程。

Clocteck：

- 开机自动启动 ActionCtrlBLE。
- Mac 未广播时持续扫描，但采用有限间隔和退避，避免高频消耗资源。
- Mac 出现后连接。
- GATT 连接中断后清理旧连接状态。
- 重新扫描、发现、订阅、认证。
- 授权成功后恢复 Ready。
- 停止 Service 时注销 IRQ 并释放 BLE 资源。
- 不能因为 BLE 初始化失败而影响 Wi-Fi 和 HTTP。

Mac：

- Bluetooth 关闭时显示状态，不崩溃。
- Bluetooth 再次开启后恢复广播。
- Clocteck 断开后重新等待连接。
- `updateValue()` 发送队列满时正确等待恢复。
- 收到来自未授权 Central 的 Write 时拒绝控制。
- 应用退出后释放广播服务。
- 应用重新打开后自动恢复广播。
- 不依赖 Clocteck 的 IP 地址或 mDNS 来建立 BLE。

认证信息在重连后需重新验证，不能仅凭上一次连接成功就默认当前连接授权。

建议设置合理的连接、认证、分片、IPC 和回复超时；实际参数经真机测试后确定并记录。

**Commit（两端分别提交）：** `fix(ble): handle reconnect, timeout and session recovery`

---

## Step 10 — 端到端回归测试

- [ ] 执行完整回归测试，并保存可复核的测试结果。

注意: F先不要测试, 先不要更改macOS的网络状态. 但你要确保之前的BLE测试走的确实是蓝牙而不是依赖WI-FI.

### A. HTTP 回归

保持 Clocteck Wi-Fi 不变：

- `clocteck-cubic.local` 可以访问。
- `/api/system/state` 正常。
- `/remote/api/v1/status` 正常。
- 原有 HTTP 按键全部可用。
- HTTP Token 验证没有变化。
- QueueCapacity / Key Delay 配置正常。
- HTTP 模式下不需要 BLE。
- ActionCtrlBLE 停止后 HTTP 仍正常。

### B. BLE 独立控制

MacCtrlHTTP 选择 `BLE Only`：

- Clocteck 连接成功。
- 授权成功。
- `tap(up)` 正常执行。
- 重复 `tap(up)` 每次产生一次动作。
- 方向键、A/B/Home 全部通过测试。
- `status` 可以返回真实状态。
- 操作期间确认没有向 Clocteck HTTP 地址发送控制请求。

初期不主动断开 Clocteck 的 Wi-Fi，保留局域网调试与恢复能力。

确认 BLE 稳定后，再执行一次没有 HTTP 可达路径的独立性测试，验证 BLE 确实不依赖 Wi-Fi。

### C. 双通道并发

- HTTP 和 BLE 同时在线。
- 从 HTTP 发送一次按键，再从 BLE 发送一次。
- 不出现双重 Publisher 冲突。
- 混合发送时 FIFO 顺序合理。
- 统一去重有效。
- 队列满时 HTTP 和 BLE 都返回正确结果。

### D. 断线恢复

- 关闭 MacCtrlHTTP 广播，观察 ActionCtrlBLE 断线。
- 恢复广播，验证自动重连。
- 重启 MacCtrlHTTP，验证恢复。
- 重启 ActionCtrlBLE，验证恢复。
- 重启 ActionCtrlHTTP，验证 IPC 恢复。
- 重启 Clocteck，验证两个 Service 自启动与重新连接。
- 重启过程不得破坏 Wi-Fi 配置或造成永久按键按下。

### E. 密钥测试

- 两端 Token 相同，认证成功。
- 两端 Token 不同，认证失败。
- 手动编辑 Mac 本地配置，重启后生效。
- 手动编辑 Clocteck 配置，重启 Service 后生效。
- 错误 Token 不触发按键。
- 日志不输出完整 Token。
- 实际 Token 配置不会被提交 Git。

### F. 校园网场景

MacBook 连接 `XJTU_STU`，保持用户现有 Portal 登录方式。

在 macOS 选择 BLE Only，验证：

- MacBook 校园网正常访问互联网。
- Clocteck 不需要通过校园网 HTTP 路径被 MacBook 访问。
- MacCtrlHTTP 可以通过 BLE 控制 Clocteck。
- BLE 不影响 MacBook 的正常网络连接。
- 回到私人局域网后，HTTP 模式依旧可用。

**验收报告：** 每项测试必须标记 PASS / FAIL / NOT TESTED，并附关键日志或复现方法。禁止把未经执行的测试标记为 PASS。

---

## Step 11 — 整理文档及最终提交

- [ ] 更新安装、配置、故障排查与架构文档，完成两个仓库的最终 Git 检查和提交。

Clocteck 文档：

- ActionCtrlBLE 安装与自启动。
- 如何创建和修改 `/sd/data/blebridge/config.json`。
- ActionCtrlBLE 与 ActionCtrlHTTP 的职责。
- IPC 协议和 GATT 协议。
- BLE Owner / Controller Publisher 冲突排查。
- 如何重启 ActionCtrlBLE。
- 如何卸载 ActionCtrlBLE 并恢复原纯 HTTP 模式。
- 已知限制及未实现功能。

macOS 文档：

- 蓝牙权限。
- HTTP/BLE/Auto 模式。
- 如何编辑本地 BLE Token。
- 如何查看连接和认证状态。
- 断线时如何恢复。
- 当前 WidgetKit 只支持原有 HTTP 路径的限制。

最后执行：

- 检查 `git diff`。
- 检查 `git status`。
- 检查 `.gitignore`。
- 执行可用的构建、测试及真机回归。
- 清除意外生成的密钥文件、日志和构建产物。
- 分别提交 Clocteck 与 macOS 项目的剩余文档和测试修改。
- 不提交与此次功能无关的工作区修改。

建议最终 Commit：

`docs(ble): document installation, testing and recovery`

---

## 最终验收标准

完成时必须满足：

1. Clocteck `wifi_guide` 未被修改。
2. Clocteck Firmware 未被修改，除非原有 API 经实测证明无法支持，并另行报告。
3. ActionCtrlHTTP 的 HTTP 接口完全兼容。
4. ActionCtrlBLE 可独立启动、停止和重新连接。
5. Clocteck 与 Mac 两端使用相同的可编辑明文 Token。
6. MacCtrlHTTP 支持 HTTP、BLE、Auto。
7. BLE Only 可独立操作 Launcher 和 2048。
8. HTTP 和 BLE 同时运行时无控制队列、去重或所有权冲突。
9. MacBook 校园网连接方式不需要改变。
10. 两端都已实际构建并执行适用测试；无法执行的真机测试需明确报告。
11. 两个 Git 工作区均有清晰的分阶段提交记录。

## Agent 执行规则

- 按 Step 1 → Step 11 执行，每完成一个步骤，勾选对应 checkbox。
- 每个步骤必须先实现、再测试，通过后再提交对应 Commit。
- 遇到 BLE API 限制、IPC 不支持、蓝牙权限或固件问题时，先记录实际错误和复现方法，不得默默绕过。
- 不得为了方便而修改 Wi-Fi 配网、停用现有 HTTP 服务或重写 Launcher。
- 能在 macOS 与设备之间执行实际测试时，应使用真实设备，不要仅依赖 Mock。
- 不要把调试用明文 Token 解释为安全认证机制。
- 最终报告给出修改文件清单、Commit SHA、测试结果、未解决问题和恢复方法。

