-- Map a HomeKit /accessories tree to SmartThings devices, and characteristic updates to their state.
local M = {}

local SUFFIX = "-0000-1000-8000-0026BB765291"

--- HomeKit type ("7C", "0000007C-0000-1000-8000-0026BB765291") -> short upper form "7C"
function M.short(t)
  t = tostring(t or ""):upper()
  if t:sub(-#SUFFIX) == SUFFIX then t = t:sub(1, -#SUFFIX - 1) end
  t = t:gsub("^0+", "")
  return t
end

local S = { info = "3E", window = "8B", covering = "8C", temp = "8A", hum = "82", co2 = "97", air = "8D" }
local C = { name = "23", serial = "30", cur = "6D", tgt = "7C", state = "72", hold = "6F",
            temp = "11", hum = "10", co2 = "93" }

local function chars_by_type(svc)
  local out = {}
  for _, ch in ipairs(svc.characteristics or {}) do out[M.short(ch.type)] = ch end
  return out
end

--- Build the model: { devices = {key -> dev}, index = {"aid.iid" -> {key, field}} }
--- dev = { key, kind = "window"|"blind"|"climate", name, aid, chars = {field -> iid}, values = {} }
function M.build(accessories)
  local model = { devices = {}, index = {}, order = {} }
  for _, acc in ipairs(accessories or {}) do
    local aid = acc.aid
    local acc_name = "VELUX " .. tostring(aid)
    for _, svc in ipairs(acc.services or {}) do
      if M.short(svc.type) == S.info then
        local ch = chars_by_type(svc)
        if ch[C.name] and ch[C.name].value and ch[C.name].value ~= "" then acc_name = ch[C.name].value end
      end
    end
    local climate
    for _, svc in ipairs(acc.services or {}) do
      local st = M.short(svc.type)
      local ch = chars_by_type(svc)
      local function add(dev, field, ctype)
        if ch[ctype] then
          dev.chars[field] = ch[ctype].iid
          dev.values[field] = ch[ctype].value
          model.index[aid .. "." .. ch[ctype].iid] = { dev.key, field }
        end
      end
      if (st == S.window or st == S.covering) and ch[C.tgt] then
        local name = (ch[C.name] and ch[C.name].value) or acc_name
        local dev = { key = aid .. "." .. svc.iid, kind = (st == S.window) and "window" or "blind",
                      name = name, aid = aid, chars = {}, values = {} }
        add(dev, "position", C.cur)
        add(dev, "target", C.tgt)
        add(dev, "state", C.state)
        add(dev, "hold", C.hold)
        model.devices[dev.key] = dev
        model.order[#model.order + 1] = dev.key
      elseif st == S.temp or st == S.hum or st == S.co2 then
        if not climate then
          climate = { key = aid .. ".climate", kind = "climate", name = acc_name, aid = aid, chars = {}, values = {} }
          model.devices[climate.key] = climate
          model.order[#model.order + 1] = climate.key
        end
        add(climate, "temperature", C.temp)
        add(climate, "humidity", C.hum)
        add(climate, "co2", C.co2)
      end
    end
  end
  -- the gateway names every window "Roof Window": number duplicates so the app shows distinct devices
  local count, seen = {}, {}
  for _, key in ipairs(model.order) do
    local n = model.devices[key].name
    count[n] = (count[n] or 0) + 1
  end
  for _, key in ipairs(model.order) do
    local dev = model.devices[key]
    if count[dev.name] > 1 then
      seen[dev.name] = (seen[dev.name] or 0) + 1
      dev.name = dev.name .. " " .. seen[dev.name]
    end
  end
  return model
end

--- ids to subscribe to / poll: list of {aid, iid}, excluding write-only HoldPosition
function M.read_ids(model)
  local ids = {}
  for _, key in ipairs(model.order) do
    local dev = model.devices[key]
    for field, iid in pairs(dev.chars) do
      if field ~= "hold" then ids[#ids + 1] = { dev.aid, iid } end
    end
  end
  return ids
end

--- Apply a list of {aid, iid, value}; returns set of touched device keys.
function M.apply(model, chars)
  local touched = {}
  for _, c in ipairs(chars or {}) do
    local hit = model.index[tostring(c.aid) .. "." .. tostring(c.iid)]
    if hit and c.value ~= nil then
      model.devices[hit[1]].values[hit[2]] = c.value
      touched[hit[1]] = true
    end
  end
  return touched
end

--- windowShade state name for a window/blind dev
function M.shade_state(dev)
  local v = dev.values
  local pos = tonumber(v.position) or tonumber(v.target)
  local st = tonumber(v.state)
  if st == 0 then return "closing", pos end
  if st == 1 then return "opening", pos end
  if pos == nil then return "unknown", nil end
  if pos >= 99 then return "open", pos end
  if pos <= 1 then return "closed", pos end
  return "partially open", pos
end

return M
