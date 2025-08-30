# MiniOS Tools

A collection of command-line tools for managing MiniOS live systems and module bundles.

## Overview

MiniOS Tools provides utilities for creating, managing, and customizing MiniOS live systems. These tools allow you to build custom ISO images, manage compressed filesystem bundles (.sb modules), and maintain live system configurations.

## Tools

### System Building
- **sb2iso** - Generate MiniOS ISO images with custom modules and localized menus
- **apt2sb** - Install packages from repositories and package them into modules  
- **script2sb** - Package modules from changes made by installation scripts
- **chroot2sb** - Package modules using chroot environment

### Module Management  
- **sb** - Activate, deactivate, and manage MiniOS bundles
- **dir2sb** - Convert directories to compressed .sb modules
- **sb2dir** - Extract .sb modules to directories
- **rmsbdir** - Remove module directories created by sb2dir
- **savechanges** - Save runtime changes to compressed bundles

## Installation

These tools are typically included with MiniOS distributions. For manual installation:

```bash
make install
```

## Usage

Each tool includes built-in help:

```bash
sb2iso --help
apt2sb --help
# etc.
```

For detailed documentation, see the individual manual pages in the `doc/` directory.

## Language Support

The tools support multiple languages with full localization:
- English (en_US)
- Russian (ru_RU) 
- German (de_DE)
- Spanish (es_ES)
- Italian (it_IT)
- Indonesian (id_ID)
- Portuguese Brazil (pt_BR)
- Portuguese Portugal (pt_PT)
- French (fr_FR)

## Requirements

- Linux system with squashfs-tools
- Root privileges for most operations
- AUFS/OverlayFS support for some bundle operations

## License

Distributed under the same license as MiniOS Linux.

## Support

For issues and questions, visit: https://github.com/minios-linux/minios-live