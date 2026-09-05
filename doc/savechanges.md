% SAVECHANGES(1) MiniOS Live Manual

## NAME

savechanges - capture writable MiniOS session changes in a SquashFS module

## SYNOPSIS

**savechanges** [*OPTIONS*] *TARGET* [*CHANGES_DIRECTORY*]

**savechanges** [*OPTIONS*] **--inventory-json** *FILE* [*CHANGES_DIRECTORY*]

## DESCRIPTION

**savechanges** reads the writable layer of a running MiniOS session. Creating a
module or inventory requires root because the layer can contain files readable
only by root.

Without **--profile**, the legacy policy is used. It omits empty directories,
caches, logs, boot data, runtime and pseudo-filesystem paths, and selected
session and system files; parents required by retained files are recreated.

The profile modes provide explicit session-capture policies. All modes omit runtime and pseudo-mount content, internal union bookkeeping, the output itself, and nested filesystems. The **exact** profile rejects unsupported filesystem objects rather than silently omitting them. Backend-specific deletion and opacity metadata is retained only when it can be represented safely. A target that already exists, including a symbolic link, is never overwritten.

The changes directory defaults to **/run/initramfs/memory/changes** or **/lib/live/mount/changes**. When that location contains the standard OverlayFS **changes/** and **workdir/** pair, the inner **changes/** directory is selected directly; unrelated builder workspace entries beside the pair are never traversed. The filesystem mounted at **/** is authoritative for backend detection; a kernel **union=** argument is treated only as intent. For OverlayFS, the effective changes directory must match the mounted root's **upperdir**. For AUFS, it must match the writable branch reported by the mounted root. An explicitly supplied wrapper containing only **changes/** and **workdir/** is unwrapped safely, including repeated wrappers. An OverlayFS-shaped wrapper is rejected for other mounted backends. Nested mount roots are identified from mount information as well as device changes, so a same-device bind mount is not traversed.

## OPTIONS

**-c**, **--comp** *TYPE*
: Use **zstd**, **gzip**, **lzo**, **lz4**, or **xz** compression. The default is **zstd**.

**-b**, **--bext** *EXT*
: Set the bundle extension displayed by help. The default is **sb**. The exact
  target pathname is still supplied positionally.

**--profile** *PROFILE*
: Select **exact**, **clean**, or **selected** behavior.

**--selection** *FILE*
: Read the selected-profile policy from *FILE*. It is required with **--profile selected** and forbidden with other profiles. The file must be a readable, non-symlink regular file containing strict UTF-8 JSON.

**--inventory-json** *FILE*
: Write a metadata-only JSON inventory atomically and do not create a module. In this form, the optional positional argument is the changes directory.

**--metadata-json** *FILE*
: Write strict capture metadata beside a module. The file must use the module output directory and is published mode 0600. It is removed again if module publication fails.

**--work-parent** *DIR*
: Create private mode-0700 capture staging below *DIR* instead of **/tmp**. The directory must already exist and resolve without symbolic-link traversal. It may be trusted root-owned storage, or a mode-0700 directory owned by the original **PKEXEC_UID** caller; the root helper creates a root-owned mode-0700 child through a retained descriptor. This allows callers to choose storage that does not duplicate a RAM-backed writable layer in another RAM-backed temporary filesystem.

**--json**
: Emit pure NDJSON phase and result events on standard output. Human diagnostics and child-tool output are written to standard error. A failed or cancelled operation emits no result event.

**--json** cannot be combined with **--help** or **--version**.

**--cancel-file** *FILE*
: Cancel a module or inventory transaction when *FILE* appears. The file must not exist initially. Its parent must be a real mode 0700 directory owned by the original caller: **PKEXEC_UID** for a pkexec invocation, or the current EUID for direct root execution. The retained parent is opened without following symlinks and is revalidated while capture runs. Marker contents and type are ignored; only existence is observed.

**--no-color**
: Disable terminal colors. Color is also disabled when output is not a terminal or **NO_COLOR** is set.

**--help**
: Display help and exit.

**--version**
: Display version information and exit.

Long options that accept values also support the **--option=value** form.

## PROFILES

