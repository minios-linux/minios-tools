% APT2SB(1) MiniOS Live Manual

## NAME
**apt2sb** - Converts repository packages into modules.

## SYNOPSIS
`apt2sb [OPTIONS] PACKAGE1 [PACKAGE2] [...]`

## DESCRIPTION
Installs packages from repositories and packages them into a module.

## OPTIONS
* `-f, --file=FILE`  
    use FILE as the filename for the module instead of PACKAGE1.sb

* `-l, --level=LEVEL`  
    use LEVEL as the filter level

* `--help`  
    display this help and exit

* `--version`  
    display version information and exit

## CREATING MODULES
1. Run the script with root privileges using the sudo command.
2. Specify one or more package names as arguments.
3. Optionally, you can specify a filename for saving changes using the `--file=FILE` option, where `FILE` is the filename. If this option is not specified, the filename will be generated automatically based on the name of the first package.
4. Optionally, you can specify a filtering level using the `--level=LEVEL` option, where `LEVEL` is a numeric value. This option is used to filter overlay filesystem layers.

## EXAMPLES
- `apt2sb chromium chromium-sandbox`
- `apt2sb --level=03 chromium chromium-sandbox`
- `apt2sb chromium chromium-sandbox -f 06-chromium.sb -l 3`

## SEE ALSO

[scr2sb(1)](man:scr2sb.1)

[upg2sb(1)](man:upg2sb.1)