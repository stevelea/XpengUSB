# P0: making the board visible as a drive

The question P0 answers: *will a host — first a Mac, then the car — mount this
board as a USB drive and let it write clips?* Nothing else in the project matters
until that is answered yes.

## Why "I plugged it in and the Mac saw nothing" is expected

A Raspberry Pi Zero W is **not a USB drive until software on it says so**. Plug it
into a Mac with a stock image and you get a powered Pi that enumerates nothing at
all — no device, no serial port, no network interface. That is not a fault.

Verified on the Mac used for this project (2026-11-08), with a Pi Zero W plugged
into a USB-A port:

| Check | Result |
|---|---|
| `system_profiler SPUSBDataType` | only hubs, a Ugreen SSD, a BT adapter, a webcam — no Pi |
| `ioreg -p IOUSB -l -w0 \| grep -i 1d6b` (Linux Foundation gadget vendor) | nothing |
| `ls /dev/cu.*` | only `Bluetooth-Incoming-Port`, `debug-console` |
| `ifconfig -l` | no new `en*` interface |
| `log show --last 30m` filtered on USB | no attach/detach event at all |

"no attach event at all" is the useful part: the host saw *nothing plug in*, which is
consistent with either (a) no gadget configured on the Pi, or (b) the power-only port,
or (c) a charge-only cable. It does not distinguish them, so the next step is to make
the Pi into a gadget deliberately and re-check.

## Step 0 — the three things to get right before blaming software

1. **The port.** On a Pi Zero W / Zero 2 W the *middle* micro-USB is the OTG one and it
   also powers the board. The one at the corner is silkscreened `PWR IN` and has no data
   lines at all.
2. **The cable.** It must be a data cable. A charge-only micro-USB gives you a booting Pi
   and no device, forever.
3. **`dtoverlay=dwc2`** in `config.txt`. Without it the OTG port is not in peripheral
   mode, and no gadget can be created.

## Step 1 — give the Pi an OS and a way in

Flash Raspberry Pi OS Lite with Raspberry Pi Imager, and in the Imager's advanced
options set the Wi-Fi credentials and enable SSH. The Pi is powered by the Mac's USB-A
port for this test, and reached over Wi-Fi, so the USB port stays free for the gadget.

## Step 2 — make it a drive

Copy `tools/xpeng-gadget-test.sh` to the Pi and run it:

```bash
scp tools/xpeng-gadget-test.sh pi@raspberrypi.local:/tmp/
ssh pi@raspberrypi.local sudo bash /tmp/xpeng-gadget-test.sh 1G
```

It creates `/piusb.bin` (MBR + one FAT32 partition), puts `XP_DCIM/` and
`XP_EMER_DCIM/` on it, loads `g_mass_storage` and binds it. It prints the UDC it found,
which is the proof that the OTG controller is in peripheral mode.

## Step 3 — look from the Mac

```bash
system_profiler SPUSBDataType | grep -B2 -A8 -i "linux\|XPENGUSB"
diskutil list | grep -i xpeng
```

Expected: a Linux Foundation composite gadget, and a volume named `XPENGUSB`
containing the two folders.

## Step 4 — the car

Same image, same cable, into the car's **USB-A** port; enable
*Apps → Driving Recorder*; drive or idle until a clip appears; then check the Pi:

```bash
ls -l /mnt/cam 2>/dev/null   # if mounted by the product code
# or, for this test image:
sudo mount -o ro,loop,offset=1048576 /piusb.bin /mnt   # 1 MiB offset, see below
ls -l /mnt/XP_DCIM | tail
sudo umount /mnt
```

Bootstrapping note: `/piusb.bin` cannot be mounted while `g_mass_storage` has it
bound — unload it first (`sudo modprobe -r g_mass_storage`), inspect, then reload.

## If the Mac sees the drive but the car does not

That is the interesting failure, and it is a *car* question, not a cable question.
Try, in this order:

1. A different port (the USB-C one, with a C-to-A adapter on it) — some head units only
   enable the recorder on one socket.
2. A larger image (the car may ignore very small drives; 32–64 GB is the useful range).
3. A different partition type or a real volume label the car recognises.
4. A real stick in the same port, to confirm the car records at all on that socket.

