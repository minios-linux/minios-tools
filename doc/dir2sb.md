% DIR2SB(1) MiniOS Live Manual

## NAME
**dir2sb** - Convert a directory tree into a compressed .sb module.

## SYNOPSIS
`dir2sb [OPTIONS] SOURCE_DIRECTORY TARGET.sb`

## DESCRIPTION
**dir2sb** packages the contents of *SOURCE_DIRECTORY* into a compressed
SquashFS **.sb** module with **mksquashfs**. The contents of the source become
the module root, so the module never gains an accidental extra top-level
directory named after the source.

The conversion is rootless and non-destructive by default. The source tree is
never modified, an existing *TARGET* is never overwritten, and the module is
written to a private staging file on the destination filesystem and then
published atomically with no-replace semantics. The security-critical scan,
digest, and publication run in the separate **minios_convert_engine.py** helper.

## OPTIONS
* **-c, --comp** *TYPE*: Compression type: zstd (default), gzip, lzo, lz4, xz.
* **-b, --bext** *EXT*: Bundle extension used in help text (default: sb).
* **--keep-ownership**: Preserve the source ownership instead of normalizing it
  to root. Requires privilege.
* **--allow-special**: Permit device nodes, sockets, and FIFOs in the source.
  Requires privilege.
* **--json**: Emit stable `P:` phase events and a machine-readable JSON result
  containing the output path, device, inode, size, and SHA-256 digest.
* **--no-color**: Disable colored diagnostics.
* **--help**: Display help and exit.
* **--version**: Display version information and exit.

## ARGUMENTS
* **SOURCE_DIRECTORY**: The directory whose contents become the module root.
  Required.
* **TARGET.sb**: The output module path. It must not already exist. Required.

## EXIT STATUS
* **0**: Success.
* **1**: Usage or option error.
* **2**: The source is not a directory, or the target directory is missing.
* **3**: The source contains special files and no privileged mode was requested.
* **4**: The target already exists.
* **5**: The module could not be built or published.
* **130**: Cancelled by SIGINT or SIGTERM; no output is left behind.

## USAGE NOTES
1. Root privileges are not required for an ordinary rootless conversion.
   Ownership is normalized to root inside the module unless **--keep-ownership**
   is given.
2. Device nodes, sockets, and FIFOs cannot round-trip rootlessly and are
   rejected unless **--allow-special** is given with sufficient privilege.
3. Regular files, permission bits, symbolic links, empty directories, and user
   extended attributes round-trip through **dir2sb** and **sb2dir**.

## EXAMPLES
* Package the contents of `my-app` into `my-app.sb`:
   `dir2sb my-app my-app.sb`

* Package with xz compression and a machine-readable result:
   `dir2sb --comp xz --json my-app my-app.sb`

## SEE ALSO

[rmsbdir(1)](man:rmsbdir.1)

[sb2dir(1)](man:sb2dir.1)

[sb(1)](man:sb.1)
