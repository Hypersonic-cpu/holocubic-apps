# ActionCtrlBLE

`ActionCtrlBLE` is an autostart background Service that connects the HoloCubic as a BLE
central to the MacCtrlHTTP BLE peripheral. It forwards authenticated button commands and
status requests to `ActionCtrlHTTP` over local IPC. `ActionCtrlHTTP` remains the only owner
of the button FIFO, request dedupe, timing engine, and `ble-main` publisher.

## Install and configure

Install the `ActionCtrlBLE` app package under `/sd/apps/ActionCtrlBLE`, then rescan apps or
restart the Service. It does not replace or change the Launcher, Wi-Fi guide, firmware, or
HTTP ActionCtrlHTTP routes.

On its first start, the Service creates:

`/sd/data/blebridge/config.json`

The initial file uses the v1 debug token `clocteck-ble-debug-2026`. Both peers must use the
same exact token. This is plaintext debug authentication, not encryption. Edit the `token`
field in the file and restart `ActionCtrlBLE` to apply a change. The Service never logs the
token.

To disable BLE without removing the HTTP service, set `enabled` or `auto_connect` to `false`
and restart the Service. To stop it temporarily, use Settings → Services or call
`app.stop_service("ActionCtrlBLE")` from a trusted Lua tool. HTTP stays available.

## Operation

The Service scans for the fixed Control Service UUID, connects, discovers both
characteristics, finds the Command CCCD, subscribes to notifications, and authenticates.
Reconnect attempts use exponential backoff from 1 to 30 seconds. BLE messages use the
fragment format in [`docs/BLE_CONTROL_PROTOCOL.md`](../docs/BLE_CONTROL_PROTOCOL.md).

Authentication is a two-way handshake: the Mac replies `auth_ok`, then this Service writes
`auth_confirm` and waits for the Write With Response completion before entering Ready. Only
then does it forward `tap`, `status`, and `settings` messages to `actionctrlhttp-command`. It
waits for an actual IPC `result` from ActionCtrlHTTP before notifying the Mac. Neither a queued
BLE notification nor an IPC send acceptance is reported as a completed authentication or tap.

## Diagnostics and recovery

Serial logs use the `[ActionCtrlBLE]` prefix and omit token contents. A confirmed session logs
`BLE session authorized and confirmed`; disconnect logs include the current connection handle
and state but omit the peer address. Stale disconnect IRQs are ignored. Repeated
`required_lua_ble_api_unavailable`,
`ble_irq_failed`, or characteristic discovery errors indicate an onboard BLE API or GATT
compatibility issue; do not work around those errors by modifying firmware silently.

The Service does not publish `ble-main` and does not stop ActionCtrlHTTP after a BLE failure.
Removing `/sd/apps/ActionCtrlBLE` or setting `enabled:false` returns the device to the
existing HTTP-only control path.
