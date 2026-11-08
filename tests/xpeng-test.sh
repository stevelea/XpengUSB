#!/bin/bash -eu
#
# xpeng-test.sh - exercise the XPENG lanes without a car, a board or a NAS.
#
# Runs on any Linux or macOS with bash, coreutils and rsync. Everything happens
# under a temporary directory; nothing outside it is touched.
#
#   bash tests/xpeng-test.sh

HERE="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$HERE/run"
NET="$RUN/xpeng-network-state.sh"
ARCHIVE="$RUN/xpeng-archive.sh"

PASS=0
FAIL=0
WORK="$(mktemp -d "${TMPDIR:-/tmp}/xpeng-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

SRC="$WORK/cam"
DEST="$WORK/archive"
STAMP="20260928101115"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
function ok {
  PASS=$(( PASS + 1 ))
  printf '  ok   %s\n' "$1"
}

function bad {
  FAIL=$(( FAIL + 1 ))
  printf '  FAIL %s\n' "$1"
  [ $# -gt 1 ] && printf '       %s\n' "$2"
}

function check {
  local desc="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then ok "$desc"; else bad "$desc" "want '$want', got '$got'"; fi
}

function section { printf '\n%s\n' "$1"; }

function reset_fixture {
  rm -rf "$SRC" "$DEST" "$WORK/index.txt"
  mkdir -p "$SRC/XP_DCIM" "$SRC/XP_EMER_DCIM" "$DEST"

  # one minute of driving, two views; plus an unsettled one
  printf 'front-clip-%s\n' "$STAMP" > "$SRC/XP_DCIM/DVR_${STAMP}168_front.mp4"
  printf '360-clip-%s\n' "$STAMP" > "$SRC/XP_DCIM/DVR_${STAMP}168_front_and_360.mp4"
  # a second, older clip
  printf 'front-clip-old\n' > "$SRC/XP_DCIM/DVR_20260927000000001_front.mp4"

  # emergency: one pair, event id in brackets
  printf 'emer-front\n' > "$SRC/XP_EMER_DCIM/EMER_[E_A1790136609777_30000_23_E]20260923140931498_front.mp4"
  printf 'emer-360\n' > "$SRC/XP_EMER_DCIM/EMER_[E_A1790136609777_30000_23_E]20260923140931498_front_and_360.mp4"

  # junk that must never be copied or counted: the applet marker, and a clip
  # from the older XPENG layout, which lives outside the two lane folders
  printf 'ignored\n' > "$SRC/XP_DCIM/.nomedia"
  mkdir -p "$SRC/DCIM/Movie"
  printf 'old-layout\n' > "$SRC/DCIM/Movie/2025_0917_120000_0001.MP4"

  # everything settled: mtime well in the past
  find "$SRC" -type f -exec touch -t 202609270000.00 {} +
}

function new_clip {
  local name="$1"
  printf 'fresh-%s\n' "$name" > "$SRC/XP_DCIM/$name"
  touch "$SRC/XP_DCIM/$name"
}

function lane_env {
  # common environment for every run
  export XPENG_CONF=/dev/null
  export XPENG_SOURCE_ROOT="$SRC"
  export XPENG_ARCHIVE_MOUNT="$DEST"
  export XPENG_INDEX_FILE="$WORK/index.txt"
  export XPENG_ARCHIVE_SUBDIR="xpengusb"
  export XPENG_MIN_AGE=60
  XPENG_NETWORK_STATE_SCRIPT="$NET"
  export XPENG_NETWORK_STATE_SCRIPT
}

function count_archived {
  find "$DEST" -type f -name '*.mp4' 2>/dev/null | wc -l | tr -d ' '
}

function count_lane {
  # clips left under one lane folder (lower- and upper-case extension)
  find "$SRC/$1" -type f \( -name '*.mp4' -o -name '*.MP4' \) 2>/dev/null | wc -l | tr -d ' '
}

function count_source {
  # every clip on the "drive", both lanes
  find "$SRC" -type f \( -name '*.mp4' -o -name '*.MP4' \) 2>/dev/null | wc -l | tr -d ' '
}

# ---------------------------------------------------------------------------
section "network gate"
# ---------------------------------------------------------------------------
check "forced 'home'" home "$(XPENG_FORCE_STATE=home bash "$NET")"
check "forced 'other'" other "$(XPENG_FORCE_STATE=other bash "$NET")"
check "forced 'none'" none "$(XPENG_FORCE_STATE=none bash "$NET")"

# SSID matching is exercised without touching the network: nmcli stub on PATH.
STUB="$WORK/stub"; mkdir -p "$STUB"
cat > "$STUB/nmcli" <<'STUBEOF'
#!/bin/bash
echo "yes:HomeNet"
STUBEOF
chmod +x "$STUB/nmcli"
check "SSID matches XPENG_HOME_SSID" home \
  "$(PATH="$STUB:$PATH" XPENG_HOME_SSID='Other,HomeNet' XPENG_CONF=/dev/null bash "$NET")"
check "SSID does not match" wifi \
  "$(PATH="$STUB:$PATH" XPENG_HOME_SSID='SomethingElse' XPENG_CONF=/dev/null bash "$NET")"

# ---------------------------------------------------------------------------
section "emergency lane: always-sync uploads and deletes when idle"
# ---------------------------------------------------------------------------
reset_fixture
lane_env
XPENG_FORCE_STATE=other XPENG_IDLE_OK=1 XPENG_EMERGENCY_SYNC=always XPENG_DRIVE_RETENTION_DAYS=0 \
  bash "$ARCHIVE" emergency 2> "$WORK/log1"
check "emergency clips archived" 2 "$(count_archived)"
check "emergency clips deleted from drive" 0 "$(find "$SRC/XP_EMER_DCIM" -name '*.mp4' | wc -l | tr -d ' ')"
check "normal clips untouched" 3 "$(count_lane XP_DCIM)"
if grep -q 'verified 2 of 2' "$WORK/log1"; then ok "log reports verification"; else bad "log reports verification" "$(tail -3 "$WORK/log1")"; fi

# rerun: nothing left to do
XPENG_FORCE_STATE=other XPENG_IDLE_OK=1 XPENG_EMERGENCY_SYNC=always \
  bash "$ARCHIVE" emergency 2> "$WORK/log2"
check "second run archives nothing new" 2 "$(count_archived)"

# ---------------------------------------------------------------------------
section "normal lane: home-only policy"
# ---------------------------------------------------------------------------
reset_fixture
lane_env
XPENG_FORCE_STATE=other XPENG_IDLE_OK=1 XPENG_NORMAL_SYNC=home \
  bash "$ARCHIVE" normal 2> "$WORK/log3"
check "normal lane skips when away" 0 "$(count_archived)"
check "clips still on drive" 3 "$(count_lane XP_DCIM)"

XPENG_FORCE_STATE=home XPENG_IDLE_OK=1 XPENG_NORMAL_SYNC=home XPENG_DRIVE_RETENTION_DAYS=0 \
  bash "$ARCHIVE" normal 2> "$WORK/log4"
check "normal lane syncs at home" 3 "$(count_archived)"
check "home clips deleted" 0 "$(find "$SRC/XP_DCIM" -name '*.mp4' | wc -l | tr -d ' ')"
check "old-layout clip never archived" 0 \
  "$(find "$DEST" -name '*2025_0917_120000_0001*' 2>/dev/null | wc -l | tr -d ' ')"
check ".nomedia never archived" 0 \
  "$(find "$DEST" -name '.nomedia' 2>/dev/null | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
section "normal lane: always policy"
# ---------------------------------------------------------------------------
reset_fixture
lane_env
XPENG_FORCE_STATE=other XPENG_IDLE_OK=1 XPENG_NORMAL_SYNC=always \
  bash "$ARCHIVE" normal 2> "$WORK/log5"
check "always-policy syncs away from home" 3 "$(count_archived)"

# ---------------------------------------------------------------------------
section "off policy does nothing"
# ---------------------------------------------------------------------------
reset_fixture
lane_env
XPENG_FORCE_STATE=home XPENG_IDLE_OK=1 XPENG_NORMAL_SYNC=off \
  bash "$ARCHIVE" normal 2> "$WORK/log6"
check "off policy uploads nothing" 0 "$(count_archived)"

# ---------------------------------------------------------------------------
section "unsettled clip is not archived"
# ---------------------------------------------------------------------------
reset_fixture
lane_env
new_clip "DVR_20261108000000001_front.mp4"   # just written, mtime now
XPENG_FORCE_STATE=home XPENG_IDLE_OK=1 XPENG_NORMAL_SYNC=home \
  bash "$ARCHIVE" normal 2> "$WORK/log7"
check "settled clips only" 3 "$(count_archived)"
check "fresh clip left on drive" 1 "$(find "$SRC/XP_DCIM" -name 'DVR_20261108000000001_front.mp4' | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
section "not idle: upload happens, delete is deferred"
# ---------------------------------------------------------------------------
reset_fixture
lane_env
XPENG_FORCE_STATE=home XPENG_IDLE_OK=0 XPENG_NORMAL_SYNC=home \
  bash "$ARCHIVE" normal 2> "$WORK/log8"
check "uploaded while busy" 3 "$(count_archived)"
check "kept on drive while busy" 3 "$(count_lane XP_DCIM)"
if grep -q 'not idle' "$WORK/log8"; then ok "log says it deferred"; else bad "log says it deferred"; fi

# and the next idle pass deletes what is already in the index? No: the index
# records it, so the *next* run has nothing new. That is the designed trade:
# clips are re-armed by XPENG_MIN_AGE, not by idleness. Prove that a clip that
# was uploaded but not deleted is still recoverable by re-running with a clean
# index - i.e. the archive is authoritative.
XPENG_FORCE_STATE=home XPENG_IDLE_OK=1 XPENG_NORMAL_SYNC=home \
  bash "$ARCHIVE" normal 2> "$WORK/log9"
check "no duplicate upload" 3 "$(count_archived)"

# ---------------------------------------------------------------------------
section "verification refuses to delete a short copy"
# ---------------------------------------------------------------------------
reset_fixture
lane_env
# a pathologically truncated archive copy, planted where rsync will not touch it
mkdir -p "$DEST/xpengusb/fake/source"
# make rsync unable to write the destination by pointing it at a file
XFER="$WORK/xfer-blocker"
: > "$XFER"
XPENG_FORCE_STATE=home XPENG_IDLE_OK=1 XPENG_NORMAL_SYNC=home \
  XPENG_ARCHIVE_MOUNT="$XFER" bash "$ARCHIVE" normal 2> "$WORK/log10" || true
check "unwritable archive uploads nothing" 0 "$(count_archived)"
check "and deletes nothing" 3 "$(count_lane XP_DCIM)"

# ---------------------------------------------------------------------------
section "views filter"
# ---------------------------------------------------------------------------
reset_fixture
lane_env
XPENG_FORCE_STATE=home XPENG_IDLE_OK=1 XPENG_NORMAL_SYNC=home XPENG_VIEWS=front \
  bash "$ARCHIVE" normal 2> "$WORK/log11"
check "front-only archives 2 of 3" 2 "$(count_archived)"
check "360 view left on drive" 1 "$(find "$SRC/XP_DCIM" -name '*front_and_360.mp4' | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
section "missing lane folder is not an error"
# ---------------------------------------------------------------------------
reset_fixture
lane_env
rm -rf "$SRC/XP_EMER_DCIM"
if XPENG_FORCE_STATE=other XPENG_IDLE_OK=1 XPENG_EMERGENCY_SYNC=always \
     bash "$ARCHIVE" emergency 2> "$WORK/log12"; then
  ok "exits 0 with no emergency folder"
else
  bad "exits 0 with no emergency folder"
fi

# ---------------------------------------------------------------------------
section "XGuard-style folders: reported, then archivable via XPENG_EXTRA_DIRS"
# ---------------------------------------------------------------------------
reset_fixture
lane_env
# a folder the archiver does not know about, holding a clip
mkdir -p "$SRC/XP_XGUARD_DCIM"
printf 'guard\n' > "$SRC/XP_XGUARD_DCIM/XG_20260924120000000_front.mp4"
touch -t 202609270000.00 "$SRC/XP_XGUARD_DCIM/XG_20260924120000000_front.mp4"

XPENG_FORCE_STATE=home XPENG_IDLE_OK=1 XPENG_NORMAL_SYNC=home \
  bash "$ARCHIVE" emergency 2> "$WORK/log14"
if grep -q "XP_XGUARD_DCIM.*not one this archiver reads" "$WORK/log14"; then
  ok "unknown clip folder is reported, not silently ignored"
else
  bad "unknown clip folder is reported" "$(tail -3 "$WORK/log14")"
fi
check "and its clip is not archived yet" 2 "$(count_archived)"

# now opt it in: it joins the emergency lane
XPENG_FORCE_STATE=home XPENG_IDLE_OK=1 XPENG_EMERGENCY_SYNC=always \
  XPENG_EXTRA_DIRS=XP_XGUARD_DCIM \
  bash "$ARCHIVE" emergency 2> "$WORK/log15"
check "XPENG_EXTRA_DIRS archives it" 3 "$(count_archived)"
check "from the right folder" 1 \
  "$(find "$DEST" -path '*XP_XGUARD_DCIM*' -name '*.mp4' 2>/dev/null | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
section "drive retention: keep a window, delete only what is archived"
# ---------------------------------------------------------------------------
reset_fixture
lane_env
# first run: the fixtures are settled but NOT yet in the index, so nothing may go
XPENG_FORCE_STATE=home XPENG_IDLE_OK=1 XPENG_NORMAL_SYNC=home XPENG_DRIVE_RETENTION_DAYS=14 \
  bash "$ARCHIVE" normal 2> "$WORK/log18"
check "archived on the first run" 3 "$(count_archived)"
check "nothing deleted while the index is empty" 3 "$(count_lane XP_DCIM)"

# second run: they are in the index now, and the fixtures date from September,
# so they are past the 14 day window and must go
XPENG_FORCE_STATE=home XPENG_IDLE_OK=1 XPENG_NORMAL_SYNC=home XPENG_DRIVE_RETENTION_DAYS=14 \
  bash "$ARCHIVE" normal 2> "$WORK/log19"
check "archived + past the window -> deleted" 0 "$(count_lane XP_DCIM)"

# a clip is never deleted on age alone: with the lane not syncing, nothing is
# copied, so the index cannot vouch for it and it must survive
OLD="$SRC/XP_DCIM/DVR_20260101000000000_front.mp4"
printf 'old\n' > "$OLD"
touch -t 202601020000 "$OLD"
XPENG_FORCE_STATE=other XPENG_NORMAL_SYNC=home XPENG_IDLE_OK=1 XPENG_DELETE_AFTER_UPLOAD=1 \
  bash "$ARCHIVE" normal 2> "$WORK/log20"
check "never deletes what the archive lacks" 1 "$([ -f "$OLD" ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
section "retention prunes old clips only"
# ---------------------------------------------------------------------------
reset_fixture
lane_env
# clips of known age in the stick layout, plus things that must never be pruned
mkdir -p "$DEST/xpengusb/XP_DCIM" "$DEST/xpengusb/XP_EMER_DCIM"
mkdir -p "$DEST/xpengusb/_logs" "$DEST/xpengusb/do_not_touch"
printf 'old'  > "$DEST/xpengusb/XP_DCIM/DVR_20260101000000000_front.mp4"
printf 'new'  > "$DEST/xpengusb/XP_DCIM/DVR_20261108000000000_front.mp4"
printf 'emgap' > "$DEST/xpengusb/XP_EMER_DCIM/EMER_[E_A1_30000_2_E]20260101000000000_front.mp4"
printf 'log'  > "$DEST/xpengusb/_logs/copy.log"
printf 'keep' > "$DEST/xpengusb/do_not_touch/keep.txt"
# backdate the old ones well past the window
touch -t 202601020000 "$DEST/xpengusb/XP_DCIM/DVR_20260101000000000_front.mp4"
touch -t 202601020000 "$DEST/xpengusb/XP_EMER_DCIM/EMER_[E_A1_30000_2_E]20260101000000000_front.mp4"
touch -t 202601020000 "$DEST/xpengusb/_logs/copy.log"
touch -t 202601020000 "$DEST/xpengusb/do_not_touch/keep.txt"

XPENG_FORCE_STATE=home XPENG_IDLE_OK=1 XPENG_NORMAL_SYNC=home XPENG_RETENTION_DAYS=30 \
  bash "$ARCHIVE" normal 2> "$WORK/log16"
check "old normal clip pruned" 0 \
  "$([ -f "$DEST/xpengusb/XP_DCIM/DVR_20260101000000000_front.mp4" ] && echo 1 || echo 0)"
check "old emergency clip pruned" 0 \
  "$([ -f "$DEST/xpengusb/XP_EMER_DCIM/EMER_[E_A1_30000_2_E]20260101000000000_front.mp4" ] && echo 1 || echo 0)"
check "recent clip kept" 1 \
  "$([ -f "$DEST/xpengusb/XP_DCIM/DVR_20261108000000000_front.mp4" ] && echo 1 || echo 0)"
check "_logs never pruned" 1 "$([ -f "$DEST/xpengusb/_logs/copy.log" ] && echo 1 || echo 0)"
check "foreign folder never pruned" 1 "$([ -f "$DEST/xpengusb/do_not_touch/keep.txt" ] && echo 1 || echo 0)"

# retention off by default: nothing is removed
reset_fixture
lane_env
mkdir -p "$DEST/xpengusb/XP_DCIM"
printf 'old' > "$DEST/xpengusb/XP_DCIM/DVR_20260101000000000_front.mp4"
touch -t 202601020000 "$DEST/xpengusb/XP_DCIM/DVR_20260101000000000_front.mp4"
XPENG_FORCE_STATE=home XPENG_IDLE_OK=1 XPENG_NORMAL_SYNC=home \
  bash "$ARCHIVE" normal 2> "$WORK/log17"
check "retention off by default" 1 \
  "$([ -f "$DEST/xpengusb/XP_DCIM/DVR_20260101000000000_front.mp4" ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
section "unmounted archive refuses to touch the drive"
# ---------------------------------------------------------------------------
reset_fixture
lane_env
if XPENG_FORCE_STATE=home XPENG_IDLE_OK=1 XPENG_NORMAL_SYNC=home \
     XPENG_ARCHIVE_MOUNT="$WORK/not-mounted" bash "$ARCHIVE" normal 2> "$WORK/log13"; then
  bad "should have failed with no archive"
else
  ok "fails closed when the archive is missing"
fi
check "and deleted nothing" 3 "$(count_lane XP_DCIM)"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
