#!/bin/bash
# install.sh - put the settings page on the Pi and retire nginx there.
#
#   sudo bash install.sh
#
# Why retire nginx: it was serving the *archive*, which now lives on the Frigate
# host. On a 430 MB Zero W a web server that serves video is the wrong job - it
# wedged the board once already. The settings page is stdlib Python and does not
# touch the archive at all.
set -eu
[ "$(id -u)" -eq 0 ] || { echo "STOP: run as root (sudo)" >&2; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
ENV=/etc/xpeng-settings.env
CONF=/root/teslausb_setup_variables.conf

echo "== installing the app"
install -m 755 "$HERE/xpeng-settings" /usr/local/bin/xpeng-settings

if [ ! -e "$ENV" ]; then
  PASS="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)"
  umask 077
  printf 'XPENG_SETTINGS_USER=xpeng\nXPENG_SETTINGS_PASS=%s\n' "$PASS" > "$ENV"
  chmod 600 "$ENV"
  echo "== created $ENV (user xpeng, password below)"
  echo "   password: $PASS"
else
  echo "== keeping existing $ENV"
fi

echo "== systemd unit"
cat > /etc/systemd/system/xpeng-settings.service <<'UNIT'
[Unit]
Description=XPENG archiver settings page
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/xpeng-settings.env
Environment=XPENG_SETTINGS_CONF=/root/teslausb_setup_variables.conf
Environment=XPENG_SETTINGS_PORT=8081
Environment=XPENG_SETTINGS_BIND=0.0.0.0
ExecStart=/usr/local/bin/xpeng-settings
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

echo "== retiring nginx on the Pi (the archive viewer moved off this board)"
# NOT `systemctl stop`: nginx workers can be blocked in a CIFS read on /mnt/archive,
# and a graceful stop then waits for them indefinitely - it has wedged this board
# before. Disable the unit, then kill outright.
systemctl disable nginx 2>/dev/null || true
pkill -9 -x nginx 2>/dev/null || true
sleep 1
systemctl reset-failed nginx 2>/dev/null || true
rm -f /etc/nginx/sites-enabled/xpeng
if command -v apt-get > /dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq nginx-light nginx-common >/dev/null 2>&1 || true
fi
rm -rf /var/lib/xpeng-web
systemctl disable --now xpeng-web-index.timer 2>/dev/null || true
rm -f /etc/systemd/system/xpeng-web-index.service /etc/systemd/system/xpeng-web-index.timer

systemctl daemon-reload
systemctl enable --now xpeng-settings.service >/dev/null
sleep 2
echo "== status: $(systemctl is-active xpeng-settings.service)"
ss -ltn 2>/dev/null | grep 8081 | sed 's/^/   listening: /'
[ -f "$CONF" ] || echo "   NOTE: $CONF does not exist yet; the form will create it on first save"
echo
echo "Settings page: http://$(hostname -I | awk '{print $1}'):8081/   (user xpeng, password in $ENV)"
