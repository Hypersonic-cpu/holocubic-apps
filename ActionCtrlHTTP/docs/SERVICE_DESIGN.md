# ActionCtrlHTTP — Service Design

## 1. 目标

实现一个 HoloCubic ESP32-S3 后台 Service，通过局域网 HTTP 请求模拟手柄按键，从而使用 macOS 控制 HoloCubic。

**要求：**
- 不修改固件、默认 Launcher 或现有应用。
- 不依赖蓝牙手柄及原有 hidpad Service。
- Service 开机自启动，在其他应用运行时持续工作。
- 复用现有 `controller.publish("ble-main", ...)` 接口。
- 支持 Launcher 导航、启动应用及操作 2048。
- 本项目只实现 ESP32 端，不开发 macOS 客户端。

参考源码：
- `launcher/package/main.lua`
- `2048/package/main.lua`
- `README_LUA.md`

## 2. 架构

通信流程：

`macOS → HTTP → ActionCtrlHTTP Service → controller.publish("ble-main") → Launcher / 2048`

Service 使用 `httpd.dynamic()` 注册 HTTP 路由，通过定时器模拟手柄状态变化。

Launcher 和 2048 每 40 ms 读取一次 `controller.state("ble-main")`，并根据按钮上升沿触发操作。

## 3. HTTP 协议

### 3.1 按键指令

`POST /remote/api/v1/tap`

请求：

```json
{
  "button": "left",
  "request_id": "mac-001"
}
```

`request_id` 可选，用于请求去重。

正常响应：HTTP 202 Accepted

```json
{
  "ok": true,
  "request_id": "mac-001",
  "queued": true
}
```

202 仅代表 Service 接受指令，不代表前台应用完成操作。

支持以下按键：

| Button | Bitmask | 用途 |
|---|---|---|
| up | 0x0001 | 上 |
| down | 0x0002 | 下 |
| left | 0x0004 | 左 |
| right | 0x0008 | 右 |
| a | 0x0010 | 确认 / 启动应用 |
| b | 0x0020 | 应用内返回（视应用支持） |
| select | 0x1000 | 2048 退出 |
| menu | 0x2000 | 确认 / 启动 |
| home | 0x8000 | 2048 退出 |

### 3.2 状态查询

`GET /remote/api/v1/status`

响应：

```json
{
  "ok": true,
  "source": "ble-main",
  "buttons": 0,
  "queue_length": 0
}
```

用于检查 Service 运行状态、当前按钮状态和待处理队列长度。

### 3.3 错误处理

- 400：非法按钮或参数
- 401：认证失败
- 409：`ble-main` 已被其他 Service 占用
- 429：指令队列已满

使用可配置的 `X-ActionCtrl-Token` 请求头进行简单认证，避免局域网内未经授权的控制。

## 4. 按键状态机

**HTTP 只传递 `tap` 指令，不要求客户端发送 `press/release`。**

Service 内部执行：

1. 从 FIFO 队列获取指令。
2. 发布 `buttons = 指定 bitmask`，模拟 Press。
3. 保持 120 ms。
4. 发布 `buttons = 0`，模拟 Release。
5. 保证至少 80 ms 松开时间。
6. 处理下一条指令。

由于 Launcher 切换动画为 360 ms，结束定时器另有 30 ms，且按键每 40 ms 轮询一次，实测 400 ms 边界可能吞掉连续点击中的第二个方向键。当前实现将相邻按键启动间隔提高到 500 ms；这高于原计划的 400 ms 下限，也覆盖 2048 约 280 ms 的滑动动画。

实现要求：

- 使用 `tmr` 非阻塞定时器，不使用 busy-wait。
- 默认每次只按一个按钮。
- 使用 FIFO 队列，队列容量暂定 16。
- 支持 `request_id` 去重，避免 HTTP 重试导致重复操作。
- 退出或异常时确保所有按钮释放。
- 不需要自定义 `pressed/released` 字段，由 controller API 自动计算。
- 第一版不实现长按、持续按住或组合键。

