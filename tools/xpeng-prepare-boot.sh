#!/bin/bash -eu
#
# xpeng-prepare-boot.sh - finish a freshly flashed Raspberry Pi OS card so that
# it boots headless, appears as a USB network device, and can present a drive.
#
#   bash tools/xpeng-prepare-boot.sh /Volumes/bootfs
#
# Needs no root: the boot partition is a FAT volume the user can write.
#
# What it does (all idempotent):
#   ssh                    -> enables sshd on first boot
#   userconf.txt           -> creates user 'pi' with the password you pass in
#   config.txt             -> dtoverlay=dwc2  (OTG port in device mode)
#   cmdline.txt            -> modules-load=dwc2,g_ether (USB ethernet, so the
#                             board can be reached before Wi-Fi is set up)
#
# Password: XPENG_PI_PASSWORD, or prompted for. Never written anywhere except
# the hashed field of userconf.txt on the card.
#
# USB mode (optional): XPENG_USB_MODE=gadget (default) or host.
#   gadget  - the port emulates a drive/network link to a host. This is the
#             product mode and forces dr_mode=peripheral.
#   host    - the port is a normal USB host, so a keyboard or hub works there.
#             Use this for a console/keyboard debugging session; the drive
#             emulation is then unavailable, and power comes from PWR IN.
#
# Console diagnostics (optional): XPENG_CONSOLE_DIAG=1 keeps the screen awake and
# prints the wireless state to the local console, so a screen with no keyboard
# still tells you what the radio can see.
#
# Timezone (optional): XPENG_TIMEZONE, default Australia/Sydney. This matters more
# than it looks: FAT carries no timezone, and the vfat driver converts file
# timestamps using the system timezone. A Pi left on UTC sees every clip the car
# wrote as hours in the FUTURE, and an age-based "is this clip finished" test then
# rejects all of them forever.
#
# Hostname (optional): XPENG_HOSTNAME, default piXpeng.
#
# Wi-Fi (optional): XPENG_WIFI_SSID may be a space-separated list, e.g.
#   XPENG_WIFI_SSID="my-home-wifi my-other-wifi"
# One NetworkManager keyfile is written per SSID with descending autoconnect
# priority, so whichever the radio can actually see wins. A dual-band mesh SSID
# can be unusable for a 2.4 GHz-only radio (band steering, or the 2.4 GHz BSS not
# answering probes); a dedicated 2.4 GHz SSID is the workaround, and writing both
# costs nothing.
#
# Set XPENG_WIFI_SSID and XPENG_WIFI_PASSWORD and a first-boot
# script joins that network with nmcli, then removes itself. That is the only way
# to put a Bookworm card on a network with no ssh session first: Bookworm ignores
# wpa_supplicant.conf on the boot partition. The password sits in clear text on
# the card until first boot deletes the script, exactly as Raspberry Pi Imager
# leaves it.

BOOT="${1:-}"
if [ -z "$BOOT" ] || [ ! -d "$BOOT" ]; then
  echo "usage: bash $0 <mounted boot partition>   e.g. /Volumes/bootfs" >&2
  exit 2
fi

PI_USER="${XPENG_PI_USER:-pi}"
PI_PASSWORD="${XPENG_PI_PASSWORD:-}"

function log { echo "prepare-boot: $*"; }

# GNU sed takes -i with no argument; BSD/macOS sed requires an explicit (empty)
# backup suffix and otherwise swallows the script as the suffix and fails. This
# script runs on both, so pick the right form once. Getting this wrong is silent:
# the edit just does not happen, which is how a cmdline kept its modules-load
# after the log claimed it had been removed.
if sed --version > /dev/null 2>&1; then
  SED_INPLACE=(sed -i)
else
  SED_INPLACE=(sed -i '')
fi
function sedi { "${SED_INPLACE[@]}" "$@"; }

if [ -z "$PI_PASSWORD" ]; then
  if [ ! -t 0 ]; then
    echo "STOP: set XPENG_PI_PASSWORD (no terminal to prompt on)" >&2
    exit 2
  fi
  printf 'password for new user %s: ' "$PI_USER"
  read -r -s PI_PASSWORD
  echo
  [ -n "$PI_PASSWORD" ] || { echo "STOP: empty password" >&2; exit 2; }
fi

# --- ssh ---------------------------------------------------------------
: > "$BOOT/ssh"
log "ssh enabled"

