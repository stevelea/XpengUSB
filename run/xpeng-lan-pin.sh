#!/bin/bash -eu
#
# xpeng-lan-pin.sh - keep the archive host on the LAN when we are on the LAN.
#
# Why this exists: with Tailscale `--accept-routes` on, an approved subnet route
# for 192.168.1.0/24 is installed into table 52, and Tailscale's ip rule makes
# table 52 win over the main table. At home that sends NAS traffic through the
# tailnet and back down the same LAN - a hairpin through whichever node
# advertises the route. Measured on a Pi Zero W: reaching the NAS took >2 s per
# connect instead of milliseconds, and SMB pays that per file.
#
# So: when this box has an address on the archive host's subnet, put a /32 for
# the host back on the local gateway inside table 52. When it does not (driving,
# on a hotspot), remove it and let the tailnet route do its job.
#
# Called by a timer; also safe to run by hand. Idempotent.
#
# Environment:
#   XPENG_ARCHIVE_HOST   default 192.168.1.235
#   XPENG_LAN_IFACE      default wlan0
#   XPENG_LAN_GATEWAY    default 192.168.1.1
#   XPENG_LAN_PIN_FORCE  set to "lan" or "away" to force a branch (testing)

CONF_FILE="${XPENG_CONF:-/root/teslausb_setup_variables.conf}"
# shellcheck disable=SC1090  # the config location is a runtime choice
if [ -r "$CONF_FILE" ]; then . "$CONF_FILE"; fi

HOST="${XPENG_ARCHIVE_HOST:-192.168.1.235}"
IFACE="${XPENG_LAN_IFACE:-wlan0}"
GATEWAY="${XPENG_LAN_GATEWAY:-192.168.1.1}"
TABLE=52
FORCE="${XPENG_LAN_PIN_FORCE:-}"

function log { echo "$(date '+%Y-%m-%d %H:%M:%S') lan-pin: $*"; }

function on_lan {
  [ "$FORCE" = "lan" ] && return 0
  [ "$FORCE" = "away" ] && return 1
  # An address on the same /24 as the host, on the expected interface.
  local want
  want="$(printf '%s' "$HOST" | cut -d. -f1-3)"
  ip -4 -o addr show dev "$IFACE" 2>/dev/null | grep -q "inet ${want}\."
}

function route_present {
  ip route show table "$TABLE" 2>/dev/null | grep -q "^${HOST} via ${GATEWAY}"
}

if ! command -v ip > /dev/null 2>&1; then
  log "no ip command - nothing to do"
  exit 0
fi

if on_lan; then
  if route_present; then
    exit 0
  fi
  if ip route replace "${HOST}/32" via "$GATEWAY" dev "$IFACE" table "$TABLE" 2>/dev/null
  then
    log "pinned $HOST to the LAN via $GATEWAY ($IFACE)"
  else
    log "could not pin $HOST to the LAN"
    exit 1
  fi
else
  if route_present; then
    ip route del "${HOST}/32" table "$TABLE" 2>/dev/null || true
    log "removed the LAN pin for $HOST - the tailnet route takes over"
  fi
fi
