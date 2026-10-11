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
BACKUP_SHA=""

PATCH_NAMES=(
  "AchievementManager::UnlockAchievement"
  "AchievementManager::IncreaseAchievementCounter"
  "OsirisGameFunctions::UnlockAchievement"
)

PATCH_SYMBOLS=(
  '^__ZN3esv18AchievementManager17UnlockAchievementERKN2ls11_StringViewIcEEPKNS_9CharacterE$'
  '^__ZN3esv18AchievementManager26IncreaseAchievementCounterEPKNS_9CharacterERKN2ls11FixedStringEtb$'
  '^__ZN3esv19OsirisGameFunctions17UnlockAchievementEPN3osi18ExecutionParameterE$'
)

PATCH_REL=(
  $((0x94))
  $((0x98))
  $((0x78))
)

PATCH_RADIUS=(
  $((0x80))
  $((0x80))
  $((0x80))
)

PATCH_STOCK=(
  "7c000036"
  "b5170037"
  "79000036"
)

PATCH_ON=(
  "03000014"
  "1f2003d5"
  "03000014"
)

KNOWN_VMS=(
  $((0x104818af8))
  $((0x104818efc))
  $((0x105547e08))
)

PATCH_VMS=(0 0 0)
PATCH_OFFSETS=(0 0 0)
PATCH_CURRENTS=("" "" "")
PATCH_STATES=("unknown" "unknown" "unknown")
PATCH_SOURCES=("unresolved" "unresolved" "unresolved")
LOCATION_SOURCE="unresolved"

SLICE_OFF=0
TEXT_VMADDR=0
TEXT_FILEOFF=0
TEXT_FILESIZE=0

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
  restore  Restore the full original executable from the saved backup.
USAGE
}

require_tools() {
  local tool
  for tool in nm lipo otool codesign shasum dd hexdump awk grep pgrep tr sed tail find; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required."
  done
}

detect_game() {
  if [[ -f "$STEAM_BIN" ]]; then
    PLATFORM="Steam"
    APP="$STEAM_APP"
    BIN="$STEAM_BIN"
    BACKUP="$SCRIPT_DIR/Baldur's Gate 3.original"
  elif [[ -f "$GOG_BIN" ]]; then
    PLATFORM="GOG"
    APP="$GOG_APP"
    BIN="$GOG_BIN"
    BACKUP="$SCRIPT_DIR/Baldur's Gate 3 GOG.original"
  else
    die "Supported BG3 installation not found."
  fi

  BACKUP_SHA="$BACKUP.sha256"
}

require_game() {
  [[ -d "$APP" ]] || die "BG3 app not found: $APP"
  [[ -f "$BIN" ]] || die "BG3 executable not found: $BIN"
  [[ -w "$BIN" ]] || die "BG3 executable is not writable: $BIN"

  local archs
  archs="$(lipo -archs "$BIN" 2>/dev/null)" || die "Unable to inspect BG3 Mach-O architectures."
  case " $archs " in
    *" arm64 "*) ;;
    *) die "ARM64 slice not found in BG3 executable." ;;
  esac
}

ensure_not_running() {
  if pgrep -x "Baldur's Gate 3" >/dev/null 2>&1 || \
     pgrep -x "Baldur's Gate 3 GOG" >/dev/null 2>&1; then
    die "Baldur's Gate 3 is running. Quit the game first."
  fi
}

backup_sha() {
  shasum -a 256 "$1" | awk '{print $1}'
}

verify_backup() {
  [[ -f "$BACKUP" ]] || die "Original backup not found: $BACKUP"
  [[ -f "$BACKUP_SHA" ]] || die "Backup checksum not found: $BACKUP_SHA"

  local expected actual
  expected="$(tr -d '[:space:]' < "$BACKUP_SHA")"
  actual="$(backup_sha "$BACKUP")"
  [[ "$actual" == "$expected" ]] || die "Original backup checksum mismatch."
}

is_adhoc_binary() {
  codesign -dv --verbose=4 "$BIN" 2>&1 | grep -q '^Signature=adhoc$'
}

is_clean_signed_binary() {
  codesign --verify --strict "$BIN" >/dev/null 2>&1 || return 1
  is_adhoc_binary && return 1
  return 0
}

