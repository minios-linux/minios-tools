% DIR2SB(1) MiniOS Live Manual

## NAME
**dir2sb** - Transforms a directory into a compressed .sb module.

## SYNOPSIS
`dir2sb [OPTIONS]... SOURCE_DIRECTORY [TARGET_FILE.SB]`

## DESCRIPTION
Converts a directory into a compressed .sb module using mksquashfs.

## OPTIONS
* **-b, --bext EXT**:  Bundle extension. Defaults to "sb".
* **-c, --comp TYPE**: Compression type. Supported types: zstd (default), gzip, lzo, xz.
* **--help**: Display this help and exit.
* **--version**: Display version information and exit.

## ARGUMENTS
* **SOURCE_DIRECTORY**: The directory to convert to a module.  This argument is required.
* **TARGET_FILE.SB**: Optional. The name of the output module file. If omitted, `SOURCE_DIRECTORY.sb` (or with an appended 'x' if that file exists) is used.

## USAGE NOTES

1.  Requires root privileges.
2.  If `SOURCE_DIRECTORY` does not have a `.sb` extension and is not named `squashfs-root`, the directory's contents are packaged into the module, and `TARGET_FILE.SB` is **required**.
3.  If `TARGET_FILE.SB` is not specified, and `SOURCE_DIRECTORY` ends in `.sb` or is named `squashfs-root`, the original directory is replaced by the new module file.  Otherwise, `TARGET_FILE.SB` *must* be specified.
4.  Errors are reported if the source directory doesn't exist or the target file already exists.


## EXAMPLES
* Compress the "my-app" directory into my-app.sb:
   `dir2sb my-app`

* Compress the contents of the "my-app" directory into my-app.sb using xz compression:
   `dir2sb -c xz my-app my-app.sb`

* Create a module named "my-app.sb" from the contents of "my-app":
   `dir2sb my-app my-app.sb


## SEE ALSO

[rmsbdir(1)](man:rmsbdir.1)

[sb2dir(1)](man:sb2dir.1)

[sb(1)](man:sb.1)