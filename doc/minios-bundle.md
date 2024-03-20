% MINIOS-BUNDLE(1) MiniOS Live Manual

## NAME
**minios-bundle** - A script for managing MiniOS bundles.

## SYNOPSIS
`minios-bundle [OPTION]... [FILE]...`

## DESCRIPTION
A script for managing and controlling MiniOS bundles. It allows users to activate, deactivate, list active bundles, and save changes.

## OPTIONS
* `activate FILE`  
    Activate a MiniOS bundle.

* `deactivate FILE`  
    Deactivate a MiniOS bundle.

* `list`  
    List active MiniOS bundles.

* `--help`  
    Display this help and exit.

* `--version`  
    Display version information and exit.

## FILE
The path to the MiniOS bundle file.

## EXAMPLES
- `minios-bundle activate file.sb`
- `minios-bundle deactivate file.sb`
- `minios-bundle list`

## NOTES
- To run this script, the Linux kernel must support AUFS.
- When activating or deactivating a bundle, the script automatically fixes system-related issues.
- After activating or deactivating a bundle, the XFCE menu is reloaded if XFCE is running.

## SEE ALSO
[slax.org - Tomas M](http://www.slax.org/)
[minios.dev - crims0n](https://minios.dev)
[losetup(8)](https://man7.org/linux/man-pages/man8/losetup.8.html)
[mount(8)](https://man7.org/linux/man-pages/man8/mount.8.html)
[umount(8)](https://man7.org/linux/man-pages/man8/umount.8.html)
[df(1)](https://man7.org/linux/man-pages/man1/df.1.html)
[cat(1)](https://man7.org/linux/man-pages/man1/cat.1.html)
[basename(1)](https://man7.org/linux/man-pages/man1/basename.1.html)
[ls(1)](https://man7.org/linux/man-pages/man1/ls.1.html)

