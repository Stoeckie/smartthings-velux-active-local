-- SmartThings Edge driver: VELUX ACTIVE with NETATMO (KIX 300) over HomeKit, locally from the hub.
-- The hub pairs with the gateway as a HomeKit controller (HomeKit code from the gateway sticker, entered
-- as a device setting), keeps one encrypted HAP session open and receives position/sensor events.
--   parent  "VELUX Gateway"      (LAN device, settings: HomeKit code, optional IP/port, remove pairing)
--   child   window / blind       windowShade + windowShadeLevel
--   child   climate sensor       temperature, humidity, CO2
-- No secrets live in the code: the HomeKit code is a device preference, the pairing keys are stored
-- on the hub as persistent device fields.
local Driver = require "st.driver"
local capabilities = require "st.capabilities"

-- Connection status as a capability, so routines can notify when this device loses its connection
-- (SmartThings itself has no "device offline" trigger for routines).
-- Short drops (a reconnect, one missed poll) are ignored: Offline is only emitted after CONN_GRACE seconds down.
local conn_cap = capabilities["silvervalley08660.connectionStatus"]
local CONN_GRACE = 120
local function emit_conn(dev, v)
  if dev:get_field("conn_status") == v then return end
  local ok = pcall(function() dev:emit_event(conn_cap.status(v)) end)
  if ok then dev:set_field("conn_status", v) end
end
local function set_conn(dev, up)
  if up then
    dev:set_field("conn_down_since", nil)
    emit_conn(dev, "online")
    return
  end
  if dev:get_field("conn_down_since") then return end
  local since = os.time()
  dev:set_field("conn_down_since", since)
  local ok = pcall(function()
    dev.thread:call_with_delay(CONN_GRACE, function()
      if dev:get_field("conn_down_since") == since then emit_conn(dev, "offline") end
    end)
  end)
  if not ok then emit_conn(dev, "offline") end
end
local log = require "log"
local cosock = require "cosock"
local json = require "st.json"
local hap = require "hap_client"
local bignum = require "bignum"
local model_lib = require "velux_model"

local BUILD = "2026-11-01b"
local REQUEST_TIMEOUT = 15
local POLL_SECS = 300
local RECONNECT_MIN, RECONNECT_MAX = 10, 300

local windowShade = capabilities.windowShade
local windowShadeLevel = capabilities.windowShadeLevel
local PROFILE = { window = "velux-window", blind = "velux-blind", climate = "velux-climate" }

hap.json = json

local function now()
  local ok, t = pcall(cosock.socket.gettime)
  return ok and t or os.time()
end

-- entropy for keys: hap.random_bytes hashes clock jitter, time and math.random; stir in socket timing
math.randomseed(math.floor((now() * 1000000) % 2147483647))

-- modpow (SRP) runs for seconds on the hub: let other tasks run in between
bignum.yield_hook = function() cosock.socket.sleep(0) end

local conns = {}        -- parent.id -> connection state
local discovered = {}   -- dni -> { ip, port, id, name }

-- hex helpers for persisted binary keys -----------------------------------------------
local function tohex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
local function fromhex(h) return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end)) end

local function uuid4()
  local b = { hap.random_bytes(16):byte(1, 16) }
  b[7] = (b[7] & 0x0f) | 0x40
  b[9] = (b[9] & 0x3f) | 0x80
  local h = string.format(string.rep("%02X", 16), table.unpack(b))
  return h:sub(1, 8) .. "-" .. h:sub(9, 12) .. "-" .. h:sub(13, 16) .. "-" .. h:sub(17, 20) .. "-" .. h:sub(21, 32)
end

local function load_pairing(parent)
  local p = parent:get_field("hap_pairing")
  if type(p) ~= "table" or not p.controller_id then return nil end
  return { controller_id = p.controller_id, controller_seed = fromhex(p.controller_seed),
           controller_pub = fromhex(p.controller_pub), accessory_id = p.accessory_id,
           accessory_pub = fromhex(p.accessory_pub) }
end

local function save_pairing(parent, p)
  parent:set_field("hap_pairing", {
    controller_id = p.controller_id, controller_seed = tohex(p.controller_seed),
    controller_pub = tohex(p.controller_pub), accessory_id = p.accessory_id,
    accessory_pub = tohex(p.accessory_pub) }, { persist = true })
end

