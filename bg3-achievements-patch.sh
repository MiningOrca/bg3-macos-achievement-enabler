#!/bin/bash
set -euo pipefail

APP="$HOME/Library/Application Support/Steam/steamapps/common/Baldurs Gate 3/Baldur's Gate 3.app"
BIN="$APP/Contents/MacOS/Baldur's Gate 3"
STATE_DIR="$HOME/Library/Application Support/BG3AchievementPatch"
BACKUP="$STATE_DIR/Baldur's Gate 3.original"

# These offsets/bytes are for the exact BG3 macOS build reverse-engineered in this chat.
OFF_UNLOCK=$((0x13dd8af8))
OFF_COUNTER=$((0x13dd8efc))
OFF_OSIRIS_UNLOCK=$((0x14b07e08))

STOCK_UNLOCK="7c000036"      # tbz w28, #0, 0x104818b04
PATCH_UNLOCK="03000014"      # b   0x104818b04
STOCK_COUNTER="b5170037"     # tbnz w21, #0, 0x1048191f0
PATCH_COUNTER="1f2003d5"     # nop
STOCK_OSIRIS_UNLOCK="79000036" # tbz w25, #0, 0x105547e14
PATCH_OSIRIS_UNLOCK="03000014" # b   0x105547e14

usage() {
  cat <<'USAGE'
Usage:
  bg3-achievements-patch.sh status
  bg3-achievements-patch.sh on
  bg3-achievements-patch.sh off
  bg3-achievements-patch.sh restore

Commands:
  status   Show whether the achievement patch is ON/OFF.
  on       Enable Steam achievements with custom mods.
  off      Disable the patch and restore the original three instructions.
  restore  Restore the full original executable from the first-run backup.
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_game() {
  [[ -f "$BIN" ]] || die "BG3 executable not found: $BIN"
  [[ -w "$BIN" ]] || die "BG3 executable is not writable: $BIN"
}

ensure_not_running() {
  if pgrep -x "Baldur's Gate 3" >/dev/null 2>&1; then
    die "Baldur's Gate 3 is running. Quit the game first."
  fi
}

read4() {
  local off="$1"
  dd if="$BIN" bs=1 skip="$off" count=4 2>/dev/null | /usr/bin/hexdump -v -e '1/1 "%02x"'
}

write_unlock_patch() {
  printf '\x03\x00\x00\x14' | dd of="$BIN" bs=1 seek="$OFF_UNLOCK" conv=notrunc 2>/dev/null
}

write_unlock_stock() {
  printf '\x7c\x00\x00\x36' | dd of="$BIN" bs=1 seek="$OFF_UNLOCK" conv=notrunc 2>/dev/null
}

write_counter_patch() {
  printf '\x1f\x20\x03\xd5' | dd of="$BIN" bs=1 seek="$OFF_COUNTER" conv=notrunc 2>/dev/null
}

write_counter_stock() {
  printf '\xb5\x17\x00\x37' | dd of="$BIN" bs=1 seek="$OFF_COUNTER" conv=notrunc 2>/dev/null
}

write_osiris_unlock_patch() {
  printf '\x03\x00\x00\x14' | dd of="$BIN" bs=1 seek="$OFF_OSIRIS_UNLOCK" conv=notrunc 2>/dev/null
}

write_osiris_unlock_stock() {
  printf '\x79\x00\x00\x36' | dd of="$BIN" bs=1 seek="$OFF_OSIRIS_UNLOCK" conv=notrunc 2>/dev/null
}

state() {
  local a b c
  a="$(read4 "$OFF_UNLOCK")"
  b="$(read4 "$OFF_COUNTER")"
  c="$(read4 "$OFF_OSIRIS_UNLOCK")"

  if [[ "$a" == "$STOCK_UNLOCK" && "$b" == "$STOCK_COUNTER" && "$c" == "$STOCK_OSIRIS_UNLOCK" ]]; then
    echo "off"
  elif [[ "$a" == "$PATCH_UNLOCK" && "$b" == "$PATCH_COUNTER" && "$c" == "$PATCH_OSIRIS_UNLOCK" ]]; then
    echo "on"
  elif [[ ( "$a" == "$STOCK_UNLOCK" || "$a" == "$PATCH_UNLOCK" ) &&
          ( "$b" == "$STOCK_COUNTER" || "$b" == "$PATCH_COUNTER" ) &&
          ( "$c" == "$STOCK_OSIRIS_UNLOCK" || "$c" == "$PATCH_OSIRIS_UNLOCK" ) ]]; then
    echo "mixed"
  else
    echo "unknown:$a:$b:$c"
  fi
}

make_backup() {
  if [[ ! -f "$BACKUP" ]]; then
    mkdir -p "$STATE_DIR"
    echo "Creating original executable backup..."
    cp -p "$BIN" "$BACKUP"
    /usr/bin/shasum -a 256 "$BACKUP" > "$BACKUP.sha256"
    echo "Backup: $BACKUP"
  fi
}

resign() {
  echo "Removing runtime logs from Contents/MacOS..."
  find "$APP/Contents/MacOS" \
    -maxdepth 1 \
    -type f \
    -name '*.log' \
    -print \
    -delete

  echo "Re-signing BG3 ad-hoc while preserving signing metadata..."
  /usr/bin/codesign \
    --force \
    --sign - \
    --preserve-metadata=identifier,entitlements,flags \
    "$APP"

  echo "Verifying signature..."
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
}

show_status() {
  require_game
  local s a b c
  s="$(state)"
  a="$(read4 "$OFF_UNLOCK")"
  b="$(read4 "$OFF_COUNTER")"
  c="$(read4 "$OFF_OSIRIS_UNLOCK")"

  echo "BG3: $BIN"
  echo "UnlockAchievement bytes:                 $a"
  echo "IncreaseAchievementCounter bytes:        $b"
  echo "Osiris UnlockAchievement gate bytes:     $c"

  case "$s" in
    on)
      echo "Patch: ON"
      ;;
    off)
      echo "Patch: OFF"
      ;;
    mixed)
      echo "Patch: MIXED (known bytes, but only part of the patch is applied)"
      ;;
    unknown:*)
      echo "Patch: UNKNOWN BUILD / BYTES"
      echo "Refusing to modify this binary until offsets are re-verified."
      ;;
  esac
}

