#!/bin/bash -eu
#
# flash-sd-mac.sh - write a Raspberry Pi OS image to an SD card on macOS.
#
#   sudo bash tools/flash-sd-mac.sh <image.img.xz> <device>
#   sudo bash tools/flash-sd-mac.sh /tmp/rpios.img.xz /dev/disk5
#
# Deliberately paranoid: it refuses unless the target is an external, removable
# disk, shows you exactly what it is about to overwrite, and requires the word
# "yes". Getting this wrong costs a laptop.
#
# The card is left with the boot partition mounted at /Volumes/bootfs so the
# per-card configuration (ssh, userconf.txt, config.txt, cmdline.txt) can be
# dropped in straight after.

DRY_RUN="${XPENG_FLASH_DRY_RUN:-0}"

if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" != "1" ]; then
  echo "STOP: run with sudo" >&2
  exit 1
fi

IMAGE="${1:-}"
DEVICE="${2:-}"
if [ -z "$IMAGE" ] || [ -z "$DEVICE" ]; then
  echo "usage: sudo bash $0 <image.img.xz> <device>   e.g. /dev/disk5" >&2
  exit 2
fi
[ -f "$IMAGE" ] || { echo "no such image: $IMAGE" >&2; exit 2; }
case "$DEVICE" in
  /dev/disk[0-9]*) ;;
  *) echo "refusing: '$DEVICE' is not a whole disk (/dev/diskN)" >&2; exit 2 ;;
esac

# The device must exist, be external and removable. Nothing else is accepted.
if ! diskutil info "$DEVICE" > /dev/null 2>&1; then
  echo "refusing: no such disk $DEVICE" >&2
  exit 2
fi
INTERNAL=$(diskutil info "$DEVICE" | awk -F': *' '/^ *Internal:/ {print $2}')
REMOVABLE=$(diskutil info "$DEVICE" | awk -F': *' '/^ *Removable Media:/ {print $2}')
SIZE=$(diskutil info "$DEVICE" | awk -F': *' '/^ *Disk Size:/ {print $2}')
NAME=$(diskutil info "$DEVICE" | awk -F': *' '/^ *Device \/ Media Name:/ {print $2}')

if [ "$INTERNAL" = "Yes" ]; then
  echo "refusing: $DEVICE is an internal disk" >&2
  exit 2
fi
case "$REMOVABLE" in
  Yes|Removable) ;;
  *)
    echo "refusing: $DEVICE is not removable media (says '$REMOVABLE')" >&2
    exit 2
    ;;
esac

echo "about to OVERWRITE:"
echo "  device : $DEVICE  ($NAME, $SIZE)"
echo "  image  : $IMAGE"
echo
if [ "$DRY_RUN" = "1" ]; then
  echo "(dry run: stopping here, nothing written)"
  exit 0
fi

printf 'type "yes" to continue: '
read -r answer
[ "$answer" = "yes" ] || { echo "aborted"; exit 1; }

echo "unmounting..."
diskutil unmountDisk "$DEVICE" > /dev/null || true

echo "writing (this takes a while for a 256 GB card)..."
# rdisk is the raw device: much faster than the buffered one.
RAW="${DEVICE/disk/rdisk}"
if xz -dc "$IMAGE" | dd of="$RAW" bs=4m; then
  sync
else
  echo "write FAILED" >&2
  exit 1
fi

echo "re-reading the partition table..."
diskutil list "$DEVICE" | sed 's/^/  /'

# Bookworm keeps the boot partition on partition 1.
BOOT=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  BOOT=$(diskutil list "$DEVICE" | awk '/ DOS_FAT_32 | Windows_FAT_32 | FAT_32 / {print $NF}' | head -1)
  [ -n "$BOOT" ] && break
  sleep 1
done

BOOTDIR=""
if [ -n "$BOOT" ]; then
  diskutil mount "$BOOT" > /dev/null 2>&1 || true
  BOOTDIR=$(diskutil info "$BOOT" 2>/dev/null | awk -F': *' '/^ *Mount Point:/ {print $2}')
  if [ -n "$BOOTDIR" ] && [ -d "$BOOTDIR" ]; then
    echo "boot partition mounted at $BOOTDIR"
  else
    BOOTDIR=""
  fi
fi

# Finishing the card is the step people forget, and an unprepared card boots
# with no user, no ssh and no gadget - unreachable, with a bare login prompt.
if [ "$BOOTDIR" = "" ]; then
  echo "could not identify the boot partition; prepare it by hand:" >&2
  exit 1
fi

if [ -n "${XPENG_PI_PASSWORD:-}" ]; then
  PREPARE="$(dirname "$0")/xpeng-prepare-boot.sh"
  if [ -x "$PREPARE" ] || [ -f "$PREPARE" ]; then
    echo
    echo "preparing the card (ssh, user, dwc2, usb ethernet)..."
    bash "$PREPARE" "$BOOTDIR"
  else
    echo "WARNING: $PREPARE not found - the card will not be reachable" >&2
  fi
else
  echo
  echo "WARNING: XPENG_PI_PASSWORD was not set, so the card has NOT been prepared."
  echo "         It will boot with no user, no ssh and no USB gadget."
  echo "         Either re-run with XPENG_PI_PASSWORD='...' or run:"
  echo "           bash $(dirname "$0")/xpeng-prepare-boot.sh $BOOTDIR"
fi

echo
echo "wrote $IMAGE to $DEVICE"