**exact**
: Preserve representable writable-session changes, including user data, logs, caches, identity files, credentials, and deletion whiteouts. Runtime and pseudo-mount paths, internal overlay metadata, nested mount contents, and the destination are omitted. A writable layer containing a socket, FIFO, unsupported device, or hard-linked non-regular inode is rejected so a successful exact capture never reports completion after silently losing an object or inode topology.

**clean**
: Use a narrow path allowlist for system executable, library, and shared-data trees; dpkg and selected package-manager state; package-managed systemd state; snap and Flatpak payloads; alternatives and system unit links; and selected release metadata. **/usr/local**, account data, home and root data, logs, caches, identities, network configuration, credentials, and arbitrary system configuration are not eligible. This is a path-based privacy reduction, not a guarantee that an allowed software file contains no secret.

**selected**
: Include only explicit include paths and their descendants, required parent directories, and whiteouts associated with selected paths. Every include must match inventory data. Explicit excludes and their descendants win. A selected symbolic link is rejected if its resolved target escapes the changes root. An opaque marker is preserved only when the opaque directory itself or an ancestor was selected without a descendant exclusion; child-only selection strips opacity so unrelated lower siblings remain visible.

## UNION METADATA

OverlayFS deletion whiteouts are character devices with major and minor number 0, and opaque directories use **trusted.overlay.opaque** or **user.overlay.opaque**. AUFS deletion and opacity entries use zero-length, single-link regular **.wh.*** files; malformed representations are rejected. These forms are interpreted only for their mounted backend. Context-only OverlayFS **origin**, **impure**, and **uuid** attributes, including known **user.overlay** equivalents, are discarded. Replay-dependent **redirect**, **metacopy**, and **index** attributes and unknown union semantics fail closed when selected for capture. Permission-denied union or opacity metadata is not treated as absence. The same rules apply to changes-root metadata.

When a selected profile includes only a child of an opaque directory or excludes part of that directory, the opacity marker is removed so the resulting module cannot hide unrelated lower-layer entries. The **clean** profile removes ordinary extended attributes while preserving required, representable union opacity. Other explicit profiles retain user attributes, POSIX ACLs, and Linux file capabilities when the destination filesystem can represent them. An **exact** capture fails if it encounters another attribute that cannot be retained or if the staging filesystem cannot reproduce a required attribute. Symbolic-link attributes are read and written without following the link.

## SELECTION FORMAT

The selection document has exactly these fields:

```json
{
  "product_kind": "minios-session-selection",
  "schema_version": 1,
  "include_paths": ["etc/default", "opt/my-app"],
  "exclude_paths": ["opt/my-app/private"]
}
```

Unknown or duplicate JSON fields are rejected. Both path values must be arrays of unique strings. Each path must be a normalized, nonempty relative path. Absolute paths, empty components, **.**, **..**, NUL, CR, and LF are rejected. Duplicate paths within either array or across both arrays are rejected. Every include must match an entry, descendant, whiteout, or opaque ancestor. Explicit excludes still win when include and exclude paths overlap by ancestry. Diagnostics report only counts or generic validation classes; include and exclude path values are never written to logs.

## INVENTORY FORMAT

The inventory is strict UTF-8 JSON with product kind **minios-session-inventory** and schema version 2. It records the detected **union_backend** and an opaque SHA256 **source_fingerprint** derived from the boot and changes-root identity. It does not expose the changes-root pathname, device, or inode.

Each entry records its relative **path**, **type**, **category**, **sensitive** flag, and **default_exact** and **default_clean** values. A numeric **size** is present only for regular files. Categories are **system-config**, **software**, **user-data**, **logs-cache**, **network-identity**, **machine-identity**, **runtime**, and **other**.

Inventory generation reads filesystem metadata only. It does not read or emit file contents, symbolic-link targets, secret values, or identities inferred from contents. The completed file is mode 0600 and, when invoked through **pkexec**, is owned by the requesting user.

## CAPTURE METADATA

**--metadata-json** writes product kind **minios-session-capture-metadata**, schema version 2, profile, mounted union backend, running boot ID, changes-source fingerprint, base-module fingerprint when available, module size, SHA256, staged entry count, uncompressed logical regular-file size, the extraction footprint described below, and the selection-file SHA256 or JSON null. Base fingerprint version 2 hashes each mounted lower-module name and its verified loop backing bytes in effective union precedence order; reordering overlapping modules changes the fingerprint. It contains no selected paths or file contents.

