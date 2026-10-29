"""End-to-end test: Lua HAP controller against a HAP-python accessory (WindowCovering) on localhost."""
import asyncio
import os
import socket
import tempfile
import threading
import time

import pytest
from pyhap.accessory import Accessory, Bridge
from pyhap.accessory_driver import AccessoryDriver
from pyhap.const import CATEGORY_WINDOW

from run_lua import runtime, req, SRC

PIN = b"031-45-154"  # HomeKit example code
TEST_DIR = os.path.dirname(os.path.abspath(__file__))


class Roof(Accessory):
    category = CATEGORY_WINDOW

    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        svc = self.add_preload_service("Window", chars=["HoldPosition"])
        self.cur = svc.configure_char("CurrentPosition", value=0)
        self.state = svc.configure_char("PositionState", value=2)
        self.tgt = svc.configure_char("TargetPosition", value=0, setter_callback=self.set_target)
        self.targets = []

    def set_target(self, v):
        self.targets.append(v)
        self.cur.set_value(v)  # move instantly; pushes an event to subscribers


@pytest.fixture(scope="module")
def accessory():
    with socket.socket() as probe:  # free port per fixture instance
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    tmp = tempfile.mkdtemp()
    loop = asyncio.new_event_loop()
    holder = {}

    def run():
        asyncio.set_event_loop(loop)
        drv = AccessoryDriver(port=port, persist_file=os.path.join(tmp, "acc.state"), pincode=PIN,
                              loop=loop, address="127.0.0.1", listen_address="127.0.0.1",
                              advertised_address="127.0.0.1")
        bridge = Bridge(drv, "VELUX Test Gateway")
        roof = Roof(drv, "Dakraam")
        bridge.add_accessory(roof)
        drv.add_accessory(bridge)
        holder["drv"], holder["roof"], holder["port"] = drv, roof, port
        drv.start()

    t = threading.Thread(target=run, daemon=True)
    t.start()
    for _ in range(100):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
            break
        except OSError:
            time.sleep(0.1)
    yield holder
    loop.call_soon_threadsafe(loop.stop)


class Sock:
    """LuaSocket-like wrapper: send(data) -> n ; receive(n) -> data | (None, err)."""

    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=30)

    def send(self, data):
        self.s.sendall(data)
        return len(data)

    def receive(self, n):
        try:
            d = self.s.recv(n)
        except socket.timeout:
            return None, b"timeout"
        if not d:
            return None, b"closed"
        return d


def call(f, *a):
    r = f(*a)
    return r if isinstance(r, tuple) else (r, None)


def lua_env():
    lua = runtime()
    lua.execute(f'package.path = "{TEST_DIR}/?.lua;" .. package.path'.encode())
    hap = req(lua, "hap_client")
    rnd = lambda n: os.urandom(int(n))
    hap.random_bytes = rnd
    return lua, hap


def test_full_flow(accessory):
    PORT = accessory["port"]
    lua, hap = lua_env()
    events = []
    on_event = lambda chars: events.append([(c[b"aid"], c[b"iid"], c[b"value"]) for c in chars.values()])
    opts = lua.table_from({b"host": b"127.0.0.1", b"on_event": on_event})

    # pair setup
    s = hap.session(Sock(PORT), opts)
    t0 = time.time()
    p, err = call(s.pair_setup, s, PIN, b"8B4F2C1E-3A5D-4E6F-9A7B-1C2D3E4F5A6B")
    assert p is not None, err
    print(f"pair_setup {time.time() - t0:.1f}s")
    assert len(p[b"accessory_pub"]) == 32

    # pair verify on a fresh connection
    s2 = hap.session(Sock(PORT), opts)
    t0 = time.time()
    ok, err = call(s2.pair_verify, s2, p)
    assert ok, err
    print(f"pair_verify {time.time() - t0:.2f}s")

    accs, _ = call(s2.accessories, s2)
    assert accs is not None
    found = None
    for acc in accs.values():
        for svc in acc[b"services"].values():
            for ch in svc[b"characteristics"].values():
                if ch[b"type"].upper() in (b"7C", b"0000007C-0000-1000-8000-0026BB765291"):
                    found = (acc[b"aid"], ch[b"iid"])
                if ch[b"type"].upper() in (b"6D", b"0000006D-0000-1000-8000-0026BB765291"):
                    cur = (acc[b"aid"], ch[b"iid"])
    assert found, "TargetPosition not found"

    ids = lua.table_from([lua.table_from([cur[0], cur[1]])])
    r, err = call(s2.subscribe, s2, ids)
    assert r is not None, err

    items = lua.table_from([lua.table_from({b"aid": found[0], b"iid": found[1], b"value": 55})])
    r, err = call(s2.put, s2, items)
    assert r is not None, err
    assert accessory["roof"].targets[-1] == 55

    # read back + collect the event pushed by the accessory
    got, _ = call(s2.get, s2, lua.table_from([lua.table_from([cur[0], cur[1]])]))
    assert got[1][b"value"] == 55
    deadline = time.time() + 5
    while not events and time.time() < deadline:
        msg, _ = call(s2.read_message, s2)
        if msg and msg[b"event"]:
            s2._dispatch_event(s2, msg)
    assert any(e == (cur[0], cur[1], 55) for batch in events for e in batch), events

    # wrong pin on a new accessory state is covered by srp tests; here: verify fails with a wrong key
    s3 = hap.session(Sock(PORT), opts)
    bad = lua.table_from({b"controller_id": b"nobody", b"controller_seed": os.urandom(32),
                          b"controller_pub": p[b"controller_pub"], b"accessory_id": p[b"accessory_id"],
                          b"accessory_pub": p[b"accessory_pub"]})
    ok, err = call(s3.pair_verify, s3, bad)
    assert not ok


def test_http_parser():
    lua, hap = lua_env()
    msg, rest = call(hap._parse_message, b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}EVENT")
    assert msg[b"status"] == 200 and msg[b"body"] == b"{}" and rest == b"EVENT"
    chunked = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\nX"
    msg, rest = call(hap._parse_message, chunked)
    assert msg[b"body"] == b"abcde" and rest == b"X"
    msg, _ = call(hap._parse_message, b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nab")
    assert msg is None
    ev, _ = call(hap._parse_message, b"EVENT/1.0 200 OK\r\nContent-Length: 0\r\n\r\n")
    assert ev[b"event"]
