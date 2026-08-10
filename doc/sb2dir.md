% SB2DIR(1) MiniOS Live Manual

## NAME
**sb2dir** - Convert a compressed .sb module into a directory tree.

## SYNOPSIS
`sb2dir [OPTIONS] SOURCE.sb TARGET_DIRECTORY`

## DESCRIPTION
**sb2dir** extracts the SquashFS **.sb** module *SOURCE.sb* into
*TARGET_DIRECTORY* with **unsquashfs**.

The extraction is rootless and non-destructive by default. The source module is
never modified, an existing *TARGET_DIRECTORY* is never overwritten, and the
tree is extracted into a private staging directory on the destination
filesystem and then published atomically with no-replace semantics. The
security-critical digest and publication run in the separate
**minios_convert_engine.py** helper. Unlike earlier versions, **sb2dir** never
renames or deletes the source and never overmounts the target with tmpfs.

## OPTIONS
* **--keep-ownership**: Restore the module ownership instead of extracting as
  the invoking user. Requires privilege.
* **--allow-special**: Permit device nodes, sockets, and FIFOs in the module.
  Requires privilege.
* **--json**: Emit stable `P:` phase events and a machine-readable JSON result
  containing the output path, device, inode, entry count, and the source
  module SHA-256 digest.
* **--no-color**: Disable colored diagnostics.
* **--help**: Display help and exit.
* **--version**: Display version information and exit.

## ARGUMENTS
* **SOURCE.sb**: The readable module to extract. It is never modified. Required.
* **TARGET_DIRECTORY**: The directory to create. It must not already exist. Its
  parent must exist. Required.

## EXIT STATUS
* **0**: Success.
* **1**: Usage or option error.
* **2**: The source module is missing or unreadable, or the target parent is
  missing.
* **3**: The module contains special files and no privileged mode was requested.
* **4**: The target already exists.
* **5**: The module could not be extracted or published.
* **130**: Cancelled by SIGINT or SIGTERM; no output is left behind.

## USAGE NOTES
1. Root privileges are not required for an ordinary rootless extraction. The
   tree is owned by the invoking user unless **--keep-ownership** is given.
2. Device nodes, sockets, and FIFOs cannot be recreated rootlessly and are
   rejected unless **--allow-special** is given with sufficient privilege.
3. The target directory must not exist; it is created atomically from a private
   staging directory.

## EXAMPLES
* Extract `example.sb` into a new `example` directory:
   `sb2dir example.sb example`

* Extract with a machine-readable result:
   `sb2dir --json example.sb example`

## SEE ALSO

[rmsbdir(1)](man:rmsbdir.1)

[dir2sb(1)](man:dir2sb.1)

[sb(1)](man:sb.1)
