local SERVICE_KEY = "ACTIONCTRLHTTP_SERVICE"
local SOURCE = "ble-main"
local SOURCE_NAME = "ActionCtrlHTTP"
local CONFIG_PATH = "/sd/data/actionctrlhttp/config.json"
local ROUTE_TAP = "/remote/api/v1/tap"
local ROUTE_STATUS = "/remote/api/v1/status"
local BODY_LIMIT = 1024
local TOKEN_MIN_LENGTH = 32
local TOKEN_MAX_LENGTH = 256
local REQUEST_ID_MAX_LENGTH = 64
local QUEUE_CAPACITY = 16
local DEDUPE_CAPACITY = 64
local ENGINE_TICK_MS = 20
local PRESS_MS = 120
local MIN_RELEASE_MS = 80
local TAP_INTERVAL_MS = 500

local BUTTONS = {
  up = 0x0001,
  down = 0x0002,
  left = 0x0004,
  right = 0x0008,
  a = 0x0010,
  b = 0x0020,
  select = 0x1000,
  menu = 0x2000,
  home = 0x8000,
}

local previous = rawget(_G, SERVICE_KEY)
local inherited_source = type(previous) == "table" and previous.owns_source == true
if previous and type(previous.stop) == "function" then
  pcall(previous.stop, "reload")
end

local APP = {
  version = "0.1.2",
  routes = {},
  queue = {},
  queue_head = 1,
  queue_tail = 0,
  seen_requests = {},
  seen_order = {},
  engine_timer = nil,
  owns_source = inherited_source,
  buttons = 0,
  phase = "idle",
  active_request_id = nil,
  active_button = nil,
  press_started_ms = nil,
  last_completed_request_id = nil,
  last_error = nil,
  stopped = false,
  clock_ms = 0,
}
_G[SERVICE_KEY] = APP

local JSON = rawget(_G, "json") or rawget(_G, "sjson")

local function log(message)
  print("[ActionCtrlHTTP] " .. tostring(message))
end

local function json_encode(value)
  if not JSON or type(JSON.encode) ~= "function" then
    return nil, "JSON encoder unavailable"
  end
  local ok, encoded = pcall(JSON.encode, value)
  if not ok or type(encoded) ~= "string" then
    return nil, "JSON encoding failed"
  end
  return encoded
end

local function response(status, payload)
  local encoded, err = json_encode(payload)
  if not encoded then
    status = "500 Internal Server Error"
    encoded = "{\"ok\":false,\"error\":\"json_encode_failed\"}"
    APP.last_error = err
  end
  return {
    status = status,
    type = "application/json; charset=utf-8",
    headers = {
      ["cache-control"] = "no-store",
      ["connection"] = "close",
    },
    body = encoded,
  }
end

local function load_token()
  if not file or type(file.getcontents) ~= "function" or not JSON or type(JSON.decode) ~= "function" then
    return nil, "config_api_unavailable"
  end
  local read_ok, raw = pcall(file.getcontents, CONFIG_PATH)
  if not read_ok or type(raw) ~= "string" or raw == "" then
    return nil, "config_missing"
  end
  local decode_ok, config = pcall(JSON.decode, raw)
  if not decode_ok or type(config) ~= "table" then
    return nil, "config_invalid_json"
  end
  local token = config.token
  if type(token) ~= "string" or #token < TOKEN_MIN_LENGTH or #token > TOKEN_MAX_LENGTH then
    return nil, "config_invalid_token"
  end
  return token
end

APP.token, APP.config_error = load_token()

local function constant_time_equal(a, b)
  if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then
    return false
  end
  local diff = 0
  for i = 1, #a do
    if a:byte(i) ~= b:byte(i) then diff = 1 end
  end
  return diff == 0
end

