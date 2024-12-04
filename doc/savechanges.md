% SAVECHANGES(1) MiniOS Live Manual 

## NAME
**savechanges** - Saves all changed files into a compressed filesystem bundle excluding certain predefined files.

## SYNOPSIS
`savechanges [OPTIONS] [target_file.sb] [changes_directory]`

## DESCRIPTION
Saves all changed files in a compressed filesystem bundle, excluding some predefined files such as /etc/mtab, temp & log files, empty directories, apt cache, and such.

## USAGE
1. Run the script with root privileges.
2. Specify the target file name with the desired bundle extension (default is `.sb`).
3. By default, `savechanges` will look at `/run/initramfs/memory/changes` for changes. If you want to specify a different directory of changes, you can do so with `[changes_directory]`
4. The resulting bundle will not include certain excluded files (like logs, temp files, apt cache, etc.). This is to prevent unnecessary or sensitive data from being included in the output module.


## OPTIONS
* `-c`, `--comp TYPE`  
   Compression type (zstd, gzip, lzo, xz). Default: zstd
* `-b`, `--bext EXT`  
   Bundle extension. Default: sb
* `--help`  
    display help and exit
* `--version`  
    display version information and exit


## EXAMPLES
* `savechanges mychanges.sb /path/to/changes`
* `savechanges -c lz4 mymodule.lz4.sb /path/to/changes`
* `savechanges -b sfs mymodule.sfs` (Will use default changes directory `/run/initramfs/memory/changes`)
* `savechanges mymodule.sb` (Will use default changes directory `/run/initramfs/memory/changes`)


Note: This script should be run as root. 

## SEE ALSO
[apt2sb(1)](man:apt2sb.1)

[script2sb(1)](man:script2sb.1)

[chroot2sb(1)](man:chroot2sb.1)