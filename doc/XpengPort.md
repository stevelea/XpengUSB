# Porting teslausb to XPENG — investigation and design

Status: **investigation done, first implementation on branch `main`** (§12). This
document records what was verified, what maps cleanly onto teslausb, what does not, the
design that follows, and what has been built against it.
Date: 2026-11-08.

---

## 1. Verdict

teslausb is the right base, and the reason is not the dashcam logic — it is everything
around it: a USB mass-storage **gadget** backed by an image file, read-only root
filesystem, `fsck` of that image on every boot, and survival of an unannounced power
cut every time the car goes to sleep. None of that is Tesla-specific, and all of it is
the hard part of putting a computer in a car.

The Tesla-specific part is small and self-contained: the clip-folder names, the
snapshot/reflink machinery that exists because Tesla keeps only one hour of
`RecentClips`, and the web UI that assumes `SavedClips/<timestamp>/event.json`. All
three get replaced, not adapted.

The fork already exists: `stevelea/teslausb`, branch `main-dev`, HEAD `fb4ed15`.

Everything below is designed so it still installs the stock way — `setup-teslausb`
already honours `REPO` and `BRANCH` (`setup/pi/setup-teslausb:80`), so an Xpeng build
is `REPO=stevelea BRANCH=main` and no changes to the installer.

---

## 2. What the car actually writes (verified against the real archive)

Read from `/Volumes/Shared_Drive/xpg006camera` — 10 real stick imports made between
2026-09-17 and 2026-10-23, whose clips are dated 2026-06-03 to 2026-10-23 (the first
import was a 4-month backlog):

```
<plug-in stamp>/xpg-usb-sda1/
├── XP_DCIM/
│   ├── DVR_20260928101115168_front.mp4
│   └── DVR_20260928101115168_front_and_360.mp4
├── XP_EMER_DCIM/
│   ├── EMER_[E_A1790136609777_30000_23__A..._E]20260923140931498_front.mp4
│   └── EMER_[E_A1790136609777_30000_23__A..._E]20260923140931498_front_and_360.mp4
├── .nomedia
└── LOST.DIR/            (orphans from the car pulling the plug)
```

Measured:

| | count | avg size | total |
|---|---|---|---|
| `XP_DCIM` normal clips | 25,934 | 42.8 MB | 1.11 TB |
| `XP_EMER_DCIM` emergency clips | 14 | 47.4 MB | 663 MB |

- **Cadence is one minute per clip**, and **two files per minute** (`front` and
  `front_and_360`). So one hour of driving is ~5.2 GB, and the ~142 days of driving
  represented in the archive average ~7.8 GB/day (~1.5 h/day of driving).
- The timestamp lives in the **file name**, not the file date — 14 to 17 digits
  (`YYYYMMDDhhmmss` plus optional milliseconds), then `_<view>`.
- Emergency clips carry an event id in brackets. The same event appears as a pair
  (`front` + `front_and_360`).

### Behaviour that matters more than the layout

From XPENG owner reports (xpeng-fahrer.de, USB-stick-dashcam thread) and consistent
with the archive above:

1. **Normal clips rotate.** Recording continues until the card is full, then the oldest
   unprotected clips are overwritten. Same hazard as Tesla: clips are lost if not
   archived, but on a timescale of days, not one hour.
2. **Emergency clips are protected.** The car never deletes them. A stick full of
   emergency clips is a stick that stops recording.
3. Recording only happens while **Apps → Driving Recorder** is enabled and a
   compatible drive is present, in a centre-console USB port. FAT32/NTFS/exFAT are all
   accepted; 128 GB or more is recommended.
4. Emergency clips can be triggered manually *or* by the car itself (a hard
   braking event was reported to trigger one).

Points 1 and 2 are the two requirements the archiver must satisfy, and they point in
opposite directions: normal clips must be archived before they rotate away, and
emergency clips must be removed after archiving or they eventually brick the recorder.
That asymmetry is exactly what the two-lane design in §5 exploits.

---

## 3. What teslausb gives us unchanged

| Piece | Verdict |
|---|---|
| USB gadget, one LUN per backing image (`run/enable_gadget.sh`) | keep |
| exFAT/FAT32 backing image + `USE_EXFAT` (`setup/pi/create-backingfiles.sh`) | keep, must be exFAT for a 64 GB image |
| read-only root, `fsck` on boot, `clean_cam_mount` (`setup/pi/make-root-fs-readonly.sh`, `run/archiveloop:342`) | keep — this is the value |
| archive backends `cifs` / `nfs` / `rsync` / `rclone`, each a small `archive-clips.sh` | keep; this is how "same Google Drive archive" and "NAS for now" both already work |
| `waitforidle` — watches the gadget's write rate via `/proc/<pid>/io` (`run/waitforidle`) | keep; it is the safe-to-delete signal |
| `force_sync.sh` canary, notification plumbing, LED signalling | keep |
| the install/upgrade machinery (`setup-teslausb`, `tools/merge_config.sh`) | keep |

## 4. What must be replaced

| Tesla piece | Why it does not fit XPENG | Replacement |
|---|---|---|
| `TeslaCam/{RecentClips,SavedClips,SentryClips}`, `TeslaTrackMode`, event folders, `event.json`, `thumb.png` | XPENG has two flat folders, no event metadata, no thumbnails | `XP_DCIM` / `XP_EMER_DCIM`, flat |
| snapshot + reflink + symlink overlay tree (`make_snapshot.sh`, `release_snapshot.sh`, `manage_free_space.sh`, `archive_teslacam_clips` overlayfs) | exists because Tesla holds only ~1 h and overwrites; XPENG holds days and its emergency clips are already safe from rotation | drop entirely; archive-and-delete per lane |
| `ARCHIVE_RECENTCLIPS/SAVEDCLIPS/SENTRYCLIPS/TRACKMODECLIPS` | meaningless | replaced by per-lane sync policy |
| `awake_start` / `tesla_api.py` / `TESLA_*` | Tesla API | already inert when unconfigured; leave, do not ship the Python |
| web UI: `cttseraser`, `videolist.sh`, `index.html` reading the TeslaCam symlink tree | assumes `SavedClips/<ts>/event.json` grouping | v1: leave disabled. v2: a flat browser over the archive |
| `mountoptsforimage`'s `time_offset=-420` | a Tesla timezone workaround | harmless; drop |
| "skip recordings under 100 kB" | never true for XPENG | harmless; drop |

---

## 5. Design: two lanes, one drive

The user's requirement in one sentence: *emergency clips leave the car as soon as there
is any network; normal clips leave when there is a home network — unless told to
behave otherwise.*