enable_patch() {
  require_game
  ensure_not_running

  local s
  s="$(state)"
  case "$s" in
    on)
      echo "Patch is already ON."
      return 0
      ;;
    off)
      make_backup
      ;;
    mixed)
      [[ -f "$BACKUP" ]] || die "Patch is partially applied, but no original backup exists. Restore a clean executable before changing it."
      ;;
    *)
      show_status
      die "Unexpected bytes. BG3 may have been updated; not patching."
      ;;
  esac

  echo "Enabling achievement patch..."
  write_unlock_patch
  write_counter_patch
  write_osiris_unlock_patch

  if [[ "$(state)" != "on" ]]; then
    cp -p "$BACKUP" "$BIN"
    die "Byte verification failed; original executable restored."
  fi

  if ! resign; then
    echo "Signing failed; restoring original executable." >&2
    cp -p "$BACKUP" "$BIN"
    exit 1
  fi

  echo
  echo "Achievement patch: ON"
}

disable_patch() {
  require_game
  ensure_not_running

  local s
  s="$(state)"
  case "$s" in
    off)
      echo "Patch is already OFF."
      return 0
      ;;
    on|mixed)
      ;;
    *)
      show_status
      die "Unexpected bytes. Not touching the executable."
      ;;
  esac

  echo "Disabling achievement patch..."
  write_unlock_stock
  write_counter_stock
  write_osiris_unlock_stock

  [[ "$(state)" == "off" ]] || die "Failed to restore stock instructions."
  resign

  echo
  echo "Achievement patch: OFF"
}

restore_original() {
  require_game
  ensure_not_running
  [[ -f "$BACKUP" ]] || die "No backup found: $BACKUP"

  echo "Restoring full original executable..."
  cp -p "$BACKUP" "$BIN"

  echo "Verifying restored executable/app signature..."
  if /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"; then
    echo "Original executable restored and signature verifies."
  else
    echo "Original executable restored, but bundle verification failed." >&2
    echo "If BG3 does not launch, use Steam -> Properties -> Installed Files -> Verify integrity." >&2
    exit 1
  fi
}

cmd="${1:-status}"
case "$cmd" in
  status)  show_status ;;
  on)      enable_patch ;;
  off)     disable_patch ;;
  restore) restore_original ;;
  -h|--help|help) usage ;;
  *) usage; exit 2 ;;
esac
