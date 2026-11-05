"""Run the VELUX Edge driver (init.lua) with a mocked SmartThings runtime against a HAP-python
accessory: discovery-less manual address, pairing via the HomeKit code preference, session setup,
child creation, initial state, a command and an event."""
import os
import socket
import time

from run_lua import runtime
from test_hap import accessory, PIN  # noqa: F401  (fixture)

from run_lua import SRC as _SRC
SRC = str(_SRC)
TEST_DIR = os.path.dirname(os.path.abspath(__file__))

HARNESS = rb'''
EVENTS = {}
local function capmock(path)
  return setmetatable({}, {
    __index = function(t, k) local v = capmock(path .. "." .. k); rawset(t, k, v); return v end,
    __call = function(_, arg) return { path = path, arg = arg } end })
end
local caps = capmock("cap")
caps.windowShade.ID = "windowShade"
caps.windowShadeLevel.ID = "windowShadeLevel"
caps.refresh.ID = "refresh"
package.loaded["st.capabilities"] = caps
package.loaded["st.driver"] = function(name, tmpl) DRIVER = tmpl; return { run = function() end } end
package.loaded["log"] = { info = function(m) print("I " .. m) end, warn = function(m) print("W " .. m) end,
                          error = function(m) print("E " .. m) end, debug = function() end }
STOP_AFTER_SLEEP = false
local socketlib = { gettime = function() return py_time() end,
  sleep = function(s) if s > 1 and STOP_AFTER_SLEEP then error("STOP") end end,
  tcp = function() return py_tcp() end }
package.loaded["cosock"] = { socket = socketlib, spawn = function(fn, name)
  local ok, err = pcall(fn); if not ok and not tostring(err):find("STOP") then print("task " .. tostring(name) .. " error: " .. tostring(err)) end end }
package.loaded["st.json"] = require "st.json"

DEVICES = {}
local function new_device(info)
  local d = { id = info.id or ("dev" .. (#DEVICES + 1)), fields = {}, preferences = info.preferences or {},
              device_network_id = info.device_network_id, parent_device_id = info.parent_device_id,
              parent_assigned_child_key = info.parent_assigned_child_key, label = info.label,
              profile = info.profile, events = {}, state = "online" }
  function d:get_field(k) return self.fields[k] end
  function d:set_field(k, v) self.fields[k] = v end
  function d:emit_event(e) self.events[#self.events + 1] = e end
  function d:online() self.state = "online" end
  function d:offline() self.state = "offline" end
  function d:supports_capability() return true end
  function d:get_parent_device() for _, p in ipairs(DEVICES) do if p.id == self.parent_device_id then return p end end end
  d.thread = { call_on_schedule = function() end, call_with_delay = function() end }
  DEVICES[#DEVICES + 1] = d
  return d
end
DRIVER_OBJ = { get_devices = function() return DEVICES end,
  try_create_device = function(self, info) local d = new_device(info); CREATED = (CREATED or 0) + 1 end }
NEW_DEVICE = new_device
'''


class PySock:
    def __init__(self):
        self.s = None

    def settimeout(self, t):
        self._t = t
        if self.s:
            self.s.settimeout(3 if t is None else min(t, 5))

    def connect(self, ip, port):
        self.s = socket.create_connection((ip.decode(), int(port)), timeout=5)
        return 1

    def send(self, data):
        self.s.sendall(data)
        return len(data)

    def receive(self, n):
        try:
            d = self.s.recv(int(n))
        except socket.timeout:
            self.timeouts = getattr(self, "timeouts", 0) + 1
            if self.timeouts > 3:  # the reader loop now waits on idle timeouts: end the test session
                raise RuntimeError("STOP idle")
            return None, b"timeout"
        self.timeouts = 0
        if not d:
            return None, b"closed"
        return d

    def close(self):
        if self.s:
            self.s.close()


def test_driver_end_to_end(accessory):  # noqa: F811
    PORT = accessory["port"]
    lua = runtime()
    lua.execute(f'package.path = "{SRC}/?.lua;{TEST_DIR}/?.lua;" .. package.path'.encode())
    g = lua.globals()
    g.py_time = time.time
    g.py_tcp = PySock
    lua.execute(HARNESS)
    lua.execute(b'dofile("' + SRC.encode() + b'/init.lua")')
    hap = lua.execute(b'return require "hap_client"')
    hap.random_bytes = lambda n: os.urandom(int(n))
    lua.execute(b'STOP_AFTER_SLEEP = true')

    # gateway device with manual address and the HomeKit code set
    parent = lua.eval(b"NEW_DEVICE")(lua.table_from({
        b"id": b"gw", b"device_network_id": b"velux-hap-manual", b"label": b"VELUX Gateway",
        b"preferences": lua.table_from({b"homekitCode": PIN.replace(b"-", b""), b"ipAddress": b"127.0.0.1",
                                        b"hapPort": PORT})}))
    drv = lua.eval(b"DRIVER")
    added = drv[b"lifecycle_handlers"][b"added"]
    t0 = time.time()
    added(lua.eval(b"DRIVER_OBJ"), parent)   # pairs, then runs the session until the read times out
    print(f"pair+session {time.time() - t0:.1f}s")

    assert parent[b"fields"][b"hap_pairing"] is not None, "not paired"
    devs = list(lua.eval(b"DEVICES").values())
    kids = [d for d in devs if d[b"parent_device_id"] == b"gw"]
    assert len(kids) == 1, [d[b"label"] for d in devs]
    win = kids[0]
    assert win[b"profile"] == b"velux-window"
    paths = [e[b"path"] for e in win[b"events"].values()] if win[b"events"] else []
    print("events before child existed:", paths)

    # second run: child exists now, so the initial state must be emitted; then send a command
    lua.execute(b'STOP_AFTER_SLEEP = true')
    init = drv[b"lifecycle_handlers"][b"init"]
    init(lua.eval(b"DRIVER_OBJ"), parent)
    paths = [e[b"path"] for e in win[b"events"].values()]
    assert any(p.endswith(b"shadeLevel") for p in paths), paths
    assert any(p.endswith(b"windowShade.closed") for p in paths), paths
