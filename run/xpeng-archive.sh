#!/bin/bash -eu
#
# xpeng-archive.sh - archive one lane of XPENG dashcam clips, then delete what
# was provably copied.
#
#   xpeng-archive.sh emergency|normal
#
# The two lanes differ only in which folder they read, which policy gates them
# and how often they run. Everything else - the scan, the copy, the
# verification, the deletion - is the same code, on purpose.
#
# Deletion rule (taken from XpengDVRCopy/deploy/copyusb.sh, which has been in
# daily use for months): a clip leaves the car's drive only when the archive
# copy exists with the SAME byte size and a non-zero size. A clip that fails
# that test stays where it is and is reported, never silently dropped.
#
# Deletion additionally requires the caller to say it is safe:
#   XPENG_IDLE_OK=1   the car is not writing (or there is no car, as in tests)
# Without it the upload still happens and the delete is deferred - which is the
# behaviour we want while driving.
#
# Everything is driven by environment variables so this can be exercised on a
# plain directory. See tests/xpeng-test.sh.

CONF_FILE="${XPENG_CONF:-/root/teslausb_setup_variables.conf}"
# shellcheck disable=SC1090  # the config location is a runtime choice
if [ -r "$CONF_FILE" ]; then . "$CONF_FILE"; fi

LANE="${1:-}"
case "$LANE" in
  emergency|normal) ;;
  *)
    echo "usage: $0 <emergency|normal>" >&2
    exit 2
    ;;
esac

SRC_ROOT="${XPENG_SOURCE_ROOT:-${CAM_MOUNT:-/mnt/cam}}"
ARCHIVE_ROOT="${XPENG_ARCHIVE_MOUNT:-/mnt/archive}"
# Where inside the archive mount the clips go. This is the dashcam viewer's tree:
# the viewer indexes <root>/XP_DCIM and <root>/XP_EMER_DCIM, and classifies a clip by
# the folder it came from, so the archiver must land there and nowhere else.
SUBDIR="${XPENG_ARCHIVE_SUBDIR:-xpg006camera/xpengusb}"
EMERGENCY_DIR="${XPENG_EMERGENCY_DIR:-XP_EMER_DCIM}"
# Extra folders to treat as the emergency lane, space separated. XPENG has been
# seen writing only XP_DCIM and XP_EMER_DCIM, but XGuard (the parking guard /
# sentry mode) has never produced a file we could inspect, so if it uses its own
# folder it can be added here without touching the code.
EXTRA_DIRS="${XPENG_EXTRA_DIRS:-}"
NORMAL_DIR="${XPENG_NORMAL_DIR:-XP_DCIM}"
VIEWS="${XPENG_VIEWS:-front front_and_360}"
MIN_AGE="${XPENG_MIN_AGE:-120}"
# FAT has no timezone: the car stamps files in LOCAL time, and the vfat driver
# converts them using the SYSTEM timezone when it reads them. So the correct fix
# is to set the Pi's timezone to the car's (Australia/Sydney here) - verified on
# hardware: with the Pi on UTC, every fresh clip appeared 11 hours in the future
# and the settle test rejected all of them; after `timedatectl set-timezone` the
# same files read correctly with no other change.
#
# This knob exists only for the case where the system timezone cannot be set: it
# subtracts N minutes from each file's mtime before the settle test. Leave it 0
# when the timezone is right, or the timestamps get corrected twice.
MTIME_SKEW="${XPENG_MTIME_SKEW_MINUTES:-0}"
INDEX="${XPENG_INDEX_FILE:-/mutable/xpeng/archive-index.txt}"
DELETE_AFTER_UPLOAD="${XPENG_DELETE_AFTER_UPLOAD:-1}"
# How many days of archive to keep. 0 (the default) means keep everything.
# Only applies to folders this archiver created - they are named
# YYYY-MM-DD_HHMMSS - so nothing else in the share can be touched, and _logs is
# never a match.
RETENTION_DAYS="${XPENG_RETENTION_DAYS:-0}"

# How long a clip stays on the car's drive after it has been archived.
#   0  = delete as soon as it is verified (the old behaviour)
#   14 = keep a two-week window on the drive, deleting only clips that are
#        already in the archive index and have aged past the window
# A clip is NEVER deleted on the strength of this setting alone: it must also be
# present in the archive index, which is only written after a size-verified copy.
DRIVE_RETENTION_DAYS="${XPENG_DRIVE_RETENTION_DAYS:-14}"
IDLE_OK="${XPENG_IDLE_OK:-0}"
RSYNC="${XPENG_RSYNC:-rsync}"