### Extraction footprint

The module metadata and JSON result contain an additive **extraction_footprint** object with product kind **minios-extraction-footprint** and schema version 1. It describes the final staged tree before SquashFS creation. It is a set of measured inputs for a bounded extractor, not by itself a byte estimate.

**regular_file_bytes** counts logical regular-file data once per inode. **regular_file_inodes** counts those unique regular-file inodes. Semantic AUFS and OverlayFS whiteouts are excluded from regular-file counters even when their on-disk representation is a regular file. **directory_count** includes the extraction root. **symlink_count**, **symlink_target_bytes**, and **whiteout_count** describe symbolic links and retained deletion objects. **inode_count** counts all unique staged inodes, including the extraction root. **directory_entry_count** counts staged paths excluding that root, and **filename_bytes** sums their basename lengths in filesystem bytes. **hardlink_reference_count** counts regular-file names beyond the first name for each inode. **xattr_count**, **xattr_name_bytes**, and **xattr_value_bytes** count each inode's retained attribute set once, so hard-linked names do not multiply extraction requirements. **compressor** and **block_size** record the SquashFS creation settings.

## OUTPUT SAFETY

Temporary data is created in a mode-0700 directory outside the changes root.
The capture retains filesystem descriptors for its inputs, output parent, and
temporary storage; symbolic-link replacement of those paths cannot redirect the
capture. Space and inode preflight account for staging, compression, and the
no-replace publication copy, including their simultaneous use on one
filesystem. The module is accepted only when **mksquashfs** succeeds, creates a
nonempty regular file, **unsquashfs -s** recognizes it, and **unsquashfs -ll**
lists it successfully.

The final output is copied to a private random file in the retained destination
directory and published with an atomic no-replace operation. Existing paths,
paths that appear during capture, and replaced destination ancestors are left
untouched. Explicit-profile modules, inventories, and metadata are mode 0600;
modules created without **--profile** are mode 0644. INT, TERM, and a valid
cancellation marker interrupt in-process inventory and copy work. A privileged
monitor terminates and reaps the active tool process group and removes private
or incomplete temporary data.

## OUTPUT PROTOCOL

With **--json**, standard output contains one JSON object per line. Module
capture emits **prepare**, **inventory**, **capture**, **compress**, **verify**,
**publish**, and **complete**. Inventory generation emits **prepare**,
**inventory**, **publish**, and **complete**. The final module result uses
product kind **minios-tool-result**, schema version 1, tool
**savechanges**, operation **capture-module**, and includes the output path and
device/inode identity, compressed size, uncompressed logical size, entry count,
extraction footprint, SHA256, profile, and mounted union backend.

The entry count is the number of paths in the copied staging tree, excluding its
root. Uncompressed logical size counts stable regular-file data once per inode,
so hard-linked names do not multiply the extraction-memory estimate.

Without **--json**, phase, information, and warning records use standard output
with stable **P:**, **I:**, and **W:** prefixes. **E:** records and child-tool
diagnostics use standard error. Frontends can consume these untranslated phase
identifiers:

**P:capture-inventory**
: Selection validation and changes-layer inventory.

**P:capture-copy**
: Secure copy into private staging. Module mode only.

**P:capture-compress**
: SquashFS creation and validation. Module mode only.

**P:capture-complete**
: Successful atomic publication.

**P:cancelled**
: Cancellation was observed and privileged cleanup is in progress or complete.

## EXAMPLES

Use the legacy policy:

    savechanges mychanges.sb

Capture all representable session changes from an explicit writable layer:

    savechanges --profile exact session.sb /run/initramfs/memory/changes

Create a module using the narrow software allowlist:

    savechanges --profile clean --comp xz software-session.sb

Create a selected module:

    savechanges --profile selected --selection selection.json selected-session.sb

Write an inventory without creating a module:

    savechanges --inventory-json session-inventory.json /path/to/changes

## EXIT STATUS

**0**
: Successful completion.

**1**
: Invalid options, permissions, paths, tools, free space, capture policy,
  compression, publication, or SquashFS validation failure.

**2**
: The default live writable changes directory could not be detected.

**130**
: Interrupted by INT or TERM, or cancelled through **--cancel-file**.

## SEE ALSO

**apt2sb**(1), **script2sb**(1), **chroot2sb**(1)
