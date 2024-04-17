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
    specify output ISO filename (default: MiniOS-YYYYMMDD_HHMM.iso)
    
* `--help`  
    display help message and exit

* `--version`  
    display version information and exit

## CREATING ISO
1. Run the script in command line.
2. Specify one or more module paths as arguments.
3. Optionally, you can specify a filename for saving the newly created ISO using the `--file FILE` option, where `FILE` is the filename. If this option is not specified, the filename will be generated automatically based on the date and time.
4. Optionally, you can specify a regular expression to exclude matching files using the `--exclude REGEX` option, where `REGEX` is a regular expression pattern.

## EXAMPLES
- `sb2iso module1.sb module2.sb`
- `sb2iso --exclude='chromium' --name minios_without_chromium.iso module1.sb module2.sb`
- `sb2iso --exclude='firmware|xorg|desktop|apps|chromium' --name minios_textmode.iso module1.sb module2.sb`