```
┌──────────────────────────────────────────────────────────────┐
│ emergency lane   XP_EMER_DCIM   ~47 MB per event             │
│   gate    : always | home | off     (default: always)        │
│   runs    : every 2 min while the gate is open               │
│   deletes : after a size-verified upload                     │
└──────────────────────────────────────────────────────────────┘
┌──────────────────────────────────────────────────────────────┐
│ normal lane      XP_DCIM        ~5.2 GB per hour             │
│   gate    : home | always | off     (default: home)          │
│   runs    : every 10 min while the gate is open              │
│   deletes : after verified upload, and only when idle        │
└──────────────────────────────────────────────────────────────┘
```

Both lanes share the destination, the credentials, the log and the LED. Only the gate
and the cadence differ. That is deliberate: one destination means the archive stays one
tree, and one credential store means one thing to rotate.

### 5.1 The gate

A single helper, `run/xpeng-network-state.sh`, prints one word:

| state | how it is decided |
|---|---|
| `home` | connected to a configured home SSID (`nmcli -t -f active,ssid dev wifi`, or `iwgetid -r`), **or** the configured home archive host answers on its LAN address within 3 s |
| `wifi` | associated to some Wi-Fi, but not a home SSID |
| `other` | a default route exists but it is not Wi-Fi (USB tether, 4G modem, phone hotspot bridged) |
| `none` | no default route |

Then the policy is a two-line lookup:

- `always` → accept `home`, `wifi`, `other`
- `home`   → accept `home` only
- `off`    → never

This is the whole feature the user asked for, and it needs no Tesla code at all. It also
degrades honestly: with no network the lanes simply do not run, and the clips stay on
the drive the car is already happy with.

### 5.2 Settings

All read from the existing `/root/teslausb_setup_variables.conf` (which
`envsetup.sh` already sources), so no new config file:

```bash
# turn on the XPENG layout and the two lanes
export XPENG_MODE=true

# folder names on the emulated drive
export XPENG_EMERGENCY_DIR=XP_EMER_DCIM
export XPENG_NORMAL_DIR=XP_DCIM

# when each lane may sync: always | home | off
export XPENG_EMERGENCY_SYNC=always      # default: as soon as anything is online
export XPENG_NORMAL_SYNC=home           # default: home Wi-Fi only

# what "home" means (either works; both together is the most robust)
export XPENG_HOME_SSID="HomeNet"        # comma-separated list allowed
# XPENG_HOME_HOST is taken from ARCHIVE_SERVER

# emergency lane cadence, seconds
export XPENG_EMERGENCY_INTERVAL=120
export XPENG_NORMAL_INTERVAL=600

# optional: halve the normal-lane volume by dropping the 360 view
export XPENG_VIEWS="front front_and_360"   # set to "front" to skip 360

# optional: read while the car is writing (see §6)
export XPENG_HOT_READ=true
```

### 5.3 Code shape

Small, and mostly by subtraction:

1. `run/archiveloop` — replace `archive_clips` with two calls:
   `archive_lane emergency` and `archive_lane normal`, each gated and each with its own
   interval. `archive_teslacam_clips` (lines 411–640) is deleted, not edited.
2. `run/xpeng-archive.sh` (new) — builds the candidate list for one lane with
   `find <CAM_MOUNT>/<dir> -name '*.mp4' -mmin +2`, applies `XPENG_VIEWS`, verifies the
   upload by size, and only then deletes. It reuses the proven verify-then-delete rule
   from `XpengDVRCopy/deploy/copyusb.sh` rather than inventing a new one.
3. `run/xpeng-network-state.sh` (new) — the gate above.
4. `setup/pi/setup-teslausb` — when `XPENG_MODE=true`: `mkdir -p` the two folders on the
   cam image instead of the TeslaCam tree (`setup-teslausb:342`); skip the snapshot
   machinery and the web UI; install and configure Tailscale.
5. Per-backend `archive-clips.sh` — unchanged. The cifs and rclone backends already take
   `(source, filelist)` pairs and already `--remove-source-files` / `move`.

Nothing in `run/cifs_archive/` or `run/rclone_archive/` needs to change, which is a good
sign the lane split is at the right layer.

---

## 6. The one genuinely new problem: deleting while the car is writing

teslausb disconnects the gadget before it touches the image
(`ensure_cam_file_is_mounted` → `disconnect_usb_drives_from_host`, `run/archiveloop:190`).
At home in a Tesla that is invisible. **In a moving XPENG it means the dashcam loses its
drive mid-drive**, which would stop recording — unacceptable for the emergency lane,
whose whole point is to run while you are away from home.

So:

- **Reading while the car writes is allowed.** A read-only loop mount cannot corrupt the
  car's filesystem; the worst case is copying a clip that is still being appended. That
  is guarded by only considering files whose mtime is older than 2 minutes, and by
  comparing size before and after the copy.
- **Writing (deleting) is not.** Deletion requires: no gadget writes for N minutes
  (`waitforidle`), then gadget off, mount rw, delete only files whose archive copy
  exists at the same byte size, `fsck`, gadget on.
- The normal lane's delete pass therefore runs when the car has stopped, and the
  emergency lane's upload does not need to delete immediately — it can queue the delete
  for the next idle window, which is what keeps clips on the card until they are
  provably safe in the archive.

This is the part to be conservative about. The default should be: upload early, delete
late.

---

## 7. Network: Tailscale, and where the bytes go

### 7.1 What already exists (checked, not assumed)

