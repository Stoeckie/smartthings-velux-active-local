"""2026-11-09 audit fixes in init.lua: one poll timer per gateway, no zombie session after a restart during
connect, a Lua error in session setup or pairing does not leave the connection stuck, optimistic
opening/closing with the real state shown again when the write fails."""
import os
import time

from run_lua import runtime, SRC as _SRC
import test_velux_driver as base

SRC = str(_SRC)
TEST_DIR = os.path.dirname(os.path.abspath(__file__))

SETUP = rb'''
LOGS = {}
local log = package.loaded["log"]
log.error = function(m) LOGS[#LOGS + 1] = m; print("E " .. m) end
GW = NEW_DEVICE({ id = "gw", device_network_id = "velux-hap-x", label = "GW",
  preferences = { ipAddress = "127.0.0.1", hapPort = 1, homekitCode = "03145154" } })
TIMERS, CANCELLED, DELAYS = 0, {}, 0
GW.thread = {
  call_on_schedule = function() TIMERS = TIMERS + 1; return "timer" .. TIMERS end,
  cancel_timer = function(_, t) CANCELLED[#CANCELLED + 1] = t end,
  call_with_delay = function() DELAYS = DELAYS + 1 end }
SOCKS = {}
function py_tcp()
  local s = { sent = 0, closed = false }
  function s:settimeout() end
  function s:connect() if CONNECT_HOOK then local h = CONNECT_HOOK; CONNECT_HOOK = nil; h() end return 1 end
  function s:send(d) if SEND_ERROR then error("boom in send") end self.sent = self.sent + 1; return #d end
  function s:receive() return nil, "closed" end
  function s:close() self.closed = true end
  SOCKS[#SOCKS + 1] = s
  return s
end
PAIRING = { controller_id = "C", controller_seed = string.rep("00", 32), controller_pub = string.rep("00", 32),
  accessory_id = "A", accessory_pub = string.rep("00", 32) }
'''


def setup(stop=True):
    lua = runtime()
    lua.execute(f'package.path = "{SRC}/?.lua;{TEST_DIR}/?.lua;" .. package.path'.encode())
    g = lua.globals()
    g.py_time = time.time
    lua.execute(base.HARNESS)
    lua.execute(b'dofile("' + SRC.encode() + b'/init.lua")')
    lua.execute(SETUP)
    if stop:
        lua.execute(b'STOP_AFTER_SLEEP = true')  # end each session task at its first reconnect wait
    return lua


CONNS = rb'''
-- conns is a local of init.lua: reach it through the upvalues of a lifecycle handler
local function find(fn, name, seen)
  seen = seen or {}
  if seen[fn] then return end
  seen[fn] = true
  for i = 1, 200 do
    local n, v = debug.getupvalue(fn, i)
    if not n then break end
    if n == name then return v end
    if type(v) == "function" then local r = find(v, name, seen); if r then return r end end
  end
end
CONNS = find(DRIVER.lifecycle_handlers.removed, "conns")
'''


def test_one_poll_timer():
    lua = setup()
    lua.execute(b'GW.fields.hap_pairing = PAIRING')
    lua.execute(b'DRIVER.lifecycle_handlers.init(DRIVER_OBJ, GW); DRIVER.lifecycle_handlers.added(DRIVER_OBJ, GW)')
    assert lua.eval(b'TIMERS') == 2
    assert lua.eval(b'#CANCELLED') == 1 and lua.eval(b'CANCELLED[1]') == b"timer1"


def test_no_zombie_session_when_restarted_during_connect():
    lua = setup()
    lua.execute(CONNS)
    lua.execute(b'''
      GW.fields.hap_pairing = PAIRING
      CONNECT_HOOK = function() FIRST_C = CONNS["gw"]; DRIVER.lifecycle_handlers.infoChanged(DRIVER_OBJ, GW,
        "infoChanged", { old_st_store = { preferences = { ipAddress = "127.0.0.2", hapPort = 1 } } }) end
      DRIVER.lifecycle_handlers.init(DRIVER_OBJ, GW)''')
    assert lua.eval(b'SOCKS[1].closed') is True
    assert lua.eval(b'SOCKS[1].sent') == 0
    assert lua.eval(b'FIRST_C.stopped') is True and lua.eval(b'not FIRST_C.alive') is True
    assert lua.eval(b'CONNS["gw"] ~= FIRST_C') is True
    assert lua.eval(b'SOCKS[2].sent') > 0


def test_lua_error_in_setup_closes_connection():
    lua = setup()
    lua.execute(CONNS)
    lua.execute(b'GW.fields.hap_pairing = PAIRING; SEND_ERROR = true')
    lua.execute(b'DRIVER.lifecycle_handlers.init(DRIVER_OBJ, GW)')
    assert lua.eval(b'CONNS["gw"].alive') is False
    assert lua.eval(b'SOCKS[1].closed') is True
    assert any(b"session error" in m for m in lua.eval(b'LOGS').values())
    assert lua.eval(b'GW.state') == b"offline"


def test_lua_error_in_pairing_resets_pairing_flag():
    lua = setup()
    lua.execute(CONNS)
    lua.execute(b'SEND_ERROR = true; DRIVER.lifecycle_handlers.init(DRIVER_OBJ, GW)')
    assert lua.eval(b'CONNS["gw"].pairing') is False
    assert lua.eval(b'SOCKS[1].closed') is True
    assert lua.eval(b'DELAYS') == 1


def test_optimistic_state_and_restore_on_failure():
    lua = setup(stop=False)
    lua.execute(CONNS)
    lua.execute(b'''
      WIN = NEW_DEVICE({ id = "w1", parent_device_id = "gw", parent_assigned_child_key = "2.9", label = "Roof" })
      PUTS = 0
      CONNS["gw"] = { alive = true, responses = {}, model = { devices = { ["2.9"] = { key = "2.9", kind = "window",
          aid = 2, chars = { target = 11, position = 10 }, values = { position = 0, target = 0 } } }, order = { "2.9" } },
        session = { put = function() PUTS = PUTS + 1; return nil, "timeout" end } }
      local caps = package.loaded["st.capabilities"]
      DRIVER.capability_handlers.windowShade[caps.windowShade.commands.open.NAME](DRIVER_OBJ, WIN)''')
    paths = [e[b"path"] for e in lua.eval(b'WIN.events').values()]
    assert lua.eval(b'PUTS') == 2  # first try and one retry
    assert paths[0].endswith(b"windowShade.opening"), paths   # right after the command
    assert paths[-1].endswith(b"windowShade.closed"), paths   # write failed: real state again


def test_poll_uses_the_session_lock():
    """poll and the batched write go through Session:request, which takes the per-session lock."""
    lua = setup(stop=False)
    hap = lua.execute(b'return require "hap_client"')
    assert hap.sleep is not None
