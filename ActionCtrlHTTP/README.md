# ActionCtrlHTTP

An auto-start HoloCubic Service that accepts authenticated HTTP `tap` commands
and publishes controller state on `ble-main`.

## Install

Copy `package/` to `/sd/apps/ActionCtrlHTTP/`, then rescan apps. The Service
starts automatically because `app.info` sets `autostart_service = true`.

Create `/sd/data/actionctrlhttp/config.json` on the device with a private token
of at least 32 characters:

```json
{
  "token": "<private-token>"
}
```

For example, generate a 32-byte token on macOS with
`openssl rand -hex 32`. Do not use `config.example.json` as a live token. Create
the `actionctrlhttp` data directory first if needed. The Service loads this
file at start; restart the Service after changing it.

## Security scope

This is a plain HTTP bearer-token check, not encrypted transport. The device's
DevTools also exposes unauthenticated SD-card file reads, so a LAN client may
read this config and recover the token. Use this only on a trusted WLAN; the
token prevents accidental requests, not a determined client on that network.

## HTTP API

Send `X-ActionCtrl-Token: <private-token>` on both endpoints.

```sh
curl -H "X-ActionCtrl-Token: $ACTIONCTRL_TOKEN" \
  http://<device-address>/remote/api/v1/status

curl -X POST -H "Content-Type: application/json" \
  -H "X-ActionCtrl-Token: $ACTIONCTRL_TOKEN" \
  --data '{"button":"left","request_id":"mac-001"}' \
  http://<device-address>/remote/api/v1/tap
```

`tap` returns `202` when queued. It does not wait for the foreground app to
finish the action. A request ID is remembered for the most recent 64 accepted
requests; repeating one returns `202` with `duplicate: true` and does not tap
again. The waiting queue holds up to 16 commands.

The Service publishes a 120 ms press, releases the button, and enforces at
least 500 ms between press starts. It uses a nonblocking 20 ms timer. The plan
specified a 400 ms minimum; live Launcher testing showed its 360 ms slide,
completion timer, and 40 ms input polling can drop a tap at that boundary.

## `ble-main` ownership

Only one Service may publish `ble-main`. The Service claims it on the first
accepted tap. If another publisher owns it, `tap` returns `409 Conflict` and
does not send a button state. It does not stop or take over that Service. It can
be installed and report status while hidpad owns the source, but button taps
will return `409` until `ble-main` is free.

Once ActionCtrlHTTP claims the source, another publisher cannot use it while
ActionCtrlHTTP is running. This manifest sets `autostart_service = true`; the
app manager relaunches a stopped persistent Service after about two seconds.
To switch to another `ble-main` publisher for an extended period, disable
`autostart_service` in the installed manifest or uninstall ActionCtrlHTTP.

The HTTP server is shared with other apps. This Service registers only its two
routes and unregisters those routes on stop; it never stops the shared server.
