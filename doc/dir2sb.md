% DIR2SB(1) MiniOS Live Manual

## NAME
**dir2sb** - Convert a directory tree into a compressed .sb module.

## SYNOPSIS
`dir2sb [OPTIONS] SOURCE_DIRECTORY TARGET`

## DESCRIPTION
**dir2sb** packages the contents of *SOURCE_DIRECTORY* into a compressed
SquashFS module with **mksquashfs**. The contents of the source become the
module root; the module does not gain an extra top-level directory named after
the source. The command does not require a particular filename extension;
**.sb** is the usual extension.

The conversion is rootless and non-destructive by default. The source tree is
opened before compression, so replacing its pathname cannot redirect the
compressor. An existing *TARGET* is never overwritten. The module is built in
a mode-0700 private workspace on the destination filesystem and published
atomically without replacement. Cleanup verifies the workspace identity;
publication failures remove only the converter-owned output inode.

## OPTIONS
* **-c, --comp** *TYPE*: Compression type: zstd (default), gzip, lzo, lz4, xz.
* **-b, --bext** *EXT*: Bundle extension displayed in help text (default: sb).
* **--keep-ownership**: Preserve the source ownership instead of normalizing it
  to root. Requires privilege.
* **--allow-special**: Permit device nodes, sockets, and FIFOs in the source.
  Requires privilege.
* **--json**: Write pure NDJSON phase objects for prepare, compress, verify,
  publish, and complete, followed by a JSON result with the output path, device,
  inode, size, SHA-256 digest, and compression.
* **--no-color**: Disable colored diagnostics.
* **--help**: Display help and exit.
* **--version**: Display version information and exit.

## ARGUMENTS
* **SOURCE_DIRECTORY**: The directory whose contents become the module root.
  Required.
* **TARGET**: The output module path. It must not already exist; its parent
  directory must already exist. Required.

## EXIT STATUS
* **0**: Success.
* **1**: Usage, option, privilege, or required-tool error.
* **2**: The source is not a directory, or the target directory is missing.
* **3**: Special-object scanning or source-tree validation failed.
* **4**: The target already exists, or private staging cannot be reserved.
* **5**: The module could not be built, staged, or published.
* **130**: Interrupted by SIGINT or SIGTERM.

## USAGE NOTES
1. Root privileges are not required for an ordinary rootless conversion.
   Ownership is normalized to root inside the module unless **--keep-ownership**
   is given.
2. Device nodes, sockets, and FIFOs cannot round-trip rootlessly and are
   rejected unless **--allow-special** is given with sufficient privilege.
3. Regular files, permission bits, symbolic links, empty directories, and user
   extended attributes are supported by the converter pair when the installed
   SquashFS tools and destination filesystem support them.
4. The staged module must pass **unsquashfs -s** before publication. A tool
   process group that leaves descendants is terminated and treated as failure.

## OUTPUT

Without **--json**, a successful conversion writes `Created: PATH` to standard
output. Frontend diagnostics use the `E:` prefix on standard error; raw
**mksquashfs** diagnostics may precede them on failure. Colors are used only
when enabled.

File publication uses `renameat2(RENAME_NOREPLACE)` where available. If that
operation is unavailable for a regular file, **dir2sb** uses an atomic
no-replace hard-link publication fallback. It never replaces an existing path.

## EXAMPLES
* Package the contents of `my-app` into `my-app.sb`:
   `dir2sb my-app my-app.sb`

* Package with xz compression and a machine-readable result:
   `dir2sb --comp xz --json my-app my-app.sb`

## SEE ALSO

[sb2dir(1)](man:sb2dir.1)

[sb(1)](man:sb.1)
