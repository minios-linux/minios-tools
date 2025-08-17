% SB2ISO(1) MiniOS Live Manual

## NAME
**sb2iso** - Generates a MiniOS ISO image with specified modules.

## SYNOPSIS
`sb2iso [OPTIONS] MODULE1 [MODULE2] [...]`

## DESCRIPTION
Generates MiniOS ISO image, adding specified modules.

## OPTIONS
* `-e, --exclude REGEX`  
    exclude any existing path or file matching REGEX

* `-n, --name NAME`  
    specify output ISO filename (default: minios-YYYYMMDD_HHMM.iso)

* `-v, --verbose`  
    increase verbosity level
    
* `--help`  
    display help message and exit

* `--version`  
    display version information and exit

## CREATING ISO
1. Run the script in command line.
2. Specify one or more module paths as arguments.
3. Optionally, you can specify a filename for saving the newly created ISO using the `--name NAME` option, where `NAME` is the filename. If this option is not specified, the filename will be generated automatically based on the date and time.
4. Optionally, you can specify a regular expression to exclude matching files using the `--exclude REGEX` option, where `REGEX` is a regular expression pattern.

## EXAMPLES
- `sb2iso module1.sb module2.sb`
- `sb2iso --exclude='firefox' --name minios_without_firefox.iso module1.sb module2.sb`
- `sb2iso --exclude='firmware|xorg|desktop|apps|firefox' --name minios_textmode.iso module1.sb module2.sb`