# --- user --------------------------------------------------------------
HASH="$(openssl passwd -6 "$PI_PASSWORD")"
printf '%s:%s\n' "$PI_USER" "$HASH" > "$BOOT/userconf.txt"
chmod 600 "$BOOT/userconf.txt" 2>/dev/null || true
log "user '$PI_USER' will be created on first boot"

# --- config.txt: OTG in device mode ------------------------------------
# Careful: stock Bookworm config.txt contains 'dtoverlay=dwc2,dr_mode=host'
# inside a [cm5] section. Matching on 'dtoverlay=dwc2' alone therefore
# "succeeds" and leaves the OTG port in HOST mode, which is the opposite of
# what the gadget needs. Look for the peripheral line specifically, and write
# dr_mode explicitly so no earlier overlay can win.
USB_MODE="${XPENG_USB_MODE:-gadget}"
case "$USB_MODE" in
  gadget) DR_MODE=peripheral ;;
  host)   DR_MODE=host ;;
  *)
    echo "STOP: XPENG_USB_MODE must be 'gadget' or 'host', not '$USB_MODE'" >&2
    exit 2
    ;;
esac

# Strip any previous XPENGUSB dr_mode line, then write the wanted one. Both are
# written in [all] so the stock [cm5] 'dtoverlay=dwc2,dr_mode=host' cannot
# interfere either way.
sedi '/^dtoverlay=dwc2,dr_mode=/d' "$BOOT/config.txt" 2>/dev/null || true
{
  echo ''
  echo "# XPENGUSB: OTG port mode ($USB_MODE). Explicit dr_mode beats any"
  echo '# earlier overlay, including the stock [cm5] host line.'
  echo '[all]'
  echo "dtoverlay=dwc2,dr_mode=$DR_MODE"
} >> "$BOOT/config.txt"
log "config.txt: dr_mode=$DR_MODE (XPENG_USB_MODE=$USB_MODE)"

# --- cmdline.txt: load dwc2 + the ethernet gadget ----------------------
CMDLINE="$BOOT/cmdline.txt"
if [ ! -f "$CMDLINE" ] && [ -f "$BOOT/firmware/cmdline.txt" ]; then
  CMDLINE="$BOOT/firmware/cmdline.txt"
fi
if [ "$USB_MODE" = "host" ]; then
  # No gadget: leave the port to the kernel as a host, and drop any g_ether so
  # the port is not claimed by a gadget function.
  sedi 's| modules-load=dwc2,g_ether||; s| modules-load=dwc2||' "$CMDLINE" 2>/dev/null || true
  log "cmdline.txt: modules-load removed (host mode)"
elif grep -q 'modules-load=' "$CMDLINE" 2>/dev/null; then
  log "cmdline.txt already has modules-load"
else
  # cmdline.txt must stay a single line.
  python3 - "$CMDLINE" <<'PY'
import io, sys
p = sys.argv[1]
with io.open(p, 'r', encoding='utf-8', newline='') as f:
    line = f.read().strip('\n')
if not line.endswith(' '):
    line += ' '
line += 'modules-load=dwc2,g_ether'
with io.open(p, 'w', encoding='utf-8', newline='') as f:
    f.write(line + '\n')
PY
  log "cmdline.txt: added modules-load=dwc2,g_ether"
fi

# --- wifi (optional): first-boot script --------------------------------
WIFI_SSID="${XPENG_WIFI_SSID:-}"   # space-separated list allowed
WIFI_PASSWORD="${XPENG_WIFI_PASSWORD:-}"
HOSTNAME_WANTED="${XPENG_HOSTNAME:-piXpeng}"
FIRSTRUN="$BOOT/firstrun.sh"

if [ -n "$WIFI_SSID" ] && [ -n "$WIFI_PASSWORD" ]; then
  cat > "$FIRSTRUN" <<'FIRSTRUN_EOF'
#!/bin/bash
# XPENGUSB early first boot.
#
# This runs at systemd.run= time - after sysinit.target, before multi-user - so
# NetworkManager does not exist yet and nmcli cannot be used. Attempting to join
# from here produced a 1-second failure followed by systemd.run_success_action=
# reboot, i.e. a reboot loop.
#
# So this script does not talk to NetworkManager at all. It WRITES the network
# as a NetworkManager keyfile, which is the declarative way to do it: on the next
# (normal) boot NM reads /etc/NetworkManager/system-connections and connects by
# itself, no helper process, no service, no ordering problem. It also drops a
# dispatcher script that records link state on the boot partition, so a laptop
# can see what the radio did without a screen.
set +e
BOOT=/boot/firmware
[ -d "$BOOT" ] || BOOT=/boot
LOG=/tmp/firstrun.log
exec > "$LOG" 2>&1
echo "=== early firstrun $(date -Is) ==="

