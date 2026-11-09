local SERVICE_KEY = "ACTIONCTRLBLE_SERVICE"
local CONFIG_DIR = "/sd/data/blebridge"
local CONFIG_PATH = CONFIG_DIR .. "/config.json"
local IPC_COMMAND_ENDPOINT = "actionctrlhttp-command"
local IPC_REPLY_ENDPOINT = "blebridge-response"
local DEFAULT_TOKEN = "clocteck-ble-debug-2026"
local SERVICE_UUID = "7d5e9a00-4eb4-47d1-b591-cc6e7ef6a100"
local COMMAND_UUID = "7d5e9a01-4eb4-47d1-b591-cc6e7ef6a100"
local RESPONSE_UUID = "7d5e9a02-4eb4-47d1-b591-cc6e7ef6a100"
local FRAME_MAGIC = 0xC7
local FRAME_VERSION = 1
local FRAME_HEADER_SIZE = 6
local DEFAULT_MTU = 23
local MAX_MESSAGE_SIZE = 1024
local REQUEST_ID_MAX_LENGTH = 64
local SCAN_DURATION_MS = 30000
local CONNECT_TIMEOUT_MS = 7000
local AUTH_TIMEOUT_MS = 10000
local IPC_TIMEOUT_MS = 5000
local TICK_MS = 500
local RETRY_MIN_MS = 1000
local RETRY_MAX_MS = 30000
local FRAGMENT_TIMEOUT_MS = 5000
local MAX_INCOMPLETE_MESSAGES = 4

local IRQ_SCAN_RESULT = 5
local IRQ_SCAN_DONE = 6
local IRQ_PERIPHERAL_CONNECT = 7
local IRQ_PERIPHERAL_DISCONNECT = 8
local IRQ_GATTC_SERVICE_RESULT = 9
local IRQ_GATTC_SERVICE_DONE = 10
local IRQ_GATTC_CHARACTERISTIC_RESULT = 11
local IRQ_GATTC_CHARACTERISTIC_DONE = 12
local IRQ_GATTC_DESCRIPTOR_RESULT = 13
local IRQ_GATTC_DESCRIPTOR_DONE = 14
local IRQ_GATTC_WRITE_DONE = 17
local IRQ_GATTC_NOTIFY = 18
local IRQ_MTU_EXCHANGED = 21

local BLE = rawget(_G, "ble")
local JSON = rawget(_G, "json") or rawget(_G, "sjson")

local previous = rawget(_G, SERVICE_KEY)
if previous and type(previous.stop) == "function" then
  pcall(previous.stop, "reload")
end

local APP = {
  version = "0.1.1",
  state = "disabled",
  config = nil,
  config_error = nil,
  stopped = false,
  owns_ble = false,
  ipc_listening = false,
  timer = nil,
  conn = nil,
  addr = nil,
  addr_type = nil,
  service_start = nil,
  service_end = nil,
  command_handle = nil,
  command_end_handle = nil,
  descriptor_start_handle = nil,
  descriptor_end_handle = nil,
  command_properties = 0,
  response_handle = nil,
  response_properties = 0,
  cccd_handle = nil,
  mtu = DEFAULT_MTU,
  write_queue = {},
  active_write = nil,
  assemblers = {},
  pending_ipc = {},
  clock_ms = 0,
  scan_deadline_ms = nil,
  connect_deadline_ms = nil,
  auth_deadline_ms = nil,
  auth_request_id = nil,
  next_scan_ms = 0,
  retry_ms = RETRY_MIN_MS,
  next_message_id = 1,
  next_request_id = 1,
}
_G[SERVICE_KEY] = APP

local function log(message)
  print("[ActionCtrlBLE] " .. tostring(message))
end

local function json_encode(value)
  if not JSON or type(JSON.encode) ~= "function" then return nil, "json_encoder_unavailable" end
  local ok, encoded = pcall(JSON.encode, value)
  if not ok or type(encoded) ~= "string" then return nil, "json_encode_failed" end
  return encoded
end

local function json_decode(value)
  if type(value) ~= "string" or not JSON or type(JSON.decode) ~= "function" then return nil end
  local ok, decoded = pcall(JSON.decode, value)
  if ok and type(decoded) == "table" then return decoded end
  return nil
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

