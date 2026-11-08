# XpengUSB

A Raspberry Pi that presents itself to an **XPENG** as a USB drive, copies the car's dashcam
clips to a NAS, and keeps the car's card clear — with the car's own drive still working
normally.

**Fork of [TeslaUSB](https://github.com/marcone/teslausb)** (MIT, © 2018 cimryan). The USB
gadget, the archiving loop and the install machinery are TeslaUSB's; the XPENG clip layout,
the two-lane design and everything described below are this fork.

---

## Status: what has actually been run on hardware

Verified on a real car on **2026-11-08** (Pi Zero W rev 1.1, 256 GB card):

| | |
|---|---|
| The XPENG accepts the Pi as its dashcam drive | ✅ |
| Records normal clips (`DVR_…`) and emergency clips (`EMER_…`) to it | ✅ |
| Does **not** reformat the drive; our folders survive | ✅ |
| Clips archive to the NAS over SMB, size-verified | ✅ |
| Verified from a **read-only loop mount while the car had the drive open** — no unmount, no complaint | ✅ |
| Clips browsable in the dashcam viewer, noodgeval/normal labelled correctly | ✅ |
| Live view in Frigate (3 cameras) and a web UI | ✅ optional |
| Delete-from-drive / retention logic | ✅ unit-tested (45 assertions) |
| Unattended scheduling | ❌ **not built yet** — archiving is run on demand |
| Drive image larger than 64 GiB | ❌ untested on a car |
| XGuard (parking guard) footage | ❌ never seen on a stick; may live in internal storage |

Details, measurements and the failures behind them: [`doc/XpengPort.md`](doc/XpengPort.md).

---

## What it does

```
car ──USB──▶ Pi Zero W ──▶ XP_DCIM/ + XP_EMER_DCIM/ on the emulated drive
                                │
                                ├─ emergency lane ─▶ NAS (on any network)
                                └─ normal lane    ─▶ NAS (at home, on Wi-Fi)
                                        │
                                        └─ verify by size ─▶ delete from drive after N days
```

Two lanes, because the data is not the same kind:

- **Emergency** — small, rare, precious. Syncs on any network, including over Tailscale.
- **Normal** — large, continuous (≈7.8 GB/day at both views). Syncs at home only.

Nothing is ever deleted from the drive until a **size-verified** copy exists in the archive,
and only once it is older than a retention window.

## Clip layout

XPENG writes one of each per minute of driving:

```
XP_DCIM/DVR_<timestamp>_front.mp4            single front camera
XP_DCIM/DVR_<timestamp>_front_and_360.mp4    4-camera quad view
XP_EMER_DCIM/EMER_[E_…_E]<timestamp>_front.mp4     emergency (button or automatic)
```

Emergency clips are **never deleted by the car** — a card full of them stops recording. That
is the main reason this project exists.

## Hardware tested

| | |
|---|---|
| Board | **Raspberry Pi Zero W rev 1.1** (single OTG port: device *xor* host) |
| Card | 256 GB, Raspberry Pi OS Bookworm Lite armhf |
| Drive image | 64 GiB file, MBR + FAT32, `/piusb.bin` |
| Car | XPENG with USB-A centre-console port |
| Cable | USB-A male → micro-USB male, into the **middle** port (never `PWR IN`), ≤30 cm, no hub |
| Wi-Fi | 2.4 GHz only on this board |

## Install

1. Flash Raspberry Pi OS Bookworm Lite, create the first-boot user and enable SSH.
2. Prepare the boot partition (hostname, Wi-Fi, gadget overlay, console):

   ```bash
   XPENG_PI_PASSWORD=… XPENG_WIFI_SSID=… XPENG_WIFI_PASSWORD=… \
     bash tools/xpeng-prepare-boot.sh /Volumes/bootfs
   ```
3. Boot the Pi, then install:

   ```bash
   REPO=stevelea BRANCH=main XPENG_MODE=true bash setup/pi/setup-teslausb
   ```
4. On the Pi, prove the gadget before involving the car:

   ```bash
   sudo bash tools/xpeng-gadget-test.sh
   ```
5. Put settings in `/root/teslausb_setup_variables.conf` (see below), or use the optional
   settings page: `sudo bash tools/xpeng-settings/install.sh`.

## Settings

All optional; the defaults are inert. Full list in
[`doc/XpengPort.md`](doc/XpengPort.md); the ones that matter:

| Setting | Default | Meaning |
|---|---|---|
| `XPENG_MODE` | `false` | master switch; Tesla path untouched when off |
| `XPENG_EMERGENCY_SYNC` | `always` | `always` / `home` / `off` |
| `XPENG_NORMAL_SYNC` | `home` | `home` / `always` / `off` |
| `XPENG_DRIVE_RETENTION_DAYS` | `14` | days a clip stays **on the drive** after it is archived; `0` = delete immediately after verify |
| `XPENG_DELETE_AFTER_UPLOAD` | `1` | allow deleting from the drive at all |
| `XPENG_VIEWS` | `front front_and_360` | archive all views, or `front` only (half the volume) |
| `XPENG_RETENTION_DAYS` | `0` | keep the **NAS archive** for N days; `0` = forever |
| `XPENG_EXTRA_DIRS` | *(empty)* | extra clip folders treated as emergency (e.g. a future XGuard folder) |

Deletion is gated twice: the clip must be in the archive index (written only after a
size-verified copy), **and** older than the window. A clip that never copied cannot be
deleted by any setting.

## Optional: Frigate live view

If you run [Frigate](https://frigate.video), the newest archived clips can appear as
cameras — no detection, no recording, no extra disk. Three streams (`xpeng_360`,
`xpeng_front`, `xpeng_emergency`) are fed by a small player that remuxes the newest clips
into MPEG-TS for go2rtc. Clips are HEVC, so browsers need an H.264 transcode; VAAPI keeps
that at ~3 % of a core, software encoding costs ~43 %. See
[`doc/XpengPort.md`](doc/XpengPort.md) §7.8.

**Entirely optional** — nothing in the archiver depends on it.

## Optional: settings page and web viewer

- `tools/xpeng-settings/` — a dependency-free settings page for the Pi (port 8081), editing a
  whitelist of values with type validation.
- A web viewer is *not* included. Any viewer that indexes `XP_DCIM` and `XP_EMER_DCIM` works;
  the reference deployment points an existing XPENG viewer at the archive.

## Differences from TeslaUSB

| | TeslaUSB | this fork |
|---|---|---|
| Clip layout | `TeslaCam/` | `XP_DCIM/`, `XP_EMER_DCIM/` |
| Lanes | one archive run | emergency and normal, separate policies and cadences |
| Deletion | after upload | after upload **and** a retention window, still gated on verification |
| Retention | snapshots/reflinks | none — dropped deliberately |
| Web UI | `teslausb-www` (Tesla events) | not included; optional settings page only |

With `XPENG_MODE` unset the Tesla code path is unchanged.

## Documentation

- [`doc/XpengPort.md`](doc/XpengPort.md) — the design record: measured clip layout, the
  Tailscale subnet-route trap, FAT/wall-clock handling, Frigate integration, retention.
  **Read this first.**
- [`doc/P0-gadget-bringup.md`](doc/P0-gadget-bringup.md) — hardware bring-up checklist and
  results, including the `dr_mode=host` trap.
- [`doc/`](doc) — upstream TeslaUSB documentation, still valid for the install machinery.
- [`AGENTS.md`](AGENTS.md) — project map (layout, commands, gotchas).

## Roadmap

1. **Automate the archiver** — a service running the loop; today it is started by hand.
2. Decide the deletion trigger: an idle window with the drive attached, or a "car is home,
   drain it" action.
3. Test whether the car accepts a drive image larger than 64 GiB (needed for a 14-day window
   with all views: ≈110 GB).
4. Test whether XGuard footage ever reaches the stick.

## Credit and license

This is a fork of **[TeslaUSB](https://github.com/marcone/teslausb)** — without it, none of the
hard parts (the USB gadget, the install system, the archive backends) would exist. Upstream
documentation is kept under `doc/`.

**MIT License**, © 2018 cimryan — see [LICENSE](LICENSE). Modifications for XPENG
© 2026 the contributors to this fork.