-- addressing / mDNS ------------------------------------------------------------------------
local function parse_txt(list)
  local t = {}
  for _, e in ipairs(list or {}) do
    local k, v = tostring(e):match("^([^=]+)=(.*)$")
    if k then t[k:lower()] = v end
  end
  return t
end

local function mdns_scan()
  local ok, mdns = pcall(require, "st.mdns")
  if not ok then
    log.warn("[velux] st.mdns not available on this hub firmware; set IP and port in the gateway settings")
    return {}
  end
  local res, err = mdns.discover("_hap._tcp", "local")
  if not res then
    log.warn("[velux] mDNS discover failed: " .. tostring(err))
    return {}
  end
  local out = {}
  for _, f in ipairs(res.found or {}) do
    local host = f.host_info or {}
    local svc = f.service_info or {}
    local txt = parse_txt(f.txt and f.txt.text)
    local name = tostring(svc.name or "")
    local md = tostring(txt.md or "")
    local is_velux = (name .. " " .. md):upper():find("VELUX", 1, true) ~= nil
    if is_velux and host.address and tostring(host.address):match("^%d+%.%d+%.%d+%.%d+$") and txt.id then
      out[#out + 1] = { ip = host.address, port = tonumber(host.port), id = txt.id, name = name,
                        paired = txt.sf == "0" }
    end
  end
  return out
end

local function address(parent)
  local p = parent.preferences or {}
  local ip = p.ipAddress
  if ip == nil or ip == "" or ip == "auto" then ip = parent:get_field("ip") end
  local port = tonumber(p.hapPort)
  if not port or port == 0 then port = parent:get_field("port") end
  if ip and not port then port = 5001 end -- VELUX gateway default HomeKit port
  return ip, port
end

local function refresh_address(parent)
  local id = parent:get_field("hap_id")
  for _, f in ipairs(mdns_scan()) do
    if not id or f.id == id then
      if parent:get_field("ip") ~= f.ip or parent:get_field("port") ~= f.port then
        log.info(string.format("[velux] gateway %s at %s:%s", f.id, f.ip, tostring(f.port)))
      end
      parent:set_field("ip", f.ip, { persist = true })
      parent:set_field("port", f.port, { persist = true })
      parent:set_field("hap_id", f.id, { persist = true })
      return true
    end
  end
  return false
end

local function open_socket(parent, timeout)
  local ip, port = address(parent)
  if not ip or not port then
    refresh_address(parent)
    ip, port = address(parent)
  end
  if not ip or not port then return nil, "gateway address unknown" end
  local sock = cosock.socket.tcp()
  sock:settimeout(timeout or 15)
  local ok, err = sock:connect(ip, port)
  if not ok then
    sock:close()
    return nil, string.format("connect %s:%s failed: %s", ip, tostring(port), tostring(err))
  end
  return sock, nil, ip
end

-- children -------------------------------------------------------------------------------
local function children(driver, parent)
  local out = {}
  for _, dev in ipairs(driver:get_devices()) do
    if dev.parent_device_id == parent.id and dev.parent_assigned_child_key then
      out[dev.parent_assigned_child_key] = dev
    end
  end
  return out
end

local function emit_child(child, dev)
  local v = dev.values
  if dev.kind == "climate" then
    if v.temperature ~= nil then
      child:emit_event(capabilities.temperatureMeasurement.temperature({ value = tonumber(v.temperature), unit = "C" }))
    end
    if v.humidity ~= nil then
      child:emit_event(capabilities.relativeHumidityMeasurement.humidity(math.floor(tonumber(v.humidity) + 0.5)))
    end
    if v.co2 ~= nil then
      child:emit_event(capabilities.carbonDioxideMeasurement.carbonDioxide({ value = tonumber(v.co2), unit = "ppm" }))
    end
    return
  end
  local st, pos = model_lib.shade_state(dev)
  if pos then child:emit_event(windowShadeLevel.shadeLevel(math.max(0, math.min(100, math.floor(pos + 0.5))))) end
  if dev.kind == "window" and pos and child:supports_capability(capabilities.contactSensor) then
    child:emit_event(pos > 0 and capabilities.contactSensor.contact.open() or capabilities.contactSensor.contact.closed())
  end
  local ev = ({ open = windowShade.windowShade.open, closed = windowShade.windowShade.closed,
                opening = windowShade.windowShade.opening, closing = windowShade.windowShade.closing,
                ["partially open"] = windowShade.windowShade.partially_open,
                unknown = windowShade.windowShade.unknown })[st]
  if ev then child:emit_event(ev()) end