local function read_config()
  if not file or type(file.getcontents) ~= "function" then return nil, "config_read_unavailable" end
  local ok, raw = pcall(file.getcontents, CONFIG_PATH)
  if ok and type(raw) == "string" and raw ~= "" then
    local config = json_decode(raw)
    if type(config) ~= "table" then return nil, "config_invalid_json" end
    if type(config.enabled) ~= "boolean"
        or type(config.token) ~= "string" or #config.token < 1 or #config.token > 256
        or type(config.auto_connect) ~= "boolean" then
      return nil, "config_invalid_fields"
    end
    return config
  end

  local config = {
    enabled = true,
    device_name = "Clocteck",
    token = DEFAULT_TOKEN,
    auto_connect = true,
  }
  if file.mkdir then pcall(file.mkdir, CONFIG_DIR) end
  if file.putcontents then
    local encoded = json_encode(config)
    if encoded then
      local write_ok, result = pcall(file.putcontents, CONFIG_PATH, encoded)
      if not write_ok or result ~= true then
        return nil, "config_initialize_failed"
      end
    else
      return nil, "json_encoder_unavailable"
    end
  else
    return nil, "config_write_unavailable"
  end
  log("created default config at " .. CONFIG_PATH .. " (edit token there; token omitted from logs)")
  return config
end

local function uuid_hex(value)
  local text = tostring(value or ""):lower():gsub("[%{%}%-%s]", "")
  text = text:gsub("^uuid%d*%(", ""):gsub("%)$", "")
  text = text:gsub("^0x", "")
  return text
end

local function uuid_matches(value, expected)
  if type(value) == "number" and #expected == 4 then
    return value == tonumber(expected, 16)
  end
  local actual = uuid_hex(value)
  local wanted = uuid_hex(expected)
  return actual == wanted or (expected == "00002902" and actual == "2902")
end

local function get_field(data, key, index)
  if type(data) ~= "table" then return nil end
  local value = data[key]
  if value == nil and index then value = data[index] end
  return value
end

