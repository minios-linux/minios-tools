% APT2SB(1) MiniOS Live Manual

## NAME
**apt2sb** - Converts repository packages into modules.

## SYNOPSIS
`apt2sb [COMMAND] [OPTIONS] PACKAGE1 [PACKAGE2] [...]`

## DESCRIPTION
Installs packages from repositories and packages them into a module.

## COMMANDS
* `install`  
    Install package(s).
    
* `upgrade`  
    Upgrade installed packages.

## OPTIONS
* `-f, --file=FILE`  
    use FILE as the filename for the module instead of PACKAGE1.sb

* `-l, --level=LEVEL`  
    use LEVEL as the filter level

* `--help`  
    display this help and exit

* `--version`  
    display version information and exit

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

* `-t, --target-release` 
    Default release to install packages from.

## CREATING MODULES

### Installing Packages:
1. Run the script with root privileges using the `sudo` command.
2. Use the `install` command followed by one or more package names that you wish to convert into modules. The script supports installing both packages from the repository and local packages. To install local packages, simply include the path to the local .deb file as an argument.
3. If you want to specify a different filename for the module, use the `-f, --file=FILE` option, where `FILE` stands for the preferred filename. If not provided, the filename will be automatically derived from the name of the first package.
4. You can also define the filter level using the `-l, --level=LEVEL` option, where `LEVEL` is a numerical value.
5. If you want to accept all confirmations automatically, use `-y, --yes` option.
6. Use other APT options according to your package dependency requirements.
7. The script will now install the packages, convert them to a module, and save it with the specified filename and filter level.

### Upgrading Installed Packages:
1. Run the script with the `upgrade` command to upgrade all installed packages.
2. Use the `-y, --yes` option if you want to accept all confirmations automatically.

## EXAMPLES
- `apt2sb install chromium chromium-sandbox`
- `apt2sb install --level=03 chromium chromium-sandbox`
- `apt2sb upgrade -y`
- `apt2sb install --no-install-recommends ./google-chrome-stable_current_amd64.deb -f 06-google-chrome.sb -l 3`

## SEE ALSO

[scr2sb(1)](man:scr2sb.1)
