% UPG2SB(1) MiniOS Live Manual

## NAME
**upg2sb** - Upgrades packages from repositories and packages them into a module.

## SYNOPSIS
`upg2sb [OPTIONS]`

## DESCRIPTION
Upgrades packages from repositories and packages them into a module.

## OPTIONS
* `-f, --file=FILE`  
    use FILE as the filename for the module instead of 10-upgrade-[current datetime].sb

* `-l, --level=LEVEL`  
    use LEVEL as the filter level

* `--help`  
    display this help and exit

* `--version`  
    display version information and exit

## USAGE
1. Run the script with root privileges.
2. It will automatically upgrade the packages from the repositories and package them into a module.
3. The filename for the module will be 10-upgrade-[current datetime].sb by default, unless a different name is specified with the `--file=FILE` option.
4. Optionally, a filter level for the overlay filesystem layers can be specified with the `--level=LEVEL` option.

## EXAMPLES
* `upg2sb`
* `upg2sb --level=03`
* `upg2sb -f 04-upgrade.sb -l 3`

This script provides a method of upgrading packages and automatically arranging them into a module.

**Note:** This console script should be run as the root user.

## SEE ALSO
[apt2sb(1)](man:apt2sb.1)

[scr2sb(1)](man:scr2sb.1)