end

local function emit_touched(driver, parent, c, touched)
  local kids = children(driver, parent)
  for key in pairs(touched) do
    local child, dev = kids[key], c.model.devices[key]
    if child and dev then
      local ok, err = pcall(emit_child, child, dev)
      if not ok then log.error("[velux] emit " .. key .. ": " .. tostring(err)) end
    end
  end
end

local function sync_children(driver, parent, c)
  local kids = children(driver, parent)
  for _, key in ipairs(c.model.order) do
    local dev = c.model.devices[key]
    if not kids[key] then
      log.info(string.format("[velux] creating %s '%s' (%s)", dev.kind, dev.name, key))
      driver:try_create_device({
        type = "EDGE_CHILD", parent_device_id = parent.id, parent_assigned_child_key = key,
        label = dev.name, profile = PROFILE[dev.kind], manufacturer = "VELUX",
        model = "VELUX ACTIVE " .. dev.kind, vendor_provided_label = dev.name,
      })
    end
  end
end

-- session ------------------------------------------------------------------------------------
local function set_children_online(driver, parent, online)
  for _, child in pairs(children(driver, parent)) do
    if online then child:online() else child:offline() end
  end
end

local function close_conn(c)
  c.alive = false
  if c.sock then pcall(function() c.sock:close() end) end
  c.sock = nil
end

local function make_waiter(c)
  return function()
    local deadline = now() + REQUEST_TIMEOUT
    while #c.responses == 0 do
      if not c.alive then return nil, "connection closed" end
      if now() > deadline then
        close_conn(c) -- resync: a late response would otherwise be taken by the next request
        return nil, "timeout"
      end
      cosock.socket.sleep(0.05)
    end
    return table.remove(c.responses, 1)
  end
end