# Hostname by writing the files directly: hostnamectl needs the system bus,
# which does not exist yet at systemd.run= time (it failed with "Failed to
# connect to bus" on every attempt in the first version).
# Timezone by files: timedatectl needs the system bus, which does not exist yet.
printf '%s\n' '@TZ@' > /etc/timezone
if [ -e "/usr/share/zoneinfo/@TZ@" ]; then
  ln -sf "/usr/share/zoneinfo/@TZ@" /etc/localtime
fi

printf '%s\n' '@HOSTNAME@' > /etc/hostname
if grep -q '^127.0.1.1' /etc/hosts; then
  sed -i "s/^127.0.1.1.*/127.0.1.1\t@HOSTNAME@/" /etc/hosts
else
  printf '127.0.1.1\t@HOSTNAME@\n' >> /etc/hosts
fi

# --- the networks, as keyfiles ---------------------------------------
# One profile per SSID, highest priority first. See the note at the top of this
# file for why a list rather than a single SSID.
CONNDIR=/etc/NetworkManager/system-connections
mkdir -p "$CONNDIR"
priority=100
for ssid in @SSIDS@; do
  safe=$(printf '%s' "$ssid" | tr -c 'A-Za-z0-9._-' '_')
  cat > "$CONNDIR/$safe.nmconnection" <<NM_EOF
[connection]
id=$ssid
type=wifi
autoconnect=true
autoconnect-priority=$priority

[wifi]
ssid=$ssid
mode=infrastructure

[match]
interface-name=wlan0

[wifi-security]
key-mgmt=wpa-psk
psk=@PASS@

[ipv4]
method=auto

[ipv6]
method=auto
NM_EOF
  chmod 600 "$CONNDIR/$safe.nmconnection"
  chown root:root "$CONNDIR/$safe.nmconnection" 2>/dev/null
  echo "--- wrote $CONNDIR/$safe.nmconnection (priority $priority) ---" >> "$LOG"
  priority=$(( priority - 10 ))
done

# regulatory domain: written where Debian wireless tooling looks, and forced by
# the dispatcher on every pre-up (see below), because an unset domain can hide
# 2.4 GHz channels 12-13 and make a connect fail with no obvious reason.
sed -i "s/^REGDOMAIN=.*/REGDOMAIN=@COUNTRY@/" /etc/default/crda 2>/dev/null

# --- a USB management link that is always reachable ---------------------
# g_ether (from cmdline.txt) gives a bare Ethernet link with no addressing on
# either end: the host shows "inactive", the Pi's usb0 has nothing, and the board
# is unreachable even though it is plugged in.
#
# usb0 is given a static address in the IPv4 link-local range (169.254/16). Hosts
# self-assign in that range automatically when DHCP fails, so a laptop reaches
# 169.254.10.2 with no configuration and no DHCP server on either side - which
# matters because dnsmasq (needed for NetworkManager's "shared" mode) is not in
# the Lite image.
cat > "$CONNDIR/xpeng-usb0.nmconnection" <<'USB_EOF'
[connection]
id=xpeng-usb0
type=ethernet
interface-name=usb0
autoconnect=true
autoconnect-priority=200

[ipv4]
method=manual
address1=169.254.10.2/16

[ipv6]
method=ignore
USB_EOF
chmod 600 "$CONNDIR/xpeng-usb0.nmconnection"
chown root:root "$CONNDIR/xpeng-usb0.nmconnection" 2>/dev/null
echo "--- wrote $CONNDIR/xpeng-usb0.nmconnection (static 169.254.10.2 on usb0) ---" >> "$LOG"

# --- a dispatcher, to observe rather than to act -----------------------
DISP=/etc/NetworkManager/dispatcher.d
mkdir -p "$DISP"
cat > "$DISP/90-xpeng-log" <<'DISP_EOF'
#!/bin/bash
# Record Wi-Fi link events on the boot partition: readable from any laptop, and
# the cheapest way to see whether the radio ever associated.
IFACE="$1"
EVENT="$2"
case "$IFACE" in wlan*) ;; *) exit 0 ;; esac

