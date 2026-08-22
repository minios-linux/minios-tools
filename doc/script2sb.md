% SCRIPT2SB(1) MiniOS Live Manual

## NAME
**script2sb** - Packages a module from changes made by an installation script. It requires root
and a supported MiniOS live session.

## SYNOPSIS
`script2sb [OPTIONS] --script FILE`

## DESCRIPTION
Packages a module from changes made by an installation script.

## OPTIONS
* `-d, --directory DIR`  
    Copy all contents of DIR, including dotfiles, to the module root. An empty
    directory is accepted.

* `-n, --name NAME`  
    Use NAME as the filename for the module

* `-l, --level LEVEL`  
    Use LEVEL as the filter level

* `-s, --script FILE`  
    Use FILE as the installation script

* `-c, --comp TYPE`  
    Compression type (zstd, gzip, lzo, xz). Default: zstd

* `-b, --bext EXT`  
    Bundle extension. Default: sb

* `--json`
    Emit pure NDJSON on stdout for machine consumers. The stream contains
    `prepare`, optional `seed`, `script`, `capture`, and `complete` phase
    events, followed by one final `script2sb` result. Installation-script and
    diagnostic output is written to stderr. A failed run emits no final result.

* `--help`  
    Display this help and exit

* `--version`  
    Display version information and exit

## CREATING MODULES
1. Run the script with root privileges using the sudo command.
2. Specify the installation script using the `-s` or `--script FILE` option, where FILE is the path to the installation script.
3. Optionally, specify a directory with `-d` or `--directory DIR`. All contents
   are copied before the installation script runs.
4. Optionally, you can specify a filename for saving changes using the `-n` or `--name NAME` option, where NAME is the filename. If this option is not specified, the filename will be generated automatically based on the name of the installation script.
5. Optionally, you can specify a filtering level using the `-l` or `--level LEVEL` option, where LEVEL is a numeric value. This option is used to filter overlay filesystem layers.
6. Optionally, specify the compression type using the `-c` or `--comp TYPE` option. Supported types are zstd, gzip, lzo, and xz. The default is zstd.
7. Optionally, change the bundle extension using the `-b` or `--bext EXT` option.  The default is sb.

If you do not specify the `--directory`, `--name`, and `--level` options, they are not used. If you do not specify the `--name` option, then a filename for saving changes is generated automatically based on the name of the installation script.

The filtering level is used to filter overlay filesystem layers. For example,
with `-l 3`, layers numbered higher than 3 are filtered out and module assembly
uses modules numbered 00 through 03.

The script specified with `-s` or `--script` must be a regular file. It is
copied to a temporary path inside the chroot, made executable, run over the
overlay filesystem, and removed before the module is saved.

When launched through `pkexec`, the selected script and optional seed directory
are read with the invoking user's `PKEXEC_UID`. The seed copy accepts regular
files, directories, and symbolic links and refuses special files; destination
paths are traversed without following symlink components.

## MACHINE OUTPUT

With `--json`, stdout is reserved for NDJSON. The final result has
`tool=script2sb`, operation `create`, and reports the output path, compressed and
uncompressed sizes, entry count, SHA-256, compression, and whether a seed
directory was supplied. The underlying `savechanges` protocol is internal and
is not forwarded to the caller. A final result is emitted only after the build
union and temporary workspace have been cleaned successfully.

## EXIT STATUS

Help and version queries return 0. Usage, setup, and installation-script
failures return non-zero. A failed installation script creates no module.

## EXAMPLES
- `script2sb -s /path/to/install_script.sh`
- `script2sb --level 03 --script /path/to/install_script.sh`
- `script2sb -s /path/to/install_script.sh -n 06-chromium.sb -l 3`
- `script2sb -s /path/to/install_script.sh -c lzo -b bundle`

## SEE ALSO

[apt2sb(1)](man:apt2sb.1)

[chroot2sb(1)](man:chroot2sb.1)
