% APT2SB(1) MiniOS Live Manual

## NAME
**apt2sb** - Converts repository packages into modules.

## SYNOPSIS
`apt2sb install [OPTIONS] PACKAGE1 [PACKAGE2] [...]`

`apt2sb upgrade [OPTIONS]`

`apt2sb --help|--version`

## DESCRIPTION
Installs packages from repositories and packages them into a module. Package
installation and upgrade require root and a supported MiniOS live session.

## COMMANDS
* `install`
    Install package(s).

* `upgrade`  
    Upgrade installed packages.

## OPTIONS
* `-n, --name NAME`  
    Use NAME as the filename for the module instead of PACKAGE1.sb

* `-l, --level LEVEL`  
    Use LEVEL as the filter level

* `-c, --comp TYPE`  
    Compression type (zstd, gzip, lzo, lz4, xz). Default: zstd

* `-b, --bext EXT`  
    Bundle extension. Default: sb

* `--json`
    Emit pure NDJSON on stdout for machine consumers. The stream contains
    `prepare`, `update`, `packages`, `capture`, and `complete` phase events,
    followed by one final `apt2sb` result. A failed run emits no final result.
    APT and diagnostic output is written to stderr in this mode.

* `--help`  
    Display help and exit

* `--version`  
    Display version information and exit

## APT OPTIONS

For `install` and `upgrade` commands:

* `-y, --yes`
    Automatic yes to prompts.

* `--allow-downgrades`
    Allow downgrades of packages.

* `--install-recommends`
    Consider recommended packages as a dependency for installing.

* `--install-suggests`
    Consider suggested packages as a dependency for installing.

* `--no-install-recommends`
    Do not consider recommended packages as a dependency for installing.

* `--no-install-suggests`
    Do not consider suggested packages as a dependency for installing.

For `install` only:

* `--target-release RELEASE`
    Use RELEASE as the APT default release for `install`. The `-t` alias is also
    accepted. The option is rejected for `upgrade`.


## CREATING MODULES

### Installing Packages:
1. Run the script with root privileges using the `sudo` command.
2. Use the `install` command followed by one or more package names that you wish to convert into modules. The script supports installing both packages from the repository and local packages. To install local packages, simply include the path to the local .deb file as an argument.
3. If you want to specify a different filename for the module, use the `-n, --name NAME` option, where `NAME` stands for the preferred filename. If not provided, the filename will be automatically derived from the name of the first package.
4. You can define the filter level using the `-l, --level LEVEL` option, where `LEVEL` is a numerical value.
5. Use the  `-c, --comp TYPE` option to set the compression type. Supported types are: zstd, gzip, lzo, lz4, xz. The default is zstd.
6. Use the `-b, --bext EXT` option to change the bundle extension. The default is sb.
7. If you want to accept all confirmations automatically, use the `-y` or `--yes` option.
8. Use other APT options according to your package dependency requirements.
9. The script will install the packages, convert them to a module, and save it with the specified filename, filter level, compression type, and extension.

### Upgrading Installed Packages:
1. Run the script with root privileges and the `upgrade` command to upgrade all installed packages.
2. Use the `-y` or `--yes` option if you want to accept all confirmations automatically.
3. Without `--name`, the default target is `upgrade.sb`.
4. Use other APT options as needed, but not `--target-release`.

## MACHINE OUTPUT

With `--json`, stdout is reserved for NDJSON. The final result has
`tool=apt2sb`, operation `install` or `upgrade`, and reports the output path,
compressed and uncompressed sizes, entry count, SHA-256, compression, and the
number of requested package operands. The underlying `savechanges` protocol is
internal and is not forwarded to the caller.

When `apt2sb` is launched through `pkexec`, local package files are opened with
the invoking user's `PKEXEC_UID` before being copied into the private build
union. The privileged wrapper therefore cannot use a local `.deb` that the
invoking user cannot read.

## EXIT STATUS

Help and version queries return 0. Usage, setup, APT, capture, and cleanup
failures return non-zero. A failed machine run publishes no final result.

## EXAMPLES
- `apt2sb install chromium chromium-sandbox`
- `apt2sb install -y --level 03 chromium chromium-sandbox`
- `apt2sb install -y --no-install-recommends ./google-chrome-stable_current_amd64.deb -n 06-google-chrome.sb -l 3`
- `apt2sb install -y libreoffice -c xz`
- `apt2sb upgrade -y -n upgrades.sb`

## SEE ALSO

[script2sb(1)](man:script2sb.1)

[chroot2sb(1)](man:chroot2sb.1)