local function request_header(req, wanted_name)
  local headers = req and req.headers
  if headers == nil then return nil end
  -- NodeMCU HTTPD exposes a table-like header lookup object. It cannot be
  -- iterated with pairs(); look up the normalized lowercase field directly.
  local ok, value = pcall(function() return headers[wanted_name:lower()] end)
  if not ok or type(value) ~= "string" then return nil end
  return value:match("^%s*(.-)%s*$")
end

local function authenticate(req)
  if not APP.token then
    return false, response("503 Service Unavailable", {
      ok = false,
      error = "configuration_required",
      detail = APP.config_error,
    })
  end
  local supplied = request_header(req, "X-ActionCtrl-Token")
  if not constant_time_equal(supplied, APP.token) then
    return false, response("401 Unauthorized", { ok = false, error = "authentication_failed" })
  end
  return true
end

local function now_ms()
  local read_millis = rawget(_G, "millis")
  if type(read_millis) == "function" then
    local ok, value = pcall(read_millis)
    value = ok and tonumber(value) or nil
    if value then return math.floor(value) end
  end
  return APP.clock_ms
end

local function elapsed_ms(started, current)
  local delta = current - started
  if delta < 0 then delta = delta + 4294967296 end
  return delta
end

local function make_state(button_bits, connected)
  return {
    connected = connected ~= false,
    buttons = button_bits or 0,
    lx = 0, ly = 0, rx = 0, ry = 0,
    lt = 0, rt = 0,
    name = SOURCE_NAME,
    device_id = "actionctrl-http",
  }
end

local function source_list_contains(sources, target)
  if type(sources) ~= "table" then return false end
  for key, value in pairs(sources) do
    if type(value) == "string" and value == target then return true end
    if type(value) == "table" then
      if value.source == target or value.id == target or value.name == target then return true end
    end
    if key == target and value then return true end
  end
  return false
end

local function inspect_source()
  if not controller or type(controller.sources) ~= "function" then
    return nil, "controller_sources_unavailable"
  end
  local sources_ok, sources = pcall(controller.sources)
  if not sources_ok or type(sources) ~= "table" then
    return nil, "controller_sources_failed"
  end
  local present = source_list_contains(sources, SOURCE)
  local state = nil
  if type(controller.state) == "function" then
    local state_ok, value = pcall(controller.state, SOURCE)
    if state_ok and type(value) == "table" then state = value end
  end
  local busy = false
  if not APP.owns_source then
    if state and state.connected == true then
      busy = true
    elseif present and not state then
      busy = true
    end
  end
  return {
    present = present,
    busy = busy,
    state = state,
  }
end

local function publish_state(button_bits, connected)
  if not controller or type(controller.publish) ~= "function" then
    return false, "controller_publish_unavailable"
  end
  local ok, result, err = pcall(controller.publish, SOURCE, make_state(button_bits, connected))
  if not ok then return false, tostring(result) end
  if result == false or (result == nil and err ~= nil) then
    return false, tostring(err or "publish_rejected")
  end
  if result == nil then
    local inspected = inspect_source()
    local state = inspected and inspected.state
    if not state or state.name ~= SOURCE_NAME then
      return false, "publish_unconfirmed"
    end
  end
  APP.buttons = button_bits or 0
  APP.owns_source = connected ~= false
  return true
end

local function looks_like_ownership_error(message)
  message = tostring(message or ""):lower()
  return message:find("busy", 1, true) ~= nil
    or message:find("owner", 1, true) ~= nil
    or message:find("claimed", 1, true) ~= nil
    or message:find("in use", 1, true) ~= nil
    or (message:find("source", 1, true) ~= nil and message:find("already", 1, true) ~= nil)
end

