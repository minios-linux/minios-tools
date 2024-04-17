% SB(1) MiniOS Live Manual

## NAME
**sb** - A utility for managing MiniOS bundles.

## SYNOPSIS
`sb COMMAND [OPTIONS]`

## DESCRIPTION
This script provides functionalities for managing MiniOS bundles. It supports commands to activate, deactivate, list active bundles, save changes to bundles, remove directories, and convert .sb files to directories or vice versa.

## COMMANDS

* `activate BUNDLE`
  Activates a MiniOS bundle by mounting the bundle to AUFS union.

* `deactivate BUNDLE`
  Deactivates an active MiniOS bundle by removing it from AUFS union.

* `list`
  Lists all active MiniOS bundles.
  
* `savechanges`
  Saves changes made at runtime to the bundle.

* `rm DIR` or `rmdir DIR`
  Removes an unpacked bundle directory.

* `conv PATH`
  Converts an `.sb` bundle to a directory or vice versa.

* `help`
  Displays the script usage help.

* `version`
  Displays version information of the script.

## USAGE NOTES

1. The script should be run as root.
2. Certain commands require AUFS support in the system's Linux kernel.
3. Always provide appropriate arguments based on the command. For instance, for `activate` and `deactivate` commands, bundle path should be provided.

## EXAMPLES

- `sb activate example_bundle.sb`
- `sb deactivate example_bundle.sb`
- `sb list`
- `sb savechanges`
- `sb rm example_directory`
- `sb conv example_directory_or_file.sb`

## SEE ALSO

[rmsbdir(1)](man:rmsbdir.1)

[sb2dir(1)](man:sb2dir.1)

[dir2sb(1)](man:dir2sb.1)
