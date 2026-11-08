#!/bin/bash -eu
#
# xpeng-loop.sh - the XPENG supervisor: two lanes, two cadences, one idle gate.
#
# This is the XPENG counterpart of run/archiveloop and is what archiveloop
# execs when XPENG_MODE=true. archiveloop itself stays untouched.
#
# It deliberately does nothing clever: wake up, ask each lane whether its
# network policy is satisfied, run it if the cadence says so, and mark whether
# deletion is safe. Sync decisions belong to xpeng-archive.sh.
#
# Idle detection: on a board that emulates the drive, "idle" means the car
# stopped writing, which run/waitforidle already answers. When there is no
# gadget (development on a plain directory, as on the Orange Pi 3 LTS) there is
# nobody to disturb, so it is always idle.

CONF_FILE="${XPENG_CONF:-/root/teslausb_setup_variables.conf}"
# shellcheck disable=SC1090  # the config location is a runtime choice
if [ -r "$CONF_FILE" ]; then . "$CONF_FILE"; fi

HERE="$(cd "$(dirname "$0")" && pwd)"
ARCHIVE="$HERE/xpeng-archive.sh"

EMERGENCY_INTERVAL="${XPENG_EMERGENCY_INTERVAL:-120}"
NORMAL_INTERVAL="${XPENG_NORMAL_INTERVAL:-600}"
TICK="${XPENG_TICK:-15}"
WAITFORIDLE="${XPENG_WAITFORIDLE:-/root/bin/waitforidle}"
REQUIRE_IDLE_FOR_DELETE="${XPENG_REQUIRE_IDLE_FOR_DELETE:-0}"
IDLE_CHECK_INTERVAL="${XPENG_IDLE_CHECK_INTERVAL:-300}"
RUN_ONCE="${XPENG_RUN_ONCE:-0}"

function log {
  echo "$(date '+%Y-%m-%d %H:%M:%S') xpeng-loop: $*" >&2
}

# waitforidle can take up to 90 s, so its answer is cached: the point of the
# check is "may I delete", and that does not change every two minutes.
idle_ok_cached=0
idle_checked_at=0

function car_is_idle {
  local now="$1"
  if [ "$REQUIRE_IDLE_FOR_DELETE" != "1" ]; then
    # No gadget to protect, or deletion explicitly allowed without a check.
    return 0
  fi
  if [ "$idle_checked_at" -gt 0 ] && [ $(( now - idle_checked_at )) -lt "$IDLE_CHECK_INTERVAL" ]; then
    return "$idle_ok_cached"
  fi
  idle_checked_at="$now"
  idle_ok_cached=1
  if [ -x "$WAITFORIDLE" ]; then
    "$WAITFORIDLE" > /dev/null 2>&1 || idle_ok_cached=0
  else
    log "idle check requested but $WAITFORIDLE is missing - assuming busy"
    idle_ok_cached=0
  fi
  return "$idle_ok_cached"
}

function run_lane {
  local lane="$1" now="$2" idle=0
  if car_is_idle "$now"; then
    idle=1
  fi
  XPENG_IDLE_OK="$idle" bash "$ARCHIVE" "$lane" || log "$lane lane exited $?"
}

emergency_next=0
normal_next=0

log "starting (emergency every ${EMERGENCY_INTERVAL}s, normal every ${NORMAL_INTERVAL}s, tick ${TICK}s)"

while true; do
  now="$(date +%s)"

  if [ "$now" -ge "$emergency_next" ]; then
    run_lane emergency "$now"
    emergency_next=$(( $(date +%s) + EMERGENCY_INTERVAL ))
  fi

  if [ "$now" -ge "$normal_next" ]; then
    run_lane normal "$now"
    normal_next=$(( $(date +%s) + NORMAL_INTERVAL ))
  fi

  if [ "$RUN_ONCE" = "1" ]; then
    log "single pass done (XPENG_RUN_ONCE=1)"
    exit 0
  fi

  sleep "$TICK"
done
