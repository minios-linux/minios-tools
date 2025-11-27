% MINIOS-SETUP-KEYBOARD(1) MiniOS Live Manual

## NAME
**minios-setup-keyboard** - Configure keyboard layout in desktop environment

## SYNOPSIS
`minios-setup-keyboard`

## DESCRIPTION
This script applies keyboard layout settings to XFCE and Fluxbox/Openbox desktop environments based on system keyboard configuration from `/etc/default/keyboard`.

The script runs as user at desktop startup, after live-config component `0150-keyboard-configuration` has processed system-level configuration.

## CONFIGURATION

The script reads configuration from `/etc/default/keyboard`, which contains the following variables:

* `XKBMODEL` - Keyboard model (e.g., pc105)
* `XKBLAYOUT` - Keyboard layout(s) (e.g., us,ru)
* `XKBVARIANT` - Keyboard variant(s)
* `XKBOPTIONS` - Keyboard options (e.g., grp:alt_shift_toggle)
* `BACKSPACE` - Backspace behavior (console-specific)

If `XKBOPTIONS` is not set, the script defaults to `grp:alt_shift_toggle` for layout switching.

## BEHAVIOR

The script:

1. Checks if it has already run in the current session (using marker file)
2. Reads keyboard configuration from `/etc/default/keyboard`
3. Detects the running desktop environment (XFCE or Fluxbox/Openbox)
4. Applies keyboard settings using:
   - `setxkbmap` for immediate X11 configuration
   - `xfconf-query` for XFCE persistent settings
   - Configuration files for Fluxbox/Openbox

The script only runs once per session to avoid repeatedly applying the same configuration.

## FILES

* `/etc/default/keyboard` - System keyboard configuration file
* `~/.config/minios/keyboard-configured` - Marker file to prevent multiple runs

## DESKTOP ENVIRONMENTS

**XFCE:**
Configures keyboard settings via xfconf, including:
- Keyboard model
- Keyboard layout(s)
- Keyboard variant(s)
- Layout switching options

**Fluxbox/Openbox:**
Saves keyboard layout to configuration files:
- `~/.fluxbox/kblayout`
- `~/.config/openbox/kblayout`

## EXAMPLES

The script is typically run automatically at desktop startup via autostart mechanisms.

Manual execution:
```
minios-setup-keyboard
```

## SEE ALSO
**setxkbmap(1)**, **keyboard(5)**, **xfconf-query(1)**

## AUTHORS
Written by MiniOS developers.
