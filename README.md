# VELUX ACTIVE (HomeKit local) — SmartThings Edge driver

Local control of **VELUX ACTIVE with NETATMO** (gateway **KIX 300**) roof windows, blinds and the indoor climate sensor in SmartThings. The hub talks to the gateway directly over **HomeKit** on your own network: no cloud, no Apple device, no bridge computer.

The complete HomeKit controller (pair setup with SRP-6a, Ed25519, X25519, ChaCha20-Poly1305, TLV8, encrypted sessions and events) is written in pure Lua and runs on the hub.

## What you get

* **Roof windows**: open, close, any position 0 to 100 % (100 = fully open, e.g. 30 % for airing), plus an open/closed contact for routines ("window open and it rains", "window still open at night")
* **Blinds, awnings, roller shutters**: open, close, any position
* **Climate sensor**: temperature, humidity, CO₂
* Live updates: the gateway pushes every change, plus a safety poll every 5 minutes
* Online/offline state, automatic reconnect

Not available over HomeKit (VELUX limitation): the rain sensor. "Pause" while moving sends the current position as the new target.

## Requirements

* SmartThings hub with Edge (v2, v3/Aeotec, Station)
* VELUX ACTIVE gateway KIX 300, set up with the VELUX ACTIVE app, on the same network as the hub
* The 8-digit **HomeKit code** on the sticker of the gateway
* The gateway must **not** be paired with Apple Home or another HomeKit controller (it accepts one). Remove it there first.

## Install

1. Enroll your hub in the channel: https://bestow-regional.api.smartthings.com/invite/qWjBdybRNG2y (Stoeckie Edge Drivers) and install **VELUX ACTIVE (HomeKit local)**.
2. SmartThings app: **Add device → Scan nearby**. A "VELUX Gateway" device appears (found via mDNS).
3. Open the gateway device → Settings → **HomeKit code**. Digits only or with dashes, both work.
4. Pairing runs once on the hub and takes 1 to 3 minutes (3072-bit SRP in Lua). After that every window, blind and the sensor appears as its own device. Reconnects only take a few seconds.

Rename the devices in the app; the gateway calls every window "Roof Window" and every awning "Awning Blinds", the driver numbers them.

## Settings (gateway device)

| Setting | Meaning |
|---|---|
| HomeKit code | 8 digits from the gateway sticker, needed once |
| Gateway IP | `auto` (mDNS) or a fixed IP |
| HomeKit port | `0` = auto; the KIX 300 uses **5001** (also used automatically when you set an IP) |
| Remove pairing | Unpairs the hub from the gateway, e.g. before re-pairing |

## Departure mode and rain sensor (optional)

HomeKit has no lock, so the departure mode (all windows and blinds blocked, as with the departure switch) and the gateway's rain sensor are not in this driver. They come from the VELUX cloud through the [Stoeckie Bridge](https://github.com/Stoeckie/smartthings-stoeckie-bridge): a **VELUX vertrekstand** lock device (lock and unlock) and a **VELUX regensensor** device (rain sensor: detected = raining), updated every 60 s (adjustable in the settings of VELUX vertrekstand). The windows keep running locally through this driver.

## Troubleshooting

* **Gateway not found / no open port**: on our gateway the HomeKit service was off (the gateway answered ping, but had no open ports and no mDNS record). A Wi-Fi reset fixed it: hold the gear button on the back until the LED blinks red, release, press again to confirm, then set up Wi-Fi again in the VELUX ACTIVE app (Settings → Gateway). Window pairings are kept. After that port 5001 was open.
* **"HomeKit error 2"**: wrong code. **"HomeKit error 6"**: already paired with another controller.
* Logs: `smartthings edge:drivers:logcat <driverId> --hub-address <hub-ip>`, lines start with `[velux]`.

## Privacy

The HomeKit code is a device setting. The pairing keys (controller identity and the gateway's public key) are stored on the hub as device fields. Nothing secret is in this code or the package.

## Development

```
smartthings edge:drivers:package .
```

`config.yaml` needs both `lan` and `discovery` permissions.

Files:

* `src/init.lua`: driver (discovery, pairing, session, children, commands)
* `src/hap_client.lua`: HomeKit (HAP over IP) controller
* `src/srp.lua`, `src/bignum.lua`: SRP-6a with SHA-512 and the 3072-bit group (Montgomery modpow)
* `src/curve25519.lua`: X25519 and Ed25519; `src/chacha20poly1305.lua`: AEAD; `src/sha512.lua`: SHA-512, HMAC, HKDF; `src/tlv8.lua`: TLV8
* `src/velux_model.lua`: maps the HomeKit accessory tree to SmartThings devices

Tests (Python + lupa, Lua 5.3): crypto against `cryptography` and RFC vectors, SRP against aiohomekit, the full controller and the driver (with a mocked SmartThings runtime) against a HAP-python accessory.

```
pip install lupa cryptography aiohomekit HAP-python pytest
python -m pytest tests
```

`tools/pair_test.py` pairs a computer with a real gateway using the same Lua code, lists the accessories and removes the pairing again.

## License

Apache 2.0, see LICENSE. Not affiliated with VELUX, Netatmo, Apple or Samsung SmartThings.