# Optional: after a clip is verified in the archive, also push it somewhere else.
# OFF by default and deliberately so: pushing a second copy costs bandwidth on a
# link that is the bottleneck (a Zero W manages ~1.2-1.5 MB/s), so the preferred
# arrangement is for consumers such as Frigate to read the archive itself. Kept
# for the case where a consumer genuinely cannot reach the NAS.
PUSH_TARGET="${XPENG_PUSH_TARGET:-}"
PUSH_SSH="${XPENG_PUSH_SSH:-ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new}"

if [ "$LANE" = "emergency" ]; then
  LANE_DIR="$EMERGENCY_DIR"
  POLICY="${XPENG_EMERGENCY_SYNC:-always}"
else
  LANE_DIR="$NORMAL_DIR"
  POLICY="${XPENG_NORMAL_SYNC:-home}"
fi

STATE_SCRIPT="${XPENG_NETWORK_STATE_SCRIPT:-$(dirname "$0")/xpeng-network-state.sh}"

function log {
  echo "$(date '+%Y-%m-%d %H:%M:%S') xpeng[$LANE]: $*" >&2
}

function size_of {
  stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1" 2>/dev/null || echo 0
}

function mtime_of {
  stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null || echo 0
}

function network_state {
  if [ -r "$STATE_SCRIPT" ]; then
    bash "$STATE_SCRIPT" 2>/dev/null || echo none
  else
    echo none
  fi
}

function policy_allows {
  case "$POLICY" in
    always) [ "$1" != "none" ] ;;
    home)   [ "$1" = "home" ] ;;
    off)    false ;;
    *)
      log "unknown policy '$POLICY' - refusing to sync"
      false
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Gate
# ---------------------------------------------------------------------------
STATE="$(network_state)"
if ! policy_allows "$STATE"; then
  log "network=$STATE policy=$POLICY - nothing to do"
  exit 0
fi
log "network=$STATE policy=$POLICY - syncing"

# One lane can own several folders (emergency = XP_EMER_DCIM plus anything in
# XPENG_EXTRA_DIRS).
LANE_DIRS="$LANE_DIR"
if [ "$LANE" = "emergency" ] && [ -n "$EXTRA_DIRS" ]; then
  LANE_DIRS="$LANE_DIR $EXTRA_DIRS"
fi

FOUND_ANY=0
for d in $LANE_DIRS; do
  [ -d "$SRC_ROOT/$d" ] && FOUND_ANY=1
done
if [ "$FOUND_ANY" -eq 0 ]; then
  log "none of [$LANE_DIRS] on this drive - nothing to do"
  exit 0
fi

