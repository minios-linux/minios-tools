% MINIOS-VIRTUAL-RESOLUTION(1) MiniOS Live Manual

## NAME
**minios-virtual-resolution** - Automatically adjust screen resolution in virtual machines

## SYNOPSIS
`minios-virtual-resolution`

## DESCRIPTION
This script automatically adjusts the screen resolution when running MiniOS in a virtual machine environment where guest utilities are not available or not functioning properly.

The script detects if the system is running in a virtual machine and applies a specified screen resolution if guest utilities (like VirtualBox Guest Additions, VMware Tools, etc.) are not active.

## KERNEL PARAMETERS

* `virtres=WIDTHxHEIGHT` - Specifies the desired screen resolution (e.g., virtres=1920x1080)
  If not specified, defaults to 1280x800

* `novirtres` - Disables automatic resolution adjustment
  When this parameter is present, the script exits without making any changes

## BEHAVIOR

The script performs the following checks:

1. Verifies it hasn't already run in the current session
2. Checks for the `novirtres` kernel parameter
3. Detects if running in a virtual environment
4. Checks if guest utilities are active
5. If in VM without guest utilities, applies the specified resolution using `xrandr`

## VIRTUAL ENVIRONMENTS

The script detects the following virtual machine platforms:

* VirtualBox
* VMware
* KVM/QEMU
* Xen
* Hyper-V
* Bochs

## GUEST UTILITIES

The script checks for the following guest utility processes:

* **VirtualBox:** VBoxClient (display, seamless)
* **VMware:** vmtoolsd, vmware-user
* **QEMU/KVM:** spice-vdagent, qemu-ga
* **Hyper-V:** hv_kvp_daemon, hypervvssd
* **Xen:** xenstore

If any of these are detected and running, the script assumes guest utilities are managing display resolution and exits without making changes.

## FILES

* `~/.config/minios/virtual-resolution-configured` - Marker file to prevent multiple runs

## EXAMPLES

Set resolution to 1920x1080 via kernel parameter:
```
virtres=1920x1080
```

Disable automatic resolution adjustment:
```
novirtres
```

Default resolution (if no parameter specified):
```
1280x800
```

## USAGE NOTES

1. The script runs once per user session at desktop startup
2. Resolution changes only apply in virtual machines without active guest utilities
3. It's recommended to install proper guest utilities for better integration
4. The script requires `xrandr` to be available

## SEE ALSO
**xrandr(1)**

## AUTHORS
Written by MiniOS developers.
