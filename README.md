# SignalRGB — Secretlab MAGRGB (Nanoleaf NL72S2)

SignalRGB network plugin for the **Secretlab MAGRGB lightstrip, Smart Lighting Edition**
(Nanoleaf model `NL72S2`, Matter-over-Wi-Fi hardware). Gives per-zone, real-time RGB
sync alongside the rest of your SignalRGB devices.

Install it as a SignalRGB **addon** (Devices → Addons → add this repository's URL).

```
network/SecretlabMAGRGB/SecretlabMAGRGB.js    the plugin
network/SecretlabMAGRGB/SecretlabMAGRGB.qml   its panel in the SignalRGB UI
tools/                                        PowerShell pairing + diagnostic scripts
```

---

## How it works

```
SignalRGB canvas
      │  device.color(x, 0)  ×41
      ▼
plugin  ──HTTP PUT /api/v1/<token>/effects──►  arm extControl v2   (TCP 16021)
        ──UDP extControl v2 frames──────────►  41 zones @ 30 fps   (UDP 60222)
```

The strip is a Nanoleaf Essentials-class device. It speaks three protocols:

| Port | Protocol | Used for |
|---|---|---|
| 16021/TCP | Nanoleaf OpenAPI (`_nanoleafapi._tcp`) | pairing, arming extControl |
| 60222/UDP | Nanoleaf external control v2 | the actual pixel stream |
| 12566/TCP | LTPDU (proprietary, encrypted) | unlocking the OpenAPI, effects |

Matter is **not** used. Although the product is marketed as Matter-over-Wi-Fi, the unit
advertises only `_nanoleafapi._tcp` and `_ltpdu._tcp` over mDNS — no `_matter._tcp`
operational service — and every Nanoleaf product in the CSA Distributed Compliance Ledger
is certified as device type `0x010D` (Extended Color Light): a single endpoint with
OnOff / LevelControl / ColorControl. Matter through 1.5.1 has no multi-zone lighting
device type and no streaming transport, so it cannot express per-zone control at all.

---

## Measured device facts (firmware 4.0.0, hardware 1.3.0)

- **41 addressable zones**, panel IDs `0..40`.
- **Panel ID 0 is at the right-hand end** of the strip. The plugin reverses the mapping
  by default (`Reverse direction` setting) so the SignalRGB canvas isn't mirrored.
- `GET /panelLayout/*` returns **HTTP 500** — not implemented on this 1D device. The zone
  count therefore cannot be discovered and is pinned per model in `MODEL_ZONES`.
- A frame containing **any out-of-range panel ID is rejected in full**, not partially
  applied. Never send more than 41 entries.
- extControl **only updates the zones present in the frame**; every other zone keeps its
  previous colour. The plugin always sends all 41, so this never causes stale zones.
- `PUT /effects` with extControl v2 replies **204**, after which
  `GET /effects/select` reads `"*ExtControl*"`.

### extControl v2 frame format (big-endian)

```
uint16  panelCount
repeat panelCount times:
    uint16  panelId
    uint8   R, G, B, W
    uint16  transitionTime      (units of 100 ms; 0 = instant)
```

---

## First-time pairing

The OpenAPI is gated behind two commands that only exist on the LTPDU channel:

```
POST openapi/enable [1]    turns the OpenAPI server on
POST openapi/pair   [1]    opens a 30-second /api/v1/new window
```

Today the only thing on Windows that speaks LTPDU is Nanoleaf Desktop, so:

1. Open **Nanoleaf Desktop**, confirm the strip is online.
2. Select the strip → settings → **Enable API** ON.
3. Press **Connect to API**.

The plugin polls `POST /api/v1/new` while unpaired and stores the token automatically via
`service.saveSetting`. This is needed **once ever** — the token persists on both the
device and in SignalRGB, across reboots and power cycles. Only a factory reset requires
redoing it.

`tools/magrgb-probe.ps1` does the same thing outside SignalRGB and writes
`tools/magrgb-token.json` (gitignored). If you already have a token, paste it into the
"Existing auth token" box in the plugin panel instead of re-pairing.

**No credentials are stored in this repository.** Tokens live only in SignalRGB own
settings store and in the gitignored token file.

---

## Tools

| Script | Purpose |
|---|---|
| `magrgb-probe.ps1` | Pair, dump device info, arm extControl, run a colour + throughput test |
| `magrgb-find.ps1`  | Interactive zone-count finder — you drive with the keyboard |
| `magrgb-count.ps1` | Guided zone/orientation/colour sweep |
| `magrgb-zones.ps1` | Endpoint dump + gradient / dot / split tests |

All reuse the token in `tools/magrgb-token.json`.

> When testing with these scripts, close SignalRGB first — both stream to the same strip
> and will fight over it.

---

## Settings

| Setting | Default | Notes |
|---|---|---|
| Lighting Mode | Canvas | `Forced` locks the whole strip to one colour |
| Update rate | 30 fps | Drop to 20 if it stutters |
| Reverse direction | on | Off if effects run backwards |
| Transition | 0 | ×100 ms; 0 is lowest latency |
| Turn strip OFF on shutdown | off | |

---

## Adding another strip

Just add it by IP and let it auto-pair, or paste an existing token in the panel. For a
different Nanoleaf model, add its zone count to `MODEL_ZONES` — models absent from that
table fall back to 41.
