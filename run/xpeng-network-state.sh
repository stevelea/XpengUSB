#!/bin/bash -eu
#
# xpeng-network-state.sh - which network are we on, for the XPENG sync gates.
#
# Prints exactly one word on stdout and exits 0:
#
#   home   on a network that counts as home (see below)
#   wifi   associated to some Wi-Fi that is not a home network
#   other  online, but not over Wi-Fi (USB tether, 4G modem, ...)
#   none   no default route
#
# "home" means, in this order:
#   1. the current SSID matches XPENG_HOME_SSID (comma separated list)
#   2. no SSID is associated (or none configured) and XPENG_HOME_HOST answers
#      on XPENG_HOME_PORT - the wired-at-home case
#
# Rule 1 is the reliable one. Rules 2 and 3 can be fooled when the archive host
# is also reachable over Tailscale from somewhere else - if that matters, set
# XPENG_HOME_SSID.
#
# Test hooks: XPENG_FORCE_STATE short-circuits everything.

CONF_FILE="${XPENG_CONF:-/root/teslausb_setup_variables.conf}"
# shellcheck disable=SC1090  # the config location is a runtime choice
if [ -r "$CONF_FILE" ]; then . "$CONF_FILE"; fi

if [ -n "${XPENG_FORCE_STATE:-}" ]; then
  printf '%s\n' "$XPENG_FORCE_STATE"
  exit 0
fi

HOME_SSIDS="${XPENG_HOME_SSID:-}"
HOME_HOST="${XPENG_HOME_HOST:-}"
HOME_PORT="${XPENG_HOME_PORT:-445}"
PROBE_SECONDS="${XPENG_HOME_PROBE_SECONDS:-3}"

function default_interface {
  # -n so macOS and Linux both work (ip route show default / netstat -rn)
  if command -v ip > /dev/null 2>&1; then
    ip route show default 2>/dev/null \
      | awk '!/^default/ {next} {for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}'
    return 0
  fi
  if command -v route > /dev/null 2>&1; then
    route -n get default 2>/dev/null \
      | awk '/interface:/ {print $2; exit}'
    return 0
  fi
  echo ""
}

function current_ssid {
  if command -v nmcli > /dev/null 2>&1; then
    nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null \
      | awk -F: '$1=="yes" && $2!="" {print $2; exit}'
    return 0
  fi
  if command -v iwgetid > /dev/null 2>&1; then
    iwgetid -r 2>/dev/null || true
    return 0
  fi
  if command -v iwconfig > /dev/null 2>&1; then
    iwconfig 2>/dev/null | awk -F'"' '/ESSID:/ {print $2; exit}'
    return 0
  fi
  if command -v networksetup > /dev/null 2>&1; then
    networksetup -getairportnetwork "${1:-en0}" 2>/dev/null \
      | sed -n 's/^Current Wi-Fi Network: //p'
    return 0
  fi
  echo ""
}

function ssid_matches_home {
  local ssid="$1" want
  [ -n "$HOME_SSIDS" ] || return 1
  [ -n "$ssid" ] || return 1
  local IFS=,
  for want in $HOME_SSIDS; do
    want="${want# }"; want="${want% }"
    [ -n "$want" ] || continue
    [ "$ssid" = "$want" ] && return 0
  done
  return 1
}

function host_answers {
  [ -n "$HOME_HOST" ] || return 1
  if command -v nc > /dev/null 2>&1; then
    nc -z -w "$PROBE_SECONDS" "$HOME_HOST" "$HOME_PORT" > /dev/null 2>&1 && return 0
  fi
  if command -v timeout > /dev/null 2>&1; then
    timeout "$PROBE_SECONDS" bash -c ": > /dev/tcp/$HOME_HOST/$HOME_PORT" > /dev/null 2>&1 && return 0
  fi
  return 1
}

IFACE="$(default_interface)"

if [ -z "$IFACE" ]; then
  printf 'none\n'
  exit 0
fi

SSID="$(current_ssid "$IFACE" || true)"

if ssid_matches_home "$SSID"; then
  printf 'home\n'
  exit 0
fi

if [ -n "$SSID" ]; then
  printf 'wifi\n'
  exit 0
fi

if host_answers; then
  printf 'home\n'
  exit 0
fi

printf 'other\n'
