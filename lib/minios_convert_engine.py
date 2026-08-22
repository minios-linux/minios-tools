#!/usr/bin/env python3
# Filesystem engine for MiniOS Tools converters and module-store operations.
# Validates staged content, computes identities, and performs no-follow,
# no-replace filesystem mutations.
from __future__ import print_function

import ctypes
import errno
import hashlib
import json
import os
import pwd
import stat
import subprocess
import sys
import sysconfig


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


def _syscall_abi(machine=None, multiarch=None, pointer_size=None):
    machine = machine or os.uname().machine
    if multiarch is None:
        multiarch = sysconfig.get_config_var("MULTIARCH") or ""
    pointer_size = pointer_size or ctypes.sizeof(ctypes.c_void_p)
    token = multiarch.split("-", 1)[0]
    aliases = {
        "amd64": "x86_64",
        "arm64": "aarch64",
        "armv7l": "arm",
        "i386": "i386",
        "i486": "i386",
        "i586": "i386",
        "i686": "i386",
        "powerpc64le": "ppc64le",
    }
    if token in aliases:
        return aliases[token]
    if token in ("aarch64", "arm", "ppc64", "ppc64le", "riscv64", "s390x",
                 "x86_64"):
        return token
    if machine in ("i386", "i486", "i586", "i686", "x86_64"):
        return "x86_64" if pointer_size == 8 else "i386"
    return aliases.get(machine, machine)


def _load_renameat2(force_syscall=False):
    try:
        libc = ctypes.CDLL(None, use_errno=True)
    except OSError:
        return None
    if not force_syscall:
        try:
            symbol = libc.renameat2
        except AttributeError:
            pass
        else:
            symbol.restype = ctypes.c_int
            symbol.argtypes = [
                ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p,
                ctypes.c_uint]
            return symbol

    numbers = {
        "aarch64": 276,
        "arm": 382,
        "i386": 353,
        "ppc64": 357,
        "ppc64le": 357,
        "riscv64": 276,
        "s390x": 347,
        "x86_64": 316,
    }
    number = numbers.get(_syscall_abi())
    if number is None:
        return None
    syscall = libc.syscall
    syscall.restype = ctypes.c_long

    def call(source_fd, source, target_fd, target, flags):
        return syscall(
            ctypes.c_long(number), ctypes.c_int(source_fd),
            ctypes.c_char_p(source), ctypes.c_int(target_fd),
            ctypes.c_char_p(target), ctypes.c_uint(flags))

    return call


_RENAMEAT2 = _load_renameat2()