# Right moment to force the regulatory domain, before the interface is configured
# and before it can start scanning.
if [ "$EVENT" = "pre-up" ]; then
  iw reg set '@COUNTRY@' 2>/dev/null
  exit 0
fi

BOOT=/boot/firmware
[ -d "$BOOT" ] || BOOT=/boot
[ -w "$BOOT" ] || exit 0
{
  echo "$(date -Is) $IFACE $EVENT"
  if [ "$EVENT" = "up" ]; then
    iw dev "$IFACE" link 2>/dev/null | sed 's/^/    /'
    ip -4 addr show dev "$IFACE" 2>/dev/null | sed -n 's/.*inet /    ip /p'
  fi
} >> "$BOOT/xpeng-wifi.log" 2>/dev/null
exit 0
DISP_EOF
chmod 755 "$DISP/90-xpeng-log"
echo "--- installed $DISP/90-xpeng-log ---" >> "$LOG"

# --- print the wireless state on the console at every boot ---------------
# A screen is an output channel even with no keyboard: this runs after
# NetworkManager, writes to tty1 and appends to the boot partition, so the same
# information is available on the display and from the card.
cat > /etc/systemd/system/xpeng-diag.service <<'DIAGSVC_EOF'
[Unit]
Description=XPENGUSB print wireless diagnostics to the console
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/xpeng-diag.sh

[Install]
WantedBy=multi-user.target
DIAGSVC_EOF
chmod 644 /etc/systemd/system/xpeng-diag.service
if [ -f "$BOOT/xpeng-diag.sh" ]; then
  install -m 755 "$BOOT/xpeng-diag.sh" /usr/local/sbin/xpeng-diag.sh
  # Enable by hand: systemctl needs the system bus, which does not exist yet at
  # this point in boot ("Failed to connect to bus"). A symlink is exactly what
  # systemctl enable creates, and needs nothing but the filesystem.
  mkdir -p /etc/systemd/system/multi-user.target.wants
  ln -sf /etc/systemd/system/xpeng-diag.service \
         /etc/systemd/system/multi-user.target.wants/xpeng-diag.service
  echo "--- installed and enabled xpeng-diag.service (by symlink) ---" >> "$LOG"
fi

# Remove the early hook so nothing here runs twice. Note there is deliberately
# no systemd.run_success_action=reboot in cmdline.txt: a reboot was what turned
# a failing first run into a loop. The boot continues normally, NetworkManager
# starts later in this same boot, reads the keyfiles and connects.
rm -f "$BOOT/firstrun.sh" 2>/dev/null
sed -i 's| systemd.run=[^ ]*||; s| systemd.run_success_action=[^ ]*||; s| systemd.unit=kernel-command-line.target||' "$BOOT/cmdline.txt" 2>/dev/null

# Put the early log on the console as well: a screen is the only output channel
# when there is no keyboard, and this part needs no services at all.
[ -w /dev/tty1 ] && cat "$LOG" > /dev/tty1 2>/dev/null
[ -w "$BOOT" ] && cp "$LOG" "$BOOT/firstrun.log" 2>/dev/null
exit 0
FIRSTRUN_EOF

  # Values are substituted with a delimiter that cannot appear in an SSID.
  WIFI_COUNTRY="${XPENG_WIFI_COUNTRY:-AU}"
TIMEZONE_WANTED="${XPENG_TIMEZONE:-Australia/Sydney}"
python3 - "$FIRSTRUN" "$WIFI_SSID" "$WIFI_PASSWORD" "$HOSTNAME_WANTED" "$WIFI_COUNTRY" "$TIMEZONE_WANTED" <<'SUBST'
import io, sys
path, ssid, pw, host, country, tz = sys.argv[1:7]
text = io.open(path, encoding='utf-8').read()
text = (text.replace('@SSIDS@', ssid).replace('@PASS@', pw)
            .replace('@HOSTNAME@', host).replace('@COUNTRY@', country)
            .replace('@TZ@', tz))
io.open(path, 'w', encoding='utf-8', newline='\n').write(text)
SUBST
  chmod 755 "$FIRSTRUN"
  log "wrote firstrun.sh: hostname '$HOSTNAME_WANTED', Wi-Fi '$WIFI_SSID', country '$WIFI_COUNTRY'"

  if grep -q 'systemd.run=' "$CMDLINE" 2>/dev/null
  then
    # Remove any reboot action left by an earlier version: it is what produced
    # the reboot loop.
    sedi 's| systemd.run_success_action=[^ ]*||; s| systemd.unit=kernel-command-line.target||' "$CMDLINE" 2>/dev/null || true
    log "cmdline.txt already runs a first-boot script (reboot action removed)"
  else
    python3 - "$CMDLINE" <<'ADDRUN'