local function ensure_source()
  if APP.owns_source then return true end
  local inspected, inspect_err = inspect_source()
  if not inspected then return false, "controller_unavailable", inspect_err end
  if inspected.busy then return false, "source_busy" end

  local ok, result, err = pcall(controller.publish, SOURCE, make_state(0, true))
  if not ok then
    local after = inspect_source()
    if after and after.busy or looks_like_ownership_error(result) then
      return false, "source_busy", tostring(result)
    end
    return false, "publish_failed", tostring(result)
  end
  if result == false or (result == nil and err ~= nil) then
    local after = inspect_source()
    if after and (after.busy or after.present) or looks_like_ownership_error(err) then
      return false, "source_busy", tostring(err or "source_busy")
    end
    return false, "publish_failed", tostring(err or "publish_rejected")
  end

  if result == nil then
    local after, after_err = inspect_source()
    local state = after and after.state
    if not after or not state or state.name ~= SOURCE_NAME then
      if after and (after.busy or after.present) then
        return false, "source_busy", after_err
      end
      return false, "publish_unconfirmed", after_err
    end
  end
  APP.owns_source = true
  APP.buttons = 0
  return true
end

local function current_source_busy()
  local inspected = inspect_source()
  if not inspected then return nil end
  return inspected.busy
end

local function queue_length()
  if APP.queue_tail < APP.queue_head then return 0 end
  return APP.queue_tail - APP.queue_head + 1
end

local function queue_push(command)
  APP.queue_tail = APP.queue_tail + 1
  APP.queue[APP.queue_tail] = command
end

local function queue_pop()
  if APP.queue_tail < APP.queue_head then return nil end
  local command = APP.queue[APP.queue_head]
  APP.queue[APP.queue_head] = nil
  APP.queue_head = APP.queue_head + 1
  if APP.queue_head > APP.queue_tail then
    APP.queue_head = 1
    APP.queue_tail = 0
  end
  return command
end

local function queue_clear()
  APP.queue = {}
  APP.queue_head = 1
  APP.queue_tail = 0
end

local function was_seen(request_id)
  return request_id ~= nil and APP.seen_requests[request_id] == true
end

