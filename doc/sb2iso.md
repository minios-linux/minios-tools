% SB2ISO(1) MiniOS Live Manual

## NAME

sb2iso - generate MiniOS ISO image with specified modules

## SYNOPSIS

**sb2iso** [**-e** *REGEX*] [**-n** *NAME*] [**--grub-bios**] [**--grub-menu** *TYPE*] [**--help**] [**--version**] *MODULE*...

## DESCRIPTION

**sb2iso** generates MiniOS ISO image, adding specified modules. The tool supports both SYSLINUX and GRUB bootloaders with customizable menu types and full localization support.

## OPTIONS

**-e**, **--exclude** *REGEX*
: Exclude any existing path or file matching *REGEX*.

**-n**, **--name** *NAME*  
: Specify output ISO filename. Default is minios-YYYYMMDD_HHMM.iso.

**--grub-bios**
: Use GRUB for BIOS boot instead of SYSLINUX.

**--grub-menu** *TYPE*
: Set GRUB menu type. *TYPE* can be:
  **multilang** (default) - menu with language selection
  **template** - simple themed menu
  *LANG* - specific language code (en_US, ru_RU, de_DE, es_ES, it_IT, id_ID, pt_BR)

**--help**
: Display help message and exit.

**--version**
: Display version information and exit.

## BOOTLOADER SUPPORT

The tool supports two bootloader types:

**SYSLINUX** (default)
: Standard BIOS bootloader compatible with all systems. Uses isolinux.bin for booting.

**GRUB BIOS**
: Alternative BIOS bootloader with more advanced features. Uses eltorito.img for booting. Enabled with **--grub-bios**.

## MENU TYPES

**multilang** (default)
: Multi-language menu with language selection screen.

**template**
: Simple themed menu in English.

*Language codes*
: Fully localized menus with translated text and language-specific themes. Supported languages: en_US, ru_RU, de_DE, es_ES, it_IT, id_ID, pt_BR.

## EXAMPLES

Create ISO with default settings:

    sb2iso module1.sb module2.sb

Exclude specific modules:

    sb2iso --exclude='firefox' --name minios_without_firefox.iso module1.sb module2.sb

Create text-mode core only:

    sb2iso --exclude='firmware|xorg|desktop|apps|firefox' --name minios_textmode.iso module1.sb module2.sb

Use GRUB BIOS instead of SYSLINUX:

    sb2iso --grub-bios --name minios_grub.iso module1.sb module2.sb

Create Russian localized menu:

    sb2iso --grub-menu ru_RU --name minios_russian.iso module1.sb module2.sb

Combined GRUB BIOS with localization:

    sb2iso --grub-bios --grub-menu ru_RU --name minios_grub_russian.iso module1.sb module2.sb

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