init_macho_layout() {
  local detailed text

  detailed="$(lipo -detailed_info "$BIN" 2>/dev/null)" || die "Unable to inspect BG3 universal binary."

  if grep -q '^Fat header in:' <<<"$detailed"; then
    SLICE_OFF="$(awk '
      /^architecture arm64$/ { in_arm64=1; next }
      /^architecture /       { in_arm64=0 }
      in_arm64 && $1 == "offset" { print $2; exit }
    ' <<<"$detailed")"
    [[ -n "$SLICE_OFF" ]] || die "Unable to determine ARM64 slice offset."
  else
    SLICE_OFF=0
  fi

  text="$(otool -arch arm64 -l "$BIN" 2>/dev/null | awk '
    $1 == "segname" && $2 == "__TEXT" { in_text=1; next }
    in_text && $1 == "vmaddr"   { vm=$2 }
    in_text && $1 == "fileoff"  { fo=$2 }
    in_text && $1 == "filesize" { print vm, fo, $2; exit }
  ')"
  [[ -n "$text" ]] || die "Unable to locate ARM64 __TEXT segment."

  read -r TEXT_VMADDR TEXT_FILEOFF TEXT_FILESIZE <<<"$text"
}

vm_to_fileoff() {
  local vm="$1"
  (( vm >= TEXT_VMADDR && vm < TEXT_VMADDR + TEXT_FILESIZE )) || return 1
  printf '%s\n' $((SLICE_OFF + TEXT_FILEOFF + vm - TEXT_VMADDR))
}

read4_file() {
  local image="$1" off="$2"
  dd if="$image" bs=1 skip="$off" count=4 2>/dev/null |
    hexdump -v -e '1/1 "%02x"'
}

read4() {
  read4_file "$BIN" "$1"
}

