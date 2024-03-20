% MINIOS-UPDATE-CACHE(1) MiniOS Live Manual

## NAME
**minios-update-cache** - Updates cache for all MiniOS bundles in a specified location.

## SYNOPSIS
`minios-update-cache [BUNDLE-MOUNT-POINTS-LOCATION]`

## DESCRIPTION
Updates cache for all bundles in the specified location.

## OPTIONS
This script does not accept any options. Instead, it accepts a single argument which is the location of the bundle mount points.

## UPDATING CACHE
1. Run the script with root privileges using the sudo command.
2. Specify the location of the bundle mount points as an argument. E.g., `/run/initramfs/memory/bundles`

## EXAMPLES
- `minios-update-cache /run/initramfs/memory/bundles`
