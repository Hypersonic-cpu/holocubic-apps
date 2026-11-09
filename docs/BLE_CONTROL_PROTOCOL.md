# ActionCtrl BLE Control Protocol v1

This protocol carries the existing ActionCtrlHTTP button commands over BLE. It does not
change the HTTP API, Wi-Fi configuration, Launcher, or firmware.

## GATT layout

| Item | UUID | Properties | Direction |
|---|---|---|---|
| Control Service | `7d5e9a00-4eb4-47d1-b591-cc6e7ef6a100` | Primary service | — |
| Command | `7d5e9a01-4eb4-47d1-b591-cc6e7ef6a100` | Notify | Mac → HoloCubic |
| Response | `7d5e9a02-4eb4-47d1-b591-cc6e7ef6a100` | Write with response | HoloCubic → Mac |

The Mac is the GATT peripheral and the HoloCubic is the GATT central. The central must
discover the Command characteristic's CCCD and enable notifications before sending `auth`.
The Mac accepts one subscribed central at a time.

## JSON messages

Every message is UTF-8 JSON with `version: 1` and `type`. The maximum encoded message size
is 1024 bytes. `request_id` values are 1–64 UTF-8 bytes and are preserved across retries.

The HoloCubic sends this message over Response after notification subscription:

```json
{"version":1,"type":"auth","request_id":"ble-auth-1","token":"clocteck-ble-debug-2026"}
```

The Mac replies with `auth_ok` or `auth_failed`. `auth_ok` means the token matched, but is not
yet the Ready state. The HoloCubic confirms receipt with the same request ID:

```json
{"version":1,"type":"auth_confirm","request_id":"ble-auth-1"}
```

The Mac enters Ready only after receiving `auth_confirm`; the HoloCubic enters Ready after the
confirmation write completes. Only then may the session send `tap`, `status`, or `settings`.
A new BLE connection must authenticate again. This final confirmation prevents the Mac UI from
showing an authorized state merely because CoreBluetooth accepted an `auth_ok` notification into
its transmit queue.

```json
{"version":1,"type":"auth_ok","request_id":"ble-auth-1"}
{"version":1,"type":"auth_failed","request_id":"ble-auth-1","error":"token_mismatch"}
```

Mac-to-device button command:

```json
{"version":1,"type":"tap","request_id":"mac-ble-000001","button":"up","hold_ms":120}
```

`button` is one of `up`, `down`, `left`, `right`, `a`, `b`, `select`, `menu`, or `home`.
`hold_ms` is optional and follows ActionCtrlHTTP's 120–5000 ms validation; omission means
120 ms. `request_id` is required for BLE and is passed unchanged to ActionCtrlHTTP.

The device replies only after ActionCtrlHTTP has accepted or rejected the command:

```json
{"version":1,"type":"ack","request_id":"mac-ble-000001","ok":true,"queued":true}
```

An accepted duplicate is acknowledged with `queued:false, duplicate:true`. Rejection uses
`ok:false` and an `error` code such as `queue_full`, `source_busy`, `service_unavailable`,
`invalid_button`, or `invalid_hold_ms`.

Mac status request and device response:

```json
{"version":1,"type":"status","request_id":"mac-ble-status-1"}
{"version":1,"type":"status_result","request_id":"mac-ble-status-1","ok":true,"status":{"version":"0.4.0","source":"ble-main","queue_length":0,"queue_capacity":16,"phase":"idle","source_owned":false,"source_busy":false,"engine_ready":true}}
```

The existing queue capacity setting can also be synchronized over BLE without exposing an
arbitrary HTTP proxy:

```json
{"version":1,"type":"settings","request_id":"mac-ble-settings-1","queue_capacity":16}
{"version":1,"type":"settings_result","request_id":"mac-ble-settings-1","ok":true,"queue_capacity":16,"queue_length":0,"persisted":true}
```

The capacity must be an integer from 1 through 32 and is saved using ActionCtrlHTTP's existing
atomic configuration update path.

Other error messages use `{"version":1,"type":"error","request_id":"...","error":"..."}`.
Unknown types, unsupported versions, malformed JSON, oversized messages, and unauthenticated
control requests are rejected without publishing a button.

## GATT fragmentation

Each ATT value carries one frame. Its six-byte header is:

| Offset | Size | Meaning |
|---:|---:|---|
| 0 | 1 | Magic `0xC7` |
| 1 | 1 | Frame format version `1` |
| 2 | 2 | Message ID, unsigned big-endian |
| 4 | 1 | Zero-based fragment index |
| 5 | 1 | Fragment count, 1–255 |
| 6 | remaining | UTF-8 JSON bytes |

Maximum fragment data is `ATT_MTU - 3 - 6` bytes. At the default MTU 23 this is 14 bytes.
Peers may exchange a larger MTU, but must use the negotiated per-write/per-notify size and
must continue to accept the default MTU. A message of 1024 bytes fits in 74 fragments at
the default MTU.

Reassembly is per connection and direction. Fragments may arrive out of order and exact
duplicate fragments are ignored. Conflicting duplicates, invalid indices/counts, or a
message exceeding 1024 bytes discard that message. Keep at most four incomplete messages
per connection; expire them after five seconds and clear them on disconnect. JSON is parsed
only after all fragments are present and reassembled.

The Mac queues notifications and resumes when CoreBluetooth reports it is ready to update
subscribers. The HoloCubic serializes Write-with-response fragments and waits for
`IRQ_GATTC_WRITE_DONE` before sending the next frame.

## Authentication and retry semantics

The initial shared debug token is `clocteck-ble-debug-2026`. Each peer stores its own
editable plaintext configuration. This token is not encryption and does not protect against
radio eavesdropping, replay, or an active peer. Do not reuse the HTTP ActionCtrlHTTP token.
Never log the full BLE token. No random key generation or cryptographic claim is part of v1.

Auto transport uses the same `request_id` for an uncertain HTTP-to-BLE retry. ActionCtrlHTTP
owns the only queue, dedupe table, and `ble-main` publisher, so an HTTP and BLE retry with
the same ID can enqueue at most once.

## Local IPC contract

ActionCtrlBLE sends JSON on `actionctrlhttp-command` with topic `tap`, `status`, or `settings`, including
`reply_to:"blebridge-response"` and a unique `correlation_id`. ActionCtrlHTTP replies to
that endpoint with topic `result` and the same correlation ID only after processing the
request. `ipc.send()` success only means that IPC accepted the message for delivery; it is
not an action acknowledgment.