# Anything that looks like a clip folder but is not one we read gets reported,
# once per run. This is how a new folder (XGuard?) announces itself instead of
# being ignored in silence.
for d in "$SRC_ROOT"/*/; do
  [ -d "$d" ] || continue
  name="$(basename "$d")"
  case " $LANE_DIRS $NORMAL_DIR " in
    *" $name "*) continue ;;
  esac
  n="$(find "$d" -maxdepth 2 -type f \( -name '*.mp4' -o -name '*.MP4' \) 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${n:-0}" -gt 0 ]; then
    log "NOTE: folder '$name' holds $n clip(s) but is not one this archiver reads - add it to XPENG_EXTRA_DIRS to archive it"
  fi
done

if [ ! -d "$ARCHIVE_ROOT" ]; then
  log "archive $ARCHIVE_ROOT is not mounted - refusing to touch the drive"
  exit 1
fi

mkdir -p "$(dirname "$INDEX")" 2>/dev/null || true

# Views live in the file name, which is where XPENG puts them:
#   DVR_20260928101115168_front.mp4
#   EMER_[E_..._E]20260923140931498_front_and_360.mp4
function view_wanted {
  local base="$1" view
  for view in $VIEWS; do
    case "$base" in
      *"_$view.mp4"|*"_$view.MP4") return 0 ;;
    esac
  done
  return 1
}

TMPDIR_RUN="$(mktemp -d "${TMPDIR:-/tmp}/xpeng.XXXXXX")"
trap 'rm -rf "$TMPDIR_RUN"' EXIT

# ---------------------------------------------------------------------------
# Candidates: settled clips that are not already in the index.
#
# The settle window (XPENG_MIN_AGE) is the only protection against copying a
# clip the car is still appending to. It is deliberately generous: a clip that
# is one minute long is complete long before it is two minutes old.
# ---------------------------------------------------------------------------
NOW="$(date +%s)"
CUTOFF=$(( NOW - MIN_AGE ))

ONCARD="$TMPDIR_RUN/oncard"
: > "$ONCARD"

scanned=0
skipped_view=0
skipped_unsettled=0

# One pass per folder the lane owns, so each candidate can be tagged with the
# folder it came from (the archive path and the index both depend on it).
for d in $LANE_DIRS; do
  [ -d "$SRC_ROOT/$d" ] || continue
  while IFS= read -r -d '' path; do
    base="$(basename "$path")"
    scanned=$(( scanned + 1 ))

    if ! view_wanted "$base"; then
      skipped_view=$(( skipped_view + 1 ))
      continue
    fi

    # Correct the car's local-time stamping before the settle test.
    if [ "$(( $(mtime_of "$path") - MTIME_SKEW * 60 ))" -gt "$CUTOFF" ]; then
      skipped_unsettled=$(( skipped_unsettled + 1 ))
      continue
    fi

    if [ "$(size_of "$path")" -le 0 ]; then
      skipped_unsettled=$(( skipped_unsettled + 1 ))
      continue
    fi

    printf '%s/%s\n' "$d" "$base" >> "$ONCARD"
  done < <(find "$SRC_ROOT/$d" -type f \( -name '*.mp4' -o -name '*.MP4' \) -print0 2>/dev/null)
done

CAND="$TMPDIR_RUN/candidates"
if [ -s "$ONCARD" ]; then
  LC_ALL=C sort -u "$ONCARD" > "$TMPDIR_RUN/oncard.sorted"
  if [ -r "$INDEX" ]; then
    LC_ALL=C sort -u "$INDEX" > "$TMPDIR_RUN/index.sorted"
    LC_ALL=C comm -23 "$TMPDIR_RUN/oncard.sorted" "$TMPDIR_RUN/index.sorted" > "$CAND"
  else
    cp "$TMPDIR_RUN/oncard.sorted" "$CAND"
  fi
else
  : > "$CAND"
fi

TOTAL="$(wc -l < "$CAND" | tr -d ' ')"
log "scanned $scanned file(s): $TOTAL new, $skipped_unsettled not settled/empty, $skipped_view other view"

# Nothing new to copy is NOT the same as nothing to do: the retention sweep
# below still has to run, or clips past the window would only ever be deleted on
# a day when a new clip happened to arrive.
SKIP_COPY=0
if [ "$TOTAL" -eq 0 ]; then
  log "no new clip(s)"
  SKIP_COPY=1
fi

ok=0
bad=0
VERIFIED="$TMPDIR_RUN/verified"
: > "$VERIFIED"
if [ "$SKIP_COPY" -eq 0 ]; then
# ---------------------------------------------------------------------------
# Copy into the SAME layout the car uses on the stick: <subdir>/XP_DCIM/<clip>
# and <subdir>/XP_EMER_DCIM/<clip>.
#
# A dated folder per run was tidier for humans but wrong for the consumer that
# matters: the dashcam viewer indexes <root>/XP_DCIM and <root>/XP_EMER_DCIM and
# labels clips by which of the two they came from. A per-run folder hid both the
# folder name and the lane, so emergency clips were filed as ordinary ones.
# Filenames are already unique (they carry the car's timestamp), so a flat
# layout loses nothing.
# ---------------------------------------------------------------------------
DEST="$ARCHIVE_ROOT/$SUBDIR"
mkdir -p "$DEST"

log "copying $TOTAL clip(s) to $DEST"

if ! "$RSYNC" -rt --no-perms --no-owner --no-group --no-specials --no-devices \
      --partial --relative --files-from="$CAND" "$SRC_ROOT/" "$DEST/" \
      > "$TMPDIR_RUN/rsync.log" 2>&1
then
  log "rsync failed - nothing will be deleted"
  sed 's/^/  rsync: /' "$TMPDIR_RUN/rsync.log" >&2 || true
  exit 1
fi

# ---------------------------------------------------------------------------
# Verify, then (maybe) delete. Never the other way round.
# ---------------------------------------------------------------------------
while IFS= read -r rel; do
  src="$SRC_ROOT/$rel"
  dst="$DEST/$rel"
  ssize="$(size_of "$src")"
  if [ ! -f "$dst" ]; then
    log "MISSING in archive: $rel"
    bad=$(( bad + 1 ))
    continue
  fi
  dsize="$(size_of "$dst")"
  if [ "$ssize" -ne "$dsize" ] || [ "$dsize" -le 0 ]; then
    log "SIZE MISMATCH: $rel (source $ssize, archive $dsize)"
    bad=$(( bad + 1 ))
    continue
  fi
  printf '%s\n' "$rel" >> "$VERIFIED"
done < "$CAND"
fi

ok="$(wc -l < "$VERIFIED" | tr -d ' ')"
log "verified $ok of $TOTAL clip(s)"

if [ "$ok" -gt 0 ]; then
  cat "$VERIFIED" >> "$INDEX"
  LC_ALL=C sort -u "$INDEX" -o "$INDEX"
fi

# --- optional push (best effort, never fatal) --------------------------
if [ -n "$PUSH_TARGET" ] && [ "$ok" -gt 0 ]; then
  log "pushing $ok clip(s) to $PUSH_TARGET"
  if "$RSYNC" -rt --no-perms --no-owner --no-group --relative \
        -e "$PUSH_SSH" --files-from="$VERIFIED" "$SRC_ROOT/" "$PUSH_TARGET/" \
        > "$TMPDIR_RUN/push.log" 2>&1
  then
    log "push ok"
  else
    log "push failed (continuing): $(tail -1 "$TMPDIR_RUN/push.log" 2>/dev/null)"
  fi
fi

deleted=0
kept=$ok
if [ "$ok" -eq 0 ] && [ ! -s "$TMPDIR_RUN/oncard.sorted" ]; then
  :
elif [ "$DELETE_AFTER_UPLOAD" != "1" ]; then
  log "XPENG_DELETE_AFTER_UPLOAD=$DELETE_AFTER_UPLOAD - keeping clips on the drive"
elif [ "$IDLE_OK" != "1" ]; then
  log "not idle - keeping clips on the drive for now"
else
  DEL_LIST="$TMPDIR_RUN/deletable"
  : > "$DEL_LIST"

  if [ "$DRIVE_RETENTION_DAYS" -eq 0 ]; then
    # delete nothing but what this run verified
    cp "$VERIFIED" "$DEL_LIST"
  else
    # Delete only clips that are BOTH in the archive index (so a size-verified
    # copy exists) AND older than the window. Intersecting with the index is what
    # makes this safe: a clip that failed to copy, or was never scanned, cannot
    # be reached by this path.
    cutoff=$(( $(date +%s) - DRIVE_RETENTION_DAYS * 86400 ))
    if [ -s "$TMPDIR_RUN/index.sorted" ] && [ -s "$TMPDIR_RUN/oncard.sorted" ]; then
      LC_ALL=C comm -12 "$TMPDIR_RUN/oncard.sorted" "$TMPDIR_RUN/index.sorted" > "$TMPDIR_RUN/archived_oncard"
      while IFS= read -r rel; do
        src="$SRC_ROOT/$rel"
        [ -f "$src" ] || continue
        if [ "$(mtime_of "$src")" -le "$cutoff" ]; then
          printf '%s\n' "$rel" >> "$DEL_LIST"
        fi
      done < "$TMPDIR_RUN/archived_oncard"
    fi
  fi

  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if rm -f "$SRC_ROOT/$rel"; then
      deleted=$(( deleted + 1 ))
    else
      log "could not delete $rel"
    fi
  done < "$DEL_LIST"
  kept=$(( $(wc -l < "$TMPDIR_RUN/oncard.sorted" | tr -d ' ') - deleted ))
  [ "$kept" -lt 0 ] && kept=0
  if [ "$DRIVE_RETENTION_DAYS" -gt 0 ]; then
    log "deleted $deleted clip(s) archived and older than ${DRIVE_RETENTION_DAYS} days; $kept still within the window"
  else
    log "deleted $deleted of $ok archived clip(s) from the drive"
  fi
fi

# --- retention: drop archive folders older than N days --------------------
# Deliberately after the copy and the index update, so a failed or interrupted run
# never prunes what it had not yet archived.
if [ "$RETENTION_DAYS" -gt 0 ] && [ -d "$ARCHIVE_ROOT/$SUBDIR" ]; then
  # Now that clips live in a flat XP_DCIM/XP_EMER_DCIM layout, retention works on
  # files, by mtime - which rsync preserves from the car, so a clip's age is its
  # recording date, not when it happened to be uploaded.
  cutoff=$(( $(date +%s) - RETENTION_DAYS * 86400 ))
  pruned=0
  for d in "$ARCHIVE_ROOT/$SUBDIR"/*/; do
    [ -d "$d" ] || continue
    case "$(basename "$d")" in
      XP_*DCIM) ;;
      *) continue ;;                  # never prune anything else in the share
    esac
    while IFS= read -r -d '' f; do
      if [ "$(mtime_of "$f")" -lt "$cutoff" ]; then
        rm -f "$f" && pruned=$(( pruned + 1 ))
      fi
    done < <(find "$d" -type f \( -name '*.mp4' -o -name '*.MP4' \) -print0 2>/dev/null)
  done
  [ "$pruned" -gt 0 ] && log "retention: pruned $pruned clip(s) older than ${RETENTION_DAYS} days"
fi

# An empty dated folder is noise in the archive.
if [ -d "$DEST" ] && [ -z "$(find "$DEST" -type f -print -quit 2>/dev/null)" ]; then
  rm -rf "$DEST"
  log "nothing actually landed - removed $DEST"
fi

if [ "$bad" -gt 0 ]; then
  log "finished with $bad unverified clip(s) left on the drive"
  exit 1
fi

log "done: $ok archived, $deleted deleted, $kept kept"
exit 0
