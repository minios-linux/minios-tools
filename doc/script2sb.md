% SCRIPT2SB(1) MiniOS Live Manual

## NAME
**script2sb** - Packages a module from changes made by an installation script.

## SYNOPSIS
`script2sb [OPTIONS] --script FILE`

## DESCRIPTION
Packages a module from changes made by an installation script.

## OPTIONS
* `-d, --directory DIR`  
    Copy contents of DIR to the root of the module

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

* `--help`  
    Display this help and exit

* `--version`  
    Display version information and exit

## CREATING MODULES
1. Run the script with root privileges using the sudo command.
2. Specify the installation script using the `-s` or `--script FILE` option, where FILE is the path to the installation script.
3. Optionally, you can specify a directory using the `-d` or `--directory DIR` option, where DIR is the path to the directory. The contents of this directory will be copied to the overlay filesystem before running the installation script.
4. Optionally, you can specify a filename for saving changes using the `-n` or `--name NAME` option, where NAME is the filename. If this option is not specified, the filename will be generated automatically based on the name of the installation script.
5. Optionally, you can specify a filtering level using the `-l` or `--level LEVEL` option, where LEVEL is a numeric value. This option is used to filter overlay filesystem layers.
6. Optionally, specify the compression type using the `-c` or `--comp TYPE` option. Supported types are zstd, gzip, lzo, and xz. The default is zstd.
7. Optionally, change the bundle extension using the `-b` or `--bext EXT` option.  The default is sb.

If you do not specify the `--directory`, `--name`, and `--level` options, they are not used. If you do not specify the `--name` option, then a filename for saving changes is generated automatically based on the name of the installation script.

The filtering level is used to filter overlay filesystem layers. For example, if you specify a filtering level of 3 using the `-l 3` or `--level=3` option, then all overlay filesystem layers with a number greater than 3 will be filtered out and module assembly will be launched based on modules with numbers 00-03. 

The installation script specified using the `-s` or `--script` option can be any executable script that performs desired installation steps. The script will be run in a chroot environment inside the overlay filesystem so it should be written with this in mind.

## EXAMPLES
- `script2sb -s /path/to/install_script.sh`
- `script2sb --level 03 --script /path/to/install_script.sh`
- `script2sb -s /path/to/install_script.sh -n 06-chromium.sb -l 3`
- `script2sb -s /path/to/install_script.sh -c lzo -b bundle`

## SEE ALSO

[apt2sb(1)](man:apt2sb.1)

[chroot2sb(1)](man:chroot2sb.1)