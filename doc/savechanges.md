% SAVECHANGES(1) MiniOS Live Manual 

## NAME
**savechanges** - Saves all changed files into a compressed filesystem bundle excluding certain predefined files.

## SYNOPSIS
`savechanges [target_file.sb] [changes_directory]`

## DESCRIPTION
Saves all changed files in a compressed filesystem bundle, excluding some predefined files such as /etc/mtab, temp & log files, empty directories, apt cache, and such.

## USAGE
1. Run the script with root privileges.
2. By default, savechanges will look at `/run/initramfs/memory/changes` for changes. If you want to specify a different directory of changes, you can do so with `[changes_directory]`
3. The script will package these changes into a `.sb` module. If no `[target_file.sb]` is specified, it will use a default naming scheme.
5. The resulting `.sb` module will not include certain excluded files (like logs, temp files, apt cache, etc.). This is to prevent unnecessary or sensitive data from being included in the output module.

## OPTIONS
* `--help`  
    display this help and exit

* `--version`  
    display version information and exit

## EXAMPLES
* `savechanges mychanges.sb /path/to/changes`
* `savechanges mymodule.sb` (Will use default changes directory `/run/initramfs/memory/changes`)

Note: This script should be run as root. 

## SEE ALSO
[apt2sb(1)](man:apt2sb.1)

[scr2sb(1)](man:scr2sb.1)

[upg2sb(1)](man:upg2sb.1)