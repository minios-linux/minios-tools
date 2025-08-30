% SB2ISO(1) MiniOS Live Manual

## NAME

sb2iso - generate MiniOS ISO image with specified modules

## SYNOPSIS

**sb2iso** [**-e** *REGEX*] [**-n** *NAME*] [**--menu** *TYPE*] [**--help**] [**--version**] *MODULE*...

## DESCRIPTION

**sb2iso** generates MiniOS ISO image, adding specified modules. The tool automatically detects the bootloader type (SYSLINUX, GRUB, or mixed) from the source system and supports customizable menu types with full localization support.

## OPTIONS

**-e**, **--exclude** *REGEX*
: Exclude any existing path or file matching *REGEX*.

**-n**, **--name** *NAME*  
: Specify output ISO filename. Default is minios-YYYYMMDD_HHMM.iso.

**--menu** *TYPE*
: Set menu type for both GRUB and SYSLINUX. *TYPE* can be:
  **multilang** (default) - menu with language selection
  *LANG* - specific language code (en_US, ru_RU, de_DE, es_ES, it_IT, id_ID, pt_BR, pt_PT, fr_FR)

**--help**
: Display help message and exit.

**--version**
: Display version information and exit.

## BOOTLOADER SUPPORT

The tool automatically detects and supports three bootloader configurations:

**syslinux-grub** (most common)
: Uses SYSLINUX as the primary bootloader which then loads GRUB. This provides compatibility with both legacy BIOS and UEFI systems.

**grub-only**
: Uses GRUB directly for all boot scenarios. Detected when only GRUB BIOS components are present.

**syslinux-native**
: Uses SYSLINUX natively without GRUB components. Detected when only SYSLINUX files are present.

The bootloader type is automatically detected based on the boot files present in the source MiniOS system.

## MENU TYPES

**multilang** (default)
: Multi-language menu with language selection screen.

*Language codes*
: Fully localized menus with translated text and language-specific themes. Supported languages: en_US (English), ru_RU (Russian), de_DE (German), es_ES (Spanish), it_IT (Italian), id_ID (Indonesian), pt_BR (Portuguese Brazil), pt_PT (Portuguese Portugal), fr_FR (French).

## EXAMPLES

Create basic ISO from current live system:

    sb2iso

Create ISO with custom name:

    sb2iso --name my_custom_minios.iso

Exclude heavy applications:

    sb2iso --exclude 'firefox|libreoffice|gimp' --name minios_lite.iso

Create minimal text-mode ISO:

    sb2iso --exclude 'desktop|xorg|apps' --name minios_minimal.iso

Add extra modules to current system:

    sb2iso development_tools.sb games.sb --name minios_extended.iso

Create localized Russian ISO:

    sb2iso --menu ru_RU --name minios_ru.iso

Combine exclusions with additions:

    sb2iso --exclude 'games' extra_productivity.sb --name minios_work.iso

## FILES

The script requires MiniOS system to be loaded from live media or RAM. Boot files are located in:

*/run/initramfs/memory/data/minios/boot/*
: Boot files location when running from live system

*/memory/data/minios/boot/*
: Alternative boot files location

## EXIT STATUS

**0**
: Successful completion.

**1**
: General error (invalid arguments, missing files).

**2**
: Required boot files not found.

**3**
: Module file does not exist.

**4**
: Cannot change to temporary directory.

## SEE ALSO

**sb**(1), **chroot2sb**(1), **apt2sb**(1)
