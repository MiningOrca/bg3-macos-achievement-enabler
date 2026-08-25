#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

STEAM_APP="$HOME/Library/Application Support/Steam/steamapps/common/Baldurs Gate 3/Baldur's Gate 3.app"
STEAM_BIN="$STEAM_APP/Contents/MacOS/Baldur's Gate 3"

GOG_APP="/Applications/Baldur's Gate 3.app"
GOG_BIN="$GOG_APP/Contents/MacOS/Baldur's Gate 3 GOG"

PLATFORM=""
APP=""
BIN=""
BACKUP=""
OFF_UNLOCK=0
OFF_COUNTER=0
OFF_OSIRIS_UNLOCK=0

STOCK_UNLOCK="7c000036"      # tbz w28, #0, 0x104818b04
PATCH_UNLOCK="03000014"      # b   0x104818b04
STOCK_COUNTER="b5170037"     # tbnz w21, #0, 0x1048191f0
PATCH_COUNTER="1f2003d5"     # nop
STOCK_OSIRIS_UNLOCK="79000036" # tbz w25, #0, 0x105547e14
PATCH_OSIRIS_UNLOCK="03000014" # b   0x105547e14

# Human-visible command output goes through these two functions.
# A terminal banner can later be integrated here without touching patch logic.
ui_print() {
  printf '%s\n' "$*"
}

ui_error() {
  printf '%s\n' "$*" >&2
}

die() {
  ui_error "ERROR: $*"
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  bg3-achievements-patch.sh status
  bg3-achievements-patch.sh on
  bg3-achievements-patch.sh off
  bg3-achievements-patch.sh restore

Commands:
  status   Show whether the achievement patch is ON/OFF.
  on       Enable achievements with custom mods.
  off      Disable the patch and restore the original three instructions.
  restore  Restore the full original executable from the first-run backup.
USAGE
}

detect_game() {
  if [[ -f "$STEAM_BIN" ]]; then
    PLATFORM="Steam"
    APP="$STEAM_APP"
    BIN="$STEAM_BIN"
    BACKUP="$SCRIPT_DIR/Baldur's Gate 3.original"
    OFF_UNLOCK=$((0x13dd8af8))
    OFF_COUNTER=$((0x13dd8efc))
    OFF_OSIRIS_UNLOCK=$((0x14b07e08))
  elif [[ -f "$GOG_BIN" ]]; then
    PLATFORM="GOG"
    APP="$GOG_APP"
    BIN="$GOG_BIN"
    BACKUP="$SCRIPT_DIR/Baldur's Gate 3 GOG.original"
    OFF_UNLOCK=$((0x13dbca18))
    OFF_COUNTER=$((0x13dbce1c))
    OFF_OSIRIS_UNLOCK=$((0x14aebd28))
  else
    die "Supported BG3 installation not found."
  fi
}

require_game() {
  [[ -f "$BIN" ]] || die "BG3 executable not found: $BIN"
  [[ -w "$BIN" ]] || die "BG3 executable is not writable: $BIN"
}

ensure_not_running() {
  if /usr/bin/pgrep -x "Baldur's Gate 3" >/dev/null 2>&1 || \
     /usr/bin/pgrep -x "Baldur's Gate 3 GOG" >/dev/null 2>&1; then
    die "Baldur's Gate 3 is running. Quit the game first."
  fi
}

# Data-returning helpers intentionally write directly to stdout.
read4() {
  local off="$1"
  /bin/dd if="$BIN" bs=1 skip="$off" count=4 2>/dev/null | /usr/bin/hexdump -v -e '1/1 "%02x"'
}

write_unlock_patch() {
  printf '\x03\x00\x00\x14' | /bin/dd of="$BIN" bs=1 seek="$OFF_UNLOCK" conv=notrunc 2>/dev/null
}

write_unlock_stock() {
  printf '\x7c\x00\x00\x36' | /bin/dd of="$BIN" bs=1 seek="$OFF_UNLOCK" conv=notrunc 2>/dev/null
}

write_counter_patch() {
  printf '\x1f\x20\x03\xd5' | /bin/dd of="$BIN" bs=1 seek="$OFF_COUNTER" conv=notrunc 2>/dev/null
}

