# Sennheiser Smart Control Plus (`com.sonova.chb.control`) — RE findings

> These are the notes the macOS app was built from. They refer to working files
> under `analysis/` (the Android package and tool output); those are not part of
> this repository, which holds only the protocol facts and the independent
> implementation.

Artifact: `uptodown-com.sonova.chb.control.apk` is **not** the Sennheiser app (it is the
Uptodown store app, `com.uptodown` v7.40). The real app was obtained as an XAPK:

| Item | Value |
|---|---|
| Bundle | `com.sonova.chb.control_1.6.3.xapk` (SHA-256 of file content not recorded here; use `analysis/xapk/`) |
| Base APK | `analysis/xapk/com.sonova.chb.control.apk` — SHA-256 `1a6d8af1c7f8c5d44d020ba7a3846e837bbb26b198344acdefab2f70d79e7ad3` |
| Package | `com.sonova.chb.control` — SmartControlPlus 1.6.3 (versionCode 72844) |
| SDK | minSdk 26, targetSdk 36 |
| Classes / resources | 10,738 / 1,318 (obfuscated app code, `A.a`, `J3.S`, …) |

Evidence: REA `inspect_artifact` on the original file (app inventory), CLI
`inspect-android-package` (engine jadx-headless-mcp 0.7.1, JAR SHA-256
`6e5eacf500b64292bfb73c49797c1958f6ee44646e43e868039ae7feb573ff75`), saved to
`analysis/01-package.json` / `analysis/02-package.json`; `search-android-classes`
inventories in `analysis/03-classes.json`, `analysis/05-classes-*.json`; method
decompilations in `analysis/07-*.json`, `analysis/08-*.json`.

## Architecture (observed)

- **Flutter** app (`MainActivity` is Flutter; libapp.so is a Dart AOT snapshot,
  SHA-256 `4f296a86f0e302ea9a58616be394c17b82924e0dfb15533422bfc7dd0a3864ba`).
- Device control lives in **Dart**; the Java layer provides plugins:
  - `com.signify.hue.*` — flutter_reactive_ble (GATT transport)
  - `com.airoha.sdk.*` (123 classes) — Airoha device-control SDK API
    (`AirohaDeviceControl`, `PEQControl`, `HAControl`, `AirohaAncSettings`,
    `AirohaBatteryInfo`, `AirohaMessageID`, `ConnectionUUID`, …)
  - `com.qtil.gaia` — string constant in libapp.so (Qualcomm GAIA library
    namespace), i.e. the Dart code is a port of Qualcomm's GAIA stack
- Native DSP helpers (not transport): `libnative-anc*.so` (adaptive IIR/FIR ANC
  tuning), `libnative-peq.so` (`com.airoha.libNativePeq.NativePeq` coefficient
  synthesis), `libnative-ha.so` (`EQUtils`), `libmusic_fit_native-lib.so`
  (Fraunhofer IDMT hearing test).
- Flutter assets under `assets/flutter_assets/assets/.encrypted/` are AES-sealed
  (`SHASSET3` container + `index.json`, runtime-keyed); per-model capability JSONs
  are inside those sealed assets (see prior art below). ~101 sealed files.

## Transports and UUIDs (observed in libapp.so strings; `analysis/04-uuids.txt`)

| UUID | Role |
|---|---|
| `A2129FF3-081B-4C45-8AFE-469D9C4842EC` | **GAIA control service** — SPP/RFCOMM service UUID (also exposed as GATT service on BLE-only models) |
| `8769C9B6-96FC-4F7F-9A5F-C232BDF70365` | second GAIA-related service (BLE-only models) |
| `63331338…3D`, `63331379` `-23C1-11E5-B696-FEFF819CDC9F` | Sennheiser custom service family (7 UUIDs) — purpose not yet resolved |
| `E290DE85-F841-401B-A329-ED4E7DADxxxx` | characteristic-ID family (`xxxx` ∈ 0100/0104/0123/1100/1104/1123/B000/B100-B104/B120-B123) — purpose not yet resolved |

## GAIA V3 wire format (Sennheiser vendor 0x0495)

```
byte 0     0xFF                 start of frame
byte 1     0x03                 flags
byte 2-3   payload length       big-endian
byte 4-5   vendor id            big-endian  (0x0495 Sennheiser, 0x001D Qualcomm core)
byte 6-7   command id           big-endian
byte 8..   payload
```

Command-id convention: request `id`; response `id|0x0100`; async notification
`id|0x0080`; error `id|0x0180`. Notification registration: invoke `0x0007`
with a feature id (battery=3, userEQ=8, versions=9, deviceManagement=10,
mmi=11, transparentHearing=12, ANC=13).

Verified captures (from cross-checked public protocol analysis of this app):

