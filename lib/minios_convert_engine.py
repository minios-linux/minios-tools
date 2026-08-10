#!/usr/bin/env python3
# minios-tools directory/.sb converter engine (Python 3.6+, stdlib only).
#
# Separated from the dir2sb/sb2dir bash frontends so the security-critical
# filesystem operations live in a real Python module instead of an embedded
# here-doc string, mirroring the minios-image-compose engine split. The bash
# frontends run the external squashfs tool (with bounded cancellation) and then
# call this engine to scan, digest, and atomically publish the result.
#
# It is invoked as: env -i PATH=... python3 -I minios_convert_engine.py <cmd> ...
#
# Subcommands:
#   scan-specials SOURCE_DIR
#       Reject a directory tree that contains device nodes, sockets, or FIFOs
#       (which cannot round-trip rootlessly). Print a JSON {entries,bytes}
#       summary on success.
#   publish-file PARENT TEMP TARGET COMPRESSION SOURCE_ENTRIES JSON
#       Hash the staged module, then atomically publish it with no-replace
#       semantics and print an identity/digest result.
#   publish-dir PARENT TEMP TARGET SOURCE_FILE ALLOW_SPECIAL JSON
#       Verify the staged directory, then atomically publish it with no-replace
#       semantics and print an identity/digest result.
from __future__ import print_function

import ctypes
import errno
import hashlib
import json
import os
import stat
import sys


BLOCK_SIZE = 1024 * 1024
RENAME_NOREPLACE = 1


class EngineError(Exception):
    """A recoverable converter failure with a stable exit status."""

    def __init__(self, status, message):
        super(EngineError, self).__init__(message)
        self.status = status
        self.message = message


def fail(status, message):
    raise EngineError(status, message)


def emit_error(message):
    sys.stderr.write("E: {}\n".format(message))
    sys.stderr.flush()