import io, sys
p = sys.argv[1]
# Deliberately no run_success_action=reboot: the board must boot through
# normally, not reboot into another first-run pass.
extra = 'systemd.run=/boot/firmware/firstrun.sh'
line = io.open(p, encoding='utf-8', newline='').read().strip('\n')
if not line.endswith(' '):
    line += ' '
io.open(p, 'w', encoding='utf-8', newline='').write(line + extra + '\n')
ADDRUN
    log "cmdline.txt: will run firstrun.sh on first boot"
  fi
else
  log "no Wi-Fi credentials given (XPENG_WIFI_SSID / XPENG_WIFI_PASSWORD) - skipped"
fi

# --- keep the screen awake, and print the wireless state on it ----------
if [ "${XPENG_CONSOLE_DIAG:-0}" = "1" ]; then
  # hdmi_safe forces a conservative mode and keeps the output on even when the
  # display handshake is flaky, which is what "the screen went blank" usually
  # means on a Zero. Remove this line once the console is no longer needed.
  if ! grep -q '^hdmi_safe=1' "$BOOT/config.txt" 2>/dev/null; then
    {
      echo ''
      echo '# XPENGUSB diagnostics: conservative HDMI mode, so the console stays on.'
      echo '[all]'
      echo 'hdmi_safe=1'
      echo 'hdmi_force_hotplug=1'
    } >> "$BOOT/config.txt"
    log "config.txt: hdmi_safe=1 + hdmi_force_hotplug=1"
  fi
  if ! grep -q 'consoleblank=' "$CMDLINE" 2>/dev/null; then
    python3 - "$CMDLINE" <<'ADDBLANK'
import io, sys
p = sys.argv[1]
line = io.open(p, encoding='utf-8', newline='').read().strip('\n')
if not line.endswith(' '):
    line += ' '
io.open(p, 'w', encoding='utf-8', newline='').write(line + 'consoleblank=0\n')
ADDBLANK
    log "cmdline.txt: consoleblank=0 (screen stays on)"
  fi

  cat > "$BOOT/xpeng-diag.sh" <<'DIAG_EOF'
#!/bin/bash
# Print the wireless state to the console, so a screen with no keyboard still
# says what the radio can see:
#   sudo bash /boot/firmware/xpeng-diag.sh      (or /boot/xpeng-diag.sh)
OUT=/dev/tty1
[ -w "$OUT" ] || OUT=/dev/console
{
  echo "===== XPENGUSB diagnostics $(date -Is) ====="
  echo "--- model: $(tr -d '\0' < /proc/device-tree/model 2>/dev/null)"
  echo "--- hostname: $(cat /etc/hostname 2>/dev/null)"
  echo "--- radio:"
  rfkill list wifi 2>/dev/null | sed 's/^/    /'
  iw reg get 2>/dev/null | head -4 | sed 's/^/    /'
  echo "--- interfaces:"
  ip -o link show 2>/dev/null | awk '{print "    " $2, $9}' | head -8
  echo "--- NetworkManager:"
  for _ in $(seq 1 30); do
    nmcli -t general status >/dev/null 2>&1 && break
    sleep 1
  done
  nmcli device status 2>/dev/null | sed 's/^/    /'
  echo "--- networks visible:"
  nmcli --wait 20 device wifi rescan >/dev/null 2>&1
  nmcli -f SSID,SIGNAL,CHAN,SECURITY device wifi list 2>/dev/null | sed 's/^/    /'
  echo "===== end ====="
} 2>&1 | tee -a "$OUT" "$BOOT/xpeng-diag.log"
DIAG_EOF
  chmod 755 "$BOOT/xpeng-diag.sh"
  log "wrote xpeng-diag.sh to the boot partition"
fi

echo
log "card is ready. Next:"
log "  1. eject, put the card in the board, plug the middle micro-USB into the Mac"
log "  2. the board appears as a USB network device; ssh $PI_USER@raspberrypi.local"
log "  3. configure Wi-Fi there: nmcli device wifi connect '<ssid>' password '<pw>'"