```
GET battery    FF 03 00 00 04 95 06 03  ->  FF 03 00 01 04 95 07 03 2A   (42%)
GET ANC modes  FF 03 00 00 04 95 1A 01  ->  FF 03 00 06 04 95 1B 01 01 02 02 00 03 01
GET model id   FF 03 00 00 04 95 12 06  ->  FF 03 00 0D 04 95 13 06 "…\0"
GET codec      FF 03 00 00 04 95 08 00  ->  FF 03 00 01 04 95 09 00 05   (aptX-HD)
```

### Command catalog (subset implemented in the macOS app)

| Feature | SET | GET | Response | Notif |
|---|---|---|---|---|
| Battery % | — | `0603` | `0703` | `0683` |
| ANC on/off | `1A04` | `1A05` | `1B05` | `1A85` |
| Transparency on/off | `1804` | `1805` | `1905` | `1885` |
| Transparency level | `1A02` | `1A03` | `1B03` | `1A83` |
| Noise-control mode (M4) | `1A00` | `1A01` | `1B01` | `1A81` |
| Codec | — | `0800` | `0900` | — |
| Model id | — | `1206` | `1306` | — |
| Firmware (3×u16) | — | `1201` | `1301` | — |
| Serial (Qualcomm) | — | `001D:0003` | `0103` | — |
| HW revision | — | `1200` | `1300` | — |
| Smart Pause | `080C` | `080D` | `090D` | — |
| On-Head Detection | `0400` | `0401` | `0501` | — |
| Auto-Answer | `080A` | `080B` | `090B` | — |
| Comfort Call | `0814` | `0815` | `0915` | — |
| Low Latency | `0817` | `0818` | `0918` | — |
| Sidetone | `0805` | `0806` | `0906` | — |
| Audio mode (podcast=2) | `0803` | `0804` | `0904` | `0884` |
| BT compatibility | `0405` | `0406` | `0506` | — |
| Auto power-off (u16 seconds) | `0600` | `0601` | `0701` | — |
| Graphic EQ config | — | `1000` | `1100` | — |
| EQ band set/get | `1001` / `1002` | | `1101`/`1102` | `1082` |
| Bass boost | `1008` | `1009` | `1109` | `1089` |
| Register notification | `0007 [featureID]` | — | — | — |

Noise-control semantics: MOMENTUM 4 uses the combined mode property
`1A00 [mode,state]` ×3 pairs (mode 1 = anti-wind, 2 = transparency, 3 = adaptive
ANC; state 0/1/2). ACCENTUM-class devices ignore the combined property and use
two independent toggles (ANC `1A04`, Transparency `1804`); the app drives both.

## Corroboration

- `A2129FF3…` and `8769C9B6…` were independently found as string literals in our
  1.6.3 Dart snapshot, matching the community protocol analysis of the same app
  (`Oein/sennheiser-desktop-client`, `momentumctl`, `accentum-plus-control` —
  see credits in the app README).
- Dart symbols in our snapshot confirm the same architecture: `Gaia3Client`,
  `Gaia3Codec.`, `Gaia3ClassicFrameHandler`, `CoreCommandId.`, `DeviceCommandId.`,
  `EarbudCommandId.`, `UserEqCommandId.`, ~100 `*NotificationHandler` classes
  (BatteryLevel, AncMode, AncTransparency, StageGain/Frequency/Q, ChargeCase…),
  "Received frame with invalid vendor ID", "Previous command is not completed yet!
  Opcode: " (command queue).

## Remaining unknowns

1. Semantics of `E290DE85…xxxx` and `63331338…` UUID families (BLE-only/"SUE"/
   HDB 630 class devices). Likely GATT endpoints for newer products.
2. BLE-only transport: characteristic pair(s) hosting GAIA on `8769C9B6`/`A2129FF3`
   GATT services (Classic RFCOMM is verified working; GATT wiring is unverified).
3. Parametric EQ (`0x100A–0x1013`) payload details.
4. Sealed asset configs per model (feature variant matrices) — keyed at runtime in Dart.
5. The GAIA v3 command surface beyond the catalog above (e.g. Auracast, spatial,
   head-tracking) exists in the app handlers but was not exhaustively extracted.

Runtime validation: **verified live** against a real ACCENTUM from the macOS
app — GAIA link up on RFCOMM channel 15;
read model `ACAEBT Black`, firmware `3.34.0`, the serial number, battery
40 %, ANC on / transparency off, EQ config `05 C4 3C 00 00` (5 bands, ±6 dB),
toggles (sidetone 1, prompt mode 2, auto-answer 1, BT compat 1, power-off 0,
HW rev 4) and the paired-device list. Write commands are implemented per the
catalog but were not exercised on hardware.
