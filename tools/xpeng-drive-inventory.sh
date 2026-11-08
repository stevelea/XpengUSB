#!/bin/bash
# xpeng-drive-inventory.sh - show what is on the emulated drive, read-only.
#
#   sudo bash tools/xpeng-drive-inventory.sh [/piusb.bin]
#
# Mounts the drive image read-only via loopback, so the car is not disturbed even
# while it has the drive open (the gadget keeps writing; we only read).
#
# This exists to answer "did the car write anything new, and where?" - which is
# exactly the XGuard question: if XGuard records to internal storage, nothing new
# appears here.
set -u
IMAGE="${1:-/piusb.bin}"
MNT="${XPENG_INVENTORY_MNT:-/mnt/inventory}"

[ "$(id -u)" -eq 0 ] || { echo "STOP: run as root (sudo)" >&2; exit 1; }
[ -f "$IMAGE" ] || { echo "no such image: $IMAGE" >&2; exit 1; }

mkdir -p "$MNT"
LOOP=$(losetup --read-only -f --show -P "$IMAGE") || { echo "losetup failed" >&2; exit 1; }
PART="${LOOP}p1"; [ -b "$PART" ] || PART="${LOOP}1"
cleanup() { umount "$MNT" 2>/dev/null; losetup -d "$LOOP" 2>/dev/null; }
trap cleanup EXIT

mount -o ro "$PART" "$MNT" || { echo "could not mount $PART read-only (car mid-write?)" >&2; exit 1; }

echo "== folders on the drive (clip counts):"
find "$MNT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | while read -r d; do
  n=$(find "$MNT/$d" -maxdepth 2 -type f \( -name '*.mp4' -o -name '*.MP4' \) 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -gt 0 ] && printf '  %-24s %s clip(s)\n' "$d" "$n"
done

echo
echo "== newest 10 clips anywhere on the drive:"
find "$MNT" -type f \( -name '*.mp4' -o -name '*.MP4' \) -printf '%T@ %s %P\n' 2>/dev/null \
  | sort -nr | head -10 | while read -r ts size rel; do
      printf '  %s  %8s  %s\n' "$(date -d "@${ts%.*}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')" "$size" "$rel"
    done
