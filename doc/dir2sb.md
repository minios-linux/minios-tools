% DIR2SB(1) MiniOS Live Manual

## NAME
**dir2sb** - Transforms a directory into an .sb compressed module.

## SYNOPSIS
`dir2sb [SOURCE_DIRECTORY] [[TARGET_FILE.SB]]`

## DESCRIPTION
Converts a directory into a .sb compressed module.

## OPTIONS
* `SOURCE_DIRECTORY`:   
    Specify the directory to be converted to the SB compressed module. This is required.
  
* `TARGET_FILE.SB`:
    Optional. Specify the name of the output .sb compressed module file. This is required if `SOURCE_DIRECTORY` does not have .sb suffix and it is not 'squashfs-root'. If `TARGET_FILE.SB` is not specified,`SOURCE_DIRECTORY` is replaced by the newly generated module file.

## USAGE NOTES
1. The script is to be executed with the `SOURCE_DIRECTORY` as the argument.
2. Optionally, you can specify a `TARGET_FILE.SB`. If not provided, the source directory is replaced by the newly generated module.
3.  If the source directory does not have a .sb suffix and it is not 'squashfs-root', then the source directory itself is included in the module and then the `TARGET_FILE.SB` parameter is required.
4. Errors will be reported if the specified directory does not exist, or if the targeted .sb file already exists.

## EXAMPLES
- `dir2sb example_directory`
- `dir2sb example_directory target_file.sb`

## SEE ALSO

[rmsbdir(1)](man:rmsbdir.1)

[sb2dir(1)](man:sb2dir.1)

[sb(1)](man:sb.1)