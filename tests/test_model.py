import json
from run_lua import runtime, req
import os

ACC = {"accessories": [
 {"aid": 1, "services": [{"iid": 1, "type": "3E", "characteristics": [{"iid": 2, "type": "23", "value": "VELUX Gateway"}]}]},
 {"aid": 2, "services": [
   {"iid": 1, "type": "0000003E-0000-1000-8000-0026BB765291", "characteristics": [{"iid": 2, "type": "00000023-0000-1000-8000-0026BB765291", "value": "Dakraam"}]},
   {"iid": 8, "type": "8B", "characteristics": [{"iid": 9, "type": "6D", "value": 0}, {"iid": 10, "type": "7C", "value": 0}, {"iid": 11, "type": "72", "value": 2}]}]},
 {"aid": 3, "services": [
   {"iid": 1, "type": "3E", "characteristics": [{"iid": 2, "type": "23", "value": "Rolluik"}]},
   {"iid": 8, "type": "8C", "characteristics": [{"iid": 9, "type": "6D", "value": 40}, {"iid": 10, "type": "7C", "value": 40}, {"iid": 12, "type": "6F"}]}]},
 {"aid": 4, "services": [
   {"iid": 1, "type": "3E", "characteristics": [{"iid": 2, "type": "23", "value": "Sensor"}]},
   {"iid": 8, "type": "8A", "characteristics": [{"iid": 9, "type": "11", "value": 21.5}]},
   {"iid": 10, "type": "82", "characteristics": [{"iid": 11, "type": "10", "value": 48}]},
   {"iid": 12, "type": "97", "characteristics": [{"iid": 13, "type": "92", "value": 0}, {"iid": 14, "type": "93", "value": 620}]}]}]}

def test_model():
    lua = runtime()
    json_ = req(lua, "st.json")
    m = req(lua, "velux_model")
    accs = json_.decode(json.dumps(ACC).encode())
    model = m.build(accs[b"accessories"])
    devs = model[b"devices"]
    kinds = {k: (d[b"kind"], d[b"name"]) for k, d in devs.items()}
    assert kinds == {b"2.8": (b"window", b"Dakraam"), b"3.8": (b"blind", b"Rolluik"), b"4.climate": (b"climate", b"Sensor")}, kinds
    ids = m.read_ids(model)
    assert len(ids) == 3 + 2 + 3  # hold excluded
    ev = json_.decode(b'[{"aid":2,"iid":9,"value":30},{"aid":2,"iid":11,"value":1},{"aid":9,"iid":9,"value":1}]')
    touched = m.apply(model, ev)
    assert list(touched.keys()) == [b"2.8"]
    st = m.shade_state(devs[b"2.8"])
    assert st == (b"opening", 30)
    assert m.shade_state(devs[b"3.8"]) == (b"partially open", 40)
    assert devs[b"4.climate"][b"values"][b"co2"] == 620