local function uuid_little_endian_bytes(uuid)
  local hex = uuid_hex(uuid)
  if #hex ~= 32 then return nil end
  local bytes = {}
  for i = 1, 32, 2 do
    local byte = tonumber(hex:sub(i, i + 1), 16)
    if not byte then return nil end
    bytes[#bytes + 1] = string.char(byte)
  end
  local reversed = {}
  for i = #bytes, 1, -1 do reversed[#reversed + 1] = bytes[i] end
  return table.concat(reversed)
end

local SERVICE_UUID_BYTES = uuid_little_endian_bytes(SERVICE_UUID)

local function advertisement_has_service(raw)
  if type(raw) ~= "string" or not SERVICE_UUID_BYTES then return false end
  local offset = 1
  while offset <= #raw do
    local field_length = raw:byte(offset)
    if not field_length or field_length == 0 then break end
    local field_end = offset + field_length
    if field_end > #raw + 1 then break end
    local ad_type = raw:byte(offset + 1)
    if ad_type == 0x06 or ad_type == 0x07 then
      local start = offset + 2
      local value_end = field_end
      while start + 15 <= value_end do
        if raw:sub(start, start + 15) == SERVICE_UUID_BYTES then return true end
        start = start + 16
      end
    end
    offset = field_end + 1
  end
  return false
end

local function next_id(prefix)
  local id = tostring(prefix) .. "-" .. tostring(now_ms()) .. "-" .. tostring(APP.next_request_id)
  APP.next_request_id = APP.next_request_id + 1
  return id
end

local function clear_link_state()
  APP.conn = nil
  APP.addr = nil
  APP.addr_type = nil
  APP.service_start = nil
  APP.service_end = nil
  APP.command_handle = nil
  APP.command_end_handle = nil
  APP.descriptor_start_handle = nil
  APP.descriptor_end_handle = nil
  APP.command_properties = 0
  APP.response_handle = nil
  APP.response_properties = 0
  APP.cccd_handle = nil
  APP.mtu = DEFAULT_MTU
  APP.write_queue = {}
  APP.active_write = nil
  APP.assemblers = {}
  APP.pending_ipc = {}
  APP.scan_deadline_ms = nil
  APP.connect_deadline_ms = nil
  APP.auth_deadline_ms = nil
  APP.auth_request_id = nil
  APP.write_purpose = nil
end

local function schedule_scan_retry(reason)
  if APP.stopped or not APP.config or not APP.config.enabled or not APP.config.auto_connect then return end
  APP.state = "disconnected"
  clear_link_state()
  APP.next_scan_ms = now_ms() + APP.retry_ms
  log("will rescan in " .. tostring(APP.retry_ms) .. " ms: " .. tostring(reason))
  APP.retry_ms = math.min(APP.retry_ms * 2, RETRY_MAX_MS)
end

local function fail_link(reason)
  log("link error: " .. tostring(reason))
  if APP.conn and BLE and type(BLE.gap_disconnect) == "function" then
    pcall(BLE.gap_disconnect, APP.conn)
  end
  schedule_scan_retry(reason)
end

local function scan()
  if APP.stopped or not APP.config or not APP.config.enabled or not APP.config.auto_connect then return end
  if APP.conn or APP.state == "connecting" or APP.state == "discovering"
      or APP.state == "subscribing" or APP.state == "authorizing" or APP.state == "ready" then
    return
  end
  if not BLE or type(BLE.gap_scan) ~= "function" then
    APP.state = "error"
    APP.config_error = "ble_scan_unavailable"
    log(APP.config_error)
    return
  end
  local ok, result, err = pcall(BLE.gap_scan, SCAN_DURATION_MS)
  if not ok or result == false or (result == nil and err ~= nil) then
    APP.state = "error"
    APP.config_error = "ble_scan_failed: " .. tostring(err or result)
    log(APP.config_error)
    APP.next_scan_ms = now_ms() + APP.retry_ms
    APP.retry_ms = math.min(APP.retry_ms * 2, RETRY_MAX_MS)
    return
  end
  APP.state = "scanning"
  APP.scan_deadline_ms = now_ms() + SCAN_DURATION_MS + 1000
end

local function stop_scan()
  if BLE and type(BLE.gap_scan) == "function" then pcall(BLE.gap_scan, nil) end
  APP.scan_deadline_ms = nil
end

local function start_connect(addr_type, addr)
  if type(addr) ~= "string" or addr == "" or type(addr_type) ~= "number" then
    log("scan_result_address_invalid")
    return
  end
  stop_scan()
  APP.state = "connecting"
  APP.addr = addr
  APP.addr_type = addr_type
  APP.connect_deadline_ms = now_ms() + CONNECT_TIMEOUT_MS
  local ok, result, err = pcall(BLE.gap_connect, addr_type, addr, 5000)
  if not ok or result == false or (result == nil and err ~= nil) then
    schedule_scan_retry("connect_failed: " .. tostring(err or result))
  end
end

local function frame_message(message)
  if type(message) ~= "string" or #message == 0 or #message > MAX_MESSAGE_SIZE then
    return nil, "message_size_invalid"
  end
  local payload_size = APP.mtu - 3 - FRAME_HEADER_SIZE
  if payload_size < 1 then return nil, "mtu_too_small" end
  local count = math.ceil(#message / payload_size)
  if count < 1 or count > 255 then return nil, "fragment_count_invalid" end
  local message_id = APP.next_message_id
  APP.next_message_id = (APP.next_message_id + 1) % 65536
  local fragments = {}
  for index = 0, count - 1 do
    local start_at = index * payload_size + 1
    local chunk = message:sub(start_at, math.min(start_at + payload_size - 1, #message))
    local header = string.char(
      FRAME_MAGIC,
      FRAME_VERSION,
      math.floor(message_id / 256),
      message_id % 256,
      index,
      count
    )
    fragments[#fragments + 1] = header .. chunk
  end
  return fragments
end

local function write_next()
  if APP.stopped or APP.active_write or #APP.write_queue == 0 then return end
  if not APP.conn or not APP.response_handle then return end
  APP.active_write = table.remove(APP.write_queue, 1)
  APP.active_write.index = 1
  local function send_frame()
    if not APP.active_write or not APP.conn then return end
    local frame = APP.active_write.frames[APP.active_write.index]
    local ok, result, err = pcall(BLE.gattc_write, APP.conn, APP.response_handle, frame, 1)
    if not ok or result == false or (result == nil and err ~= nil) then
      fail_link("write_failed: " .. tostring(err or result))
    end
  end
  send_frame()
end

local function enqueue_write(message, completed)
  if not APP.conn or not APP.response_handle then return false, "response_characteristic_unavailable" end
  local encoded, encode_error = json_encode(message)
  if not encoded then return false, encode_error end
  local frames, frame_error = frame_message(encoded)
  if not frames then return false, frame_error end
  APP.write_queue[#APP.write_queue + 1] = { frames = frames, completed = completed }
  write_next()
  return true
end

local function send_error(request_id, error_code)
  enqueue_write({ version = 1, type = "error", request_id = request_id, error = error_code })
end

local function send_auth()
  APP.state = "authorizing"
  APP.auth_deadline_ms = now_ms() + AUTH_TIMEOUT_MS
  APP.auth_request_id = next_id("ble-auth")
  local ok, err = enqueue_write({
    version = 1,
    type = "auth",
    request_id = APP.auth_request_id,
    token = APP.config.token,
  })
  if not ok then fail_link(err) end
end

local function new_assembler()
  return { messages = {} }
end

local function assemble_frame(assembler, frame)
  if type(frame) ~= "string" or #frame <= FRAME_HEADER_SIZE or frame:byte(1) ~= FRAME_MAGIC then
    return nil, "frame_invalid"
  end
  if frame:byte(2) ~= FRAME_VERSION then return nil, "frame_version_unsupported" end
  local message_id = frame:byte(3) * 256 + frame:byte(4)
  local fragment_index = frame:byte(5)
  local fragment_count = frame:byte(6)
  if fragment_count < 1 or fragment_index >= fragment_count then return nil, "fragment_index_invalid" end
  local now = now_ms()
  for id, partial in pairs(assembler.messages) do
    if elapsed_ms(partial.updated_ms, now) > FRAGMENT_TIMEOUT_MS then assembler.messages[id] = nil end
  end
  local partial = assembler.messages[message_id]
  if not partial then
    local in_flight = 0
    for _ in pairs(assembler.messages) do in_flight = in_flight + 1 end
    if in_flight >= MAX_INCOMPLETE_MESSAGES then return nil, "too_many_incomplete_messages" end
    partial = { count = fragment_count, fragments = {}, total = 0, received = 0, updated_ms = now }
    assembler.messages[message_id] = partial
  end
  if partial.count ~= fragment_count then
    assembler.messages[message_id] = nil
    return nil, "fragment_conflict"
  end
  local payload = frame:sub(FRAME_HEADER_SIZE + 1)
  local existing = partial.fragments[fragment_index]
  if existing then
    if existing ~= payload then
      assembler.messages[message_id] = nil
      return nil, "fragment_conflict"
    end
  else
    partial.fragments[fragment_index] = payload
    partial.total = partial.total + #payload
    partial.received = partial.received + 1
    if partial.total > MAX_MESSAGE_SIZE then
      assembler.messages[message_id] = nil
      return nil, "message_too_large"
    end
  end
  partial.updated_ms = now
  if partial.received < partial.count then return nil end
  local chunks = {}
  for i = 0, partial.count - 1 do
    if not partial.fragments[i] then return nil end
    chunks[#chunks + 1] = partial.fragments[i]
  end
  assembler.messages[message_id] = nil
  return table.concat(chunks)
end

local function valid_request_id(value)
  return type(value) == "string" and #value > 0 and #value <= REQUEST_ID_MAX_LENGTH
end

local function send_ipc_request(topic, request)
  if not ipc or type(ipc.send) ~= "function" then return false, "ipc_send_unavailable" end
  local correlation_id = next_id("ble-ipc")
  request.reply_to = IPC_REPLY_ENDPOINT
  request.correlation_id = correlation_id
  local encoded, encode_error = json_encode(request)
  if not encoded then return false, encode_error end
  APP.pending_ipc[correlation_id] = {
    topic = topic,
    request_id = request.request_id,
    deadline_ms = now_ms() + IPC_TIMEOUT_MS,
  }
  local ok, result, err = pcall(ipc.send, IPC_COMMAND_ENDPOINT, topic, encoded)
  if not ok or result == false or (result == nil and err ~= nil) then
    APP.pending_ipc[correlation_id] = nil
    return false, tostring(err or result)
  end
  return true
end

local function handle_ble_message(message)
  if type(message) ~= "table" or message.version ~= 1 or type(message.type) ~= "string" then
    send_error(nil, "invalid_message")
    return
  end
  if APP.state == "authorizing" then
    if message.type == "auth_ok" and message.request_id == APP.auth_request_id then
      APP.state = "ready"
      APP.auth_deadline_ms = nil
      APP.auth_request_id = nil
      APP.retry_ms = RETRY_MIN_MS
      APP.next_scan_ms = 0
      log("BLE session authorized")
    elseif message.type == "auth_failed" then
      log("Mac rejected BLE authentication (token omitted)")
      fail_link("authentication_failed")
    else
      send_error(message.request_id, "authentication_pending")
    end
    return
  end
  if APP.state ~= "ready" then
    send_error(message.request_id, "authentication_required")
    return
  end
  if message.type == "auth_failed" then
    log("Mac revoked BLE authorization (token omitted)")
    fail_link("authentication_failed")
    return
  end
  if message.type == "tap" then
    if not valid_request_id(message.request_id) then
      send_error(nil, "invalid_request_id")
      return
    end
    if type(message.button) ~= "string" then
      send_error(message.request_id, "button_required")
      return
    end
    if message.hold_ms ~= nil and (type(message.hold_ms) ~= "number" or message.hold_ms ~= math.floor(message.hold_ms)
        or message.hold_ms < 120 or message.hold_ms > 5000) then
      send_error(message.request_id, "invalid_hold_ms")
      return
    end
    local sent, err = send_ipc_request("tap", {
      request_id = message.request_id,
      button = message.button,
      hold_ms = message.hold_ms,
    })
    if not sent then
      enqueue_write({ version = 1, type = "ack", request_id = message.request_id, ok = false, error = err })
    end
    return
  end
  if message.type == "status" then
    if not valid_request_id(message.request_id) then
      send_error(nil, "invalid_request_id")
      return
    end
    local sent, err = send_ipc_request("status", { request_id = message.request_id })
    if not sent then
      enqueue_write({ version = 1, type = "status_result", request_id = message.request_id, ok = false, error = err })
    end
    return
  end
  if message.type == "settings" then
    if not valid_request_id(message.request_id) then
      send_error(nil, "invalid_request_id")
      return
    end
    local capacity = tonumber(message.queue_capacity)
    if not capacity or capacity ~= math.floor(capacity) or capacity < 1 or capacity > 32 then
      enqueue_write({
        version = 1,
        type = "settings_result",
        request_id = message.request_id,
        ok = false,
        error = "invalid_queue_capacity",
      })
      return
    end
    local sent, err = send_ipc_request("settings", {
      request_id = message.request_id,
      queue_capacity = capacity,
    })
    if not sent then
      enqueue_write({
        version = 1,
        type = "settings_result",
        request_id = message.request_id,
        ok = false,
        error = err,
      })
    end
    return
  end
  send_error(message.request_id, "unsupported_message_type")
end

local function handle_command_response(topic, payload)
  if topic ~= "result" then return end
  local result = json_decode(payload)
  if not result or type(result.correlation_id) ~= "string" then return end
  local pending = APP.pending_ipc[result.correlation_id]
  if not pending then return end
  APP.pending_ipc[result.correlation_id] = nil
  if pending.topic == "tap" then
    local response = {
      version = 1,
      type = "ack",
      request_id = pending.request_id,
      ok = result.ok == true,
      queued = result.queued == true,
      duplicate = result.duplicate == true,
    }
    if result.ok ~= true then response.error = result.error or "command_rejected" end
    enqueue_write(response)
  elseif pending.topic == "settings" then
    local response = {
      version = 1,
      type = "settings_result",
      request_id = pending.request_id,
      ok = result.ok == true,
      queue_capacity = result.queue_capacity,
      queue_length = result.queue_length,
      persisted = result.persisted == true,
    }
    if result.ok ~= true then response.error = result.error or "settings_rejected" end
    enqueue_write(response)
  else
    local response = {
      version = 1,
      type = "status_result",
      request_id = pending.request_id,
      ok = result.ok == true,
      status = result.ok == true and result or nil,
    }
    if result.ok ~= true then response.error = result.error or "status_unavailable" end
    enqueue_write(response)
  end
end

local function start_ipc()
  if not ipc or type(ipc.listen) ~= "function" then return false, "ipc_listen_unavailable" end
  local ok, result, err = pcall(ipc.listen, IPC_REPLY_ENDPOINT, handle_command_response)
  if not ok or result == false or (result == nil and err ~= nil) then
    return false, tostring(err or result)
  end
  APP.ipc_listening = true
  return true
end

local function start_notifications()
  local descriptor_end = APP.command_end_handle or APP.service_end
  if not APP.conn or not APP.command_handle or not descriptor_end
      or descriptor_end < APP.command_handle then
    fail_link("gatt_characteristics_incomplete")
    return
  end
  APP.descriptor_start_handle = APP.command_handle
  APP.descriptor_end_handle = descriptor_end
  local ok, result, err = pcall(BLE.gattc_discover_descriptors, APP.conn, APP.command_handle, descriptor_end)
  if not ok or result == false or (result == nil and err ~= nil) then
    fail_link("descriptor_discovery_failed: " .. tostring(err or result))
    return
  end
  APP.state = "discovering"
end

local function begin_cccd_write()
  if not APP.cccd_handle then
    fail_link("command_cccd_missing")
    return
  end
  APP.state = "subscribing"
  APP.write_purpose = "subscribe"
  local ok, result, err = pcall(BLE.gattc_write, APP.conn, APP.cccd_handle, string.char(1, 0), 1)
  if not ok or result == false or (result == nil and err ~= nil) then
    fail_link("cccd_write_failed: " .. tostring(err or result))
  end
end

local function on_irq(event, data)
  if APP.stopped then return end
  if event == IRQ_SCAN_RESULT then
    if APP.state ~= "scanning" then return end
    local adv_data = get_field(data, "adv_data") or get_field(data, "data")
    if advertisement_has_service(adv_data) then
      local addr_type = tonumber(get_field(data, "addr_type"))
      local addr = get_field(data, "addr")
      log("found MacCtrlHTTP GATT service")
      start_connect(addr_type, addr)
    end
  elseif event == IRQ_SCAN_DONE then
    APP.scan_deadline_ms = nil
    if APP.state == "scanning" then schedule_scan_retry("scan_complete") end
  elseif event == IRQ_PERIPHERAL_CONNECT then
    local status = tonumber(get_field(data, "status")) or 0
    if status ~= 0 then schedule_scan_retry("connect_status_" .. tostring(status)); return end
    APP.conn = tonumber(get_field(data, "conn_handle"))
    if not APP.conn then fail_link("connection_handle_missing"); return end
    APP.state = "discovering"
    APP.connect_deadline_ms = nil
    APP.retry_ms = RETRY_MIN_MS
    APP.assemblers.command = new_assembler()
    APP.assemblers.response = new_assembler()
    if BLE.gattc_exchange_mtu then pcall(BLE.gattc_exchange_mtu, APP.conn) end
    local ok, result, err = pcall(BLE.gattc_discover_services, APP.conn, SERVICE_UUID)
    if not ok or result == false or (result == nil and err ~= nil) then
      fail_link("service_discovery_failed: " .. tostring(err or result))
    end
  elseif event == IRQ_PERIPHERAL_DISCONNECT then
    schedule_scan_retry("peripheral_disconnected")
  elseif event == IRQ_MTU_EXCHANGED then
    local mtu = tonumber(get_field(data, "mtu"))
    if mtu and mtu >= DEFAULT_MTU then APP.mtu = math.min(mtu, 517) end
  elseif event == IRQ_GATTC_SERVICE_RESULT then
    if uuid_matches(get_field(data, "uuid"), SERVICE_UUID) then
      APP.service_start = tonumber(get_field(data, "start_handle"))
      APP.service_end = tonumber(get_field(data, "end_handle"))
    end
  elseif event == IRQ_GATTC_SERVICE_DONE then
    if not APP.service_start or not APP.service_end then fail_link("control_service_missing"); return end
    local ok, result, err = pcall(BLE.gattc_discover_characteristics, APP.conn, APP.service_start, APP.service_end)
    if not ok or result == false or (result == nil and err ~= nil) then
      fail_link("characteristic_discovery_failed: " .. tostring(err or result))
    end
  elseif event == IRQ_GATTC_CHARACTERISTIC_RESULT then
    local uuid = get_field(data, "uuid")
    local value_handle = tonumber(get_field(data, "value_handle"))
    local properties = tonumber(get_field(data, "properties")) or 0
    if value_handle and uuid_matches(uuid, COMMAND_UUID) then
      APP.command_handle = value_handle
      APP.command_end_handle = tonumber(get_field(data, "end_handle"))
      APP.command_properties = properties
    elseif value_handle and uuid_matches(uuid, RESPONSE_UUID) then
      APP.response_handle = value_handle
      APP.response_properties = properties
    end
  elseif event == IRQ_GATTC_CHARACTERISTIC_DONE then
    if not APP.command_handle or not APP.response_handle
        or APP.command_properties % 32 < 16
        or math.floor(APP.response_properties / 8) % 2 ~= 1 then
      fail_link("required_characteristic_property_missing")
      return
    end
    start_notifications()
  elseif event == IRQ_GATTC_DESCRIPTOR_RESULT then
    if uuid_matches(get_field(data, "uuid"), "00002902") then
      APP.cccd_handle = tonumber(get_field(data, "handle")) or tonumber(get_field(data, "descriptor_handle"))
    end
  elseif event == IRQ_GATTC_DESCRIPTOR_DONE then
    begin_cccd_write()
  elseif event == IRQ_GATTC_WRITE_DONE then
    local handle = tonumber(get_field(data, "value_handle")) or tonumber(get_field(data, "handle"))
    local status = tonumber(get_field(data, "status")) or 0
    if status ~= 0 then fail_link("gatt_write_status_" .. tostring(status)); return end
    if APP.write_purpose == "subscribe" and handle == APP.cccd_handle then
      APP.write_purpose = nil
      send_auth()
      return
    end
    if not APP.active_write then return end
    if handle and handle ~= APP.response_handle then return end
    APP.active_write.index = APP.active_write.index + 1
    if APP.active_write.index <= #APP.active_write.frames then
      local frame = APP.active_write.frames[APP.active_write.index]
      local ok, result, err = pcall(BLE.gattc_write, APP.conn, APP.response_handle, frame, 1)
      if not ok or result == false or (result == nil and err ~= nil) then
        fail_link("gatt_write_failed: " .. tostring(err or result))
      end
    else
      local completed = APP.active_write.completed
      APP.active_write = nil
      if type(completed) == "function" then pcall(completed) end
      write_next()
    end
  elseif event == IRQ_GATTC_NOTIFY then
    local handle = tonumber(get_field(data, "value_handle")) or tonumber(get_field(data, "handle"))
    local raw = get_field(data, "data")
    if handle ~= APP.command_handle or get_field(data, "truncated") == true then return end
    local complete, err = assemble_frame(APP.assemblers.command, raw)
    if err then
      log("discarded invalid command frame: " .. tostring(err))
      return
    end
    if complete then
      local message = json_decode(complete)
      if not message then send_error(nil, "invalid_json") else handle_ble_message(message) end
    end
  end
end

local function timer_tick()
  if APP.stopped then return end
  APP.clock_ms = APP.clock_ms + TICK_MS
  if app and type(app.exiting) == "function" then
    local ok, exiting = pcall(app.exiting)
    if ok and exiting == true then APP.stop("service_exit"); return end
  end
  local now = now_ms()
  if APP.state == "scanning" and APP.scan_deadline_ms and elapsed_ms(APP.scan_deadline_ms, now) < 4294967296
      and now >= APP.scan_deadline_ms then
    stop_scan()
    schedule_scan_retry("scan_timeout")
  elseif APP.state == "connecting" and APP.connect_deadline_ms and now >= APP.connect_deadline_ms then
    fail_link("connect_timeout")
  elseif APP.state == "authorizing" and APP.auth_deadline_ms and now >= APP.auth_deadline_ms then
    fail_link("authorization_timeout")
  end
  for correlation_id, pending in pairs(APP.pending_ipc) do
    if now >= pending.deadline_ms then
      APP.pending_ipc[correlation_id] = nil
      local response
      if pending.topic == "tap" then
        response = { version = 1, type = "ack", request_id = pending.request_id, ok = false, error = "ipc_timeout" }
      elseif pending.topic == "settings" then
        response = { version = 1, type = "settings_result", request_id = pending.request_id, ok = false, error = "ipc_timeout" }
      else
        response = { version = 1, type = "status_result", request_id = pending.request_id, ok = false, error = "ipc_timeout" }
      end
      enqueue_write(response)
    end
  end
  for _, assembler in pairs(APP.assemblers) do
    if assembler and assembler.messages then
      for message_id, partial in pairs(assembler.messages) do
        if elapsed_ms(partial.updated_ms, now) > FRAGMENT_TIMEOUT_MS then
          assembler.messages[message_id] = nil
        end
      end
    end
  end
  if APP.state == "disconnected" and now >= APP.next_scan_ms then scan() end
end

function APP.stop(reason)
  if APP.stopped then return end
  APP.stopped = true
  if APP.timer then
    pcall(function() APP.timer:stop() end)
    pcall(function() APP.timer:unregister() end)
    APP.timer = nil
  end
  stop_scan()
  if APP.conn and BLE and type(BLE.gap_disconnect) == "function" then
    pcall(BLE.gap_disconnect, APP.conn)
  end
  if APP.owns_ble and BLE and type(BLE.irq) == "function" then
    pcall(BLE.irq, nil)
    pcall(BLE.active, false)
  end
  if APP.ipc_listening and ipc and type(ipc.listen) == "function" then
    pcall(ipc.listen, IPC_REPLY_ENDPOINT, nil)
    APP.ipc_listening = false
  end
  clear_link_state()
  APP.state = "stopped"
  if rawget(_G, SERVICE_KEY) == APP then rawset(_G, SERVICE_KEY, nil) end
  log("stopped: " .. tostring(reason or ""))
end

local config, config_error = read_config()
APP.config = config
APP.config_error = config_error
if not config then
  APP.state = "error"
  log("configuration unavailable: " .. tostring(config_error))
  return APP
end
if not config.enabled or not config.auto_connect then
  APP.state = "disabled"
  log("BLE bridge is disabled by config")
  return APP
end

if not BLE or type(BLE.active) ~= "function" or type(BLE.irq) ~= "function"
    or type(BLE.gap_scan) ~= "function" or type(BLE.gap_connect) ~= "function"
    or type(BLE.gattc_discover_services) ~= "function"
    or type(BLE.gattc_discover_characteristics) ~= "function"
    or type(BLE.gattc_discover_descriptors) ~= "function"
    or type(BLE.gattc_write) ~= "function" then
  APP.state = "error"
  APP.config_error = "required_lua_ble_api_unavailable"
  log(APP.config_error)
  return APP
end

local active_ok, active_result, active_error = pcall(BLE.active, true)
if not active_ok or active_result == false or (active_result == nil and active_error ~= nil) then
  APP.state = "error"
  APP.config_error = "ble_active_failed: " .. tostring(active_error or active_result)
  log(APP.config_error)
  return APP
end
local irq_ok, irq_result, irq_error = pcall(BLE.irq, on_irq)
if not irq_ok or irq_result == false or (irq_result == nil and irq_error ~= nil) then
  APP.state = "error"
  APP.config_error = "ble_irq_failed: " .. tostring(irq_error or irq_result)
  log(APP.config_error)
  pcall(BLE.irq, nil)
  pcall(BLE.active, false)
  return APP
end
APP.owns_ble = true

local ipc_ok, ipc_error = start_ipc()
if not ipc_ok then log("IPC reply endpoint unavailable: " .. tostring(ipc_error)) end
if tmr and type(tmr.create) == "function" then
  local ok, timer = pcall(tmr.create)
  if ok and timer then
    APP.timer = timer
    local alarm_ok, alarm_error = pcall(function() timer:alarm(TICK_MS, tmr.ALARM_AUTO, timer_tick) end)
    if not alarm_ok then
      APP.timer = nil
      pcall(function() timer:unregister() end)
      APP.state = "error"
      APP.config_error = "timer_start_failed: " .. tostring(alarm_error)
      log(APP.config_error)
      APP.stop("timer_start_failed")
      return APP
    end
  else
    APP.state = "error"
    APP.config_error = "timer_create_failed"
    log(APP.config_error)
    APP.stop("timer_create_failed")
    return APP
  end
else
  APP.state = "error"
  APP.config_error = "timer_unavailable"
  log(APP.config_error)
  APP.stop("timer_unavailable")
  return APP
end

APP.state = "disconnected"
APP.next_scan_ms = 0
scan()
log("started; waiting for MacCtrlHTTP over BLE")
return APP
