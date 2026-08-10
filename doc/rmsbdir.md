% RMSBDIR(1) MiniOS Live Manual

## NAME
**rmsbdir** - Refuses the retired unsafe module-directory removal operation.

## SYNOPSIS
`rmsbdir [--help|--version] SOURCE_DIRECTORY.SB`

## DESCRIPTION
This compatibility command no longer unmounts or recursively deletes paths.
Directories created by modern **sb2dir** are ordinary directories. Review the
path and contents, then use standard filesystem tools if removal is intended.

## OPTIONS
* `SOURCE_DIRECTORY.SB`:
    Identify the directory that the retired command would have removed. The
    command reports the safe replacement workflow and exits without changing it.

* `--help`:
    Display usage information and exit.

* `--version`:
    Display version information and exit.

## USAGE NOTES
The command always refuses removal. This behavior also applies to the `sb rm`
and `sb rmdir` compatibility aliases.

## EXAMPLES
- `rmsbdir example_directory.sb`

## SEE ALSO

[sb(1)](man:sb.1)

[sb2dir(1)](man:sb2dir.1)

[dir2sb(1)](man:dir2sb.1)
