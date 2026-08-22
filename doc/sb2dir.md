% SB2DIR(1) MiniOS Live Manual

## NAME
**sb2dir** - Convert a compressed .sb module into a directory tree.

## SYNOPSIS
`sb2dir [OPTIONS] SOURCE_MODULE TARGET_DIRECTORY`

## DESCRIPTION
**sb2dir** extracts *SOURCE_MODULE*, a SquashFS module, into
*TARGET_DIRECTORY* with **unsquashfs**. The command does not require a
particular source filename extension; **.sb** is the usual extension.

The extraction is rootless and non-destructive by default. The source module is
opened before extraction and hashing, so replacing its pathname cannot redirect
either operation. The source is never modified. An existing *TARGET_DIRECTORY*
is never overwritten. The tree is extracted into a private staging directory on
the destination filesystem and then published atomically without replacement.
Cleanup verifies the private workspace identity; publication failures remove
only the converter-owned output inode.

## OPTIONS
* **-b, --bext** *EXT*: Bundle extension displayed in help text (default: sb).
* **--keep-ownership**: Declare that archive ownership may be restored. Requires
  privilege; actual ownership follows **unsquashfs** and caller privileges.
* **--allow-special**: Permit device nodes, sockets, and FIFOs in the module.
  Requires privilege.
* **--json**: Write pure NDJSON phase objects for prepare, extract, publish, and
  complete, followed by a JSON result with the output path, device, inode, entry
  count, source size, and source SHA-256 digest.
* **--no-color**: Disable colored diagnostics.
* **--help**: Display help and exit.
* **--version**: Display version information and exit.

## ARGUMENTS
* **SOURCE_MODULE**: The readable module to extract. It is never modified.
  Required.
* **TARGET_DIRECTORY**: The directory to create. It must not already exist. Its
  parent must exist. Required.

## EXIT STATUS
* **0**: Success.
* **1**: Usage, option, privilege, or required-tool error.
* **2**: The source module is missing or unreadable, or the target parent is
  missing.
* **3**: The module contains special files and no privileged mode was requested.
* **4**: The target already exists, or private staging cannot be reserved.
* **5**: The module could not be extracted, staged, or published.
* **130**: Interrupted by SIGINT or SIGTERM.

## USAGE NOTES
1. Root privileges are not required for ordinary extraction. Ownership follows
   **unsquashfs** and caller privileges; **--keep-ownership** is an explicit
   privileged compatibility mode and does not add another extractor option.
   Rootless extraction restores only `user.*` extended attributes, so root-only
   SquashFS metadata such as `trusted.overlay.*` does not turn an otherwise
   valid MiniOS module into an extraction failure. Privileged extraction keeps
   the normal full-xattr **unsquashfs** behavior.
2. Device nodes, sockets, and FIFOs cannot be recreated rootlessly and are
   rejected unless **--allow-special** is given with sufficient privilege.
3. The target directory must not exist; it is created atomically from a private
   staging directory.

## OUTPUT AND PUBLICATION

Without **--json**, a successful extraction writes `Created: PATH` to standard
output. Frontend diagnostics use the `E:` prefix on standard error; raw
**unsquashfs** diagnostics may precede them on failure. Colors are used only
when enabled.

Any non-zero exit from **unsquashfs** fails the extraction. The private staging
directory is removed and no target is published. A tool process group that
leaves descendants is terminated and treated as failure.

Directory publication requires atomic `renameat2(RENAME_NOREPLACE)`. When a C
library wrapper is unavailable, including on Bionic, **sb2dir** uses the
supported direct system call. On a kernel, filesystem, or architecture where
atomic no-replace directory publication is unavailable, it fails closed rather
than using a non-atomic fallback.

## EXAMPLES
* Extract `example.sb` into a new `example` directory:
   `sb2dir example.sb example`

* Extract with a machine-readable result:
   `sb2dir --json example.sb example`

## SEE ALSO

[dir2sb(1)](man:dir2sb.1)

[sb(1)](man:sb.1)
