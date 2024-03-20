% RMSBDIR(1) MiniOS Live Manual

## NAME
**rmsbdir** - Deletes a module directory created by the sb2dir command.

## SYNOPSIS
`rmsbdir [SOURCE_DIRECTORY.SB]`

## DESCRIPTION
Erases a module directory created by the sb2dir command.

## OPTIONS
* `SOURCE_DIRECTORY.SB`:   
    Specify the directory to be erased. This is required.

## USAGE NOTES
1. The script is to be executed with the `SOURCE_DIRECTORY.SB` as the argument.
2. An error will be reported if the specified directory does not exist.

## EXAMPLES
- `rmsbdir example_directory.sb`

## SEE ALSO

[sb(1)](man:sb.1)

[sb2dir(1)](man:sb2dir.1)

[dir2sb(1)](man:dir2sb.1)