## 5. 实现步骤

### Step 1 — 创建 Service

在 `ActionCtrlHTTP/package/` 中实现：

- `app.info`：`kind = service`、`autostart_service = true`。
- `main.lua`：Service 入口和资源管理。
- 按需拆分 HTTP Handler、按键状态机及配置模块。

### Step 2 — 实现 Controller Publisher

- 使用 `controller.publish("ble-main", state)`。
- 设置 `connected = true` 和标准按钮 bitmask。
- 不使用 BLE API。
- 检查 `ble-main` 的发布权限及所有权冲突，不能抢占其他 Service。
- Service 停止时释放所有按钮及控制源。

### Step 3 — 实现状态机与 FIFO

- 接收按键命令并加入队列。
- 按 120 ms Press、Release、至少 500 ms 点击起始间隔处理（实测 Launcher 动画后调整；原计划为 400 ms 下限）。
- 实现状态查询、队列上限和请求去重。
- 保证连续相同按键也能产生独立上升沿。

### Step 4 — 实现 HTTP Server

- 注册 `/remote/api/v1/tap` 和 `/remote/api/v1/status`。
- 实现 JSON 解析、参数验证、认证和状态码。
- HTTP Handler 不阻塞等待按键执行。
- 复用系统 HTTP 服务，不影响已有路由。
- Service 退出时注销自身路由，不停止其他应用共享的 HTTP 服务。

### Step 5 — 验证功能

使用 macOS `curl` 直接测试 HTTP 接口：

1. GET `status`，验证 Service 正常运行。
2. 在 Launcher 发送 `left/right`，检查应用切换。
3. 发送 `a`，检查应用启动。
4. 进入 2048，依次发送四方向指令。
5. 连续发送相同方向，验证每次均产生独立按键事件。
6. 使用 `home` 返回 Launcher。
7. 测试错误请求、队列满、重复请求及 Service 重启。
8. 验证前台应用运行期间 HTTP 接口持续可用。

## 6. 验收标准

- 无需修改 Launcher、2048 或固件。
- 无需安装 hidpad，不需要真实手柄。
- 能通过 HTTP 完成 Launcher 和 2048 的基本操作。
- 连续相同按键不会丢失上升沿。
- Service 不阻塞前台应用，也不会影响已有 HTTP 服务。
- Service 可自动启动、正常停止并释放资源。

**不在第一版范围内：** macOS GUI、长按/组合键、游戏操作完成 ACK、游戏状态读取及通用应用按键映射适配。

## 7. 实现与真机验证记录

- 实现版本：`0.1.2`。真机确认 `req.headers` 是 table-like 查找对象，不能用 `pairs()` 枚举；认证改为按小写字段名索引。
- 计划的 400 ms 最小间隔在 Launcher 动画边界可能丢掉连续方向键。Launcher 动画为 360 ms，结束计时器另有 30 ms，控制器轮询为 40 ms；实现改为 500 ms。真机验证连续 Left→Right 后两次移动均显示。
- Firmware 1.213 真机验证：有效 token 的状态请求 200；缺失/错误 token 为 401；非法 JSON/按钮为 400；超长请求体为 413；队列满返回 429，17 条接受后第 18 条被拒绝，队列排空且按钮归零。
- 真机操作验证：Launcher 的 A 启动 2048；2048 的上、下、左、右及重复左键都被接受，Home 返回 Launcher；运行 2048 时 HTTP Service 仍可用。
- Service 重启 API 返回成功；重启后路由短暂返回一次 404，稍后状态路由恢复 200，队列为空且按钮归零。
- 安全限制：HTTP 不加密；设备 DevTools 的 SD 文件读取接口未认证。因此 token 仅作为可信 WLAN 上的请求门槛，不能防止同网段客户端读取 token 或监听请求。