- Tailnet `<your-tailnet>.ts.net`; `ha-1` = `100.x.y.z` (offers an exit node).
- **The NAS is not on the tailnet.** There is no UniFi/UNAS node in `tailscale status`.
- The NAS is `192.168.1.235`, share `Shared_Drive` (from `XpengDVRCopy`'s config).
- A USB-powered Pixel 7 in the car already runs Tailscale and **hosts a Wi-Fi hotspot**
  (`carphone` workspace) — that hotspot is the obvious internet source for the Pi.

### 7.2 Consequence, stated plainly

Tailscale on the Pi does **not** by itself make the NAS reachable from the car. Three
ways to fix that, in order of preference:

1. **Advertise the LAN as a subnet route** from an always-on node (`ha-1` is already a
   routing-capable node): `tailscale up --advertise-routes=192.168.1.0/24`, approve in
   the admin console, and run the Pi with `--accept-routes`. Then CIFS to
   `192.168.1.235` works from anywhere and both lanes share one destination.
2. **Archive remotely to Google Drive over rclone** and to the NAS over CIFS at home.
   Two destinations, but zero new infrastructure, and it is the "same Google Drive
   archive" the user originally asked for. rclone only needs HTTPS, so it also works on
   hardware where Tailscale cannot create a `tun` device (§8).
3. Push from the car to a tailnet host that writes to the NAS. More moving parts; not
   recommended.

Recommendation: **(1) for the NAS-only phase, with (2) kept as the fallback** — and note
that option 2 is the only one that works on a Pi Zero W.

### 7.3 Tailscale on the Pi — the integration points

- Install during setup, before the root filesystem is made read-only
  (`setup/pi/make-root-fs-readonly.sh` runs late, so there is a window).
- **Move `tailscaled` state to `/mutable`.** `/var/lib/tailscale` must be a symlink into
  the writable partition, exactly the way `/var/lib/NetworkManager` is already handled
  (`make-root-fs-readonly.sh:101`). Without this the node re-authenticates on every boot
  and Tailscale is useless as an "is there internet" signal.
- `tailscale up --authkey=... --hostname=xpengusb --accept-routes --ssh` — the authkey
  is a secret in the same class as the SMB password, so it goes in
  `/root/teslausb_setup_variables.conf` (root-only) and nowhere else.
- The emergency lane uses *"tailscaled reports Running"* as its cheapest "we have
  internet" test; it is one local socket call and does not depend on the destination
  being up.

### 7.4 Measured: the subnet route works, and it hijacks the LAN

Verified on the Pi Zero W (`pixpeng`, `100.x.y.z`) on 2026-11-08, after login and
`--accept-routes`:

- `ha-1` is `192.168.1.88` — it *is* the Home Assistant box — and it already advertises
  `192.168.1.0/24` with the route approved (`PrimaryRoutes: ['192.168.1.0/24']`). Nothing
  needed configuring there.
- The route forwards: HTTP from HA over the tunnel returned 200 in 155 ms, and
  `192.168.1.235:445` was reachable through it.
- **Side effect that matters:** Tailscale installs accepted routes into table 52 and its
  `ip rule` puts that table ahead of main, so once the route is accepted *every*
  `192.168.1.x` destination — the router included — goes Pi → ha-1 → LAN. A hairpin for
  traffic that is already on the same wire.
- The fix is `run/xpeng-lan-pin.sh` (installed as `/usr/local/sbin/xpeng-lan-pin` with a
  30 s timer): when the box has an address on the archive host's subnet it installs a
  `/32` for the host via the local gateway inside table 52; when it does not, it removes
  it and the tailnet route takes over.

Resulting paths, measured:

| Destination | At home | Away from home |
|---|---|---|
| `192.168.1.235` (NAS) | direct LAN, `/32` pin, SMB connect 65–144 ms | tailnet via ha-1 |
| other LAN hosts | tailnet via ha-1 | tailnet via ha-1 |

One more observation worth keeping: `gl-be3600` also advertises `192.168.8.0/24`, and
`--accept-routes` accepts it too. Accepted routes are all-or-nothing on the client; if
that ever causes trouble it has to be scoped in the tailnet ACLs, not on the Pi.

### 7.5 The trap: a node on the LAN that accepts the LAN's own subnet route

This cost hours on 2026-11-08 and is worth stating as a rule.

`ha-1` advertises `192.168.1.0/24`. The Pi sits **inside** that subnet. With
`--accept-routes` the Pi installed the advertised route into table 52, and Tailscale's
`ip rule` consults table 52 before main, so **everything** addressed to the LAN - including
replies to the Mac - went out `tailscale0` instead of `wlan0`:

```
ip route get 192.168.1.103
  192.168.1.103 dev tailscale0 table 52 src 100.x.y.z     <- broken
```

The symptoms were misleading in the extreme:

- `nmcli` said `connected`, the link never dropped, the IP never changed;
- the *tailnet* address answered fine;
- the Pi could `ping` the Mac;
- but nothing could reach the Pi's LAN address - not ping, not ssh - and a
  `tcpdump` on `wlan0` showed requests arriving with **no replies leaving**.

That last observation is the diagnostic: requests in, no replies out, means the reply is
being routed somewhere else - check `ip route get <peer>` before blaming the radio,
firmware or power supply.

**Rule: never accept a subnet route for a subnet the node is itself attached to.**
On this board `tailscale set --accept-routes=false` is the correct setting. It also
showed that the "Wi-Fi drops every 30 seconds" theory was wrong: 18 samples over three
minutes showed `state=connected` throughout.

Separately, `brcmfmac` enables 802.11 power save about 55 s after the link comes up
(`brcmf_cfg80211_set_power_mgmt: power save enabled`), which is a genuine cause of drops
on a BCM43430. It is now disabled via `/etc/NetworkManager/conf.d/wifi-powersave-off.conf`
(`[connection] wifi.powersave = 2`). `vcgencmd get_throttled` returned `0x0`, so
undervoltage was ruled out.

### 7.6 FAT has no timezone, and it silently rejects every clip

Found on real car footage (2026-11-08). The car stamps files in **local** time; the vfat
driver converts them to an epoch using the **system timezone** when it reads them. The Pi
was on UTC, the car on AEST (UTC+11 in summer), so every fresh clip appeared **eleven
hours in the future**:

```
raw mtime: 2026-11-08 18:36:26 +0000     file epoch 1794123386
now:                                    epoch     1794123859     -> mtime > now
```

The settle window then classified all six real clips as "not settled" and archived
nothing - for ever, because they only ever age *towards* the future from that viewpoint.

The fix is one command, not a workaround in the code:

```bash
sudo timedatectl set-timezone Australia/Sydney
```

After that the same file reads `18:36:26 +1100` = 07:36 UTC, eight minutes in the past, and
all six clips archived and verified with no other change. `XPENG_MTIME_SKEW_MINUTES`
exists for images where the timezone cannot be set and must stay **0** otherwise, or the
timestamps get corrected twice. `tools/xpeng-prepare-boot.sh` now writes `/etc/timezone`
and links `/etc/localtime` from the first-boot script - by file, not `timedatectl`, which
needs the bus that is not up yet.

### 7.7 End-to-end, on the car's own footage (2026-11-08)

The pipeline ran against the clips the car had just written. The drive stayed attached and
was mounted **read-only via loopback** while the car still had it open, so nothing was
disrupted - this is the "hot read" path from §6, and it works.

```
emergency lane: 2 clips  → copied, size-verified, kept on the drive (delete disabled)
normal lane:    4 clips  → copied, size-verified, kept on the drive (delete disabled)
```

On the NAS, checked independently from a different machine:

```
Shared_Drive/xpengusb/2026-11-08_184922/cam/XP_EMER_DCIM/…   28,002,412 + 15,633,160
Shared_Drive/xpengusb/2026-11-08_184952/cam/XP_DCIM/…        17,678,065 + 14,538,924
                                                               480,980 +    511,448
```

Measured throughput: 43 MB in ~29 s (emergency), 33 MB in ~27 s (normal) - about
**1.2-1.5 MB/s**, which is the Zero W's SMB-over-Wi-Fi ceiling, not the CPU. At the
observed ~7.8 GB/day that is roughly 90 minutes of archiving per day, and it is why
`XPENG_VIEWS="front"` (skip the 360 view, halving the volume) matters if this stays on a
Zero W.

The CIFS mount is in `/etc/fstab` with `noauto,nofail,_netdev`, so `mount /mnt/archive`
works and the archiver can mount it on demand rather than depending on boot ordering.

### 7.8 Live view in Frigate: three streams, one per view (2026-11-08)

The clips are watchable in Frigate as a **camera with no detection and no recording**, so
it costs no disk and adds nothing to the Coral's work.

```
/clips on the Pi ──archive──▶ NAS Shared_Drive/xpengusb ──NFS ro──▶ frigate:/mnt/xpeng
                                                                       │
                        go2rtc exec:/opt/xpeng-stream/play.sh ─────────┘
                        (plays the newest 12 clips, VAAPI H.264 640x360@10)
                                │
                                └──▶ rtsp://127.0.0.1:8554/xpeng_dashcam
                                        └──▶ camera xpeng_dashcam (roles: [], detect/record off)
```

XPENG writes **two files per minute of driving**:

```
DVR_<stamp>_front.mp4           single front camera
DVR_<stamp>_front_and_360.mp4   the 4-camera quad view
```

A single stream that takes "the newest N clips" therefore alternates between the quad
layout and the single camera every clip - unwatchable, and not obvious from a still. So
there are three streams, each with its own selector:

| Camera | Source files | Selector |
|---|---|---|
| `xpeng_360` | `*_front_and_360.mp4` | pattern |
| `xpeng_front` | `*_front.mp4` (does not match the 360 name) | pattern |
| `xpeng_emergency` | `*_front.mp4` under `XP_EMER_DCIM` | pattern + path glob |

All three are live-view only (`roles: []`, detect/record/snapshots disabled), share
`/opt/xpeng-stream/play.sh`, and differ only by two environment variables
(`XPENG_STREAM_PATTERN`, `XPENG_STREAM_PATH_GLOB`) set in the tiny wrapper scripts
`play-360.sh`, `play-front.sh`, `play-emergency.sh`. Verified: each stream produced a
frame, and the front and emergency frames are the same camera from different clips.

**One caveat to expect:** `xpeng_emergency` has nothing to play until the car actually
records an emergency clip, so that camera sits without frames until then. That is correct
behaviour, not a fault.

Four further things had to be right, and each failed first:

| Symptom | Real cause |
|---|---|
| `exec:` stream rejected | go2rtc refuses exec sources unless `GO2RTC_ALLOW_ARBITRARY_EXEC: "true"` is in the container environment |
| stream absent after config edit | `docker compose up -d` does **not** restart Frigate when only the mounted `config.yml` changed - `docker restart frigate` is required |
| source produced 0 bytes | inside the Frigate container **ffmpeg is not on `PATH`**; it lives at `/usr/lib/ffmpeg/<ver>/bin/ffmpeg` |
| stream unplayable in the UI | the clips are **HEVC**, which browsers cannot play over WebRTC/HLS; it must be transcoded to H.264 |

The transcode is the expensive part: software `libx264` measured **43% of one core** on a
4-core i5-6400T already at load ~8. With VAAPI (the container has `/dev/dri`) it is **~3%**,
which is why the player tries hardware first and falls back per clip.

Two consequences worth stating: the view shows the **archive**, not the live car - there is
the archive round trip in between, so it lags by however often the consumer runs; and it
plays the newest N clips on a loop, so "live" here means "recent footage", not a camera.

Consumer side (frigate host `192.168.1.202`): NFS mount `/mnt/xpeng` (ro, `noauto,nofail`),
compose volumes `/opt/xpeng-stream` + `/mnt/xpeng`, the `GO2RTC_ALLOW_ARBITRARY_EXEC` env
var, and the camera block. Backup of the pre-change config is in `/tmp/config.yml.bak-*`.
The NAS export had to allow `192.168.1.202`; kernel CIFS from that host is refused
(`IPC$ rc=-13`) even though `smbclient` authenticates, which is why NFS is used.

### 7.9 One archive, one interface: the dashcam viewer on `pantry`

The display interface is the existing **XpengDashcamViewer** at
`http://192.168.1.109:8965` (host `pantry`), not a viewer of our own. A viewer built for
the job already knew about `XP_DCIM` and `XP_EMER_DCIM` and labels each clip with the lane
it came from, so the archiver moved to where that viewer looks instead of the other way
round. An earlier `xpeng-viewer` container on the Frigate host was **retired** - it was a
duplicate of a better thing.

```
car -> Pi -> NAS Shared_Drive/xpg006camera/xpengusb/{XP_DCIM,XP_EMER_DCIM}/
                                   |
                                   +-- container "xpeng-dashcam" on pantry (/mnt/xpg006camera -> /footage)
                                   +-- Frigate live-view cameras (/mnt/xpeng/xpg006camera/xpengusb)
```

The archive is flat: `XP_DCIM/<clip>` and `XP_EMER_DCIM/<clip>`, next to the historical
tree which keeps its own `<date>/xpg-usb-sda1/XP_DCIM` shape. Filenames carry the car's
timestamp, so a flat layout is unambiguous.

Three things had to be fixed in the viewer to make the consolidation real:

1. **`folders` was `{"normaal": "", "noodgeval": ""}`.** Both empty strings resolve to
   `root`, so every scan walked the entire tree **twice**, once per lane - which is why a
   scan "found" 51,852 clips on a 25,926-clip archive. With real folder names the scan
   takes 39 s and visits each clip once.
2. **The lane was decided by the folder scanned, not the path.** Nested archives
   (`<date>/xpg-usb-sda1/XP_EMER_DCIM/…`) would be filed as normal. `scan.py` now derives
   the lane from the path, so it works at any depth: verified `483` emergency clips
   (481 historical + our 2) out of 25,932.
3. **The app caches `config.json` at startup.** Editing the file changed nothing until the
   container was recreated. Worth remembering before concluding "the setting has no
   effect".

Retiring nginx from the Pi also removed its boot-ordering problem (it had to start after
`tailscaled` to bind the tailnet address) and freed the memory that wedged it.

The config that matters is the one the container reads:
`/home/stevelea/xpeng-dashcam/config.json` (bind-mounted to `/app/config.json`), with
`root: /footage` and `folders: {normaal: XP_DCIM, noodgeval: XP_EMER_DCIM}`.

### 7.10 Emergency vs XGuard, and why unknown folders are now reported
### 7.11 Retention, and the settings page

**Retention.** `XPENG_RETENTION_DAYS` (default **0** = keep forever) prunes archive folders
older than N days. It only touches folders this archiver created - names matching
`YYYY-MM-DD_HHMMSS` - so `_logs`, foreign folders, and anything else in the share are
untouched, and it runs *after* the copy and the index update, so an interrupted run can
never prune what it had not yet archived. Five assertions cover it, including "retention off
by default".

The first implementation used `date -d` to build an epoch cutoff. That is GNU-only, so on
macOS it produced `0` and pruned nothing, silently. It now compares **date strings**
(`YYYY-MM-DD` sorts correctly as text), which works identically on both.

**Settings.** `tools/xpeng-settings/xpeng-settings` is a stdlib-Python single page on the Pi
(port 8081, HTTP Basic) that edits a whitelist of keys in
`/root/teslausb_setup_variables.conf`: lane policies, retention days, delete-after-upload,
views, settle window, intervals, extra folders. Each value is validated against its own
type before writing, so `$(reboot)` in the text field is rejected rather than written; the
file is written temp-then-rename, and unrelated keys and comments are preserved. Install
with `sudo bash tools/xpeng-settings/install.sh`, which also **purges nginx** from the Pi.

### 7.12 Deleting from the car's drive: a 14 day window, gated on the archive

The drive is the car's own storage, so what leaves it matters. The rule is now:

> when the car is at home, delete a clip from the drive once it is **older than
> `XPENG_DRIVE_RETENTION_DAYS`** (default **14**) **and the archive already holds it**.

The second half is the important one, and it is enforced structurally rather than by
trust: the delete list is the **intersection of the clips still on the drive with the
archive index**, and that index is only appended to after a size-verified copy. A clip
that failed to copy, or was never scanned, cannot be reached by this path at all.

```
drive ∩ archive index   ->  keep only those older than 14 days  ->  delete
```

`XPENG_DRIVE_RETENTION_DAYS=0` restores the old behaviour: delete as soon as verified.
Deletion also still requires `XPENG_DELETE_AFTER_UPLOAD=1` and `XPENG_IDLE_OK=1`, so the
car must not be writing, and it happens on the **normal** lane, which only runs at home.

One flow bug had to be fixed to make this work: when there was nothing new to copy the
script returned early, so the sweep only ran on a day a new clip arrived. Copying and
verifying are now skippable, and the sweep always runs.

### 7.13 Views: a real choice, with its cost shown

`XPENG_VIEWS` decides whether both files per minute are archived or only the front one. It is
a selector on the settings page, and the options state what they cost rather than showing raw
values:

| Choice | Files | Volume | Consequence |
|---|---|---|---|
| all views | `_front` + `_front_and_360` | ~7.8 GB/day | what the 360 quad view needs; archive grows ~2.8 TB/year |
| front only | `_front` | ~3.9 GB/day | half the upload time, half the growth; no quad view |

This is the same trade-off as the drive size: **all views plus a 14-day window needs ~110 GB
on the drive**, which is more than a 64 GiB image holds. The 360 file is also four small,
low-detail panes - the front file is the one a number plate is legible in. Front-only is
therefore the better default for a small card, and all views is the right choice when the
archive matters more than the bandwidth.

Two settings are easy to confuse, so they are labelled apart in the settings page:

| Setting | Means |
|---|---|
| `XPENG_DRIVE_RETENTION_DAYS` | how long clips stay **on the car's drive** (default 14) |
| `XPENG_RETENTION_DAYS` | how long the **NAS archive** is kept (default 0 = forever; this is the viewer's library) |

### 7.14 The car's own hotspot as a fallback network

The car runs an access point, which is the one network that is available exactly when the car
is away from home - the case the emergency lane exists for. It is configured as a **fallback**:

| Connection | SSID | Autoconnect priority |
|---|---|---|
| home | (home SSID) | **100** |
| car hotspot | `Xpeng006` | **-10** |

NetworkManager therefore joins home whenever it is in range and only falls back to the car's
AP otherwise. Both are 600-mode keyfiles; the password is not in this repository.

`tools/xpeng-prepare-boot.sh` accepts it for a fresh card:

```bash
XPENG_WIFI_SSID="my-home-wifi" XPENG_WIFI_PASSWORD="…" \
XPENG_WIFI_ALT_SSID="car-hotspot" XPENG_WIFI_ALT_PASSWORD="…" \
  bash tools/xpeng-prepare-boot.sh /Volumes/bootfs
```

**What it does and does not buy you.** `xpeng-network-state.sh` reports this as `other`, not
`home`, so only the emergency lane runs - which is the intent. But the NAS is a LAN address
and is not reachable from the car's hotspot; a car-side upload therefore needs either an
internet-reachable backend (rclone/Drive) or a route to the NAS over Tailscale. Joining the
hotspot alone does not make emergency clips leave the car - it makes the lane *eligible*.

---

## 8. Hardware

Four candidates have been looked at: the two Pi Zeroes (the user's preference and the
sensible default), and the Orange Pi Zero 2W (asked about separately — verdict in §8.3,
and it is stronger than expected). Short version: all of them can do the job; they differ
in how much of the surrounding port has to be written, not in whether the car sees a USB
drive.

### 8.1 Raspberry Pi Zero W — yes, with a defined scope

| | Pi Zero W | Pi Zero 2 W | Pi 4 | Pi 5 |
|---|---|---|---|---|
| USB gadget | yes (`dwc2`) | yes | yes | yes in this fork (#800) |
| Wi-Fi | 2.4 GHz only | 2.4 GHz only | 2.4/5 GHz | 2.4/5 GHz |
| CPU | single-core ARMv6 | quad A53 | quad A72 | quad A76 |
| Realistic CIFS/rsync | ~1–2 MB/s | ~4–8 MB/s | ~20 MB/s | ~20 MB/s+ |
| Tailscale | **works** — armv6 build runs, TUN mode (§8.1) | fine | fine | fine |
| USB host port for extra storage | no (one data port, used by the gadget) | no | yes | yes |

The two edges on a Zero W:

1. ~~**Tailscale on ARMv6 is not a supported configuration.**~~ **Measured on the
   hardware on 2026-11-08 and this is wrong.** The current `linux/arm` build
   (`1.104.5`, go1.27.3) runs on the Pi Zero W's ARMv6 without a segfault, `/dev/net/tun`
   exists, `tailscaled` starts under the packaged systemd unit, and `tailscale0` comes up
   in **TUN mode** — no `--tun=userspace-networking` needed. The v1.62.0-then-update
   workaround circulating in a 2026 write-up did not apply here. So the Zero W *can*
   route to the NAS over the tailnet, subject to §7.2 option 1 (a subnet route on `ha-1`).
2. **Throughput.** At ~1.5 MB/s a ~7.8 GB/day habit needs ~90 minutes of powered sync
   per day. If the car cuts USB power when it is locked, that 90 minutes has to come out
   of driving time (which generates 5.2 GB/hour, so ~1.5 MB/s is break-even at best) —
   the backlog then never drains over a busy week.

If a board still has to be bought and there is no hard preference, **Zero 2 W** is the
better buy: same footprint and power profile, keeps the option of real Tailscale routing,
and is 4–5× faster for the same job. If the Zero W is already in the drawer — which is the
case here — §8.2 is how to make it work. Pi 4/5 only if you want a USB SSD for a big
archive and a nightly drain measured in minutes rather than an hour.

Either way, set `USE_EXFAT=true` and `CAM_SIZE=64G` (~8 days of driving at 7.8 GB/day).
`CAM_SIZE` larger than 32 G cannot be FAT32.

### 8.2 If it has to be a Zero W — the configuration that works

The board the user prefers is the Zero W, and it is *good enough* for this job provided
three rules are followed. This is the supported configuration, not a hack:

1. **Remote lane can be CIFS over Tailscale** — the ARMv6 limit that used to force rclone
   does not exist on this hardware (measured, §8.1). rclone → Google Drive remains the
   simpler option when there is no subnet route, but it is no longer the only one. The
   normal lane stays on home Wi-Fi → CIFS → NAS, where no Tailscale is involved either.
2. **Tailscale is for reaching the Pi, not for moving clips.** Remote shell and the web
   UI only. Budget ~2–5 Mbit/s and expect it to be relaunchy after a power cut.
3. **`XPENG_VIEWS="front"`.** Skipping the 360 view halves the daily volume to
   ~3.9 GB/day, which at 1.5 MB/s is ~45 minutes of powered sync. This is the single
   cheapest thing that makes slow hardware viable. The 360 view still exists on the card
   until it rotates; the trade is coverage of the second camera for throughput.

With those, the Zero W is a legitimate choice: ~$15, ~120 mA, and the car's port will not
notice it. Do not use it if the plan is to archive every clip of a long commute at home
only — that is the case where the faster board pays for itself.

What the Zero W cannot do, stated once so it is not rediscovered later: no second USB
port (the one data port is the gadget, so no external SSD for the archive or the spool),
no `tun`, and no AES instruction — SMB3 signing costs it real CPU, which is why the home
lane should prefer CIFS with `vers=3.0` and, if it is ever slow, NFS or rsync instead.

### 8.3 Orange Pi Zero 2W (H618, 1 GB) — checked, and yes

This one was asked about directly, so it was checked against the two things that actually
decide it, rather than against reputation.

**Can it present a USB drive to the car? Yes.** Three independent pieces of evidence:

1. Upstream Linux sets the port up for exactly this. In mainline
   `arch/arm64/boot/dts/allwinner/sun50i-h618-orangepi-zero2w.dts`:

   ```dts
   &usbotg {
       /* ... a role switch is not implemented: both CC pins are pulled to GND.
          The VBUS pins power the device, so a fixed peripheral mode is the
          best choice. */
       dr_mode = "peripheral";
       status = "okay";
   };
   ```

   Peripheral mode is the *documented default* on this board — no DTB surgery, and no
   `dtoverlay=` equivalent of the Pi's `dwc2` dance. The controller is MUSB
   (`allwinner,sun50i-h616-musb`), which has had gadget support in mainline for years.
2. Armbian's sunxi64 kernel (both `current` and `edge`) is built with what a mass-storage
   gadget needs: `CONFIG_USB_GADGET=y`, `CONFIG_USB_CONFIGFS=m`,
   `CONFIG_USB_CONFIGFS_MASS_STORAGE=y`, `CONFIG_USB_MUSB_SUNXI=m`, `CONFIG_EXFAT_FS=m`.
3. PiKVM — which is a USB gadget (HID + mass storage) — has been run on the Orange Pi
   Zero 2/H616 family. Worth reading precisely: that port did swap in a patched DTB on an
   older image, so it is evidence the hardware can do it, not that it is turnkey.

**It is also faster than any Pi Zero**, which matters here: quad Cortex-A53 at 1.5 GHz,
1 GB LPDDR4, and **Wi-Fi 5 (802.11ac, 2.4 + 5 GHz)**. That is the difference between the
`~1.5 MB/s` ceiling that makes a Zero W marginal and something in the 8–20 MB/s class, so
a 7.8 GB/day habit drains in minutes rather than an hour. (Tailscale was once thought to
be a Zero-W-only limitation; it is not — see §8.1.)

**Three things to know before buying:**

1. **Cable: USB-C to USB-A. Not C-to-C.** There is no role switch and both CC pins are
   tied to GND, so a USB-C host will never negotiate with it. A car's centre-console port
   is USB-A, so this is fine — but use a data cable, not a charge-only one.
2. **One cable does power and data.** The DTS comment above says the VBUS pins power the
   board, so the same port that emulates the drive also runs it. Nice for a car: one
   cable, no splitter, no second supply.
3. **Use Armbian or DietPi with a mainline DTB, not the vendor BSP image.** The vendor
   Debian/Ubuntu images for this board are older kernels with their own DTBs; whether
   their `usbotg` node says `peripheral` is not something to assume. Also note a
   reported trap: a hand-edited DTB plus a C-to-C cable produces exactly the symptoms of
   "gadget is broken" (`current_speed` reads `UNKNOWN`, host sees nothing) when the real
   cause is the cable.

**The cost is in the installer, not the hardware.** teslausb's setup path is
Raspberry-Pi-centric: `setup/generic/install.sh` exists to "make things look sufficiently
like what the main Raspberry Pi centric install scripts expect", and it is used for the
Rock Pi 4 and Radxa Zero, so a non-Pi install is a known shape. But for this board you
would still have to own:

- the root-partition shrink + `/backingfiles` partition creation (the riskiest step on a
  vendor image; Armbian's layout differs from Raspberry Pi OS),
- the read-only-root conversion (`setup/pi/make-root-fs-readonly.sh` is Pi/Debian tuned),
- LED naming (there is no `ACT`; `envsetup.sh` falls back to `/tmp/fakeled`, so status
  indication would need one of this board's LEDs mapped),

and none of it has been done before for this board. Budget 1–2 days, and expect to debug
`fsck`-after-power-cut behaviour yourself.

**Verdict.** If the choice is "cheap board that is fast enough and has 5 GHz Wi-Fi", the
Orange Pi Zero 2W is a defensible pick and beats the Pi Zero W on every performance axis
that matters here. If the choice is "working this weekend", the Pi is the paved path: its
gadget support is upstream, first-class and already exercised by teslausb on thousands of
cars. The hardware risk is roughly equal; the schedule risk is not. Both are still behind
the P0 question in §9, which is whether the *car* accepts an emulated drive at all.

### 8.4 The power question decides the whole normal lane

Everything above assumes the Pi is powered long enough to sync. A Tesla keeps its USB
ports alive while parked; whether an XPENG does — while locked, and while charging at
home — is **not known and must be measured first**. If the port dies with the ignition,
then the normal lane can only ever run while driving, and a Zero W cannot keep up. The
cheap fixes, in order: leave the car on charge at home overnight (many cars keep
accessory power while charging), or fit a small 5 V UPS so the Pi has 30–60 minutes
after the car stops.

---

## 9. De-risking: the experiment that gates the car side

The single unknown that can invalidate the whole design is: **will the XPENG accept a
Raspberry Pi gadget as a USB drive at all?** Tesla does; there is no reason XPENG would
refuse a standard mass-storage device, but nobody has tried it.

P0 — one evening, no code. Step-by-step checklist, including the Mac-side checks:
**[`P0-gadget-bringup.md`](P0-gadget-bringup.md)**; the Pi-side helper is
`tools/xpeng-gadget-test.sh`.

1. Raspberry Pi OS Lite on the board, `dtoverlay=dwc2`, `modprobe g_mass_storage` or a
   plain configfs gadget with a 64 GB exFAT image.
2. Put `XP_DCIM/` and `XP_EMER_DCIM/` on the image.
3. Plug into the centre-console port, enable **Apps → Driving Recorder**.
4. Drive for ten minutes. Then check the image for `DVR_*_front.mp4`.
5. Power the Pi from a USB meter and note the current draw and whether the car's port
   keeps it alive after locking, and while charging.

Pass criteria: the car writes clips, and `ls` on the Pi sees them. If it fails, the
options are: a real stick plus the existing `XpengDVRCopy` flow (already proven), or
investigate what the car dislikes (partition table, LUN count, volume label, size).

The P0 result does not block the archiver (it is built and tested against
directories — see §12), it blocks *trusting it in the car*. Do not deploy to the
car until P0 passes.

---

## 10. Work breakdown

| Phase | Work | Est. |
|---|---|---|
| P0 | Gadget accepted by the car; power behaviour measured (§9) | ½ day + one drive |
| P1 | XPENG layout: folders on the image, drop snapshots, `xpeng-archive.sh` with verify-then-delete | 1–2 days |
| P2 | Network gate + per-lane policy + settings (§5) | ½ day |
| P3 | Tailscale in setup, state moved to `/mutable`, subnet-route doc | ½ day |
| P4 | Normal-lane deletion window (hot-read + idle delete) (§6) | 1 day |
| P5 | Oversight: MQTT/HA status and notifications, reusing the already-written `copyusb.sh` publisher | ½ day |
| P6 | Web UI over the archive (optional, only if wanted) | 1–2 days |
| P7 | **Only if the board is not a Pi** (e.g. Orange Pi Zero 2W): non-Pi install path — `/teslausb` shim, backingfiles partitioning on Armbian, read-only root, LED naming (§8.3) | 1–2 days |

P1+P2 is a usable device. P4 is what makes it safe rather than merely working. P7 is
additive and independent — it can be done in parallel with P1/P2, and it is the entire
price of picking a non-Raspberry-Pi board.

## 11. Open questions for the owner

1. Does the car keep USB power while locked, and while charging? (§8.4)
2. Target: NAS only for now, or Google Drive as well? That decides whether Tailscale's
   `tun` matters, which decides how much of §8.2 constrains the board. (§7)
3. Which board: an Orange Pi Zero 2W already owned (→ add P7), a Pi Zero W already owned
   (→ P7 not needed, §8.2 applies), or a purchase still to be made (§8.3)?
4. Is a subnet route on `ha-1` acceptable, or should the car only ever talk to Drive?
5. Do we archive the `front_and_360` view as well as `front`? Halving the volume is the
   cheapest way to make slow hardware viable. (§5.2)
6. Which car is this for, and does its dashcam write exactly the layout in §2?
---

## 12. Development target: the Orange Pi 3 LTS

The other board available for development is a second Orange Pi 3 LTS, identical to the
one running `XpengDVRCopy`. It is a good **development** target and it cannot be the
**in-car** one. The reason is one line of upstream device tree:

```dts
/* arch/arm64/boot/dts/allwinner/sun50i-h6-orangepi-3.dts */
&usb2otg {
    /*
     * This board doesn't have a controllable VBUS even though it
     * does have an ID pin. Using it as anything but a USB host is
     * unsafe.
     */
    dr_mode = "host";
};
```

And the board's own port list agrees: **1x USB 3.0 host, 2x USB 2.0 host, and a USB-C
port that is 5 V/3 A power input only.** There is no data-capable device-mode port on this
board, and upstream explicitly calls device mode *unsafe* on it because VBUS cannot be
controlled — forcing `dr_mode = "peripheral"` in a patched DTB would have the board and
the car both driving 5 V onto the same wire.

So this board cannot present a USB drive to the car, and P0 (§9) cannot be run on it.

### What it is good for

Everything except the gadget, which is most of the work and all of the subtlety:

| This board can | How |
|---|---|
| develop and test both lanes | `XPENG_SOURCE_ROOT` pointed at a directory of clips |
| test the network gate for real | it has Wi-Fi 5 + gigabit Ethernet, and can join the car hotspot |
| test Tailscale | arm64, first-class `tailscale0`/`tun` |
| test the NAS upload path end to end | CIFS to `192.168.1.235`, real archive, real sizes |
| test verify-then-delete against real footage | point it at a copy of the archive |
| be a staging box | pull the real stick into it, then push to the NAS |

Because the lane code takes a *directory* as its source, the same binary that will run in
the car runs here today:

```bash
# on the Orange Pi 3 LTS, with the repo cloned and Armbian's packages installed
export XPENG_CONF=/dev/null
export XPENG_SOURCE_ROOT=/path/to/clips        # a copied stick, or the car's own folders
export XPENG_ARCHIVE_MOUNT=/mnt/nas            # an existing CIFS mount
export XPENG_INDEX_FILE=/tmp/xpeng-index.txt   # start empty for a fresh archive tree
export XPENG_HOME_SSID="HomeNet"               # so the normal lane can tell home apart
export XPENG_REQUIRE_IDLE_FOR_DELETE=0         # no gadget here, so nothing to disturb

bash run/xpeng-archive.sh emergency            # one pass, one lane
bash run/xpeng-archive.sh normal
XPENG_RUN_ONCE=1 bash run/xpeng-loop.sh        # one pass of both lanes
```

Verify by hand what the tests already assert: the archive grows, the source shrinks, and a
deliberately truncated destination file stops its source from being deleted.

### What still needs the gadget board

The one thing this board cannot answer is the question that gates everything else: does the
car accept an emulated drive. That needs a board whose USB port can be a device — Pi Zero W,
Pi Zero 2 W, Pi 4/5, or an Orange Pi Zero 2W (§8.3). Until then the archiver is proven on
directories and against the real archive, which is the useful half.

### Implementation status (2026-11-08)

On branch `main`:

| File | State |
|---|---|
| `run/xpeng-network-state.sh` | done — `home` / `wifi` / `other` / `none`, SSID and host-probe rules |
| `run/xpeng-archive.sh` | done — scan, settle window, dedupe index, rsync, verify by size, deferred delete |
| `run/xpeng-loop.sh` | done — two cadences, idle-gated deletion, `XPENG_RUN_ONCE` for a single pass |
| `run/archiveloop` | 6 lines: `exec`s the XPENG loop when `XPENG_MODE=true`; the Tesla path is untouched |
| `setup/pi/envsetup.sh` | `XPENG_*` defaults (mode defaults off, so upgrades are inert) |
| `setup/pi/setup-teslausb` | installs the three scripts; creates `XP_DCIM`/`XP_EMER_DCIM` instead of the TeslaCam tree when `XPENG_MODE=true` |
| `tests/xpeng-test.sh` | 31 assertions, runs on Linux and macOS, no car or board needed |
| `check.sh` | lints the new files (shellcheck, clean) |

Not started: the idle-delete wiring to `waitforidle` on a gadget board (§6), Tailscale
installation (§7.3), MQTT/HA status, and everything in §10 beyond P1/P2.
---

## 13. Which car port, and which cable

The car has both a USB-A and a USB-C data port in the centre console. **Use the USB-A
port**, and use a *data* cable — not a charge-only one.

### Why USB-A, when the C port is also data

1. **Every candidate board can be reached from it.** Pi Zero W and Zero 2 W have a
   micro-USB device port; the Orange Pi Zero 2W and Pi 4 have a USB-C one. A→micro or
   A→C cables are ordinary, cheap and well understood, and both directions work without
   any negotiation.
2. **No CC/PD negotiation to get wrong.** The Orange Pi Zero 2W ties both CC pins to GND
   and implements no role switch (mainline DTS says so), and the Pi has no PD controller
   either. A USB-C host can refuse to enable VBUS when it does not see a proper sink term.
   USB-A has no such concept: power is always present and the data lines are always
   connected.
3. **It is the lowest-common path if the board changes.** The decision about which board
   is not final (§8), and the cable should not have to change with it.

Use the C port only if a test shows the recorder app writes to that port and not the A
one. In that case the fallback is a passive *USB-C-male to USB-A-female* adapter on the
car port and the same A cable after it — mechanically awkward, electrically fine.

### The cable, and which end is which

**The car side is the USB-A plug** — the flat rectangular one, the same plug you would
otherwise push into a laptop, a charger or a car stereo. It goes into the car's USB-A
socket in the centre console. The other end goes into the board. There is no special
"OTG" cable and no adapter in this direction.

```
   car, centre console                       board
  ┌──────────────────┐                    ┌───────────────────┐
  │  USB-A socket    │◄── USB-A plug ─────┤ micro-USB plug    │  Pi Zero / Zero 2 W
  │  (the car)       │    (flat, wide)    │ (small trapezoid) │  → the "USB" port,
  └──────────────────┘                    └───────────────────┘    never "PWR IN"

  ┌──────────────────┐                    ┌───────────────────┐
  │  USB-A socket    │◄── USB-A plug ─────┤ USB-C plug        │  Orange Pi Zero 2W / Pi 4
  │  (the car)       │    (flat, wide)    │ (small oval)      │  → the OTG USB-C port
  └──────────────────┘                    └───────────────────┘
```

| Board | Car side | Board side | Which board socket |
|---|---|---|---|
| Pi Zero W / Zero 2 W | USB-A male | micro-USB male | the **USB** port (middle), *not* `PWR IN` |
| Orange Pi Zero 2W | USB-A male | USB-C male | the USB-C **OTG** port |
| Pi 4 / Pi 5 | USB-A male | USB-C male | the USB-C port — *and see the power note* |

So the thing to buy is an ordinary **"USB-A to micro-USB"** or **"USB-A to USB-C"** data
cable — the kind sold for charging a phone or a Kindle. The end with the big flat plug is
the car end, always.

Ways to get this wrong, all of them common:

| Wrong | What happens |
|---|---|
| USB-C to USB-C | Nothing enumerates on the Zero 2W/Orange Pi; no CC role switch, VBUS may never come on |
| Charge-only cable | Board powers up, looks alive, no drive ever appears |
| micro-USB in `PWR IN` | Board powers up, no drive ever appears — the corner port has no data lines |
| "OTG adapter" (micro-A plug + A socket) | That adapter makes the *Pi* a host; it is the opposite of what is needed here |
| A long, thin cable | Brownouts that present as random reboots or SD corruption |

Rules that matter more than the connector:

- **Data, not charge-only.** A charge-only micro-USB cable has no D+/D− pair; the board
  will power up, look broken, and no drive will appear. This is the single most common
  failure with this class of project.
- **Short and thick (≤ 30 cm, 22–24 AWG).** The car port's 5 V sags under load, and the
  Pi sees that as a brownout — which looks like random reboots or SD-card corruption, not
  like a power problem.
- **No hub, no splitter.** Both the power budget and the enumeration get fragile.
- The Pi Zero's *middle* micro-USB is the OTG one and it also powers the board, so it is
  genuinely one cable. The port nearest the corner is `PWR IN` and carries no data.

### Power budget, per board

Car USB-A data ports are usually 5 V/1 A, sometimes only 0.5 A.

| Board | Typical draw | Verdict on a car A port |
|---|---|---|
| Pi Zero W | 80–220 mA | fine |
| Pi Zero 2 W | 150–350 mA | fine |
| Orange Pi Zero 2W | 300–800 mA with Wi-Fi 5 active | fine on 1 A, marginal on 0.5 A |
| Pi 4 / Pi 5 | 0.6–1.5 A+ | **do not** run it from the car port; give it its own supply |

The gadget also *tells* the host what it will draw (`MaxPower` in
`run/enable_gadget.sh`): 100 mA on a board teslausb does not recognise, 200 mA for a Zero
2, 500/600 mA for a Pi 4/5. A conservative number is the safe direction — the car is less
likely to refuse to mount the drive — so a non-Pi board landing on the 100 mA default is
fine, not a bug.

### The ten-minute test that settles "which port"

Before trusting either, plug a **plain USB stick** into the A port, enable
*Apps → Driving Recorder*, drive or idle until a clip is written, and look at the stick.
Repeat in the C port. Whichever port the car writes to is the one the Pi must emulate, and
that answer is worth more than any reasoning about the connectors.