write_counter_stock() {
  printf '\xb5\x17\x00\x37' | /bin/dd of="$BIN" bs=1 seek="$OFF_COUNTER" conv=notrunc 2>/dev/null
}

write_osiris_unlock_patch() {
  printf '\x03\x00\x00\x14' | /bin/dd of="$BIN" bs=1 seek="$OFF_OSIRIS_UNLOCK" conv=notrunc 2>/dev/null
}

write_osiris_unlock_stock() {
  printf '\x79\x00\x00\x36' | /bin/dd of="$BIN" bs=1 seek="$OFF_OSIRIS_UNLOCK" conv=notrunc 2>/dev/null
}

state() {
  local a b c
  a="$(read4 "$OFF_UNLOCK")"
  b="$(read4 "$OFF_COUNTER")"
  c="$(read4 "$OFF_OSIRIS_UNLOCK")"

  if [[ "$a" == "$STOCK_UNLOCK" && "$b" == "$STOCK_COUNTER" && "$c" == "$STOCK_OSIRIS_UNLOCK" ]]; then
    printf '%s\n' "off"
  elif [[ "$a" == "$PATCH_UNLOCK" && "$b" == "$PATCH_COUNTER" && "$c" == "$PATCH_OSIRIS_UNLOCK" ]]; then
    printf '%s\n' "on"
  elif [[ ( "$a" == "$STOCK_UNLOCK" || "$a" == "$PATCH_UNLOCK" ) &&
          ( "$b" == "$STOCK_COUNTER" || "$b" == "$PATCH_COUNTER" ) &&
          ( "$c" == "$STOCK_OSIRIS_UNLOCK" || "$c" == "$PATCH_OSIRIS_UNLOCK" ) ]]; then
    printf '%s\n' "mixed"
  else
    printf 'unknown:%s:%s:%s\n' "$a" "$b" "$c"
  fi
}

run_logged() {
  local output

  if output="$("$@" 2>&1)"; then
    [[ -z "$output" ]] || ui_print "$output"
    return 0
  fi

  [[ -z "$output" ]] || ui_error "$output"
  return 1
}

make_backup() {
  if [[ ! -f "$BACKUP" ]]; then
    ui_print "Creating original executable backup..."
    /bin/cp -p "$BIN" "$BACKUP"
    /usr/bin/shasum -a 256 "$BACKUP" > "$BACKUP.sha256"
    ui_print "Backup: $BACKUP"
  fi
}

