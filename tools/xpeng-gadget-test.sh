#!/bin/bash -eu
#
# xpeng-gadget-test.sh - make this Pi present itself as a USB drive, so a host
# (a Mac, a PC, or the car) can see it. This is the first half of P0.
#
#   sudo bash tools/xpeng-gadget-test.sh [size]
#
# size defaults to 1G. Creates /piusb.bin (MBR + one FAT32 partition holding
# XP_DCIM/ and XP_EMER_DCIM/), loads g_mass_storage and binds it.
#
# Run this ON THE PI. It changes nothing on the host. Re-running is safe: the
# image is only created if it is missing, and the gadget is unbound first.
#
# Why g_mass_storage and not configfs: it is one module load instead of thirty
# configfs writes, which is what a bring-up test wants. The real product uses
# the configfs gadget in run/enable_gadget.sh.
#
# Prerequisite: dtoverlay=dwc2 in config.txt (the Pi Zero needs it to put its
# OTG port in peripheral mode).

if [ "$(id -u)" -ne 0 ]; then
  echo "STOP: run as root (sudo bash $0)" >&2
  exit 1
fi

IMAGE="${XPENG_GADGET_IMAGE:-/piusb.bin}"
SIZE="${1:-1G}"
LABEL="${XPENG_GADGET_LABEL:-XPENGUSB}"

function log { echo "$(date '+%H:%M:%S') gadget-test: $*"; }
function die { log "ERROR: $*"; exit 1; }

for tool in sfdisk mkfs.vfat losetup mount; do
  command -v "$tool" > /dev/null 2>&1 || die "$tool is missing (apt install dosfstools fdisk mount)"
done

if [ -e /sys/class/udc ] && [ -n "$(ls -A /sys/class/udc 2>/dev/null)" ]; then
  log "UDC present: $(find /sys/class/udc -mindepth 1 -maxdepth 1 -printf '%f ' 2>/dev/null)"
else
  log "no UDC found - the OTG controller is not in peripheral mode."
  log "add 'dtoverlay=dwc2' to /boot/firmware/config.txt (or /boot/config.txt) and reboot."
  die "cannot continue without a peripheral-mode controller"
fi

# ---------------------------------------------------------------------------
# 1. The backing image: MBR + one FAT32 partition, like the real product.
# ---------------------------------------------------------------------------
if [ ! -e "$IMAGE" ]; then
  log "creating $IMAGE ($SIZE) ..."
  truncate -s "$SIZE" "$IMAGE" || die "cannot create $IMAGE"
  # MBR, one partition starting at 1 MiB with the partition type the car
  # expects (0x0c = FAT32 LBA).
  printf 'label: dos\nstart=2048, type=c, bootable\n' | sfdisk -q "$IMAGE" > /dev/null \
    || die "sfdisk failed on $IMAGE"
else
  log "$IMAGE already exists ($(du -h "$IMAGE" | awk '{print $1}')) - reusing"
fi

LOOP="$(losetup -f --show -P "$IMAGE")" || die "losetup failed"
cleanup_loop () { losetup -d "$LOOP" 2>/dev/null || true; }
trap cleanup_loop EXIT

PART="${LOOP}p1"
[ -b "$PART" ] || PART="${LOOP}1"
for _ in 1 2 3 4 5; do
  [ -b "$PART" ] && break
  sleep 1
done
[ -b "$PART" ] || die "partition did not appear ($PART)"

# Probe for an actual *filesystem* type. blkid's plain exit status also fires
# for a bare partition table entry, which made this skip formatting a blank
# partition and then fail to mount it - "wrong fs type, bad option".
FS_TYPE=""
if command -v blkid > /dev/null 2>&1; then
  FS_TYPE="$(blkid -o value -s TYPE "$PART" 2>/dev/null || true)"
fi
if [ -n "$FS_TYPE" ]; then
  log "partition already has a $FS_TYPE filesystem - leaving it alone"
else
  if command -v wipefs > /dev/null 2>&1; then
    wipefs -a "$PART" > /dev/null 2>&1 || true
  fi
  log "formatting $PART as FAT32, label $LABEL"
  mkfs.vfat -F 32 -n "$LABEL" "$PART" > /dev/null || die "mkfs.vfat failed"
fi

MNT="$(mktemp -d /tmp/gadgetmnt.XXXXXX)"
mount "$PART" "$MNT" || die "cannot mount $PART"
mkdir -p "$MNT/XP_DCIM" "$MNT/XP_EMER_DCIM"
# The car's own sticks carry this marker; harmless and authentic.
: > "$MNT/XP_DCIM/.nomedia"
: > "$MNT/XP_EMER_DCIM/.nomedia"
sync
umount "$MNT"
rmdir "$MNT"

losetup -d "$LOOP"
trap - EXIT

# ---------------------------------------------------------------------------
# 2. Present it. removable=1 so the host can rescan and eject.
# ---------------------------------------------------------------------------
# A boot-time g_ether (the cmdline.txt this tool expects) owns the UDC and must
# go first; g_serial is the other common one. Both are safe to remove.
for mod in g_mass_storage g_ether g_serial; do
  modprobe -q -r "$mod" 2>/dev/null || true
done
sleep 1
log "loading g_mass_storage with $IMAGE"
modprobe g_mass_storage "file=$IMAGE" removable=1 stall=0 \
  || die "modprobe g_mass_storage failed (is dtoverlay=dwc2 in config.txt?)"

sleep 2
log "done. the host should now see a disk labelled $LABEL, with"
log "  XP_DCIM/  and  XP_EMER_DCIM/  on it."
log "on a Mac, check with:  system_profiler SPUSBDataType | grep -A5 -i linux"
log "and:  diskutil list"
log ""
log "to hide the drive again:  sudo modprobe -r g_mass_storage"