write4() {
  local off="$1" hex="$2" escaped="" i
  [[ ${#hex} -eq 8 ]] || return 1

  for ((i = 0; i < 8; i += 2)); do
    escaped+="\\x${hex:i:2}"
  done

  printf '%b' "$escaped" |
    dd of="$BIN" bs=1 seek="$off" count=4 conv=notrunc 2>/dev/null || return 1

  [[ "$(read4 "$off")" == "$hex" ]]
}

symbol_vm() {
  local regex="$1" matches count hex

  matches="$(nm -arch arm64 -n "$BIN" 2>/dev/null | awk -v re="$regex" '$3 ~ re { print $1 }')" || return 1
  [[ -n "$matches" ]] || return 1

  count="$(printf '%s\n' "$matches" | awk 'END { print NR }')"
  [[ "$count" == "1" ]] || return 1

  hex="$(printf '%s\n' "$matches" | awk 'NR == 1 { print $1 }')"
  [[ "$hex" =~ ^[0-9a-fA-F]+$ ]] || return 1

  printf '%s\n' $((16#$hex))
}

bytes_are_known() {
  local index="$1" bytes="$2"
  [[ "$bytes" == "${PATCH_STOCK[index]}" || "$bytes" == "${PATCH_ON[index]}" ]]
}

resolve_exact_vm() {
  local index="$1" vm="$2" source="$3" off current

  off="$(vm_to_fileoff "$vm")" || return 1
  current="$(read4 "$off")"
  bytes_are_known "$index" "$current" || return 1

  PATCH_VMS[index]="$vm"
  PATCH_OFFSETS[index]="$off"
  PATCH_CURRENTS[index]="$current"
  PATCH_SOURCES[index]="$source"
  return 0
}

scan_near_expected_vm() {
  local index="$1" expected="$2" radius="$3"
  local vm off current found=0 found_vm=0 found_off=0
  local start=$((expected - radius))
  local end=$((expected + radius))

  # The fallback searches only for the stock instruction. Searching for the
  # patched NOP used by the counter gate would be ambiguous in normal code.
  for ((vm = start; vm <= end; vm += 4)); do
    off="$(vm_to_fileoff "$vm")" || continue
    current="$(read4 "$off")"
    [[ "$current" == "${PATCH_STOCK[index]}" ]] || continue

    ((found += 1))
    found_vm="$vm"
    found_off="$off"
  done

  [[ "$found" == "1" ]] || return 1

  PATCH_VMS[index]="$found_vm"
  PATCH_OFFSETS[index]="$found_off"
  PATCH_CURRENTS[index]="${PATCH_STOCK[index]}"
  PATCH_SOURCES[index]="symbol local scan"
  return 0
}

resolve_one_patch() {
  local index="$1" base expected

  if base="$(symbol_vm "${PATCH_SYMBOLS[index]}")"; then
    expected=$((base + PATCH_REL[index]))

    if resolve_exact_vm "$index" "$expected" "symbol + relative offset"; then
      return 0
    fi

    if scan_near_expected_vm "$index" "$expected" "${PATCH_RADIUS[index]}"; then
      return 0
    fi
  fi

  # Fail-safe fallback for binaries where symbols are unavailable. The VM is
  # translated through the current Mach-O layout; no file offset is hard-coded.
  if resolve_exact_vm "$index" "${KNOWN_VMS[index]}" "verified VM fallback"; then
    return 0
  fi

  return 1
}

resolve_patch_locations() {
  local i failed=0 saw_scan=0 saw_fallback=0

  for ((i = 0; i < ${#PATCH_NAMES[@]}; i++)); do
    PATCH_VMS[i]=0
    PATCH_OFFSETS[i]=0
    PATCH_CURRENTS[i]="unresolved"
    PATCH_STATES[i]="unknown"
    PATCH_SOURCES[i]="unresolved"

    if ! resolve_one_patch "$i"; then
      failed=1
      continue
    fi

    case "${PATCH_SOURCES[i]}" in
      "symbol local scan") saw_scan=1 ;;
      "verified VM fallback") saw_fallback=1 ;;
    esac
  done

  if (( failed )); then
    LOCATION_SOURCE="unresolved"
    return 1
  elif (( saw_fallback )); then
    LOCATION_SOURCE="symbols / verified VM fallback"
  elif (( saw_scan )); then
    LOCATION_SOURCE="symbols + local scan"
  else
    LOCATION_SOURCE="symbols + relative offsets"
  fi

  return 0
}

classify_patch_locations() {
  local i current

  for ((i = 0; i < ${#PATCH_NAMES[@]}; i++)); do
    current="${PATCH_CURRENTS[i]}"

    if [[ "$current" == "${PATCH_STOCK[i]}" ]]; then
      PATCH_STATES[i]="stock"
    elif [[ "$current" == "${PATCH_ON[i]}" ]]; then
      PATCH_STATES[i]="patched"
    else
      PATCH_STATES[i]="unknown"
    fi
  done
}

resolve_and_classify() {
  init_macho_layout
  resolve_patch_locations || true
  classify_patch_locations
}

global_state() {
  local state stock_count=0 patched_count=0 unknown_count=0

  for state in "${PATCH_STATES[@]}"; do
    case "$state" in
      stock)   ((stock_count += 1)) ;;
      patched) ((patched_count += 1)) ;;
      *)       ((unknown_count += 1)) ;;
    esac
  done

  if (( unknown_count > 0 )); then
    printf '%s\n' "UNKNOWN"
  elif (( stock_count == ${#PATCH_STATES[@]} )); then
    printf '%s\n' "OFF"
  elif (( patched_count == ${#PATCH_STATES[@]} )); then
    printf '%s\n' "ON"
  else
    printf '%s\n' "MIXED"
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

show_status_resolved() {
  local i state line
  state="$(global_state)"

  ui_print "Platform: $PLATFORM"
  ui_print "BG3: $BIN"
  ui_print "Locations: $LOCATION_SOURCE"
  ui_print ""

  for ((i = 0; i < ${#PATCH_NAMES[@]}; i++)); do
    if [[ "${PATCH_OFFSETS[i]}" != "0" ]]; then
      printf -v line '%-48s bytes: %s  VM: 0x%x  file: 0x%x' \
        "${PATCH_NAMES[i]}" \
        "${PATCH_CURRENTS[i]}" \
        "${PATCH_VMS[i]}" \
        "${PATCH_OFFSETS[i]}"
    else
      printf -v line '%-48s bytes: %s' \
        "${PATCH_NAMES[i]}" \
        "${PATCH_CURRENTS[i]}"
    fi
    ui_print "$line"
  done

  ui_print ""
  case "$state" in
    ON)    ui_print "Patch: ON" ;;
    OFF)   ui_print "Patch: OFF" ;;
    MIXED) ui_print "Patch: MIXED (known bytes, but only part of the patch is applied)" ;;
    *)
      ui_print "Patch: UNKNOWN BUILD / BYTES"
      ui_print "The achievement gates could not be resolved unambiguously; refusing to modify the executable."
      ;;
  esac
}

show_status() {
  resolve_and_classify
  show_status_resolved
}

patch_binary() {
  local action="$1" i desired state

  resolve_and_classify
  state="$(global_state)"

  [[ "$state" != "UNKNOWN" ]] || {
    show_status_resolved
    return 1
  }

  case "$action" in
    on)
      [[ "$state" != "ON" ]] || return 0
      ;;
    off)
      [[ "$state" != "OFF" ]] || return 0
      ;;
    *) return 1 ;;
  esac

  for ((i = 0; i < ${#PATCH_NAMES[@]}; i++)); do
    if [[ "$action" == "on" ]]; then
      desired="${PATCH_ON[i]}"
    else
      desired="${PATCH_STOCK[i]}"
    fi

    if [[ "${PATCH_CURRENTS[i]}" != "$desired" ]]; then
      write4 "${PATCH_OFFSETS[i]}" "$desired" || return 1
    fi
  done

  resolve_and_classify
  state="$(global_state)"
  if [[ "$action" == "on" ]]; then
    [[ "$state" == "ON" ]]
  else
    [[ "$state" == "OFF" ]]
  fi
}

make_or_refresh_backup() {
  local current_sha stored_sha state

  resolve_and_classify
  state="$(global_state)"
  [[ "$state" == "OFF" ]] || die "A clean unpatched executable is required before creating or refreshing the backup."

  current_sha="$(backup_sha "$BIN")"

  if [[ -f "$BACKUP" || -f "$BACKUP_SHA" ]]; then
    [[ -f "$BACKUP" && -f "$BACKUP_SHA" ]] ||
      die "Incomplete backup state. Keep/remove both backup files together after verifying BG3."

    verify_backup
    stored_sha="$(tr -d '[:space:]' < "$BACKUP_SHA")"

    if [[ "$current_sha" == "$stored_sha" ]]; then
      return 0
    fi

    is_clean_signed_binary ||
      die "The saved backup belongs to another build, but the current executable is not a clean vendor-signed binary. Verify BG3 first."

    ui_print "BG3 build changed; refreshing original executable backup..."
  else
    is_clean_signed_binary ||
      die "Refusing to create an original backup from an ad-hoc or invalidly signed executable. Verify BG3 first."

    ui_print "Creating original executable backup..."
  fi

  cp -p "$BIN" "$BACKUP"
  backup_sha "$BACKUP" > "$BACKUP_SHA"
  verify_backup
  ui_print "Backup: $BACKUP"
}

report_bundle_root() {
  local entry found=0

  ui_error ""
  ui_error "Unexpected content found in the app bundle root:"

  while IFS= read -r -d '' entry; do
    [[ "$entry" == "$APP/Contents" ]] && continue
    ui_error "  ${entry#"$APP/"}"
    found=1
  done < <(find "$APP" -mindepth 1 -maxdepth 1 -print0)

  if [[ "$found" -eq 0 ]]; then
    ui_error "  (no extra root entries were found)"
  fi
}

preflight_steam_bundle_root() {
  local entry unexpected=0
  [[ "$PLATFORM" == "Steam" ]] || return 0

  # AppleDouble and Finder metadata are safe to discard and can prevent
  # codesign from sealing an otherwise valid application bundle.
  while IFS= read -r -d '' entry; do
    ui_print "Removing macOS metadata: ${entry#"$APP/"}"
    rm -f "$entry" || return 1
  done < <(
    find "$APP" \
      -mindepth 1 \
      -maxdepth 1 \
      -type f \
      \( -name '._*' -o -name '.DS_Store' \) \
      -print0
  )

  while IFS= read -r -d '' entry; do
    [[ "$entry" == "$APP/Contents" ]] && continue

    if [[ "$unexpected" -eq 0 ]]; then
      ui_error "Unexpected content found in the Steam app bundle root:"
    fi
    ui_error "  ${entry#"$APP/"}"
    unexpected=1
  done < <(find "$APP" -mindepth 1 -maxdepth 1 -print0)

  if [[ "$unexpected" -ne 0 ]]; then
    ui_error ""
    ui_error "Refusing to patch because whole-app signing would fail."
    ui_error "Move or remove the entries above, then run the command again."
    return 1
  fi

  return 0
}

sign_bg3_app() {
  local attempt output nested

  for attempt in 1 2 3 4 5 6 7 8; do
    if output="$(
      codesign \
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

    if [[ "$output" == *"unsealed contents present in the bundle root"* ]]; then
      report_bundle_root
      return 1
    fi

    [[ "$output" == *"code object is not signed at all"* ]] || return 1

    nested="$(
      printf '%s\n' "$output" |
        sed -n 's/^In subcomponent: //p' |
        tail -n 1
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
    run_logged codesign --force --sign - "$nested" || return 1
  done

  ui_error "Too many unsigned nested code objects; aborting."
  return 1
}

resign() {
  if [[ "$PLATFORM" == "GOG" ]]; then
    ui_print "Re-signing GOG game executable ad-hoc while preserving signing metadata..."
    run_logged codesign \
      --force \
      --sign - \
      --preserve-metadata=identifier,entitlements,flags \
      "$BIN" || return 1

    ui_print "Verifying GOG executable signature..."
    run_logged codesign --verify --strict --verbose=2 "$BIN" || return 1
    return 0
  fi

  ui_print "Removing runtime logs from Contents/MacOS..."
  run_logged find "$APP/Contents/MacOS" \
    -maxdepth 1 \
    -type f \
    -name '*.log' \
    -delete || return 1

  ui_print "Re-signing BG3 ad-hoc while preserving signing metadata..."
  sign_bg3_app || return 1

  ui_print "Verifying signature..."
  run_logged codesign --verify --deep --strict --verbose=2 "$APP" || return 1
  return 0
}

cmd_status() {
  show_status
}

cmd_on() {
  local state

  ensure_not_running
  resolve_and_classify
  state="$(global_state)"

  case "$state" in
    ON)
      ui_print "Patch is already ON."
      return 0
      ;;
    OFF) ;;
    MIXED)
      [[ -f "$BACKUP" && -f "$BACKUP_SHA" ]] ||
        die "Patch is partially applied, but no complete original backup exists. Restore/verify BG3 first."
      ;;
    *)
      show_status_resolved
      die "Unknown build/signature. Not touching the executable."
      ;;
  esac

  if [[ "$state" == "OFF" ]]; then
    preflight_steam_bundle_root || return 1
    make_or_refresh_backup
  else
    verify_backup
  fi

  ui_print "Enabling achievement patch..."
  if ! patch_binary on; then
    ui_error "Patching failed; restoring original executable."
    cp -p "$BACKUP" "$BIN"
    return 1
  fi

  if ! resign; then
    ui_error "Signing failed; restoring original executable."
    cp -p "$BACKUP" "$BIN"

    if [[ "$PLATFORM" == "Steam" ]]; then
      ui_error "Attempting to restore a valid Steam app signature..."
      sign_bg3_app >/dev/null 2>&1 || true
    fi
    return 1
  fi

  ui_print ""
  ui_print "Achievement patch: ON"
}

cmd_off() {
  local state

  ensure_not_running
  resolve_and_classify
  state="$(global_state)"

  case "$state" in
    OFF)
      ui_print "Patch is already OFF."
      return 0
      ;;
    ON|MIXED) ;;
    *)
      show_status_resolved
      die "Unknown build/signature. Not touching the executable."
      ;;
  esac

  preflight_steam_bundle_root || return 1

  ui_print "Disabling achievement patch..."
  patch_binary off || die "Failed to restore stock achievement instructions."
  resign || die "Signing failed after restoring stock instructions."

  ui_print ""
  ui_print "Achievement patch: OFF"
}

cmd_restore() {
  ensure_not_running
  verify_backup

  ui_print "Restoring full original executable..."
  cp -p "$BACKUP" "$BIN"

  local expected actual
  expected="$(tr -d '[:space:]' < "$BACKUP_SHA")"
  actual="$(backup_sha "$BIN")"
  [[ "$actual" == "$expected" ]] || die "Restored executable checksum mismatch."

  if [[ "$PLATFORM" == "GOG" ]]; then
    ui_print "Verifying restored GOG executable signature..."
    if run_logged codesign --verify --strict --verbose=2 "$BIN"; then
      ui_print "Original executable restored and signature verifies."
      return 0
    fi

    ui_error "Original executable restored, but its signature did not verify."
    ui_error "Repair/verify the game installation through GOG Galaxy if BG3 does not launch."
    return 1
  fi

  preflight_steam_bundle_root || return 1
  ui_print "Re-signing restored Steam app..."
  if sign_bg3_app && run_logged codesign --verify --deep --strict --verbose=2 "$APP"; then
    ui_print "Original executable restored and app signature verifies."
    return 0
  fi

  ui_error "Original executable restored, but bundle verification failed."
  ui_error "Use Steam -> Properties -> Installed Files -> Verify integrity if BG3 does not launch."
  return 1
}

main() {
  local cmd="${1:-status}"

  case "$cmd" in
    -h|--help|help)
      usage
      return 0
      ;;
    status|on|off|restore) ;;
    *)
      usage >&2
      return 2
      ;;
  esac

  require_tools
  detect_game
  require_game

  case "$cmd" in
    status)  cmd_status ;;
    on)      cmd_on ;;
    off)     cmd_off ;;
    restore) cmd_restore ;;
  esac
}

main "$@"
