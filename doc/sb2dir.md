% SB2DIR(1) MiniOS Live Manual

## NAME
**sb2dir** - Converts an SB compressed module into a directory.

## SYNOPSIS
`sb2dir [SOURCE_FILE.SB] [[OPTIONAL OUTPUT_DIRECTORY]]`

## DESCRIPTION
Converts an SB compressed module into a directory with the same name.

## OPTIONS
* `SOURCE_FILE.SB`:   
    Define the source SB compressed module. This is required.

* `OPTIONAL OUTPUT_DIRECTORY`   
    If specified, this directory will serve as the output location. The directory must exist prior to running the script. If not specified, a directory named after the source file (SOURCE_FILE.SB) will be created. The directory will be overmounted with tmpfs.

## USAGE NOTES
1. This script has to be executed with the source file (in .sb format) as an argument.
2. Optionally, you can specify an output directory. If it's not specified, a new directory with the name of the source file will be created and overmounted with tmpfs.
3. If the output directory is provided it must exist, else a 'Directory does not exist' error will be reported.
4. If the specified source file doesn't exist or is unreadable, a relevant error message will be displayed.

## EXAMPLES  
- `sb2dir example_file.sb`
- `sb2dir example_file.sb existing_directory`

## SEE ALSO

[rmsbdir(1)](man:rmsbdir.1)

[dir2sb(1)](man:dir2sb.1)

[sb(1)](man:sb.1)