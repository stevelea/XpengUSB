# XpengUSB

Fork of `stevelea/teslausb` (upstream `marcone/teslausb`), being turned into an
**XPENG** dashcam archiver: a Raspberry Pi presents itself to the car as a USB
drive, archives `XP_DCIM` / `XP_EMER_DCIM` clips to a NAS (or Google Drive via
rclone), optionally over Tailscale, and deletes them only after a verified upload.

**Verified on hardware (2026-11-08):** the car records normal and emergency clips to the Pi,
the archive lands on the NAS and verifies, and the clips appear in Frigate (3 live-view
cameras) and in a web viewer on the Frigate host.

**Branch `xpeng` holds the first implementation:** `run/xpeng-{loop,archive,network-state}.sh`
behind `XPENG_MODE=true`, with `tests/xpeng-test.sh` (40 assertions, runs on macOS/Linux, no
board needed). The Tesla path is untouched when `XPENG_MODE` is off. Read
[`doc/XpengPort.md`](doc/XpengPort.md) first — it has the measured car layout, the design and
the hardware verdicts.

## Layout

- `run/archiveloop` — the Tesla supervisor. It `exec`s `run/xpeng-loop.sh` when
  `XPENG_MODE=true`; otherwise unchanged.
- `run/xpeng-loop.sh` — two lanes, two cadences, idle-gated deletion (`XPENG_RUN_ONCE=1`
  for a single pass).
- `run/xpeng-archive.sh` — one lane: scan → settle window → dedupe index → rsync →
  verify by size → delete (only when idle). Takes a *directory* as source, so it runs on
  any box.
- `run/xpeng-network-state.sh` — prints `home|wifi|other|none`; `XPENG_FORCE_STATE` for tests.
- `run/xpeng-lan-pin.sh` — with Tailscale `--accept-routes`, table 52 hijacks the whole
  home LAN; this pins the archive host to the local gateway while on the LAN, and removes
  the pin when away. Runs from a 30 s timer.
- `run/{cifs,nfs,rsync,rclone,none}_archive/archive-clips.sh` — one small backend each;
  **reuse, do not rewrite**.
- `run/enable_gadget.sh`, `run/disable_gadget.sh` — USB gadget from `/backingfiles/*.bin`.
- `run/waitforidle` — "is the car writing?" via the gadget's `/proc/<pid>/io`.
- `setup/pi/setup-teslausb` — the installer; honours `REPO`/`BRANCH`, so this fork installs
  as `REPO=stevelea BRANCH=xpeng`. Creates `XP_DCIM`/`XP_EMER_DCIM` when `XPENG_MODE=true`.
- `setup/pi/envsetup.sh` — reads `/root/teslausb_setup_variables.conf`; all `XPENG_*`
  settings live here, defaults inert.
- `teslausb-www/` — Tesla-specific web UI (event folders); leave it off for XPENG.
- `doc/` — upstream docs; `doc/XpengPort.md` is ours, and `doc/P0-gadget-bringup.md`
  is the hardware bring-up checklist.
- `tools/xpeng-gadget-test.sh` — run **on the Pi** to make it present a drive
  (`g_mass_storage`, MBR+FAT32 image with `XP_DCIM`/`XP_EMER_DCIM`).
- `tools/xpeng-drive-inventory.sh` — run **on the Pi**: mounts the drive image read-only and
  lists its folders and newest clips. Answers "did the car write anything, and where?".
- `tools/xpeng-settings/` — the Pi's settings page (stdlib Python, port 8081). `install.sh`
  also purges nginx from the Pi.
- The **archive viewer is not in this repo's Pi image**: it is the `xpeng-viewer` container
  on the Frigate host (`192.168.1.202:8090`), reading the NAS over NFS. See
  `doc/XpengPort.md` §7.9.

## Commands

- Tests: `bash tests/xpeng-test.sh` — the XPENG lane suite. **Runs here (macOS/Linux).**
- Lint/CI parity: `bash check.sh` (shellcheck). The new files are in `check.sh` and must
  stay clean.
- Upstream tests `sudo bash tests/create-backingfiles{-partition,}-test.sh` need root and
  loop/block devices — they do not run on the Mac.
- Nothing else here executes on macOS: the scripts target Debian/Armbian/Raspberry Pi OS.
- Editing on this SMB mount: the `edit`/`write` tools fail (rename across the share).
  Use `python3 -` / heredoc / `sed -i`, then `read`.

## Working rules

- Smallest correct change; match the existing bash style (`function name ()`, `local -r`).
- Do not re-add anything snapshot/reflink-related for XPENG — the design drops it.
- The verify-then-delete rule already proven in `XpengDVRCopy/deploy/copyusb.sh` is the
  one to reuse; do not invent a second dedupe scheme.
- New files on this SMB mount cannot be created with the `write` tool: create with
  `cat > file <<'EOF'` (or `: > file`) first, then `read`, then edit.

## Gotchas

- `/backingfiles` must be XFS (`reflink`) for upstream snapshots; XPENG does not need it
  but `create-backingfiles*.sh` still expects it.
- `USE_EXFAT=true` is required for a `CAM_SIZE` above 32 G.
- `tailscaled` state must be moved into `/mutable` or the node re-auths every boot
  (the root filesystem is read-only) — same treatment as `/var/lib/NetworkManager`.

<!-- dsh-context-pointer -->
## Workspace context — read before exploring

Cross-machine context for this workspace: `/Volumes/projects/Work/.harness/context/Volumes-projects-XpengUSB.md`
(purpose, layout, commands, current state, open threads, gotchas). Read it first;
it is maintained by the `dsh-context` skill. Update its **Current state** and
**Open threads** before you finish a session that changed anything, and bump the
`generated:` date. Stale context is worse than none.
