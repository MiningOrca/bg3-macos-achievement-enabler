# BG3 macOS Achievement Enabler

Enables Steam achievements in modded Baldur's Gate 3 on Apple Silicon Macs.

The script patches the achievement-specific mod checks in the ARM64 game executable. It does not disable mod detection globally.

No Script Extender or NativeModLoader required.

## Requirements

- Baldur's Gate 3 for macOS
- Apple Silicon (ARM64)
- Steam version
- A supported game build (4.1.1.7398727)

The patch is build-specific. Before modifying the executable, the script verifies the expected instruction bytes at each patch location and refuses to continue if they do not match.
## Usage

Download the script and make it executable:

```bash
chmod +x bg3-achievements-patch.sh
```

Check current state:

```bash
./bg3-achievements-patch.sh status
```

Enable achievements with mods:

```bash
./bg3-achievements-patch.sh on
```

Disable the patch:

```bash
./bg3-achievements-patch.sh off
```

Restore the original executable:

```bash
./bg3-achievements-patch.sh restore
```

Baldur's Gate 3 must be closed before applying or removing the patch.

## What it does

BG3 checks whether all loaded modules are standard modules before processing some achievement events.

This script bypasses only the achievement-related checks:

- `esv::AchievementManager::UnlockAchievement`
- `esv::AchievementManager::IncreaseAchievementCounter`
- `esv::OsirisGameFunctions::UnlockAchievement`

`ls::ModuleShortDesc::IsStandardModule()` itself is left unchanged.

The script creates a backup of the original executable before the first modification and re-signs the application with an ad-hoc signature after patching.

## Updating BG3

Game updates may change the executable and invalidate the patch offsets.

If the expected instruction bytes do not match, the script will refuse to modify the executable.

After a BG3 update, wait for the offsets to be verified for the new build.

## Uninstall

Run:

```bash
./bg3-achievements-patch.sh restore
```

or verify the game files through Steam.

## License

MIT