# codesign reports one bad nested code object at a time. Repair only the
# reported unsigned object, then retry the outer app signature.
sign_bg3_app() {
  local attempt output nested

  for attempt in 1 2 3 4 5 6 7 8; do
    if output="$(
      /usr/bin/codesign \
        --force \
        --sign - \
        --preserve-metadata=identifier,entitlements,flags \
        "$APP" \
        2>&1
    )"; then
      [[ -z "$output" ]] || ui_print "$output"
      return 0
    fi

    [[ -z "$output" ]] || ui_error "$output"
    [[ "$output" == *"code object is not signed at all"* ]] || return 1

    nested="$(
      printf '%s\n' "$output" |
        /usr/bin/sed -n 's/^In subcomponent: //p' |
        /usr/bin/tail -n 1
    )"

    [[ -n "$nested" ]] || return 1
    case "$nested" in
      "$APP"/*) ;;
      *)
        ui_error "Refusing to sign code outside the BG3 app: $nested"
        return 1
        ;;
    esac

    [[ -e "$nested" ]] || {
      ui_error "Nested code reported by codesign does not exist: $nested"
      return 1
    }

    [[ ! -L "$nested" ]] || {
      ui_error "Refusing to sign symlinked nested code: $nested"
      return 1
    }

    ui_print "Signing unsigned nested code: ${nested#"$APP/"}"
    run_logged /usr/bin/codesign --force --sign - "$nested" || return 1
  done

  ui_error "Too many unsigned nested code objects; aborting."
  return 1
}

resign() {
  ui_print "Removing runtime logs from Contents/MacOS..."
  /usr/bin/find "$APP/Contents/MacOS" \
    -maxdepth 1 \
    -type f \
    -name '*.log' \
    -delete

  if [[ "$PLATFORM" == "GOG" ]]; then
    ui_print "Re-signing GOG game executable ad-hoc while preserving signing metadata..."
    run_logged /usr/bin/codesign \
      --force \
      --sign - \
      --preserve-metadata=identifier,entitlements,flags \
      "$BIN" || return 1
  fi

  ui_print "Re-signing BG3 ad-hoc while preserving signing metadata..."
  sign_bg3_app || return 1

  ui_print "Verifying signature..."
  run_logged /usr/bin/codesign \
    --verify \
    --deep \
    --strict \
    --verbose=2 \
    "$APP"
}

show_status() {
  require_game

  local s a b c
  s="$(state)"
  a="$(read4 "$OFF_UNLOCK")"
  b="$(read4 "$OFF_COUNTER")"
  c="$(read4 "$OFF_OSIRIS_UNLOCK")"

  ui_print "Platform: $PLATFORM"
  ui_print "BG3: $BIN"
  ui_print "UnlockAchievement bytes:                 $a"
  ui_print "IncreaseAchievementCounter bytes:        $b"
  ui_print "Osiris UnlockAchievement gate bytes:     $c"

  case "$s" in
    on)
      ui_print "Patch: ON"
      ;;
    off)
      ui_print "Patch: OFF"
      ;;
    mixed)
      ui_print "Patch: MIXED (known bytes, but only part of the patch is applied)"
      ;;
    unknown:*)
      ui_print "Patch: UNKNOWN BUILD / BYTES"
      ui_print "Refusing to modify this binary until offsets are re-verified."
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
      ui_print "Patch is already ON."
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

  ui_print "Enabling achievement patch..."
  write_unlock_patch
  write_counter_patch
  write_osiris_unlock_patch

  if [[ "$(state)" != "on" ]]; then
    /bin/cp -p "$BACKUP" "$BIN"
    die "Byte verification failed; original executable restored."
  fi

  if ! resign; then
    ui_error "Signing failed; restoring original executable."
    /bin/cp -p "$BACKUP" "$BIN"

    if [[ "$PLATFORM" == "GOG" ]]; then
      /usr/bin/codesign \
        --force \
        --sign - \
        --preserve-metadata=identifier,entitlements,flags \
        "$APP" \
        >/dev/null 2>&1 || true
    fi

    exit 1
  fi

  ui_print ""
  ui_print "Achievement patch: ON"
}

disable_patch() {
  require_game
  ensure_not_running

  local s
  s="$(state)"
  case "$s" in
    off)
      ui_print "Patch is already OFF."
      return 0
      ;;
    on|mixed)
      ;;
    *)
      show_status
      die "Unexpected bytes. Not touching the executable."
      ;;
  esac

  ui_print "Disabling achievement patch..."
  write_unlock_stock
  write_counter_stock
  write_osiris_unlock_stock

  [[ "$(state)" == "off" ]] || die "Failed to restore stock instructions."
  resign || die "Signing failed after restoring stock instructions."

  ui_print ""
  ui_print "Achievement patch: OFF"
}

restore_original() {
  require_game
  ensure_not_running
  [[ -f "$BACKUP" ]] || die "No backup found: $BACKUP"

  ui_print "Restoring full original executable..."
  /bin/cp -p "$BACKUP" "$BIN"

  if [[ "$PLATFORM" == "GOG" ]]; then
    ui_print "Re-signing BG3 ad-hoc while preserving signing metadata..."
    sign_bg3_app || die "Failed to re-sign restored GOG app."
  fi

  ui_print "Verifying restored executable/app signature..."
  if run_logged /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"; then
    ui_print "Original executable restored and signature verifies."
  else
    ui_error "Original executable restored, but bundle verification failed."

    if [[ "$PLATFORM" == "Steam" ]]; then
      ui_error "If BG3 does not launch, use Steam -> Properties -> Installed Files -> Verify integrity."
    else
      ui_error "If BG3 does not launch, repair/verify the game installation through GOG Galaxy."
    fi

    exit 1
  fi
}

main() {
  local cmd="${1:-status}"

  case "$cmd" in
    -h|--help|help)
      usage
      return 0
      ;;
    status|on|off|restore)
      ;;
    *)
      usage >&2
      return 2
      ;;
  esac

  detect_game

  case "$cmd" in
    status)  show_status ;;
    on)      enable_patch ;;
    off)     disable_patch ;;
    restore) restore_original ;;
  esac
}

main "$@"
