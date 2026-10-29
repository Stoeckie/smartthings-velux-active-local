"""Pair the Lua HAP stack with the real VELUX gateway, list accessories, then remove the pairing again
(so the SmartThings hub can pair afterwards). Usage: python3 real_test.py IP PORT PIN [keep]"""
import os, socket, sys, time, json
from lupa import lua53
HERE = os.path.dirname(os.path.abspath(__file__))
ip, port, pin = sys.argv[1], int(sys.argv[2]), sys.argv[3].encode()
keep = len(sys.argv) > 4
lua = lua53.LuaRuntime(unpack_returned_tuples=True, encoding=None)
lua.execute(f'package.path = "{HERE}/?.lua;" .. package.path'.encode())
hap = lua.execute(b'return require "hap_client"')
hap.json = lua.execute(b'return require "st.json"')
hap.random_bytes = lambda n: os.urandom(int(n))

class Sock:
    def __init__(self): self.s = socket.create_connection((ip, port), timeout=60)
    def send(self, d): self.s.sendall(d); return len(d)
    def receive(self, n):
        try: d = self.s.recv(int(n))
        except socket.timeout: return None, b"timeout"
        return d if d else (None, b"closed")
def call(f, *a):
    r = f(*a); return r if isinstance(r, tuple) else (r, None)
def py(o):
    if hasattr(o, "items"):
        keys = list(o.keys())
        if keys and all(isinstance(k, int) for k in keys): return [py(o[k]) for k in sorted(keys)]
        return {(k.decode() if isinstance(k, bytes) else k): py(v) for k, v in o.items()}
    return o.decode("utf-8", "replace") if isinstance(o, bytes) else o

opts = lua.table_from({b"host": ip.encode()})
pf = os.path.join(HERE, "pairing.json")
if os.path.exists(pf):
    d = json.load(open(pf))
    p = lua.table_from({b"controller_id": d["controller_id"].encode(), b"controller_seed": bytes.fromhex(d["seed"]),
        b"controller_pub": bytes.fromhex(d["pub"]), b"accessory_id": d["acc_id"].encode(), b"accessory_pub": bytes.fromhex(d["acc_pub"])})
    print("using existing pairing")
else:
    s = hap.session(Sock(), opts)
    t0 = time.time()
    import uuid
    p, err = call(s.pair_setup, s, pin, str(uuid.uuid4()).upper().encode())
    print("pair_setup:", "OK" if p else err, f"{time.time()-t0:.1f}s")
    if not p: sys.exit(1)
    json.dump({"controller_id": p[b"controller_id"].decode(), "seed": p[b"controller_seed"].hex(), "pub": p[b"controller_pub"].hex(),
               "acc_id": p[b"accessory_id"].decode(), "acc_pub": p[b"accessory_pub"].hex()}, open(pf, "w"))
s2 = hap.session(Sock(), opts)
ok, err = call(s2.pair_verify, s2, p)
print("pair_verify:", "OK" if ok else err)
if not ok: sys.exit(1)
accs, err = call(s2.accessories, s2)
accs = py(accs)
json.dump(accs, open(os.path.join(HERE, "accessories.json"), "w"), indent=1)
model = lua.execute(b'return require "velux_model"')
m = model.build(lua.execute(b'return require("st.json").decode(...)', json.dumps(accs).encode()))
for k in m[b"order"].values():
    d = m[b"devices"][k]
    print(" ", k.decode(), d[b"kind"].decode(), d[b"name"].decode(), py(d[b"values"]))
if not keep:
    r, err = call(s2.remove_pairing, s2, p[b"controller_id"])
    print("remove_pairing:", "OK" if r else err)
    if r: os.remove(pf)
