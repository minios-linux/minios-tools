# CHROOT2SB(1) MiniOS Live Manual

## NAME
**chroot2sb** - Creates a module of changes made within a chroot environment.

## SYNOPSIS
`chroot2sb [OPTIONS]`

## DESCRIPTION
chroot2sb takes changes made within a chroot environment and packages them into a module which can be used by the MiniOS.

## OPTIONS
* `-d, --directory DIR`  
    Copy contents of DIR to the root of the module

* `-n, --name NAME`  
    Use NAME as the filename for the module

* `-l, --level LEVEL`  
    Use LEVEL as the filter level

* `-c, --comp TYPE`  
    Compression type (zstd, gzip, lzo, xz). Default: zstd

* `-b, --bext EXT`  
    Bundle extension. Default: sb
  
* `--help`  
    Display this help and exit

* `--version`  
    Display version information and exit

## CREATING MODULES
1. Run the script with root privileges.
2. Optionally, you can specify the directory using the `-d` or `--directory DIR` option, where DIR is the path to the directory. The contents of this directory will be copied to the module before any operations.
3. Optionally, you can specify a filename for saving changes using the `-n` or `--name NAME` option, where NAME is the filename. If this option is not specified, the filename will be generated automatically based on the date and time.
4. Optionally, you can specify a filtering level using the `-l` or `--level LEVEL` option, where LEVEL is a numeric value. This option is used to filter overlay filesystem layers.
5. Optionally, specify the compression type using the `-c` or `--comp TYPE` option. Supported types are zstd, gzip, lzo, and xz. The default is zstd.
6. Optionally, change the bundle extension using the `-b` or `--bext EXT` option.  The default is sb.


## EXAMPLES
- `chroot2sb --level 03`
- `chroot2sb -n 06-chromium.sb -l 3`
- `chroot2sb -d /path/to/copy/contents`
- `chroot2sb -c lz4 -b mod`


## SEE ALSO

[script2sb(1)](man:script2sb.1)

[apt2sb(1)](man:apt2sb.1)