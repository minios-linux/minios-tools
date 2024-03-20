% SB(1) MiniOS Live Manual 

## NAME
**sb** - A utility for managing .sb modules by calling corresponding scripts based on supplied arguments.

## SYNOPSIS
`sb [COMMAND] [PARAMETERS]`

## DESCRIPTION
Provides a convenient way to manage .sb modules by calling appropriate scripts based on given arguments.

## COMMANDS
* `rm [DIRECTORY]` or `rmdir [DIRECTORY]`:  
   Calls the **rmsbdir** script to erase a directory created by the sb2dir command

* `conv [DIRECTORY or FILE]`:   
   Detects whether the input is a file or a directory and calls appropriate conversion scripts (sb2dir, dir2sb)

The rest will be considered as [PARAMETERS] for the commands.

## USAGE NOTES
1. The script should be executed with a specific COMMAND along with respective PARAMETERS.
2. If the COMMAND is `rm` or `rmdir`, **rmsbdir** script gets executed to erase a directory.
3. If the COMMAND is `conv`, it detects the type of the first PARAMETER. If it's a directory, **dir2sb** script is called. If it's a file, **sb2dir** script is called.

## EXAMPLES
- `sb rm example_directory.sb`
- `sb conv example_file.sb`
- `sb conv example_directory`

## SEE ALSO

[rmsbdir(1)](man:rmsbdir.1)

[sb2dir(1)](man:sb2dir.1)

[dir2sb(1)](man:dir2sb.1)
