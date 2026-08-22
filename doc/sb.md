% SB(1) MiniOS Live Manual

## NAME
**sb** - A utility for managing MiniOS bundles.

## SYNOPSIS
`sb COMMAND [OPTIONS]`

## DESCRIPTION
**sb** manages active MiniOS bundles and dispatches to the converter and
session-capture tools.

## COMMANDS

* `activate BUNDLE`
  Mounts a readable bundle and adds it to the AUFS root union.

* `deactivate BUNDLE`
  Removes an active bundle from the AUFS root union and unmounts it.

* `list [--json]`
  Lists the bundles that actually compose the running AUFS or OverlayFS root,
  from lowest to highest priority. `list` keeps the historical tab-separated
  mountpoint/backing-file output. `list --json` emits one machine-readable
  result containing the union backend and ordered module records. A backing
  source that cannot be read without privilege is reported as `null` rather
  than hiding the active module.

* `next-boot [--json]`
  Lists the module composition selected by the current MiniOS boot rules. It
  reads the effective MiniOS data tree, its `modules/` tree, and an additional
  persistence `minios/modules/` tree only when `changes` is a separate mounted
  source. Current `bext`, `load`, and `noload` parameters are applied. Later
  sources replace an earlier module with the same basename before final layer
  ordering. JSON additionally reports whether a durable writable add target is
  available and whether each selected module can be removed.

* `next-boot add FILE [--json]`
  Adds a valid SquashFS module to durable next-boot storage. A separate durable
  writable persistence store is preferred; otherwise the effective MiniOS
  `modules/` directory is used only when it is itself durable and writable.
  The module must match the current `bext`, `load`, and `noload` rules. Copying
  is staged under a non-module name, validated, fsynced, and atomically
  published without replacing an existing module. Requires root.

* `next-boot remove NAME [--json]`
  Removes the currently selected user module with the exact basename from its
  durable writable `modules/` or persistence source. Base modules and modules
  on a read-only or volatile source are refused. Requires root.

* `inspect FILE [--json]`
  Lists a SquashFS module without extracting it. The command is rootless and
  does not require a running MiniOS live session. `--json` returns the absolute
  input path, compressed file size, entry count, and ordered relative paths.
  Invalid or ambiguous listings fail without publishing a JSON result.

* `savechanges`
  Runs **savechanges** with the remaining arguments.

* `rm DIR` or `rmdir DIR`
  Always refuses. It does not load MiniOS configuration, require root, unmount,
  or remove the supplied path.

* `conv SOURCE TARGET`
  If *SOURCE* is a directory, runs **dir2sb**; otherwise it runs **sb2dir**.
  The arguments are passed to that converter.

* `help`
  Displays the script usage help.

* `version`
  Displays version information of the script.

## USAGE NOTES

1. `list`, the read-only `next-boot` query, `inspect`, `help`, and `version`
   do not require root. `next-boot add`, `next-boot remove`, `activate`,
   `deactivate`, `savechanges`, and the compatibility `conv` dispatcher retain
   their privilege requirements.
2. Native MiniOS runtime state is read from `/run/initramfs/memory`. The Debian
   live-boot `/lib/live/mount` layout remains a compatibility fallback.
3. `activate` and `deactivate` are available only when `/` is actually mounted
   as AUFS. Merely having AUFS support in the kernel is not sufficient.
4. JSON query modes write no result to stdout when their authoritative state
   cannot be determined or inspected. An empty module list is emitted only
   after successful inspection.
5. The `conv` command checks that its first argument is readable before
   dispatching; provide both converter operands.

## EXAMPLES

- `sb activate example_bundle.sb`
- `sb deactivate example_bundle.sb`
- `sb list`
- `sb list --json`
- `sb next-boot`
- `sb next-boot --json`
- `sb next-boot add 50-extra.sb`
- `sb next-boot remove 50-extra.sb`
- `sb savechanges session.sb`
- `sb rm example_directory`
- `sb conv example_directory example.sb`
- `sb conv example.sb example_directory`

## SEE ALSO

[rmsbdir(1)](man:rmsbdir.1)

[sb2dir(1)](man:sb2dir.1)

[dir2sb(1)](man:dir2sb.1)
