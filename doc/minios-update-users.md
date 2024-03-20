% MINIOS-UPDATE-USERS(1) MiniOS Live Manual

## NAME

**minios-update-users** - Shell script to build common users files based on all bundles.

## SYNOPSIS

`minios-update-users [OPTIONS] BUNDLES_LOCATION [CHANGES_LOCATION]`

## DESCRIPTION

This script builds common user files (passwd, shadow, group, gshadow) from bundles. It must be run with root privileges.

## OPTIONS

* `BUNDLES_LOCATION`  
    The location of bundles mount points. This is a required positional argument.
  
* `CHANGES_LOCATION`  
    Optional. The location to store any changes made by the script.

## RUNNING THE SCRIPT

1. Run the script with root privileges using the sudo command.
2. Provide the location of the bundles mount points as the first argument.
3. Optionally, you can specify a changes location as the second argument.

## EXAMPLES

- `minios-update-users /run/initramfs/memory/bundles`
- `minios-update-users /run/initramfs/memory/bundles /run/initramfs/memory/changes`

## NOTES

- If the script is launched without providing `BUNDLES_LOCATION`, it will display a usage guide and exit.
- An error message will be displayed and the script will exit if it's not launched as root.
- Logs for the script can be found in the directory `/var/log/minios`.