def open_absolute_directory(path):
    """Open an absolute directory without ever following a symlink component."""
    path_bytes = os.path.abspath(os.fsencode(path))
    descriptor = os.open(b"/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for component in path_bytes.split(b"/"):
            if not component:
                continue
            next_descriptor = os.open(
                component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=descriptor)
            os.close(descriptor)
            descriptor = next_descriptor
        return descriptor
    except OSError:
        os.close(descriptor)
        raise


def _load_renameat2():
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        symbol = libc.renameat2
    except (OSError, AttributeError):
        return None
    symbol.restype = ctypes.c_int
    symbol.argtypes = [
        ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p,
        ctypes.c_uint]
    return symbol


_RENAMEAT2 = _load_renameat2()


def rename_noreplace(directory_fd, source, target, allow_link_fallback):
    """Atomically publish ``source`` as ``target`` refusing to overwrite.

    Uses ``renameat2(RENAME_NOREPLACE)`` when the kernel and filesystem
    support it. For regular files an ``O_EXCL`` hard link plus source unlink is
    an equally atomic fallback; directories (which cannot be hard linked) fall
    back to an explicit existence check immediately before ``rename``.
    """
    source_bytes = source if isinstance(source, bytes) else os.fsencode(source)
    target_bytes = target if isinstance(target, bytes) else os.fsencode(target)
    if _RENAMEAT2 is not None:
        result = _RENAMEAT2(directory_fd, source_bytes, directory_fd,
                            target_bytes, RENAME_NOREPLACE)
        if result == 0:
            return
        code = ctypes.get_errno()
        if code == errno.EEXIST:
            fail(4, "output path already exists: {}".format(
                os.fsdecode(target_bytes)))
        if code not in (errno.ENOSYS, errno.EINVAL, errno.ENOTTY):
            raise OSError(code, os.strerror(code))
    if allow_link_fallback:
        try:
            os.link(source_bytes, target_bytes, src_dir_fd=directory_fd,
                    dst_dir_fd=directory_fd, follow_symlinks=False)
        except FileExistsError:
            fail(4, "output path already exists: {}".format(
                os.fsdecode(target_bytes)))
        os.unlink(source_bytes, dir_fd=directory_fd)
        return
    try:
        os.stat(target_bytes, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        pass
    else:
        fail(4, "output path already exists: {}".format(
            os.fsdecode(target_bytes)))
    os.rename(source_bytes, target_bytes, src_dir_fd=directory_fd,
              dst_dir_fd=directory_fd)


def hash_regular_fd(descriptor):
    digest = hashlib.sha256()
    total = 0
    os.lseek(descriptor, 0, os.SEEK_SET)
    while True:
        block = os.read(descriptor, BLOCK_SIZE)
        if not block:
            break
        total += len(block)
        digest.update(block)
    return total, digest.hexdigest()


def scan_tree(root_fd):
    """Walk ``root_fd`` and return (entries, bytes, special_found)."""
    entries = 0
    total_bytes = 0
    stack = [root_fd]
    opened = [root_fd]
    special = False
    try:
        while stack:
            current = stack.pop()
            for name in os.listdir(current):
                metadata = os.stat(name, dir_fd=current, follow_symlinks=False)
                mode = metadata.st_mode
                entries += 1
                if stat.S_ISDIR(mode):
                    child = os.open(
                        name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                        dir_fd=current)
                    opened.append(child)
                    stack.append(child)
                elif stat.S_ISREG(mode):
                    total_bytes += metadata.st_size
                elif stat.S_ISLNK(mode):
                    continue
                elif (stat.S_ISBLK(mode) or stat.S_ISCHR(mode) or
                      stat.S_ISFIFO(mode) or stat.S_ISSOCK(mode)):
                    special = True
        return entries, total_bytes, special
    finally:
        for descriptor in reversed(opened[1:]):
            try:
                os.close(descriptor)
            except OSError:
                pass


def remove_tree(parent_fd, name):
    """Best-effort recursive removal of a staged directory below ``parent_fd``."""
    try:
        metadata = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except OSError:
        return
    if not stat.S_ISDIR(metadata.st_mode):
        try:
            os.unlink(name, dir_fd=parent_fd)
        except OSError:
            pass
        return
    try:
        directory_fd = os.open(
            name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=parent_fd)
    except OSError:
        return
    try:
        for child in os.listdir(directory_fd):
            remove_tree(directory_fd, child)
    finally:
        os.close(directory_fd)
    try:
        os.rmdir(name, dir_fd=parent_fd)
    except OSError:
        pass


def require_absent(parent_fd, name):
    try:
        os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    fail(4, "output path already exists: {}".format(os.fsdecode(name)))


def fsync_directory(parent_fd):
    try:
        os.fsync(parent_fd)
    except OSError as error:
        if error.errno not in (errno.EINVAL, errno.ENOTSUP, getattr(
                errno, "EOPNOTSUPP", errno.ENOTSUP)):
            raise


def command_scan_specials(arguments):
    if len(arguments) != 1:
        fail(2, "scan-specials requires SOURCE_DIR")
    source = os.path.realpath(os.fsencode(arguments[0]))
    metadata = os.lstat(source)
    if not stat.S_ISDIR(metadata.st_mode):
        fail(2, "source is not a directory: {}".format(os.fsdecode(source)))
    root_fd = os.open(source, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        entries, total_bytes, special = scan_tree(root_fd)
    finally:
        os.close(root_fd)
    if special:
        fail(3, "source contains device nodes, sockets, or FIFOs that cannot "
                "be packaged rootlessly")
    print(json.dumps({"entries": entries, "bytes": total_bytes}))


def command_publish_file(arguments):
    if len(arguments) != 6:
        fail(2, "publish-file requires PARENT TEMP TARGET COMP ENTRIES JSON")
    parent, temp_name, target_name, compression, entries_text, json_text = \
        arguments
    emit_json = json_text == "1"
    parent_fd = open_absolute_directory(parent)
    try:
        require_absent(parent_fd, os.fsencode(target_name))
        descriptor = os.open(
            os.fsencode(temp_name), os.O_RDONLY | os.O_NOFOLLOW,
            dir_fd=parent_fd)
        try:
            staged = os.fstat(descriptor)
            if not stat.S_ISREG(staged.st_mode):
                fail(5, "staged module is not a regular file")
            size, digest = hash_regular_fd(descriptor)
            os.fchmod(descriptor, 0o644)
            os.fsync(descriptor)
            identity = (staged.st_dev, staged.st_ino)
        finally:
            os.close(descriptor)
        rename_noreplace(parent_fd, os.fsencode(temp_name),
                         os.fsencode(target_name), True)
        published = os.stat(os.fsencode(target_name), dir_fd=parent_fd,
                            follow_symlinks=False)
        if (published.st_dev, published.st_ino) != identity:
            fail(5, "published module identity changed")
        fsync_directory(parent_fd)
    finally:
        os.close(parent_fd)
    if emit_json:
        result = {
            "product": "dir2sb",
            "output": os.path.join(parent, target_name),
            "device": published.st_dev,
            "inode": published.st_ino,
            "size": size,
            "sha256": digest,
            "compression": compression,
        }
        try:
            result["source_entries"] = int(entries_text)
        except ValueError:
            pass
        print(json.dumps(result))


def command_publish_dir(arguments):
    if len(arguments) != 6:
        fail(2, "publish-dir requires PARENT TEMP TARGET SOURCE ALLOW JSON")
    parent, temp_name, target_name, source_file, allow_text, json_text = \
        arguments
    allow_special = allow_text == "1"
    emit_json = json_text == "1"
    parent_fd = open_absolute_directory(parent)
    try:
        require_absent(parent_fd, os.fsencode(target_name))
        directory_fd = os.open(
            os.fsencode(temp_name), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=parent_fd)
        try:
            entries, total_bytes, special = scan_tree(directory_fd)
            fsync_directory(directory_fd)
        finally:
            os.close(directory_fd)
        if special and not allow_special:
            remove_tree(parent_fd, os.fsencode(temp_name))
            fail(3, "extracted tree contains device nodes, sockets, or FIFOs; "
                    "re-run with the privileged special-object mode")
        source_descriptor = os.open(os.fsencode(source_file), os.O_RDONLY)
        try:
            source_meta = os.fstat(source_descriptor)
            if not stat.S_ISREG(source_meta.st_mode):
                fail(5, "source module is not a regular file")
            source_size, source_digest = hash_regular_fd(source_descriptor)
        finally:
            os.close(source_descriptor)
        rename_noreplace(parent_fd, os.fsencode(temp_name),
                         os.fsencode(target_name), False)
        published = os.stat(os.fsencode(target_name), dir_fd=parent_fd,
                            follow_symlinks=False)
        fsync_directory(parent_fd)
    finally:
        os.close(parent_fd)
    if emit_json:
        result = {
            "product": "sb2dir",
            "output": os.path.join(parent, target_name),
            "device": published.st_dev,
            "inode": published.st_ino,
            "entries": entries,
            "bytes": total_bytes,
            "source_size": source_size,
            "source_sha256": source_digest,
        }
        print(json.dumps(result))


COMMANDS = {
    "scan-specials": command_scan_specials,
    "publish-file": command_publish_file,
    "publish-dir": command_publish_dir,
}


def main(argv):
    if len(argv) < 2 or argv[1] not in COMMANDS:
        emit_error("unknown converter engine command")
        return 2
    try:
        COMMANDS[argv[1]](argv[2:])
    except EngineError as error:
        emit_error(error.message)
        return error.status
    except FileNotFoundError as error:
        emit_error("missing path: {}".format(error))
        return 2
    except OSError as error:
        emit_error("filesystem error: {}".format(error))
        return 5
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