local function run_session(driver, parent)
  local c = conns[parent.id]
  local backoff = RECONNECT_MIN
  while c and not c.stopped do
    local pairing = load_pairing(parent)
    if not pairing then
      log.info("[velux] not paired: enter the HomeKit code in the gateway settings")
      return
    end
    local sock, err = open_socket(parent, 20)
    if sock then
      c.sock, c.alive, c.responses = sock, true, {}
      local s = hap.session(sock, { host = "velux" })
      c.session = s
      local ok, verr = s:pair_verify(pairing)
      local accs
      if ok then accs, verr = s:accessories() end
      if accs then
        c.model = model_lib.build(accs)
        sync_children(driver, parent, c)
        local ids = model_lib.read_ids(c.model)
        if #ids > 0 then
          local _, serr = s:subscribe(ids)
          if serr then log.warn("[velux] subscribe: " .. tostring(serr)) end
        end
        parent:online(); set_conn(parent, true)
        set_children_online(driver, parent, true)
        local all = {}
        for key in pairs(c.model.devices) do all[key] = true end
        emit_touched(driver, parent, c, all)
        log.info(string.format("[velux] session up, %d device(s)", #c.model.order))
        backoff = RECONNECT_MIN
        -- reader loop: this task owns the socket from now on
        sock:settimeout(nil)
        s.on_event = function(chars)
          emit_touched(driver, parent, c, model_lib.apply(c.model, chars))
        end
        s.wait_response = make_waiter(c)
        while c.alive do
          local msg, rerr = s:read_message()
          if not msg then
            if c.alive then log.warn("[velux] session closed: " .. tostring(rerr)) end
            break
          end
          if msg.event then s:_dispatch_event(msg) else c.responses[#c.responses + 1] = msg end
        end
      else
        log.error("[velux] session setup failed: " .. tostring(verr))
        if tostring(verr):find("unknown accessory id") or tostring(verr):find("authentication") then
          log.error("[velux] the gateway no longer knows this hub; remove pairing and pair again")
        end
      end
      close_conn(c)
    else
      log.warn("[velux] " .. tostring(err))
    end
    if c.stopped then return end
    set_conn(parent, false); parent:offline()
    set_children_online(driver, parent, false)
    cosock.socket.sleep(backoff)
    backoff = math.min(backoff * 2, RECONNECT_MAX)
    refresh_address(parent)
  end
end

local function start_session(driver, parent)
  local old = conns[parent.id]
  if old then
    old.stopped = true
    close_conn(old)
  end
  conns[parent.id] = { responses = {} }
  cosock.spawn(function() run_session(driver, parent) end, "velux-session-" .. parent.id)
end

-- pairing ----------------------------------------------------------------------------------
local function normalize_pin(pin)
  local d = tostring(pin or ""):gsub("%D", "")
  if #d ~= 8 then return nil end
  return d:sub(1, 3) .. "-" .. d:sub(4, 5) .. "-" .. d:sub(6, 8)
end

local function pair(driver, parent)
  if conns[parent.id] and conns[parent.id].pairing then return end
  local pin = normalize_pin((parent.preferences or {}).homekitCode)
  if not pin then
    log.info("[velux] enter the 8-digit HomeKit code in the gateway settings to pair")
    return
  end
  conns[parent.id] = conns[parent.id] or { responses = {} }
  conns[parent.id].pairing = true
  cosock.spawn(function()
    local c = conns[parent.id]
    refresh_address(parent)
    local sock, err = open_socket(parent, 120)
    if not sock then
      log.error("[velux] pairing: " .. tostring(err) .. " (retry in 60 s)")
      c.pairing = false
      parent.thread:call_with_delay(60, function() if not load_pairing(parent) then pair(driver, parent) end end)
      return
    end
    log.info("[velux] pairing with gateway (this takes up to a minute on the hub)...")
    local t0 = now()
    local s = hap.session(sock, { host = "velux" })
    local p, perr = s:pair_setup(pin, uuid4(), { yield = function() cosock.socket.sleep(0) end })
    sock:close()
    c.pairing = false
    if not p then
      log.error("[velux] pairing failed: " .. tostring(perr))
      if not tostring(perr):find("HomeKit error") then -- network trouble: try again; wrong code: wait for a new code
        parent.thread:call_with_delay(60, function() if not load_pairing(parent) then pair(driver, parent) end end)
      end
      return
    end
    save_pairing(parent, p)
    log.info(string.format("[velux] paired in %.0f s with accessory %s", now() - t0, tostring(p.accessory_id)))
    start_session(driver, parent)
  end, "velux-pair-" .. parent.id)
end

local function unpair(driver, parent)
  local c = conns[parent.id]
  local p = load_pairing(parent)
  if not p then return end
  cosock.spawn(function()
    local ok, err
    if c and c.session and c.alive then
      ok, err = c.session:remove_pairing(p.controller_id)
    end
    if c then
      c.stopped = true
      close_conn(c)
    end
    parent:set_field("hap_pairing", nil, { persist = true })
    log.info("[velux] pairing removed" .. (ok and "" or (" locally (gateway: " .. tostring(err) .. ")")))
  end, "velux-unpair")
end

-- capability handlers -------------------------------------------------------------------------
local function child_target(driver, child)
  local parent = child:get_parent_device()
  local c = parent and conns[parent.id]
  local dev = c and c.model and c.model.devices[child.parent_assigned_child_key]
  return c, dev
end

local function write(driver, child, field, value)
  local c, dev = child_target(driver, child)
  if not (c and c.alive and dev and dev.chars[field]) then
    log.warn("[velux] " .. child.label .. ": not connected")
    return
  end
  local _, err = c.session:put({ { aid = dev.aid, iid = dev.chars[field], value = value } })
  if err then log.error("[velux] " .. child.label .. " write failed: " .. tostring(err)) end
end

local function handle_open(driver, child) write(driver, child, "target", 100) end
local function handle_close(driver, child) write(driver, child, "target", 0) end
local function handle_level(driver, child, cmd)
  write(driver, child, "target", math.max(0, math.min(100, math.floor(tonumber(cmd.args.shadeLevel) or 0))))
end
local function handle_pause(driver, child)
  local _, dev = child_target(driver, child)
  if dev and dev.chars.hold then
    write(driver, child, "hold", true)
  elseif dev and dev.values.position then
    write(driver, child, "target", math.floor(tonumber(dev.values.position) + 0.5))
  end
end

local function poll(driver, parent)
  local c = conns[parent.id]
  if not (c and c.alive and c.model) then return end
  local ids = model_lib.read_ids(c.model)
  if #ids == 0 then return end
  local chars, err = c.session:get(ids)
  if chars then
    emit_touched(driver, parent, c, model_lib.apply(c.model, chars))
  else
    log.warn("[velux] poll failed: " .. tostring(err))
  end
end

local function handle_refresh(driver, device)
  local parent = device.parent_assigned_child_key and device:get_parent_device() or device
  cosock.spawn(function() poll(driver, parent) end, "velux-refresh")
end

-- lifecycle -----------------------------------------------------------------------------------------
local function is_parent(device) return device.parent_assigned_child_key == nil end

local function device_init(driver, device)
  if not is_parent(device) then
    if device:supports_capability(windowShade) then
      device:emit_event(windowShade.supportedWindowShadeCommands({ "open", "close", "pause" },
        { visibility = { displayed = false } }))
    end
    return
  end
  device.thread:call_on_schedule(POLL_SECS, function()
    cosock.spawn(function() poll(driver, device) end, "velux-poll")
  end, "velux-poll")
  if load_pairing(device) then
    start_session(driver, device)
  else
    pair(driver, device)
  end
end

local function device_added(driver, device)
  if not is_parent(device) then
    -- a new child: show the state we already have instead of waiting for the next event/poll
    device_init(driver, device)
    local parent = device:get_parent_device()
    local c = parent and conns[parent.id]
    local dev = c and c.model and c.model.devices[device.parent_assigned_child_key]
    if dev then pcall(emit_child, device, dev) end
    return
  end
  if is_parent(device) then
    local d = discovered[device.device_network_id]
    if d then
      device:set_field("ip", d.ip, { persist = true })
      device:set_field("port", d.port, { persist = true })
      device:set_field("hap_id", d.id, { persist = true })
    end
  end
  device_init(driver, device)
end

local function info_changed(driver, device, event, args)
  if not is_parent(device) then return end
  local old = (args and args.old_st_store and args.old_st_store.preferences) or {}
  local new = device.preferences or {}
  if new.resetPairing and not old.resetPairing then
    unpair(driver, device)
    return
  end
  if old.ipAddress ~= new.ipAddress or old.hapPort ~= new.hapPort then
    if load_pairing(device) then start_session(driver, device) end
  end
  if old.homekitCode ~= new.homekitCode and not load_pairing(device) then
    pair(driver, device)
  end
end

local function device_removed(driver, device)
  local c = conns[device.id]
  if c then
    c.stopped = true
    close_conn(c)
    conns[device.id] = nil
  end
end

local function discovery(driver, opts, should_continue)
  local found = mdns_scan()
  log.info(string.format("[velux] discovery: %d VELUX HomeKit gateway(s)", #found))
  local existing = {}
  for _, dev in ipairs(driver:get_devices()) do
    if is_parent(dev) then existing[dev.device_network_id] = dev end
  end
  for _, f in ipairs(found) do
    local dni = "velux-hap-" .. f.id:gsub(":", ""):lower()
    discovered[dni] = f
    if existing[dni] then
      existing[dni]:set_field("ip", f.ip, { persist = true })
      existing[dni]:set_field("port", f.port, { persist = true })
    else
      log.info(string.format("[velux] new gateway %s at %s:%d (%s)", f.id, f.ip, f.port,
        f.paired and "already paired with another controller" or "ready to pair"))
      driver:try_create_device({
        type = "LAN", device_network_id = dni, label = "VELUX Gateway", profile = "velux-gateway",
        manufacturer = "VELUX", model = "KIX 300", vendor_provided_label = "VELUX Gateway",
      })
    end
  end
  if #found == 0 and next(existing) == nil then
    -- no mDNS result: create a gateway device anyway so IP/port can be set by hand
    driver:try_create_device({
      type = "LAN", device_network_id = "velux-hap-manual", label = "VELUX Gateway", profile = "velux-gateway",
      manufacturer = "VELUX", model = "KIX 300", vendor_provided_label = "VELUX Gateway",
    })
  end
end

local driver = Driver("velux-active-homekit-local", {
  discovery = discovery,
  lifecycle_handlers = { init = device_init, added = device_added, infoChanged = info_changed,
                         removed = device_removed },
  capability_handlers = {
    [capabilities.refresh.ID] = { [capabilities.refresh.commands.refresh.NAME] = handle_refresh },
    [windowShade.ID] = {
      [windowShade.commands.open.NAME] = handle_open,
      [windowShade.commands.close.NAME] = handle_close,
      [windowShade.commands.pause.NAME] = handle_pause,
    },
    [windowShadeLevel.ID] = { [windowShadeLevel.commands.setShadeLevel.NAME] = handle_level },
  },
})

log.info("[velux] VELUX ACTIVE (HomeKit local) driver starting, build " .. BUILD)
driver:run()