## If the Mac sees nothing after step 2

- `cat /sys/class/udc/*/state` on the Pi — `configured` means the host attached.
- `dmesg | tail -30` on the Pi for `g_mass_storage` and `dwc2` lines.
- `dtoverlay=dwc2` really present, and the Pi really rebooted since.
- The cable, then the port, then the other cable.

---

## Results, 2026-11-08 — host side: **passed**

Board: Raspberry Pi Zero W Rev 1.1, Raspberry Pi OS (Buster, kernel 5.10.103+), hostname
`piXpeng` (renamed from `coffice` on 2026-11-08; mDNS `pixpeng.local`, reachable at
`pi@piXpeng.local`), on Wi-Fi. Backing image: 512 MB, MBR + one FAT32 partition labelled `XPENGUSB`,
carrying `XP_DCIM/` and `XP_EMER_DCIM/`.

| Step | Result |
|---|---|
| `dtoverlay=dwc2` + `modules-load=dwc2,g_ether` | the Pi came up as an RNDIS Ethernet gadget on the Mac (`20980000.usb`), which is how it was reached without HDMI |
| `modprobe -r g_ether; modprobe g_mass_storage file=/piusb.bin removable=1 stall=0` | Mac enumerated **Mass Storage Gadget**, vendor `0x0525` (PLX), product `0xa4a5`, "Linux 5.10.103+ with 20980000.usb", 536.9 MB, `Partition Map Type: MBR` |
| `/sys/class/udc/20980000.usb/state` | `configured` |
| `diskutil` | `disk4s1  DOS_FAT_32 XPENGUSB  536.9 MB` |
| volume mounted on the Mac | `XPENGUSB/` showing `XP_DCIM/` and `XP_EMER_DCIM/` |
| **write round trip** | wrote `DVR_…_front.mp4` from the Mac, unmounted, remounted, read the content back correctly — so the write went through the gadget into the Pi's file and persisted |

So: **a Pi Zero W can present this drive to a host, and the host can write clips to it.**
The gadget half of P0 is answered yes.

### What was installed on the Pi

- `/piusb.bin` — the backing image (512 MB; the real product wants 32–64 GB).
- `/etc/modprobe.d/xpeng-gadget.conf` — `options g_mass_storage file=/piusb.bin removable=1 stall=0`
- `/etc/systemd/system/xpeng-gadget.service` — enabled; unloads the boot-time `g_ether`,
  then binds `g_mass_storage`. Keeping `g_ether` in `cmdline.txt` means that if the unit
  ever fails, the USB-ethernet maintenance path still exists.
- `/boot/xpeng-gadget-test.sh` — the bring-up helper, for reference.

### Card edits (backups kept on the boot partition)

`config.txt.xpeng-backup-20261108`, `cmdline.txt.xpeng-backup-20261108`.

### Still to do

1. **The car.** Unplug from the Mac, plug the middle micro-USB into the car's USB-A port,
   wait ~40 s for the Zero W to boot and the unit to bind, then enable
   *Apps → Driving Recorder*. Then unplug, bring it back, and look for `DVR_*` clips in
   `XP_DCIM`.
2. Decide whether 512 MB is big enough; if the car ignores it, try 32–64 GB.
3. macOS drops `.Spotlight-V100`, `.fseventsd` and `._*` files on the volume every time it
   mounts it. They are ignored by the archiver, but strip them before a car test so the
   car sees exactly what it would see on a real stick.

## Card preparation gotcha (2026-11-08)

Stock Raspberry Pi OS Bookworm `config.txt` contains

```
[cm5]
dtoverlay=dwc2,dr_mode=host
```

which is inside a `[cm5]` section and therefore inert on a Zero W - but a naive
"does config.txt mention dwc2" check matches it and skips the line that actually
matters, leaving the OTG port in **host** mode and the gadget permanently absent.
`tools/xpeng-prepare-boot.sh` now writes the unambiguous form at the end of the file:

```
[all]
dtoverlay=dwc2,dr_mode=peripheral
```

If a card ever presents no USB device at all, check that exact line first.