local function remember_request(request_id)
  if not request_id then return end
  APP.seen_requests[request_id] = true
  APP.seen_order[#APP.seen_order + 1] = request_id
  if #APP.seen_order > DEDUPE_CAPACITY then
    local expired = table.remove(APP.seen_order, 1)
    APP.seen_requests[expired] = nil
  end
end

local function service_exiting()
  if not app or type(app.exiting) ~= "function" then return false end
  local ok, value = pcall(app.exiting)
  return ok and value == true
end

local function unregister_routes()
  if not httpd or type(httpd.unregister) ~= "function" then
    APP.routes = {}
    return
  end
  for i = #APP.routes, 1, -1 do
    local item = APP.routes[i]
    pcall(httpd.unregister, item.method, item.route)
  end
  APP.routes = {}
end

local function stop_timers()
  if APP.engine_timer then
    pcall(function() APP.engine_timer:stop() end)
    pcall(function() APP.engine_timer:unregister() end)
    APP.engine_timer = nil
  end
end

function APP.stop(reason)
  if APP.stopped then return end
  APP.stopped = true
  stop_timers()
  if APP.owns_source then
    -- Explicitly release any held button; the runtime marks the source disconnected on exit.
    local released, release_error = publish_state(0, true)
    if not released then APP.last_error = "release_on_stop_failed: " .. tostring(release_error) end
  end
  APP.phase = "idle"
  APP.active_request_id = nil
  APP.active_button = nil
  queue_clear()
  unregister_routes()
  if rawget(_G, SERVICE_KEY) == APP then rawset(_G, SERVICE_KEY, nil) end
  log("stopped: " .. tostring(reason or ""))
end

local function fail_engine(reason)
  APP.last_error = tostring(reason or "engine_error")
  queue_clear()
  APP.active_request_id = nil
  APP.active_button = nil
  APP.phase = "fault"
  if APP.owns_source then
    local released = publish_state(0, true)
    if not released and app and type(app.exit) == "function" then
      pcall(app.exit)
    end
  end
  log("engine fault: " .. APP.last_error)
end

local function start_next_command(now)
  local command = queue_pop()
  if not command then return end
  local bits = BUTTONS[command.button]
  if not bits then
    APP.last_error = "queued_button_invalid"
    APP.last_completed_request_id = command.request_id
    return
  end
  local ok, err = publish_state(bits, true)
  if not ok then
    fail_engine(err)
    return
  end
  APP.phase = "pressed"
  APP.active_request_id = command.request_id
  APP.active_button = command.button
  APP.press_started_ms = now
  APP.last_error = nil
end

local function engine_tick()
  if APP.stopped then return end
  if service_exiting() then APP.stop("service_exit"); return end
  -- Keep a fallback clock advancing even if millis() is unavailable or fails.
  APP.clock_ms = APP.clock_ms + ENGINE_TICK_MS
  if APP.phase == "fault" then return end

  local now = now_ms()
  if APP.phase == "pressed" and elapsed_ms(APP.press_started_ms, now) >= PRESS_MS then
    local released, err = publish_state(0, true)
    if not released then fail_engine(err); return end
    APP.phase = "release_wait"
  end

  if APP.phase == "release_wait" and elapsed_ms(APP.press_started_ms, now) >= math.max(TAP_INTERVAL_MS, PRESS_MS + MIN_RELEASE_MS) then
    APP.last_completed_request_id = APP.active_request_id
    APP.active_request_id = nil
    APP.active_button = nil
    APP.phase = "idle"
  end

  if APP.phase == "idle" and queue_length() > 0 then
    start_next_command(now)
  end
end

local function read_request_body(req)
  if not req or type(req.getbody) ~= "function" then return nil, "body_unavailable" end
  local chunks, total, oversized = {}, 0, false
  while true do
    local ok, chunk = pcall(req.getbody)
    if not ok then return nil, "body_read_failed" end
    if chunk == nil or chunk == "" then break end
    if type(chunk) ~= "string" then return nil, "body_invalid" end
    total = total + #chunk
    if total > BODY_LIMIT then
      oversized = true
    elseif not oversized then
      chunks[#chunks + 1] = chunk
    end
  end
  if oversized then return nil, "body_too_large" end
  return table.concat(chunks)
end

local function decode_command(raw)
  if not JSON or type(JSON.decode) ~= "function" then return nil, "json_decoder_unavailable" end
  local ok, value = pcall(JSON.decode, raw)
  if not ok or type(value) ~= "table" then return nil, "invalid_json" end
  if type(value.button) ~= "string" then return nil, "button_required" end
  local button = value.button:lower()
  if not BUTTONS[button] then return nil, "invalid_button" end
  local request_id = value.request_id
  if request_id ~= nil then
    if type(request_id) ~= "string" or #request_id == 0 or #request_id > REQUEST_ID_MAX_LENGTH then
      return nil, "invalid_request_id"
    end
  end
  return { button = button, request_id = request_id }
end

local function status_handler(req)
  if APP.stopped then return response("503 Service Unavailable", { ok = false, error = "service_stopped" }) end
  local authenticated, auth_response = authenticate(req)
  if not authenticated then return auth_response end
  local busy = current_source_busy()
  local status = {
    ok = true,
    source = SOURCE,
    buttons = APP.buttons,
    queue_length = queue_length(),
    phase = APP.phase,
    source_owned = APP.owns_source,
    source_busy = busy,
    engine_ready = APP.engine_timer ~= nil,
    last_error = APP.last_error,
  }
  if APP.active_request_id then status.active_request_id = APP.active_request_id end
  if APP.last_completed_request_id then status.last_completed_request_id = APP.last_completed_request_id end
  return response("200 OK", status)
end

local function tap_handler(req)
  if APP.stopped then return response("503 Service Unavailable", { ok = false, error = "service_stopped" }) end
  local authenticated, auth_response = authenticate(req)
  if not authenticated then return auth_response end
  if APP.phase == "fault" then
    return response("503 Service Unavailable", {
      ok = false,
      error = "controller_engine_fault",
      detail = APP.last_error,
    })
  end
  if not APP.engine_timer then
    return response("503 Service Unavailable", { ok = false, error = "timer_unavailable" })
  end

  local body, body_error = read_request_body(req)
  if not body then
    local status = body_error == "body_too_large" and "413 Payload Too Large" or "400 Bad Request"
    return response(status, { ok = false, error = body_error })
  end
  local command, command_error = decode_command(body)
  if not command then
    return response("400 Bad Request", { ok = false, error = command_error })
  end

  if was_seen(command.request_id) then
    return response("202 Accepted", {
      ok = true,
      request_id = command.request_id,
      queued = false,
      duplicate = true,
    })
  end
  if queue_length() >= QUEUE_CAPACITY then
    return response("429 Too Many Requests", { ok = false, error = "queue_full", request_id = command.request_id })
  end

  local acquired, acquire_error, detail = ensure_source()
  if not acquired then
    local status = acquire_error == "source_busy" and "409 Conflict" or "503 Service Unavailable"
    local payload = { ok = false, error = acquire_error }
    if detail then payload.detail = detail end
    if command.request_id then payload.request_id = command.request_id end
    return response(status, payload)
  end

  queue_push(command)
  remember_request(command.request_id)
  return response("202 Accepted", {
    ok = true,
    request_id = command.request_id,
    queued = true,
  })
end

local function register_route(method, path, handler)
  if not httpd or type(httpd.dynamic) ~= "function" then return false, "httpd_dynamic_unavailable" end
  local ok, err = pcall(httpd.dynamic, method, path, handler)
  if not ok then return false, tostring(err) end
  -- httpd.dynamic returns nil on success and an error string on failure.
  if err ~= nil then return false, tostring(err) end
  APP.routes[#APP.routes + 1] = { method = method, route = path }
  return true
end

local function start_http()
  if not httpd or type(httpd.start) ~= "function" or type(httpd.dynamic) ~= "function" then
    return false, "httpd_unavailable"
  end
  local server_ok, server_result = pcall(httpd.start, {
    webroot = "/sd",
    auto_index = httpd.INDEX_NONE,
    -- Match the Launcher's shared HTTP server capacity.
    max_handlers = 256,
  })
  if not server_ok or server_result then
    -- The server may already be running; route registration below is the
    -- authoritative check that this Service can attach without stopping it.
    log("httpd.start reported: " .. tostring(server_result))
  end
  local get_method = httpd.GET or "GET"
  local post_method = httpd.POST or "POST"
  local ok, err = register_route(post_method, ROUTE_TAP, tap_handler)
  if not ok then return false, err end
  ok, err = register_route(get_method, ROUTE_STATUS, status_handler)
  if not ok then
    unregister_routes()
    return false, err
  end
  return true
end

local function start_engine()
  if not tmr or type(tmr.create) ~= "function" then return false, "timer_unavailable" end
  local ok, timer = pcall(tmr.create)
  if not ok or not timer then return false, "timer_create_failed" end
  local alarm_ok, alarm_error = pcall(function()
    timer:alarm(ENGINE_TICK_MS, tmr.ALARM_AUTO, engine_tick)
  end)
  if not alarm_ok then
    pcall(function() timer:unregister() end)
    return false, tostring(alarm_error)
  end
  APP.engine_timer = timer
  return true
end

local http_ok, http_error = start_http()
if not http_ok then
  APP.last_error = "http_start_failed: " .. tostring(http_error)
  log(APP.last_error)
end

local engine_ok, engine_error = start_engine()
if not engine_ok then
  APP.last_error = APP.last_error or ("engine_start_failed: " .. tostring(engine_error))
  log(APP.last_error)
end

if not APP.token then
  log("token config required at " .. CONFIG_PATH)
end
if APP.owns_source then
  -- Keep the inherited source neutral across an in-place reload.
  local ok, err = publish_state(0, true)
  if not ok then
    APP.owns_source = false
    APP.last_error = "source_reload_failed: " .. tostring(err)
    log(APP.last_error)
  end
end

return APP
