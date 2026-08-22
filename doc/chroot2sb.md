# CHROOT2SB(1) MiniOS Live Manual

## NAME
**chroot2sb** - Creates a module from changes made in an interactive chroot.

## SYNOPSIS
`chroot2sb [OPTIONS]`

`chroot2sb prepare [OPTIONS] [--json]`

`chroot2sb shell SESSION_ID`

`chroot2sb finish SESSION_ID [--json]`

`chroot2sb cancel SESSION_ID [--json]`

## DESCRIPTION
**chroot2sb** starts an interactive chroot over the active MiniOS modules and
packages its writable changes after the chroot exits successfully. It requires root
and a supported MiniOS live session.

## INTERACTIVE LIFECYCLE

The legacy form owns the terminal and completes the whole build in one process.
GUI frontends use the split lifecycle instead:

1. `prepare` creates a protected root-owned build session and returns an opaque
   `session_id`. With `--json`, stdout contains only phase/result NDJSON.
2. `shell SESSION_ID` verifies the session and invoking `PKEXEC_UID`, locks it,
   then runs the chroot shell using the caller's current PTY.
3. `finish SESSION_ID` captures the same verified workspace through
   `savechanges`, cleans mounts and workspace, then reports success. `--json`
   returns a final `chroot2sb` result only after cleanup.
4. `cancel SESSION_ID` safely discards a non-captured session.

Sessions live below `/run/minios-tools/chroot2sb` with root-only permissions.
The state records the invoking uid plus the private workspace device/inode; each
operation revalidates that identity and is serialized by `flock`. A failed
cleanup after successful capture leaves the session in `captured` state so
`finish` can be retried without rebuilding or overwriting the module.

## OPTIONS
* `-d, --directory DIR`  
    Copy all contents of DIR, including dotfiles, to the module root. An empty
    directory is accepted.

* `-n, --name NAME`  
    Use NAME as the filename for the module

* `-l, --level LEVEL`  
    Use LEVEL as the filter level

* `-c, --comp TYPE`  
    Compression type (zstd, gzip, lzo, xz). Default: zstd

* `-b, --bext EXT`
    Bundle extension. Default: sb

* `--json`
    Machine-readable mode for `prepare`, `finish`, and `cancel`. Diagnostics
    remain on stderr.

* `--help`  
    Display this help and exit

* `--version`  
    Display version information and exit

## CREATING MODULES
1. Run the script with root privileges.
2. Optionally, specify a directory with `-d` or `--directory DIR`. All contents
   are copied before the chroot starts.
3. Optionally, you can specify a filename for saving changes using the `-n` or `--name NAME` option, where NAME is the filename. If this option is not specified, the filename will be generated automatically based on the date and time.
4. Optionally, you can specify a filtering level using the `-l` or `--level LEVEL` option, where LEVEL is a numeric value. This option is used to filter overlay filesystem layers.
5. Optionally, specify the compression type using the `-c` or `--comp TYPE` option. Supported types are zstd, gzip, lzo, and xz. The default is zstd.
6. Optionally, change the bundle extension using the `-b` or `--bext EXT` option.  The default is sb.

## EXIT STATUS

Help and version queries return 0. Usage, setup, and interactive chroot failures
return non-zero. A failed chroot creates no module.


## EXAMPLES
- `chroot2sb --level 03`
- `chroot2sb -n 06-chromium.sb -l 3`
- `chroot2sb -d /path/to/copy/contents`
- `chroot2sb -c xz -b mod`


## SEE ALSO

[script2sb(1)](man:script2sb.1)

[apt2sb(1)](man:apt2sb.1)
