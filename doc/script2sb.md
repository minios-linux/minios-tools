% SCRIPT2SB(1) MiniOS Live Manual

## NAME
**script2sb** - Packages a module from changes made by an installation script.

## SYNOPSIS
`script2sb [OPTIONS] --script FILE`

## DESCRIPTION
Packages a module from changes made by an installation script.

## OPTIONS
* `-d, --directory DIR`  
    copy contents of DIR to the root of the module

* `-n, --name NAME`  
    use FILE as the filename for the module

* `-l, --level LEVEL`  
    use LEVEL as the filter level

* `-s, --script FILE`  
    use FILE as the installation script

* `--help`  
    display this help and exit

* `--version`  
    display version information and exit

## CREATING MODULES
1. Run the script with root privileges using the sudo command.
2. Specify the installation script using the `--script FILE` option, where FILE is the path to the installation script.
3. Optionally, you can specify a directory using the `--directory DIR` option, where DIR is the path to the directory. The contents of this directory will be copied to the overlay filesystem before running the installation script.
4. Optionally, you can specify a filename for saving changes using the `--name NAME` option, where NAME is the filename. If this option is not specified, the filename will be generated automatically based on the name of the installation script.
5. Optionally, you can specify a filtering level using the `--level LEVEL` option, where LEVEL is a numeric value. This option is used to filter overlay filesystem layers.

If you do not specify options --directory, --file, and --level, they are not used. If you do not specify option --file, then a filename for saving changes is generated automatically based on the name of the installation script.

The filtering level is used to filter overlay filesystem layers. For example, if you specify a filtering level of 3 using option --level=3, then all overlay filesystem layers with a number greater than 3 will be filtered out and module assembly will be launched based on modules with numbers 00-03. 

The installation script specified using option --script can be any executable script that performs desired installation steps. The script will be run in chroot environment inside overlay filesystem so it should be written with this in mind.

## EXAMPLES
- `script2sb -s /path/to/install_script.sh`
- `script2sb --level 03 --script /path/to/install_script.sh`
- `script2sb -s /path/to/install_script.sh -f 06-chromium.sb -l 3`

## SEE ALSO

[apt2sb(1)](man:apt2sb.1)

[chroot2sb(1)](man:chroot2sb.1)