def rename_noreplace(source_fd, source, target_fd, target, allow_link_fallback):
    """Atomically publish ``source`` as ``target`` refusing to overwrite.

    Uses ``renameat2(RENAME_NOREPLACE)`` when the kernel and filesystem
    support it. For regular files an ``O_EXCL`` hard link plus source unlink is
    an equally atomic fallback. Directory publication fails closed when atomic
    no-replace rename is unavailable.
    """
    source_bytes = source if isinstance(source, bytes) else os.fsencode(source)
    target_bytes = target if isinstance(target, bytes) else os.fsencode(target)
    if _RENAMEAT2 is not None:
        result = _RENAMEAT2(source_fd, source_bytes, target_fd,
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
        source_metadata = os.stat(
            source_bytes, dir_fd=source_fd, follow_symlinks=False)
        source_identity = (source_metadata.st_dev, source_metadata.st_ino)
        try:
            os.link(source_bytes, target_bytes, src_dir_fd=source_fd,
                    dst_dir_fd=target_fd, follow_symlinks=False)
        except FileExistsError:
            fail(4, "output path already exists: {}".format(
                os.fsdecode(target_bytes)))
        try:
            os.unlink(source_bytes, dir_fd=source_fd)
        except OSError:
            target_metadata = os.stat(
                target_bytes, dir_fd=target_fd, follow_symlinks=False)
            if ((target_metadata.st_dev, target_metadata.st_ino) ==
                    source_identity):
                os.unlink(target_bytes, dir_fd=target_fd)
            raise
        return
    fail(5, "atomic no-replace directory publication is unsupported")


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
    """Recursively remove an object below a private directory."""
    try:
        metadata = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return True
    if not stat.S_ISDIR(metadata.st_mode):
        try:
            current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            if ((current.st_dev, current.st_ino) !=
                    (metadata.st_dev, metadata.st_ino)):
                return False
            os.unlink(name, dir_fd=parent_fd)
        except FileNotFoundError:
            pass
        return True
    try:
        directory_fd = os.open(
            name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=parent_fd)
    except FileNotFoundError:
        return True
    try:
        opened = os.fstat(directory_fd)
        if ((opened.st_dev, opened.st_ino) !=
                (metadata.st_dev, metadata.st_ino)):
            return False
        for child in os.listdir(directory_fd):
            if not remove_tree(directory_fd, child):
                return False
    finally:
        os.close(directory_fd)
    try:
        current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if ((current.st_dev, current.st_ino) !=
                (metadata.st_dev, metadata.st_ino)):
            return False
        os.rmdir(name, dir_fd=parent_fd)
    except FileNotFoundError:
        pass
    return True


def parse_identity(device_text, inode_text):
    try:
        return int(device_text), int(inode_text)
    except ValueError:
        fail(2, "invalid workspace identity")


def open_workspace(parent_fd, name, expected):
    name_bytes = os.fsencode(name)
    if not name or b"/" in name_bytes or name in (".", ".."):
        fail(2, "invalid workspace name")
    descriptor = os.open(
        name_bytes, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
        dir_fd=parent_fd)
    metadata = os.fstat(descriptor)
    if ((metadata.st_dev, metadata.st_ino) != expected or
            metadata.st_uid != os.geteuid() or
            stat.S_IMODE(metadata.st_mode) != 0o700):
        os.close(descriptor)
        fail(5, "workspace identity or permissions changed")
    return descriptor


def remove_workspace(parent_fd, name, expected):
    descriptor = open_workspace(parent_fd, name, expected)
    try:
        for child in os.listdir(descriptor):
            if not remove_tree(descriptor, child):
                fail(5, "workspace cleanup failed")
    finally:
        os.close(descriptor)
    current = os.stat(os.fsencode(name), dir_fd=parent_fd,
                      follow_symlinks=False)
    if (current.st_dev, current.st_ino) != expected:
        fail(5, "workspace identity changed during cleanup")
    os.rmdir(os.fsencode(name), dir_fd=parent_fd)


def command_create_workspace(arguments):
    if len(arguments) != 2:
        fail(2, "create-workspace requires PARENT PREFIX")
    parent, prefix = arguments
    prefix_bytes = os.fsencode(prefix)
    if not prefix or b"/" in prefix_bytes:
        fail(2, "invalid workspace prefix")
    parent_fd = open_absolute_directory(parent)
    try:
        parent_metadata = os.fstat(parent_fd)
        mode = stat.S_IMODE(parent_metadata.st_mode)
        if mode & 0o022 and not mode & stat.S_ISVTX:
            fail(5, "workspace parent is writable without sticky protection")
        for _ in range(128):
            name = prefix + os.urandom(12).hex()
            try:
                os.mkdir(os.fsencode(name), 0o700, dir_fd=parent_fd)
            except FileExistsError:
                continue
            descriptor = os.open(
                os.fsencode(name),
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=parent_fd)
            try:
                os.fchmod(descriptor, 0o700)
                metadata = os.fstat(descriptor)
            finally:
                os.close(descriptor)
            print("{} {} {}".format(
                name, metadata.st_dev, metadata.st_ino))
            return
    finally:
        os.close(parent_fd)
    fail(4, "cannot reserve a private workspace")


def command_cleanup_workspace(arguments):
    if len(arguments) != 4:
        fail(2, "cleanup-workspace requires PARENT NAME DEVICE INODE")
    parent, name, device_text, inode_text = arguments
    parent_fd = open_absolute_directory(parent)
    try:
        remove_workspace(
            parent_fd, name, parse_identity(device_text, inode_text))
        fsync_directory(parent_fd)
    finally:
        os.close(parent_fd)


def require_absent(parent_fd, name):
    try:
        os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    fail(4, "output path already exists: {}".format(os.fsdecode(name)))


def rollback_published(parent_fd, name, expected, directory):
    try:
        current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    if (current.st_dev, current.st_ino) != expected:
        fail(5, "published output identity changed; refusing rollback")
    if directory:
        if not remove_tree(parent_fd, name):
            fail(5, "published directory rollback failed")
    else:
        os.unlink(name, dir_fd=parent_fd)
    fsync_directory(parent_fd)


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
    root_fd = os.open(source, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        metadata = os.fstat(root_fd)
        entries, total_bytes, special = scan_tree(root_fd)
    finally:
        os.close(root_fd)
    if special:
        fail(3, "source contains device nodes, sockets, or FIFOs that cannot "
                "be packaged rootlessly")
    print(json.dumps({
        "entries": entries,
        "bytes": total_bytes,
        "device": metadata.st_dev,
        "inode": metadata.st_ino,
    }))


def command_publish_file(arguments):
    if len(arguments) != 9:
        fail(2, "publish-file requires PARENT WORK DEV INO TEMP TARGET COMP "
                "ENTRIES JSON")
    parent, work_name, device_text, inode_text, temp_name, target_name, \
        compression, entries_text, json_text = arguments
    emit_json = json_text == "1"
    expected_workspace = parse_identity(device_text, inode_text)
    parent_fd = open_absolute_directory(parent)
    workspace_fd = -1
    descriptor = -1
    published_identity = None
    try:
        require_absent(parent_fd, os.fsencode(target_name))
        workspace_fd = open_workspace(
            parent_fd, work_name, expected_workspace)
        descriptor = os.open(
            os.fsencode(temp_name), os.O_RDONLY | os.O_NOFOLLOW,
            dir_fd=workspace_fd)
        staged = os.fstat(descriptor)
        if not stat.S_ISREG(staged.st_mode):
            fail(5, "staged module is not a regular file")
        named = os.stat(os.fsencode(temp_name), dir_fd=workspace_fd,
                        follow_symlinks=False)
        if ((named.st_dev, named.st_ino) !=
                (staged.st_dev, staged.st_ino)):
            fail(5, "staged module identity changed")
        size, digest = hash_regular_fd(descriptor)
        os.fchmod(descriptor, 0o644)
        os.fsync(descriptor)
        identity = (staged.st_dev, staged.st_ino)
        rename_noreplace(
            workspace_fd, os.fsencode(temp_name), parent_fd,
            os.fsencode(target_name), True)
        published_identity = identity
        published = os.stat(os.fsencode(target_name), dir_fd=parent_fd,
                            follow_symlinks=False)
        if (published.st_dev, published.st_ino) != identity:
            fail(5, "published module identity changed")
        fsync_directory(parent_fd)
        os.close(workspace_fd)
        workspace_fd = -1
        remove_workspace(parent_fd, work_name, expected_workspace)
        fsync_directory(parent_fd)
    except BaseException:
        if published_identity is not None:
            rollback_published(
                parent_fd, os.fsencode(target_name),
                published_identity, False)
        raise
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if workspace_fd >= 0:
            os.close(workspace_fd)
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
    if len(arguments) != 9:
        fail(2, "publish-dir requires PARENT WORK DEV INO TEMP TARGET SOURCE "
                "ALLOW JSON")
    parent, work_name, device_text, inode_text, temp_name, target_name, \
        source_file, allow_text, json_text = arguments
    allow_special = allow_text == "1"
    emit_json = json_text == "1"
    expected_workspace = parse_identity(device_text, inode_text)
    parent_fd = open_absolute_directory(parent)
    workspace_fd = -1
    directory_fd = -1
    published_identity = None
    try:
        require_absent(parent_fd, os.fsencode(target_name))
        workspace_fd = open_workspace(
            parent_fd, work_name, expected_workspace)
        directory_fd = os.open(
            os.fsencode(temp_name), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=workspace_fd)
        staged = os.fstat(directory_fd)
        named = os.stat(os.fsencode(temp_name), dir_fd=workspace_fd,
                        follow_symlinks=False)
        if ((named.st_dev, named.st_ino) !=
                (staged.st_dev, staged.st_ino)):
            fail(5, "staged directory identity changed")
        entries, total_bytes, special = scan_tree(directory_fd)
        fsync_directory(directory_fd)
        if special and not allow_special:
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
        identity = (staged.st_dev, staged.st_ino)
        rename_noreplace(
            workspace_fd, os.fsencode(temp_name), parent_fd,
            os.fsencode(target_name), False)
        published_identity = identity
        published = os.stat(os.fsencode(target_name), dir_fd=parent_fd,
                            follow_symlinks=False)
        if (published.st_dev, published.st_ino) != identity:
            fail(5, "published directory identity changed")
        fsync_directory(parent_fd)
        os.close(workspace_fd)
        workspace_fd = -1
        remove_workspace(parent_fd, work_name, expected_workspace)
        fsync_directory(parent_fd)
    except BaseException:
        if published_identity is not None:
            rollback_published(
                parent_fd, os.fsencode(target_name),
                published_identity, True)
        raise
    finally:
        if directory_fd >= 0:
            os.close(directory_fd)
        if workspace_fd >= 0:
            os.close(workspace_fd)
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


def command_check_workspace(arguments):
    if len(arguments) != 4:
        fail(2, "check-workspace requires PARENT NAME DEVICE INODE")
    parent, name, device_text, inode_text = arguments
    parent_fd = open_absolute_directory(parent)
    descriptor = -1
    try:
        descriptor = open_workspace(
            parent_fd, name, parse_identity(device_text, inode_text))
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(parent_fd)


def command_ensure_directory(arguments):
    if len(arguments) != 2:
        fail(2, "ensure-directory requires ROOT RELATIVE")
    root, relative = arguments
    parts = [os.fsencode(item) for item in relative.split("/") if item]
    if not parts or any(item in (b".", b"..") for item in parts):
        fail(2, "invalid relative directory")
    descriptors = [open_absolute_directory(root)]
    try:
        for component in parts:
            parent_fd = descriptors[-1]
            created = False
            try:
                os.mkdir(component, 0o755, dir_fd=parent_fd)
                created = True
            except FileExistsError:
                pass
            child_fd = os.open(
                component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=parent_fd)
            descriptors.append(child_fd)
            if created:
                fsync_directory(parent_fd)
        fsync_directory(descriptors[-1])
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


def command_remove_file(arguments):
    if len(arguments) != 1:
        fail(2, "remove-file requires PATH")
    source = os.path.abspath(os.fsencode(arguments[0]))
    parent, name = os.path.split(source)
    if not name:
        fail(2, "invalid file path")
    parent_fd = open_absolute_directory(parent)
    try:
        metadata = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if not (stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode)):
            fail(5, "path is not a file")
        os.unlink(name, dir_fd=parent_fd)
        fsync_directory(parent_fd)
    finally:
        os.close(parent_fd)


def caller_identity(uid_text):
    if not uid_text:
        return None
    try:
        uid = int(uid_text)
    except ValueError:
        fail(2, "invalid caller uid")
    try:
        return pwd.getpwuid(uid)
    except KeyError:
        fail(2, "caller uid does not exist")


def open_as_caller(path, flags, uid_text, mode=0o666, dir_fd=None):
    account = caller_identity(uid_text)
    if account is None:
        return os.open(path, flags, mode, dir_fd=dir_fd)
    original_euid = os.geteuid()
    original_egid = os.getegid()
    original_groups = os.getgroups()
    try:
        os.initgroups(account.pw_name, account.pw_gid)
        os.setegid(account.pw_gid)
        os.seteuid(account.pw_uid)
        return os.open(path, flags, mode, dir_fd=dir_fd)
    finally:
        os.seteuid(original_euid)
        os.setgroups(original_groups)
        os.setegid(original_egid)


def open_source_for_caller(path, uid_text, directory=False):
    path_bytes = os.path.realpath(os.fsencode(path))
    flags = os.O_RDONLY | os.O_NOFOLLOW
    if directory:
        flags |= os.O_DIRECTORY
    return open_as_caller(path_bytes, flags, uid_text)


def open_child_for_caller(parent_fd, name, flags, uid_text):
    before = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    descriptor = open_as_caller(name, flags, uid_text, dir_fd=parent_fd)
    after = os.fstat(descriptor)
    if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
        os.close(descriptor)
        fail(5, "source entry changed during copy")
    return descriptor, before


def remove_destination_entry(parent_fd, name, allow_directory=False):
    try:
        metadata = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    if stat.S_ISDIR(metadata.st_mode):
        if allow_directory:
            return
        fail(5, "cannot replace destination directory with a non-directory")
    os.unlink(name, dir_fd=parent_fd)


def apply_regular_metadata(descriptor, metadata):
    os.fchmod(descriptor, stat.S_IMODE(metadata.st_mode))
    os.fchown(descriptor, metadata.st_uid, metadata.st_gid)
    try:
        os.utime(descriptor, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
    except (AttributeError, OSError):
        pass


def copy_regular_entry(source_fd, target_fd, name, metadata, caller_uid):
    source, current = open_child_for_caller(
        source_fd, name, os.O_RDONLY | os.O_NOFOLLOW, caller_uid)
    try:
        if not stat.S_ISREG(current.st_mode):
            fail(5, "source entry type changed during copy")
        remove_destination_entry(target_fd, name)
        destination = os.open(
            name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600, dir_fd=target_fd)
        try:
            while True:
                block = os.read(source, BLOCK_SIZE)
                if not block:
                    break
                offset = 0
                while offset < len(block):
                    offset += os.write(destination, block[offset:])
            apply_regular_metadata(destination, metadata)
            os.fsync(destination)
        finally:
            os.close(destination)
    finally:
        os.close(source)


def copy_symlink_entry(source_fd, target_fd, name, metadata):
    target = os.readlink(name, dir_fd=source_fd)
    current = os.stat(name, dir_fd=source_fd, follow_symlinks=False)
    if (current.st_dev, current.st_ino) != (metadata.st_dev, metadata.st_ino):
        fail(5, "source symlink changed during copy")
    remove_destination_entry(target_fd, name)
    os.symlink(target, name, dir_fd=target_fd)
    try:
        os.chown(
            name, metadata.st_uid, metadata.st_gid,
            dir_fd=target_fd, follow_symlinks=False)
    except (NotImplementedError, OSError):
        pass


def open_or_create_target_directory(target_fd, name, metadata):
    try:
        current = os.stat(name, dir_fd=target_fd, follow_symlinks=False)
    except FileNotFoundError:
        current = None
    if current is not None and not stat.S_ISDIR(current.st_mode):
        os.unlink(name, dir_fd=target_fd)
        current = None
    if current is None:
        os.mkdir(name, 0o700, dir_fd=target_fd)
    descriptor = os.open(
        name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
        dir_fd=target_fd)
    os.fchmod(descriptor, stat.S_IMODE(metadata.st_mode))
    os.fchown(descriptor, metadata.st_uid, metadata.st_gid)
    return descriptor


def copy_tree_contents(source_fd, target_fd, caller_uid):
    for name_text in os.listdir(source_fd):
        name = os.fsencode(name_text)
        metadata = os.stat(name, dir_fd=source_fd, follow_symlinks=False)
        if stat.S_ISREG(metadata.st_mode):
            copy_regular_entry(source_fd, target_fd, name, metadata, caller_uid)
        elif stat.S_ISLNK(metadata.st_mode):
            copy_symlink_entry(source_fd, target_fd, name, metadata)
        elif stat.S_ISDIR(metadata.st_mode):
            child_source, current = open_child_for_caller(
                source_fd, name,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, caller_uid)
            try:
                if not stat.S_ISDIR(current.st_mode):
                    fail(5, "source directory changed during copy")
                child_target = open_or_create_target_directory(
                    target_fd, name, metadata)
                try:
                    copy_tree_contents(child_source, child_target, caller_uid)
                    fsync_directory(child_target)
                finally:
                    os.close(child_target)
            finally:
                os.close(child_source)
        else:
            fail(3, "source tree contains unsupported special files")
    fsync_directory(target_fd)


def command_copy_tree(arguments):
    if len(arguments) != 3:
        fail(2, "copy-tree requires SOURCE TARGET CALLER_UID")
    source, target, caller_uid = arguments
    source_fd = open_source_for_caller(source, caller_uid, directory=True)
    target_fd = open_absolute_directory(target)
    try:
        copy_tree_contents(source_fd, target_fd, caller_uid)
    finally:
        os.close(source_fd)
        os.close(target_fd)


def command_copy_module(arguments):
    if len(arguments) != 5:
        fail(2, "copy-module requires SOURCE TARGET_DIR TARGET_NAME UNSQUASHFS CALLER_UID")
    source, target_dir, target_name, unsquashfs, caller_uid = arguments
    target_raw = os.fsencode(target_name)
    if not target_name or b"/" in target_raw or target_name in (".", ".."):
        fail(2, "invalid target filename")

    source_fd = open_source_for_caller(source, caller_uid)
    parent_fd = open_absolute_directory(target_dir)
    temp_fd = -1
    temp_name = None
    published_identity = None
    try:
        source_meta = os.fstat(source_fd)
        if not stat.S_ISREG(source_meta.st_mode) or source_meta.st_size <= 0:
            fail(2, "source module is not a nonempty regular file")
        require_absent(parent_fd, target_raw)
        for _ in range(128):
            candidate = (b".minios-module-" +
                         os.urandom(12).hex().encode("ascii") + b".tmp")
            try:
                temp_fd = os.open(
                    candidate, os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                    0o600, dir_fd=parent_fd)
            except FileExistsError:
                continue
            temp_name = candidate
            break
        if temp_fd < 0:
            fail(4, "cannot reserve temporary module file")

        while True:
            block = os.read(source_fd, BLOCK_SIZE)
            if not block:
                break
            offset = 0
            while offset < len(block):
                offset += os.write(temp_fd, block[offset:])
        os.fchmod(temp_fd, 0o644)
        os.fsync(temp_fd)
        staged = os.fstat(temp_fd)
        identity = (staged.st_dev, staged.st_ino)
        os.close(temp_fd)
        temp_fd = -1

        validation_fd = os.open(
            temp_name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent_fd)
        try:
            validation_path = "/proc/{}/fd/{}".format(
                os.getpid(), validation_fd)
            status = subprocess.call(
                [unsquashfs, "-s", validation_path],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                pass_fds=(validation_fd,))
            if status != 0:
                fail(5, "staged module is not a valid SquashFS filesystem")
        finally:
            os.close(validation_fd)

        rename_noreplace(parent_fd, temp_name, parent_fd, target_raw, True)
        published_identity = identity
        published = os.stat(target_raw, dir_fd=parent_fd, follow_symlinks=False)
        if (published.st_dev, published.st_ino) != identity:
            fail(5, "published module identity changed")
        fsync_directory(parent_fd)
    except BaseException:
        if temp_fd >= 0:
            os.close(temp_fd)
        if temp_name is not None:
            try:
                os.unlink(temp_name, dir_fd=parent_fd)
            except FileNotFoundError:
                pass
        if published_identity is not None:
            rollback_published(parent_fd, target_raw, published_identity, False)
        raise
    finally:
        os.close(source_fd)
        os.close(parent_fd)


def command_check_input(arguments):
    if len(arguments) != 3:
        fail(2, "check-input requires TYPE SOURCE CALLER_UID")
    kind, source, caller_uid = arguments
    if kind not in ("file", "directory"):
        fail(2, "invalid input type")
    descriptor = open_source_for_caller(
        source, caller_uid, directory=kind == "directory")
    try:
        metadata = os.fstat(descriptor)
        if kind == "file" and not stat.S_ISREG(metadata.st_mode):
            fail(2, "source is not a regular file")
        if kind == "directory" and not stat.S_ISDIR(metadata.st_mode):
            fail(2, "source is not a directory")
    finally:
        os.close(descriptor)


def command_copy_input(arguments):
    if len(arguments) != 3:
        fail(2, "copy-input requires SOURCE TARGET CALLER_UID")
    source, target, caller_uid = arguments
    target_raw = os.path.abspath(os.fsencode(target))
    parent, name = os.path.split(target_raw)
    if not name:
        fail(2, "invalid target path")
    source_fd = open_source_for_caller(source, caller_uid)
    parent_fd = open_absolute_directory(parent)
    target_fd = -1
    identity = None
    try:
        source_meta = os.fstat(source_fd)
        if not stat.S_ISREG(source_meta.st_mode):
            fail(2, "source is not a regular file")
        require_absent(parent_fd, name)
        target_fd = os.open(
            name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o644, dir_fd=parent_fd)
        created = os.fstat(target_fd)
        identity = (created.st_dev, created.st_ino)
        while True:
            block = os.read(source_fd, BLOCK_SIZE)
            if not block:
                break
            offset = 0
            while offset < len(block):
                offset += os.write(target_fd, block[offset:])
        os.fsync(target_fd)
        fsync_directory(parent_fd)
    except BaseException:
        if identity is not None:
            try:
                current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
                if (current.st_dev, current.st_ino) == identity:
                    os.unlink(name, dir_fd=parent_fd)
                    fsync_directory(parent_fd)
            except FileNotFoundError:
                pass
        raise
    finally:
        if target_fd >= 0:
            os.close(target_fd)
        os.close(source_fd)
        os.close(parent_fd)


COMMANDS = {
    "create-workspace": command_create_workspace,
    "cleanup-workspace": command_cleanup_workspace,
    "check-workspace": command_check_workspace,
    "scan-specials": command_scan_specials,
    "publish-file": command_publish_file,
    "publish-dir": command_publish_dir,
    "ensure-directory": command_ensure_directory,
    "remove-file": command_remove_file,
    "copy-module": command_copy_module,
    "check-input": command_check_input,
    "copy-input": command_copy_input,
    "copy-tree": command_copy_tree,
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
