# Capture engine for savechanges.
# Inventories writable union changes, preserves profile-required metadata,
# builds and verifies SquashFS modules, and supports bounded cancellation.
from __future__ import print_function

import ctypes
import errno
import hashlib
import json
import os
import posixpath
import re
import signal
import stat
import subprocess
import sys
import threading
import time


class CaptureError(Exception):
    pass


class Cancelled(Exception):
    pass


CURRENT_CHILD = None
CURRENT_PGID = None
STRIPPED_XATTRS = 0
CANCEL_FD = None
CANCEL_NAME = None
CANCEL_PARENT = None
CANCEL_PARENT_IDENTITY = None
CANCEL_OWNER_UID = None
CANCEL_EVENT = threading.Event()
CANCEL_STOP = threading.Event()
CANCEL_MONITOR = None
CANCEL_RAISED = False
JSON_MODE = False
TEST_MODE = False


def json_event(event):
    print(json.dumps(event, ensure_ascii=True, allow_nan=False, sort_keys=True,
                     separators=(",", ":")), flush=True)


def fail(message):
    raise CaptureError(message)


def information(message):
    print("I: {}".format(message), file=sys.stderr if JSON_MODE else sys.stdout, flush=True)


def warning(message):
    print("W: {}".format(message), file=sys.stderr if JSON_MODE else sys.stdout, flush=True)


def cancel_parent_is_current():
    if CANCEL_FD is None:
        return True
    try:
        held = os.fstat(CANCEL_FD)
        if (not stat.S_ISDIR(held.st_mode) or stat.S_IMODE(held.st_mode) != 0o700 or
                held.st_uid != CANCEL_OWNER_UID):
            return False
        current_fd = open_absolute_directory(CANCEL_PARENT)
        try:
            current = os.fstat(current_fd)
            return (current.st_dev, current.st_ino) == CANCEL_PARENT_IDENTITY
        finally:
            os.close(current_fd)
    except OSError:
        return False


def cancel_marker_exists():
    if CANCEL_FD is None:
        return False
    if not cancel_parent_is_current():
        return True
    try:
        os.stat(CANCEL_NAME, dir_fd=CANCEL_FD, follow_symlinks=False)
    except FileNotFoundError:
        return False
    except OSError:
        return True
    return True


def check_cancelled():
    global CANCEL_RAISED
    if CANCEL_EVENT.is_set() or cancel_marker_exists():
        CANCEL_EVENT.set()
        request_child_termination(CURRENT_PGID)
        CANCEL_RAISED = True
        raise Cancelled()


def cancel_monitor():
    while not CANCEL_STOP.wait(0.05):
        if not cancel_marker_exists():
            continue
        CANCEL_EVENT.set()
        request_child_termination(CURRENT_PGID)
        if not CANCEL_STOP.is_set():
            try:
                os.kill(os.getpid(), signal.SIGUSR1)
            except ProcessLookupError:
                pass
        return


def configure_cancel_marker(path, owner_uid):
    global CANCEL_FD, CANCEL_NAME, CANCEL_PARENT, CANCEL_PARENT_IDENTITY
    global CANCEL_OWNER_UID, CANCEL_MONITOR
    if not path:
        return
    encoded = os.fsencode(path)
    if (not encoded.startswith(b"/") or os.path.normpath(encoded) != encoded or
            os.path.basename(encoded) in (b"", b".", b"..")):
        fail("invalid cancel marker path")
    parent = os.path.dirname(encoded)
    descriptor = None
    try:
        descriptor = open_absolute_directory(parent)
        verification_fd = open_absolute_directory(parent)
    except OSError:
        if descriptor is not None:
            os.close(descriptor)
        fail("invalid cancel marker parent")
    try:
        metadata = os.fstat(descriptor)
        verification = os.fstat(verification_fd)
        if (metadata.st_dev, metadata.st_ino) != (verification.st_dev, verification.st_ino):
            fail("cancel marker parent changed during validation")
    finally:
        os.close(verification_fd)
    if (not stat.S_ISDIR(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o700 or
            metadata.st_uid != owner_uid):
        os.close(descriptor)
        fail("cancel marker parent must be mode 0700 and owned by the original user")
    name = os.path.basename(encoded)
    try:
        os.stat(name, dir_fd=descriptor, follow_symlinks=False)
    except FileNotFoundError:
        pass
    except OSError:
        os.close(descriptor)
        fail("cannot validate initial cancel marker state")
    else:
        os.close(descriptor)
        fail("cancel marker must not initially exist")
    CANCEL_FD = descriptor
    CANCEL_NAME = name
    CANCEL_PARENT = parent
    CANCEL_PARENT_IDENTITY = (metadata.st_dev, metadata.st_ino)
    CANCEL_OWNER_UID = owner_uid
    CANCEL_MONITOR = threading.Thread(target=cancel_monitor, name="savechanges-cancel",
                                      daemon=True)
    CANCEL_MONITOR.start()
    check_cancelled()


def shutdown_cancel_monitor():
    global CANCEL_FD, CANCEL_MONITOR
    CANCEL_STOP.set()
    if CANCEL_MONITOR is not None:
        CANCEL_MONITOR.join(timeout=1)
        CANCEL_MONITOR = None
    if CANCEL_FD is not None:
        os.close(CANCEL_FD)
        CANCEL_FD = None


def phase(identifier, message):
    check_cancelled()
    if JSON_MODE:
        names = {
            "capture-inventory": "inventory",
            "capture-copy": "capture",
            "capture-compress": "compress",
            "capture-complete": "complete",
        }
        json_event({"type": "phase", "phase": names.get(identifier, identifier)})
    else:
        print("P:{}".format(identifier), flush=True)
    information(message)
    check_cancelled()


def machine_phase(identifier):
    if JSON_MODE:
        check_cancelled()
        json_event({"type": "phase", "phase": identifier})
        check_cancelled()


def enter_commit_boundary():
    check_cancelled()
    shutdown_cancel_monitor()
    check_cancelled()
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGUSR1, signal.SIG_IGN)


def emit_complete(message, result):
    if JSON_MODE:
        json_event({"type": "phase", "phase": "complete"})
        information(message)
        json_event(result)
    else:
        print("P:capture-complete", flush=True)
        information(message)


def trusted_tool(path, test_mode):
    resolved = os.path.realpath(os.fsencode(path))
    metadata = os.stat(resolved, follow_symlinks=False)
    if not stat.S_ISREG(metadata.st_mode) or not os.access(resolved, os.X_OK):
        fail("capture tool is not an executable regular file")
    if not test_mode and (metadata.st_uid != 0 or stat.S_IMODE(metadata.st_mode) & 0o022):
        fail("capture tool is not trusted: {}".format(os.fsdecode(resolved)))
    return os.fsdecode(resolved)


def open_absolute_directory(path):
    path_bytes = os.path.abspath(os.fsencode(path))
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(b"/", flags)
    try:
        for component in path_bytes.split(b"/"):
            if not component:
                continue
            next_descriptor = os.open(component, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = next_descriptor
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def canonical_directory(path):
    canonical = os.path.abspath(os.fsencode(path))
    descriptor = open_absolute_directory(canonical)
    return canonical, descriptor, os.fstat(descriptor)


def open_input_directory(path):
    absolute = os.path.abspath(os.fsencode(path))
    if absolute == b"/":
        return absolute, open_absolute_directory(absolute)
    parent = os.path.realpath(os.path.dirname(absolute))
    parent_fd = open_absolute_directory(parent)
    name = os.path.basename(absolute)
    try:
        metadata = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if not stat.S_ISDIR(metadata.st_mode):
            fail("changes path is not a non-symlink directory")
        descriptor = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                             dir_fd=parent_fd)
    finally:
        os.close(parent_fd)
    return os.path.join(parent, name), descriptor


def split_output(path):
    absolute = os.path.abspath(os.fsencode(path))
    basename = os.path.basename(absolute)
    if not basename or basename in (b".", b"..") or b"/" in basename:
        fail("invalid output basename")
    parent, descriptor, metadata = canonical_directory(os.path.dirname(absolute))
    return parent, descriptor, metadata, basename


def safe_parent_fd(root_fd, path):
    components = path.split(b"/")
    descriptor = os.dup(root_fd)
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        for component in components[:-1]:
            next_descriptor = os.open(component, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = next_descriptor
        return descriptor, components[-1]
    except Exception:
        os.close(descriptor)
        raise


def safe_lstat(root_fd, path):
    parent_fd, name = safe_parent_fd(root_fd, path)
    try:
        return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    finally:
        os.close(parent_fd)


def safe_open_dir(root_fd, path):
    if not path:
        return os.dup(root_fd)
    descriptor = os.dup(root_fd)
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        for component in path.split(b"/"):
            next_descriptor = os.open(component, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = next_descriptor
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def decode_mount_field(value):
    for encoded, decoded in ((b"\\040", b" "), (b"\\011", b"\t"),
                             (b"\\012", b"\n"), (b"\\134", b"\\")):
        value = value.replace(encoded, decoded)
    return value


def read_aufs_branches(sysfs_path, session_id):
    sysfs_path = os.fsencode(sysfs_path)
    if not re.match(br"^[A-Za-z0-9_-]+$", session_id):
        fail("mounted AUFS root reports an invalid session identifier")
    session_path = os.path.join(sysfs_path, b"si_" + session_id)
    try:
        names = os.listdir(session_path)
    except OSError:
        fail("mounted AUFS branch information is unavailable")
    branches = []
    for name in names:
        encoded = os.fsencode(name)
        match = re.match(br"^br([0-9]+)$", encoded)
        if not match:
            continue
        branches.append((int(match.group(1)), encoded))
    if not branches or len(branches) > 4096:
        fail("mounted AUFS branch information is invalid")
    branches.sort()
    if [index for index, _name in branches] != list(range(len(branches))):
        fail("mounted AUFS branch order is incomplete")
    upperdir = None
    lowerdirs = []
    for _index, name in branches:
        path = os.path.join(session_path, name)
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            value = os.read(descriptor, 1024 * 1024).rstrip(b"\n")
        finally:
            os.close(descriptor)
        if b"=" not in value:
            fail("mounted AUFS branch record is invalid")
        branch_path, branch_mode = value.rsplit(b"=", 1)
        branch_path = decode_mount_field(branch_path)
        if not branch_path.startswith(b"/") or not branch_mode:
            fail("mounted AUFS branch record is invalid")
        if branch_mode.startswith(b"rw"):
            if upperdir is not None:
                fail("mounted AUFS root reports multiple writable branches")
            upperdir = branch_path
        else:
            lowerdirs.append(branch_path)
    return upperdir, lowerdirs


def read_root_mount(mountinfo_path, aufs_sysfs_path, mounted_root):
    mounted_root = os.path.normpath(os.fsencode(mounted_root))
    try:
        with open(mountinfo_path, "rb") as stream:
            lines = stream.readlines()
    except OSError:
        fail("cannot read mounted root filesystem information")
    for line in lines:
        sections = line.rstrip(b"\n").split(b" - ", 1)
        if len(sections) != 2:
            continue
        mounted = sections[0].split()
        filesystem = sections[1].split()
        if len(mounted) < 5 or len(filesystem) < 3 or decode_mount_field(mounted[4]) != mounted_root:
            continue
        fstype = filesystem[0]
        options = filesystem[2].split(b",")
        upperdir = None
        lowerdirs = []
        aufs_session_id = None
        for option in options:
            if option.startswith(b"upperdir="):
                upperdir = decode_mount_field(option.split(b"=", 1)[1])
            elif option.startswith(b"lowerdir="):
                lowerdirs = [decode_mount_field(item) for item in
                             option.split(b"=", 1)[1].split(b":") if item]
            elif fstype == b"aufs" and option.startswith((b"br:", b"br=")):
                branches = option[3:].split(b":")
                for branch in branches:
                    if b"=" not in branch:
                        continue
                    path, branch_mode = branch.rsplit(b"=", 1)
                    if branch_mode.startswith(b"rw"):
                        if upperdir is not None:
                            fail("mounted AUFS root reports multiple writable branches")
                        upperdir = decode_mount_field(path)
                    else:
                        lowerdirs.append(decode_mount_field(path))
            elif fstype == b"aufs" and option.startswith(b"si="):
                aufs_session_id = option.split(b"=", 1)[1]
        if fstype == b"aufs" and upperdir is None and aufs_session_id:
            upperdir, lowerdirs = read_aufs_branches(aufs_sysfs_path, aufs_session_id)
        return fstype, upperdir, lowerdirs
    fail("mounted capture root is absent from mountinfo")


def read_union_intent(cmdline_path):
    try:
        with open(cmdline_path, "rb") as stream:
            fields = stream.read(1024 * 1024).split()
    except OSError:
        return None
    for field in fields:
        if not field.startswith(b"union="):
            continue
        value = field.split(b"=", 1)[1]
        if value in (b"overlay", b"overlayfs"):
            return "overlayfs"
        if value == b"aufs":
            return "aufs"
    return None


def detect_union(mountinfo_path, cmdline_path, aufs_sysfs_path, mounted_root):
    fstype, upperdir, lowerdirs = read_root_mount(mountinfo_path, aufs_sysfs_path, mounted_root)
    intent = read_union_intent(cmdline_path)
    if fstype == b"overlay":
        backend = "overlayfs"
    elif fstype == b"aufs":
        backend = "aufs"
    else:
        backend = "unknown"
    if intent is not None and intent != backend:
        warning("Kernel union intent differs from the mounted root; using mounted {}".format(backend))
    return backend, upperdir, lowerdirs


def mounted_path_candidates(path):
    candidates = [path]
    if path.startswith(b"/"):
        for prefix in (b"/run/initramfs", b"/lib/live/mount"):
            candidate = prefix + path
            if candidate not in candidates:
                candidates.append(candidate)
    return candidates


def mounted_directory_identities(path):
    identities = set()
    for candidate in mounted_path_candidates(path):
        try:
            descriptor = open_absolute_directory(candidate)
        except OSError:
            continue
        try:
            metadata = os.fstat(descriptor)
            identities.add((metadata.st_dev, metadata.st_ino))
        finally:
            os.close(descriptor)
    return identities


def unwrap_changes(root_fd, backend, upperdir):
    if backend == "overlayfs":
        if not upperdir:
            fail("mounted OverlayFS root does not report an upperdir")
        expected = mounted_directory_identities(upperdir)
        if not expected:
            fail("mounted OverlayFS upperdir is not reachable from the live system")
        for _ in range(16):
            current = os.fstat(root_fd)
            if (current.st_dev, current.st_ino) in expected:
                return root_fd
            names = sorted(os.fsencode(name) for name in os.listdir(root_fd))
            if names != [b"changes", b"workdir"]:
                fail("changes root does not resolve to the mounted OverlayFS upperdir")
            changes_fd = os.open(b"changes", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                 dir_fd=root_fd)
            work_fd = os.open(b"workdir", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                              dir_fd=root_fd)
            changes_metadata = os.fstat(changes_fd)
            work_metadata = os.fstat(work_fd)
            if ((changes_metadata.st_dev != work_metadata.st_dev) or
                    (changes_metadata.st_dev, changes_metadata.st_ino) ==
                    (work_metadata.st_dev, work_metadata.st_ino)):
                os.close(changes_fd)
                os.close(work_fd)
                fail("invalid OverlayFS changes/workdir wrapper")
            os.close(work_fd)
            os.close(root_fd)
            root_fd = changes_fd
        fail("too many nested OverlayFS changes/workdir wrappers")

    if backend == "aufs":
        if not upperdir:
            fail("mounted AUFS root does not report a writable branch")
        expected = mounted_directory_identities(upperdir)
        if not expected:
            fail("mounted AUFS writable branch is not reachable from the live system")
        current = os.fstat(root_fd)
        if (current.st_dev, current.st_ino) not in expected:
            fail("changes root does not resolve to the mounted AUFS writable branch")

    names = sorted(os.fsencode(name) for name in os.listdir(root_fd))
    if names == [b"changes", b"workdir"]:
        fail("OverlayFS changes/workdir wrapper conflicts with mounted root backend")
    return root_fd


def nested_mount_paths(mountinfo_path, root_path):
    try:
        with open(mountinfo_path, "rb") as stream:
            lines = stream.readlines()
    except OSError:
        fail("cannot read mounted filesystem information")
    root_path = os.path.normpath(root_path)
    nested = set()
    for line in lines:
        mounted = line.split(b" - ", 1)[0].split()
        if len(mounted) < 5:
            continue
        mount_path = os.path.normpath(decode_mount_field(mounted[4]))
        try:
            relative = os.path.relpath(mount_path, root_path)
        except ValueError:
            continue
        if relative != b"." and not relative.startswith(b"../") and relative != b"..":
            nested.add(relative)
    return nested


def mounted_branch_source(mountinfo_path, branch_path, test_mode):
    try:
        with open(mountinfo_path, "rb") as stream:
            lines = stream.readlines()
    except OSError:
        fail("cannot read mounted filesystem information")
    branch_paths = {os.path.normpath(candidate) for candidate in
                    mounted_path_candidates(os.path.normpath(branch_path))}
    for line in lines:
        sections = line.rstrip(b"\n").split(b" - ", 1)
        if len(sections) != 2:
            continue
        mounted = sections[0].split()
        filesystem = sections[1].split()
        if (len(mounted) < 5 or len(filesystem) < 2 or
                os.path.normpath(decode_mount_field(mounted[4])) not in branch_paths):
            continue
        source = decode_mount_field(filesystem[1])
        try:
            metadata = os.stat(source, follow_symlinks=False)
        except OSError:
            return None
        if stat.S_ISBLK(metadata.st_mode):
            return source
        if test_mode and stat.S_ISREG(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode):
            return os.path.realpath(source)
        return None
    return None


def hash_mounted_module(path):
    absolute = os.path.abspath(os.fsencode(path))
    parent_fd = open_absolute_directory(os.path.realpath(os.path.dirname(absolute)))
    name = os.path.basename(absolute)
    descriptor = -1
    try:
        metadata = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if not (stat.S_ISREG(metadata.st_mode) or stat.S_ISBLK(metadata.st_mode)):
            fail("mounted module source is not a regular file or block device")
        descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent_fd)
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino, stat.S_IFMT(opened.st_mode)) != (
                metadata.st_dev, metadata.st_ino, stat.S_IFMT(metadata.st_mode)):
            fail("mounted module source changed while opening")
        if stat.S_ISBLK(opened.st_mode):
            size = os.lseek(descriptor, 0, os.SEEK_END)
            os.lseek(descriptor, 0, os.SEEK_SET)
        else:
            size = opened.st_size
        if size <= 0:
            fail("mounted module source has invalid size")
        digest = hashlib.sha256()
        consumed = 0
        while consumed < size:
            block = os.read(descriptor, min(1024 * 1024, size - consumed))
            if not block:
                fail("mounted module source ended before its reported size")
            digest.update(block)
            consumed += len(block)
        if stat.S_ISREG(opened.st_mode) and stable_snapshot(os.fstat(descriptor)) != \
                stable_snapshot(opened):
            fail("mounted module source changed while hashing")
        return size, digest.hexdigest()
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(parent_fd)


def read_boot_id(boot_id_path):
    try:
        with open(boot_id_path, "rb") as stream:
            value = stream.read(256).strip()
    except OSError:
        fail("cannot read running boot identity")
    try:
        text = value.decode("ascii", "strict")
    except UnicodeError:
        fail("running boot identity is invalid")
    if not text or len(text) > 128:
        fail("running boot identity is invalid")
    return text


def source_fingerprint(root_metadata, backend, boot_id):
    material = b"minios-capture-source-v1\0" + backend.encode("ascii") + b"\0"
    material += str(root_metadata.st_dev).encode("ascii") + b":"
    material += str(root_metadata.st_ino).encode("ascii") + b"\0" + boot_id.encode("ascii")
    return hashlib.sha256(material).hexdigest()


def module_fingerprint(records):
    digest = hashlib.sha256()
    digest.update(b"minios-base-modules-v2\0")
    for name, size, module_digest in records:
        digest.update(name)
        digest.update(b"\0")
        digest.update(str(size).encode("ascii"))
        digest.update(b"\0")
        digest.update(module_digest.encode("ascii"))
        digest.update(b"\0")
    return digest.hexdigest()


def discover_running_source(test_path):
    if test_path:
        candidates = [os.fsencode(test_path)]
    else:
        candidates = [
            b"/run/initramfs/memory/data/minios", b"/run/initramfs/memory/medium/minios",
            b"/run/initramfs/memory/iso/minios", b"/lib/live/mount/data/minios",
            b"/lib/live/mount/medium/minios", b"/lib/live/mount/iso/minios",
        ]
    found = []
    for candidate in candidates:
        try:
            metadata = os.stat(candidate, follow_symlinks=False)
        except OSError:
            continue
        if stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode):
            found.append(os.path.realpath(candidate))
    if len(set(found)) > 1:
        fail("multiple running MiniOS sources were discovered")
    return found[0] if found else None


def running_base_fingerprint(lowerdirs, backend, mountinfo_path, test_mode,
                             running_source_path):
    source = discover_running_source(running_source_path)
    if source is None and test_mode:
        return None
    module_paths = {}
    # Production attestation hashes the backing source of each actually mounted
    # lower branch.  The source-tree lookup exists only for the non-root test
    # fallback and must not treat numbered persistence snapshots as base modules.
    if source is not None and test_mode:
        for directory, directory_names, file_names in os.walk(source, followlinks=False):
            directory_names[:] = [name for name in directory_names
                                  if not os.path.islink(os.path.join(directory, name))]
            if os.path.normpath(directory) == os.path.normpath(source):
                directory_names[:] = [name for name in directory_names if name != b"changes"]
            for text_name in file_names:
                name = os.fsencode(text_name)
                if not name.endswith(b".sb"):
                    continue
                path = os.path.join(os.fsencode(directory), name)
                metadata = os.stat(path, follow_symlinks=False)
                if not stat.S_ISREG(metadata.st_mode):
                    continue
                if name in module_paths:
                    fail("running source has duplicate module basenames")
                module_paths[name] = path
    mounted_branches = {}
    mounted_names = []
    for path in lowerdirs:
        name = os.path.basename(path)
        if not name.endswith(b".sb"):
            continue
        if name in mounted_branches:
            fail("mounted base modules have duplicate basenames")
        mounted_branches[name] = path
        mounted_names.append(name)
    if backend in ("overlayfs", "aufs") and not mounted_names:
        if test_mode:
            return None
        fail("mounted base module branches are unavailable")
    selected_names = mounted_names if mounted_names else sorted(module_paths)
    if not selected_names:
        if test_mode:
            return None
        fail("mounted base modules are unavailable")
    records = []
    for name in selected_names:
        branch = mounted_branches[name]
        mounted_source = mounted_branch_source(mountinfo_path, branch, test_mode)
        if mounted_source is None:
            mounted_source = module_paths.get(name) if test_mode else None
        if mounted_source is None:
            fail("mounted base module source cannot be verified")
        size, digest = hash_mounted_module(mounted_source)
        records.append((name, size, digest))
    return module_fingerprint(records)


def path_at_or_below(path, parent):
    if parent == b"":
        return True
    return path == parent or path.startswith(parent + b"/")


def path_related(left, right):
    return path_at_or_below(left, right) or path_at_or_below(right, left)


def rooted(path, prefixes):
    return any(path_at_or_below(path, prefix) for prefix in prefixes)


INTERNAL_NAMES = {
    b".wh..wh.orph", b".wh..wh.plnk", b".wh..wh.aufs", b".wh..wh.pwd.lock",
}


def is_internal(path):
    components = path.split(b"/")
    if components and components[0] in (b"workdir", b".overlay", b".aufs"):
        return True
    return any(component in INTERNAL_NAMES or component.startswith(b".wh..wh.plnk.")
               for component in components)


def is_runtime(path):
    return rooted(path, (b"dev", b"proc", b"sys", b"run", b"tmp", b"mnt", b"media",
                         b"var/run", b"var/lock", b"var/tmp"))


def union_whiteout(path, metadata, backend):
    base = path.rsplit(b"/", 1)[-1]
    parent = path.rsplit(b"/", 1)[0] if b"/" in path else b""
    character = (stat.S_ISCHR(metadata.st_mode) and os.major(metadata.st_rdev) == 0 and
                 os.minor(metadata.st_rdev) == 0)
    aufs_name = base.startswith(b".wh.") and not is_internal(path)
    if backend == "overlayfs" and character:
        return path, "overlay-char"
    if backend == "aufs" and aufs_name:
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size != 0:
            fail("invalid AUFS whiteout representation")
        target_name = base[4:]
        if (target_name in (b"", b".", b"..") or
                (base.startswith(b".wh..wh.") and base != b".wh..wh..opq")):
            fail("invalid AUFS whiteout target")
        if base == b".wh..wh..opq":
            return parent, "aufs-opaque"
        return parent + (b"/" if parent else b"") + base[4:], "aufs-file"
    if (backend == "aufs" and character) or (backend == "unknown" and (character or aufs_name)):
        return path, "ambiguous"
    return None, None


def entry_kind(path, metadata, backend):
    target, representation = union_whiteout(path, metadata, backend)
    if representation is not None:
        return "whiteout", target, representation
    if stat.S_ISREG(metadata.st_mode):
        return "regular", None, None
    if stat.S_ISDIR(metadata.st_mode):
        return "directory", None, None
    if stat.S_ISLNK(metadata.st_mode):
        return "symlink", None, None
    return "unsupported", None, None


OVERLAY_CONTEXT_XATTRS = {
    "trusted.overlay.origin", "trusted.overlay.impure", "trusted.overlay.uuid",
    "user.overlay.origin", "user.overlay.impure", "user.overlay.uuid",
}

OVERLAY_DEPENDENCY_XATTRS = {
    "trusted.overlay.redirect", "trusted.overlay.metacopy", "trusted.overlay.index",
    "user.overlay.redirect", "user.overlay.metacopy", "user.overlay.index",
}


def list_xattrs(path, follow_symlinks=True):
    if TEST_MODE and os.environ.get("SAVECHANGES_TEST_XATTR_EPERM") == "1":
        raise OSError(errno.EPERM, "injected xattr permission denial")
    if follow_symlinks:
        return os.listxattr(path)
    return os.listxattr(path, follow_symlinks=False)


def get_xattr(path, name, follow_symlinks=True):
    if TEST_MODE and os.environ.get("SAVECHANGES_TEST_XATTR_EPERM") == "1":
        raise OSError(errno.EPERM, "injected xattr permission denial")
    if follow_symlinks:
        return os.getxattr(path, name)
    return os.getxattr(path, name, follow_symlinks=False)


def unsafe_union_xattr(parent_fd, name):
    path = os.fsencode("/proc/self/fd/{}/".format(parent_fd)) + name
    try:
        names = list_xattrs(path, follow_symlinks=False)
    except OSError as error:
        if error.errno in (errno.ENOTSUP, errno.EOPNOTSUPP):
            return None
        if error.errno == errno.EPERM:
            return "unreadable"
        raise
    for xattr_name in names:
        if xattr_name in OVERLAY_DEPENDENCY_XATTRS:
            return "dependency"
        if ((xattr_name.startswith("trusted.overlay.") or
             xattr_name.startswith("user.overlay.")) and
                xattr_name not in OVERLAY_CONTEXT_XATTRS and
                xattr_name not in ("trusted.overlay.opaque", "user.overlay.opaque")):
            return "unknown"
    return None


def overlay_opaque_fd(descriptor, backend, path):
    if backend not in ("overlayfs", "unknown"):
        return None
    for name in ("trusted.overlay.opaque", "user.overlay.opaque"):
        try:
            value = get_xattr(descriptor, name)
        except OSError as error:
            if error.errno in (errno.ENODATA, errno.ENOTSUP, errno.EOPNOTSUPP):
                continue
            if error.errno == errno.EPERM:
                fail("cannot verify OverlayFS opacity metadata")
            raise
        if value not in (b"y", b"x"):
            fail("unsupported OverlayFS opaque xattr value")
        return name, value
    return None


def overlay_opaque(root_fd, path, backend):
    if backend not in ("overlayfs", "unknown"):
        return None
    descriptor = safe_open_dir(root_fd, path)
    try:
        return overlay_opaque_fd(descriptor, backend, path)
    finally:
        os.close(descriptor)


def scan_tree(root_fd, backend, nested_mounts=None):
    root_metadata = os.fstat(root_fd)
    nested_mounts = nested_mounts or set()
    pending = [(b"", os.dup(root_fd))]
    entries = []
    try:
        while pending:
            check_cancelled()
            parent_path, parent_fd = pending.pop()
            try:
                names = sorted(os.listdir(parent_fd), key=os.fsencode)
                for text_name in names:
                    check_cancelled()
                    name = os.fsencode(text_name)
                    path = name if not parent_path else parent_path + b"/" + name
                    metadata = os.stat(text_name, dir_fd=parent_fd, follow_symlinks=False)
                    crosses = (metadata.st_dev != root_metadata.st_dev or
                               path in nested_mounts)
                    kind, deletion_target, representation = entry_kind(path, metadata, backend)
                    opaque = overlay_opaque(root_fd, path, backend) if kind == "directory" else None
                    unsafe_xattr = unsafe_union_xattr(parent_fd, name)
                    entries.append({
                        "path": path, "stat": metadata, "crosses": crosses, "kind": kind,
                        "deletion_target": deletion_target, "representation": representation,
                        "opaque": opaque, "unsafe_union_xattr": unsafe_xattr,
                    })
                    if kind == "directory" and not crosses:
                        child_fd = os.open(text_name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                           dir_fd=parent_fd)
                        opened = os.fstat(child_fd)
                        if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
                            os.close(child_fd)
                            fail("directory identity changed during inventory")
                        pending.append((path, child_fd))
            finally:
                os.close(parent_fd)
    except Exception:
        for _path, descriptor in pending:
            try:
                os.close(descriptor)
            except OSError:
                pass
        raise
    entries.sort(key=lambda item: item["path"])
    if backend == "aufs":
        anchor = next((item for item in entries if item["path"] == b".wh..wh.aufs"), None)
        linked_whiteouts = [item for item in entries
                            if item["representation"] == "aufs-file" and item["stat"].st_nlink > 1]
        if linked_whiteouts:
            if (anchor is None or anchor["kind"] != "regular" or anchor["stat"].st_size != 0):
                fail("invalid AUFS whiteout representation")
            identity = (anchor["stat"].st_dev, anchor["stat"].st_ino)
            links = [item for item in entries
                     if (item["stat"].st_dev, item["stat"].st_ino) == identity]
            if (anchor["stat"].st_nlink != len(links) or
                    any((item["stat"].st_dev, item["stat"].st_ino) != identity
                        for item in linked_whiteouts)):
                fail("invalid AUFS whiteout representation")
    return root_metadata, entries


def category_for(path):
    lower = path.lower()
    components = lower.split(b"/")
    base = components[-1]
    if is_runtime(lower):
        return "runtime"
    if rooted(lower, (b"home", b"root", b"srv", b"var/mail", b"var/spool", b"var/www",
                      b"var/lib/mysql", b"var/lib/mariadb", b"var/lib/postgresql",
                      b"var/lib/mongodb", b"var/lib/redis", b"var/lib/docker",
                      b"var/lib/containers", b"var/lib/lxc", b"var/lib/incus",
                      b"var/lib/libvirt", b"var/lib/gdm", b"var/lib/lightdm")):
        return "user-data"
    if rooted(lower, (b"var/log", b"var/cache", b"var/backups", b"var/crash",
                      b"var/lib/systemd/coredump")) or b".cache" in components or base.endswith(b"history"):
        return "logs-cache"
    if rooted(lower, (b"etc/machine-id", b"var/lib/dbus/machine-id", b"etc/hostname",
                      b"etc/hostid", b"etc/hosts", b"etc/fstab", b"etc/crypttab",
                      b"var/lib/systemd/random-seed", b"var/lib/bluetooth", b"var/lib/cloud",
                      b"var/lib/waagent")) or lower.startswith(b"etc/ssh/ssh_host_"):
        return "machine-identity"
    if rooted(lower, (b"etc/networkmanager/system-connections", b"var/lib/networkmanager",
                      b"etc/wpa_supplicant", b"etc/iwd", b"var/lib/iwd", b"etc/connman",
                      b"var/lib/connman", b"etc/netplan", b"etc/network", b"var/lib/dhcp",
                      b"var/lib/dhcpcd", b"etc/openvpn", b"etc/wireguard", b"etc/strongswan",
                      b"etc/ppp", b"etc/resolv.conf", b"etc/systemd/network",
                      b"var/lib/tailscale", b"var/lib/zerotier-one")):
        return "network-identity"
    if clean_software_path(lower, "regular"):
        return "software"
    if rooted(lower, (b"etc", b"boot")):
        return "system-config"
    return "other"


def is_sensitive(path, category):
    lower = path.lower()
    components = lower.split(b"/")
    base = components[-1]
    if category in ("user-data", "logs-cache", "network-identity", "machine-identity"):
        return True
    if rooted(lower, (b"etc/shadow", b"etc/gshadow", b"etc/passwd", b"etc/group",
                      b"etc/subuid", b"etc/subgid", b"etc/security/opasswd",
                      b"etc/ssl/private", b"etc/letsencrypt", b"etc/cryptsetup-keys.d",
                      b"etc/pki/private", b"etc/credstore", b"etc/samba/private",
                      b"var/lib/samba/private", b"var/lib/private", b"var/lib/secret",
                      b"etc/apt/auth.conf", b"var/lib/snapd/device", b"var/lib/sss",
                      b"var/lib/acme", b"etc/cloud")):
        return True
    private = {b".ssh", b".gnupg", b".password-store", b"keyrings", b".mozilla",
               b"google-chrome", b"chromium", b"bravesoftware", b".aws", b".azure", b".kube"}
    if any(component in private for component in components):
        return True
    if rooted(lower, (b"etc", b"var/lib")) and (
            any(marker in base for marker in (b"credential", b"secret", b"password", b"private_key")) or
            base.endswith((b".key", b".p12", b".pfx"))):
        return True
    return False


CLEAN_SOFTWARE_ROOTS = (
    b"bin", b"sbin", b"lib", b"lib32", b"lib64",
    b"usr/bin", b"usr/sbin", b"usr/lib", b"usr/lib32", b"usr/lib64",
    b"usr/libexec", b"usr/share", b"usr/include",
    b"var/lib/dpkg", b"var/lib/apt/extended_states",
    b"var/lib/systemd/deb-systemd-helper-enabled",
    b"var/lib/systemd/deb-systemd-helper-masked", b"var/lib/snapd/snaps",
    b"var/lib/flatpak/repo/objects", b"etc/dpkg",
)


def clean_software_path(path, kind):
    if rooted(path, (b"usr/local", b"var/lib/dpkg/lock", b"var/lib/dpkg/lock-frontend")):
        return False
    for root in CLEAN_SOFTWARE_ROOTS:
        if path_at_or_below(path, root):
            return True
        if kind == "directory" and path_at_or_below(root, path):
            return True
    if path_at_or_below(path, b"etc/alternatives") or path_at_or_below(path, b"etc/systemd/system"):
        return kind in ("directory", "symlink", "whiteout")
    if kind == "directory" and (path_at_or_below(b"etc/alternatives", path) or
                                 path_at_or_below(b"etc/systemd/system", path)):
        return True
    return path in (b"etc/debian_version", b"etc/os-release") and kind in ("regular", "symlink")


def baseline_safe(entry, destination):
    path = entry["path"]
    if entry["kind"] == "unsupported" or entry["crosses"] or is_internal(path) or is_runtime(path):
        return False
    if destination and path_at_or_below(path, destination):
        return False
    return True


def legacy_included(entry, destination):
    path = entry["path"]
    if entry["kind"] == "unsupported" or entry["crosses"] or is_internal(path):
        return False
    if destination and path_at_or_below(path, destination):
        return False
    if entry["kind"] == "directory":
        return False
    if rooted(path, (b"var/cache", b"var/backups", b"var/tmp", b"var/log", b"var/lib/apt",
                     b"var/lib/dhcp", b"var/lib/systemd", b"boot", b"dev", b"mnt", b"proc",
                     b"run", b"sys", b"tmp")):
        return False
    return path not in (b"sbin/fsck.aufs", b"etc/resolv.conf", b"root/.Xauthority",
                        b"root/.xsession-errors", b"root/.fehbg", b"root/.fluxbox/lastwallpaper",
                        b"root/.fluxbox/menu_resolution", b"etc/mtab", b"etc/fstab")


def validate_selection_path(value):
    if not isinstance(value, str):
        fail("selection paths must be strings")
    try:
        encoded = value.encode("utf-8", "strict")
    except UnicodeError:
        fail("selection paths must contain valid Unicode")
    if not value or value.startswith("/") or "\0" in value or "\n" in value or "\r" in value:
        fail("selection path is not a normalized relative path")
    if any(component in ("", ".", "..") for component in value.split("/")) or posixpath.normpath(value) != value:
        fail("selection path is not normalized")
    return encoded


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail("duplicate JSON field: {}".format(key))
        result[key] = value
    return result


def read_selection(path):
    absolute = os.path.abspath(os.fsencode(path))
    parent = os.path.realpath(os.path.dirname(absolute))
    parent_fd = open_absolute_directory(parent)
    try:
        descriptor = os.open(os.path.basename(absolute), os.O_RDONLY | os.O_NOFOLLOW,
                             dir_fd=parent_fd)
    finally:
        os.close(parent_fd)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            fail("selection is not a regular file")
        raw = b""
        while True:
            block = os.read(descriptor, 1024 * 1024)
            if not block:
                break
            raw += block
        if stable_snapshot(os.fstat(descriptor)) != stable_snapshot(metadata):
            fail("selection changed while being read")
    finally:
        os.close(descriptor)
    try:
        value = json.loads(raw.decode("utf-8", "strict"), object_pairs_hook=unique_object,
                           parse_constant=lambda item: fail("invalid JSON constant: {}".format(item)))
    except CaptureError:
        raise
    except (UnicodeError, ValueError) as error:
        fail("invalid selection JSON: {}".format(error))
    expected = {"product_kind", "schema_version", "include_paths", "exclude_paths"}
    if not isinstance(value, dict) or set(value) != expected:
        fail("selection JSON has missing or unknown fields")
    if value["product_kind"] != "minios-session-selection" or type(value["schema_version"]) is not int or value["schema_version"] != 1:
        fail("unsupported selection identity or schema")
    if not isinstance(value["include_paths"], list) or not isinstance(value["exclude_paths"], list):
        fail("include_paths and exclude_paths must be arrays")
    include = [validate_selection_path(item) for item in value["include_paths"]]
    exclude = [validate_selection_path(item) for item in value["exclude_paths"]]
    if len(include) != len(set(include)) or len(exclude) != len(set(exclude)) or set(include).intersection(exclude):
        fail("duplicate selection path")
    return include, exclude, hashlib.sha256(raw).hexdigest()


def lexical_link_safe(root_fd, path, target):
    if target.startswith(b"/"):
        return False
    components = path.rsplit(b"/", 1)[0].split(b"/") if b"/" in path else []
    for component in target.split(b"/"):
        if component in (b"", b"."):
            continue
        if component == b"..":
            if not components:
                return False
            components.pop()
        else:
            components.append(component)
    prefix = b""
    for component in components:
        prefix = component if not prefix else prefix + b"/" + component
        try:
            metadata = safe_lstat(root_fd, prefix)
        except FileNotFoundError:
            return True
        if stat.S_ISLNK(metadata.st_mode):
            return False
    return True


def make_plan(root_fd, entries, backend, profile, destination, includes, excludes):
    selected = []
    matched = {path: False for path in includes}
    stripped_opaque = set()
    unsafe_count = 0
    if profile == "exact":
        exact_candidates = [entry for entry in entries
                            if not entry["crosses"] and not is_internal(entry["path"]) and
                            not is_runtime(entry["path"]) and
                            not (destination and path_at_or_below(entry["path"], destination))]
        unsupported = sum(entry["kind"] == "unsupported" for entry in exact_candidates)
        if unsupported:
            fail("exact capture cannot preserve unsupported filesystem objects: {}".format(
                unsupported))
        linked_nonregular = {}
        for entry in exact_candidates:
            semantic_whiteout = (entry["kind"] == "whiteout" and
                                 entry["representation"] in ("overlay-char", "aufs-file"))
            if (entry["kind"] in ("symlink", "whiteout") and entry["stat"].st_nlink != 1 and
                    not semantic_whiteout):
                identity = (entry["stat"].st_dev, entry["stat"].st_ino)
                linked_nonregular[identity] = linked_nonregular.get(identity, 0) + 1
            if entry["unsafe_union_xattr"] == "dependency":
                fail("exact capture found dependency-bearing union xattr")
            if entry["unsafe_union_xattr"] == "unknown":
                fail("exact capture found unknown union xattr")
            if entry["unsafe_union_xattr"] == "unreadable":
                fail("exact capture cannot verify union xattrs")
        if any(count > 1 for count in linked_nonregular.values()):
            fail("exact capture cannot preserve hard-linked non-regular objects")
    for entry in entries:
        path = entry["path"]
        if entry["kind"] == "unsupported":
            unsafe_count += 1
        deletion = entry["deletion_target"]
        for included in includes:
            if (path_at_or_below(path, included) or
                    (deletion is not None and path_related(deletion, included)) or
                    (entry["opaque"] is not None and path_at_or_below(included, path))):
                matched[included] = True
        safe = baseline_safe(entry, destination)
        include = False
        if profile == "legacy":
            include = legacy_included(entry, destination)
        elif profile == "exact":
            include = safe
        elif profile == "clean":
            classified = deletion if deletion is not None else path
            include = safe and clean_software_path(classified, entry["kind"])
        elif profile == "selected":
            excluded = any(path_at_or_below(path, item) for item in excludes)
            if deletion is not None and any(path_related(deletion, item) for item in excludes):
                excluded = True
            direct = any(path_at_or_below(path, item) for item in includes)
            parent = entry["kind"] == "directory" and any(path_at_or_below(item, path) for item in includes)
            whiteout = deletion is not None and any(path_related(deletion, item) for item in includes)
            include = safe and not excluded and (direct or parent or whiteout)
        if profile == "selected" and entry["representation"] == "aufs-opaque":
            opacity_path = deletion if deletion is not None else path
            preserve_opacity = any(path_at_or_below(opacity_path, included) for included in includes)
            if any(path_at_or_below(excluded, opacity_path) for excluded in excludes):
                preserve_opacity = False
            if not preserve_opacity:
                include = False
        if not include:
            continue
        if entry["unsafe_union_xattr"] == "dependency":
            fail("dependency-bearing union xattr cannot be replayed safely")
        if entry["unsafe_union_xattr"] == "unknown":
            fail("unknown union xattr cannot be replayed safely")
        if entry["unsafe_union_xattr"] == "unreadable":
            fail("union xattrs cannot be verified safely")
        if entry["representation"] == "ambiguous":
            fail("union whiteout cannot be represented safely for backend {}".format(backend))
        if profile == "selected" and entry["kind"] == "symlink":
            parent_fd, name = safe_parent_fd(root_fd, path)
            try:
                target = os.readlink(name, dir_fd=parent_fd)
            finally:
                os.close(parent_fd)
            if not lexical_link_safe(root_fd, path, target):
                fail("selected symbolic link is not confined to the changes root")
        if entry["opaque"] is not None:
            if backend != "overlayfs":
                fail("OverlayFS opaque metadata is incompatible with backend {}".format(backend))
            if profile == "selected":
                preserve_opacity = any(path_at_or_below(path, included) for included in includes)
                if any(path_at_or_below(excluded, path) for excluded in excludes):
                    preserve_opacity = False
                if not preserve_opacity:
                    stripped_opaque.add(path)
        selected.append(entry)
    unmatched = [path for path, present in matched.items() if not present]
    if profile == "selected" and unmatched:
        fail("selected include paths did not match inventory; unmatched count: {}".format(
            len(unmatched)))
    return selected, stripped_opaque, unsafe_count


def inventory_document(root_metadata, entries, backend, fingerprint, destination):
    records = []
    for entry in entries:
        check_cancelled()
        path = entry["path"]
        try:
            text_path = path.decode("utf-8", "strict")
        except UnicodeDecodeError:
            fail("inventory contains a path that is not valid UTF-8")
        classified = entry["deletion_target"] if entry["deletion_target"] is not None else path
        category = category_for(classified)
        exact = (baseline_safe(entry, destination) and entry["representation"] != "ambiguous" and
                 entry["unsafe_union_xattr"] is None)
        clean = exact and clean_software_path(classified, entry["kind"])
        record = {
            "path": text_path,
            "type": entry["kind"],
            "category": category,
            "sensitive": bool(is_sensitive(classified, category)),
            "default_exact": bool(exact),
            "default_clean": bool(clean),
        }
        if entry["kind"] == "regular":
            record["size"] = entry["stat"].st_size
        records.append(record)
    return {
        "product_kind": "minios-session-inventory",
        "schema_version": 2,
        "source_fingerprint": fingerprint,
        "union_backend": backend,
        "entries": records,
    }


def destination_path(root, relative):
    return os.path.join(root, *relative.split(b"/"))


def copy_allowed_xattrs(source, destination, profile, backend, opaque, preserve_opaque,
                        source_is_symlink=False):
    global STRIPPED_XATTRS
    try:
        names = (list_xattrs(source, follow_symlinks=False) if source_is_symlink else
                 list_xattrs(source))
    except OSError as error:
        if error.errno in (errno.ENOTSUP, errno.EOPNOTSUPP):
            names = []
        elif error.errno == errno.EPERM:
            fail("required xattrs cannot be inspected")
        else:
            raise
    for name in names:
        if name in ("trusted.overlay.opaque", "user.overlay.opaque"):
            continue
        if name in OVERLAY_CONTEXT_XATTRS:
            STRIPPED_XATTRS += 1
            continue
        if name in OVERLAY_DEPENDENCY_XATTRS:
            fail("dependency-bearing union xattr cannot be replayed safely: {}".format(name))
        if name.startswith("trusted.overlay.") or name.startswith("user.overlay."):
            fail("unknown union xattr cannot be represented safely: {}".format(name))
        allowed = profile in ("legacy", "exact", "selected") and (
            name.startswith("user.") or name == "security.capability" or
            name in ("system.posix_acl_access", "system.posix_acl_default"))
        if not allowed:
            if profile == "exact":
                fail("exact capture cannot preserve xattr: {}".format(name))
            STRIPPED_XATTRS += 1
            continue
        try:
            value = (get_xattr(source, name, follow_symlinks=False) if source_is_symlink else
                     get_xattr(source, name))
            os.setxattr(destination, name, value, follow_symlinks=False)
        except OSError as error:
            if error.errno in (errno.ENOTSUP, errno.EOPNOTSUPP, errno.EPERM):
                fail("required xattr cannot be preserved: {}".format(name))
            raise
        if get_xattr(destination, name, follow_symlinks=False) != value:
            fail("required xattr did not retain its value: {}".format(name))
    if opaque is not None:
        if not preserve_opaque:
            STRIPPED_XATTRS += 1
        else:
            if backend != "overlayfs":
                fail("opaque metadata cannot be represented for backend {}".format(backend))
            name, value = opaque
            try:
                os.setxattr(destination, name, value, follow_symlinks=False)
            except OSError:
                fail("required OverlayFS opaque metadata cannot be preserved")
            if get_xattr(destination, name, follow_symlinks=False) != value:
                fail("required OverlayFS opacity did not retain its value")


def apply_metadata(metadata, destination, profile, backend, source_fd=None,
                   opaque=None, preserve_opaque=False, symlink=False,
                   source_is_symlink=False):
    metadata_noop = TEST_MODE and os.environ.get("SAVECHANGES_TEST_METADATA_NOOP") == "1"
    if not metadata_noop:
        try:
            os.chown(destination, metadata.st_uid, metadata.st_gid, follow_symlinks=False)
        except PermissionError:
            current = os.lstat(destination)
            if (current.st_uid, current.st_gid) != (metadata.st_uid, metadata.st_gid):
                raise
        if not symlink:
            os.chmod(destination, stat.S_IMODE(metadata.st_mode))
    if source_fd is not None:
        copy_allowed_xattrs(source_fd, destination, profile, backend, opaque,
                            preserve_opaque, source_is_symlink=source_is_symlink)
    if not metadata_noop:
        try:
            os.utime(destination, ns=(metadata.st_atime_ns, metadata.st_mtime_ns),
                     follow_symlinks=False)
        except (NotImplementedError, PermissionError):
            if profile == "exact" or not symlink:
                raise
    applied = os.lstat(destination)
    if ((applied.st_uid, applied.st_gid) != (metadata.st_uid, metadata.st_gid) or
            (not symlink and stat.S_IMODE(applied.st_mode) !=
             stat.S_IMODE(metadata.st_mode)) or
            applied.st_atime_ns != metadata.st_atime_ns or
            applied.st_mtime_ns != metadata.st_mtime_ns):
        fail("staging filesystem did not preserve required metadata")


def stable_snapshot(metadata):
    return (metadata.st_dev, metadata.st_ino, metadata.st_mode, metadata.st_nlink,
            metadata.st_uid, metadata.st_gid, metadata.st_rdev, metadata.st_size,
            metadata.st_mtime_ns, metadata.st_ctime_ns)


def copy_regular(parent_fd, name, planned, destination, hardlinks, profile, backend):
    key = (planned.st_dev, planned.st_ino)
    if key in hardlinks:
        os.link(hardlinks[key], destination)
        return
    for attempt in range(4):
        check_cancelled()
        flags = os.O_RDONLY | os.O_NOFOLLOW
        if hasattr(os, "O_NOATIME"):
            flags |= os.O_NOATIME
        try:
            source_fd = os.open(name, flags, dir_fd=parent_fd)
        except PermissionError:
            source_fd = os.open(name, flags & ~getattr(os, "O_NOATIME", 0), dir_fd=parent_fd)
        try:
            baseline = os.fstat(source_fd)
            if not stat.S_ISREG(baseline.st_mode) or (baseline.st_dev, baseline.st_ino) != key:
                fail("regular file identity changed during capture")
            output_fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            try:
                while True:
                    check_cancelled()
                    block = os.read(source_fd, 1024 * 1024)
                    if not block:
                        break
                    offset = 0
                    while offset < len(block):
                        check_cancelled()
                        written = os.write(output_fd, block[offset:])
                        if written <= 0:
                            fail("short write while copying capture data")
                        offset += written
            finally:
                os.close(output_fd)
            if stable_snapshot(os.fstat(source_fd)) != stable_snapshot(baseline):
                os.unlink(destination)
                if attempt < 3:
                    time.sleep(0.02)
                    continue
                fail("regular file changed repeatedly while being copied")
            apply_metadata(baseline, destination, profile, backend, source_fd=source_fd)
            if stable_snapshot(os.fstat(source_fd)) != stable_snapshot(baseline):
                os.unlink(destination)
                if attempt < 3:
                    time.sleep(0.02)
                    continue
                fail("regular file changed repeatedly while reading metadata")
            hardlinks[key] = destination
            return
        finally:
            os.close(source_fd)


def copy_plan(root_fd, root_metadata, all_entries, selected, stripped_opaque,
              profile, backend, staging):
    records = []
    directories = set()
    for entry in selected:
        check_cancelled()
        path = entry["path"]
        components = path.split(b"/")
        for index in range(1, len(components)):
            directories.add(b"/".join(components[:index]))
        if entry["kind"] == "directory":
            directories.add(path)
        records.append(entry)

    inventory_map = {entry["path"]: entry for entry in all_entries}
    selected_map = {entry["path"]: entry for entry in selected}
    source_directories = {b"": os.dup(root_fd)}
    try:
        for path in sorted(directories, key=lambda value: (value.count(b"/"), value)):
            check_cancelled()
            planned_entry = inventory_map.get(path)
            if planned_entry is None or planned_entry["kind"] != "directory":
                fail("capture parent was absent from the inventory")
            source_fd = safe_open_dir(root_fd, path)
            metadata = os.fstat(source_fd)
            planned = planned_entry["stat"]
            if not stat.S_ISDIR(metadata.st_mode) or (metadata.st_dev, metadata.st_ino) != (
                    planned.st_dev, planned.st_ino):
                os.close(source_fd)
                fail("parent directory changed during capture")
            source_directories[path] = source_fd
            output = destination_path(staging, path)
            try:
                os.mkdir(output, 0o700)
            except FileExistsError:
                if not stat.S_ISDIR(os.lstat(output).st_mode):
                    fail("staging parent is not a directory")

        hardlinks = {}
        for entry in records:
            check_cancelled()
            path = entry["path"]
            if entry["kind"] == "directory":
                continue
            parent_path, name = path.rsplit(b"/", 1) if b"/" in path else (b"", path)
            parent_fd = source_directories[parent_path]
            output = destination_path(staging, path)
            current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            planned = entry["stat"]
            if (current.st_dev, current.st_ino) != (planned.st_dev, planned.st_ino):
                fail("changes entry identity changed during capture")
            if stat.S_ISREG(current.st_mode):
                link_map = ({} if entry["kind"] == "whiteout" and
                            entry["representation"] == "aufs-file" else hardlinks)
                copy_regular(parent_fd, name, planned, output, link_map, profile, backend)
            elif stat.S_ISLNK(current.st_mode):
                if stable_snapshot(current) != stable_snapshot(planned):
                    fail("symbolic link changed before capture")
                target = os.readlink(name, dir_fd=parent_fd)
                after = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
                if stable_snapshot(after) != stable_snapshot(planned):
                    fail("symbolic link changed during capture")
                if profile == "selected" and not lexical_link_safe(root_fd, path, target):
                    fail("selected symbolic link escaped during copy")
                os.symlink(target, output)
                source_path = os.fsencode("/proc/self/fd/{}/".format(parent_fd)) + name
                apply_metadata(planned, output, profile, backend, source_fd=source_path,
                               symlink=True, source_is_symlink=True)
            elif (stat.S_ISCHR(current.st_mode) and os.major(current.st_rdev) == 0 and
                  os.minor(current.st_rdev) == 0 and backend == "overlayfs" and
                  stable_snapshot(current) == stable_snapshot(planned)):
                os.mknod(output, current.st_mode, current.st_rdev)
                source_path = os.fsencode("/proc/self/fd/{}/".format(parent_fd)) + name
                apply_metadata(planned, output, profile, backend, source_fd=source_path)
                after = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
                if stable_snapshot(after) != stable_snapshot(planned):
                    fail("whiteout changed while reading metadata")
            else:
                fail("filesystem object became unsafe during copy")

        for path in sorted(directories,
                           key=lambda value: (value.count(b"/"), value), reverse=True):
            check_cancelled()
            source_fd = source_directories[path]
            entry = selected_map.get(path)
            opaque = (entry["opaque"] if entry is not None else
                      overlay_opaque_fd(source_fd, backend, path))
            preserve = opaque is not None and path not in stripped_opaque
            apply_metadata(os.fstat(source_fd), destination_path(staging, path), profile, backend,
                           source_fd=source_fd, opaque=opaque, preserve_opaque=preserve)
        root_opaque = overlay_opaque_fd(root_fd, backend, b"")
        preserve_root = root_opaque is not None and profile in ("legacy", "exact")
        apply_metadata(root_metadata, staging, profile, backend, source_fd=root_fd,
                       opaque=root_opaque, preserve_opaque=preserve_root)
    finally:
        for descriptor in source_directories.values():
            os.close(descriptor)


def pause_before_copy(test_mode):
    marker = os.environ.get("SAVECHANGES_TEST_PAUSE_BEFORE_COPY")
    if not test_mode or not marker:
        return
    ready = marker + ".ready"
    release = marker + ".continue"
    descriptor = os.open(ready, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    os.close(descriptor)
    for _ in range(200):
        try:
            metadata = os.stat(release, follow_symlinks=False)
            if stat.S_ISREG(metadata.st_mode):
                return
            fail("test capture release marker is not a regular file")
        except FileNotFoundError:
            time.sleep(0.05)
    fail("timed out waiting for the test capture release marker")


def pause_after_publish():
    marker = os.environ.get("SAVECHANGES_TEST_PAUSE_AFTER_PUBLISH")
    if not TEST_MODE or not marker:
        return
    ready = marker + ".ready"
    release = marker + ".continue"
    descriptor = os.open(ready, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    os.close(descriptor)
    for _ in range(200):
        try:
            metadata = os.stat(release, follow_symlinks=False)
            if stat.S_ISREG(metadata.st_mode):
                return
            fail("test publication release marker is not a regular file")
        except FileNotFoundError:
            time.sleep(0.05)
    fail("timed out waiting for the test publication release marker")


def enable_subreaper():
    libc = ctypes.CDLL(None, use_errno=True)
    prctl = getattr(libc, "prctl", None)
    if prctl is None:
        fail("process subreaper support is unavailable")
    prctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_ulong,
                      ctypes.c_ulong, ctypes.c_ulong]
    prctl.restype = ctypes.c_int
    if prctl(36, 1, 0, 0, 0) != 0:
        number = ctypes.get_errno()
        raise OSError(number, os.strerror(number))


def process_group_alive(pgid):
    if pgid is None:
        return False
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False


def reap_orphaned_children(process):
    if process is not None and process.poll() is None:
        return True
    while True:
        try:
            child_pid, _status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return False
        if child_pid == 0:
            return True


def request_child_termination(pgid):
    if pgid is None:
        return
    try:
        os.killpg(pgid, signal.SIGTERM)
    except ProcessLookupError:
        pass


def terminate_child(process, pgid=None):
    if pgid is None and process is not None:
        pgid = process.pid
    if pgid is None:
        return
    request_child_termination(pgid)
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline:
        if process is not None:
            process.poll()
        reap_orphaned_children(process)
        if not process_group_alive(pgid):
            break
        time.sleep(0.05)
    if process_group_alive(pgid):
        try:
            os.killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    if process is not None and process.poll() is None:
        process.wait()
    deadline = time.monotonic() + 2
    empty_checks = 0
    while time.monotonic() < deadline:
        children_remain = reap_orphaned_children(process)
        if not process_group_alive(pgid) and not children_remain:
            empty_checks += 1
            if empty_checks >= 2:
                break
        else:
            empty_checks = 0
        time.sleep(0.05)
    reap_orphaned_children(process)


def ensure_process_group_finished(process, pgid):
    deadline = time.monotonic() + 1
    while process_group_alive(pgid) and time.monotonic() < deadline:
        check_cancelled()
        reap_orphaned_children(process)
        time.sleep(0.02)
    reap_orphaned_children(process)
    if process_group_alive(pgid):
        terminate_child(process, pgid)
        fail("capture tool left descendant processes")


def signal_handler(_signum, _frame):
    global CANCEL_RAISED
    if CANCEL_RAISED:
        return
    CANCEL_RAISED = True
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    CANCEL_EVENT.set()
    request_child_termination(CURRENT_PGID)
    raise Cancelled()


def run_tool(arguments, pass_fds=(), stdout=None, stderr=None, child_env=None):
    global CURRENT_CHILD, CURRENT_PGID
    CURRENT_CHILD = subprocess.Popen(arguments, pass_fds=pass_fds, start_new_session=True,
                                     env=child_env, stdout=stdout, stderr=stderr)
    CURRENT_PGID = CURRENT_CHILD.pid
    try:
        status = CURRENT_CHILD.wait()
        ensure_process_group_finished(CURRENT_CHILD, CURRENT_PGID)
        return status
    except BaseException:
        terminate_child(CURRENT_CHILD, CURRENT_PGID)
        raise
    finally:
        CURRENT_CHILD = None
        CURRENT_PGID = None


def run_tool_output(arguments, child_env=None):
    global CURRENT_CHILD, CURRENT_PGID
    CURRENT_CHILD = subprocess.Popen(arguments, start_new_session=True, env=child_env,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     universal_newlines=True)
    CURRENT_PGID = CURRENT_CHILD.pid
    try:
        output, _unused = CURRENT_CHILD.communicate()
        ensure_process_group_finished(CURRENT_CHILD, CURRENT_PGID)
        return CURRENT_CHILD.returncode, output
    except BaseException:
        terminate_child(CURRENT_CHILD, CURRENT_PGID)
        raise
    finally:
        CURRENT_CHILD = None
        CURRENT_PGID = None


def rename_noreplace(directory_fd, source, target):
    libc = ctypes.CDLL(None, use_errno=True)
    renameat2 = getattr(libc, "renameat2", None)
    if renameat2 is not None:
        renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p,
                              ctypes.c_uint]
        renameat2.restype = ctypes.c_int
        if renameat2(directory_fd, source, directory_fd, target, 1) == 0:
            return "rename"
        number = ctypes.get_errno()
        if number not in (errno.ENOSYS, errno.EINVAL):
            raise OSError(number, os.strerror(number))
    os.link(source, target, src_dir_fd=directory_fd, dst_dir_fd=directory_fd,
            follow_symlinks=False)
    return "link"


def verify_requested_parent(requested_parent, held_metadata):
    descriptor = open_absolute_directory(requested_parent)
    try:
        current = os.fstat(descriptor)
        if (current.st_dev, current.st_ino) != (held_metadata.st_dev, held_metadata.st_ino):
            fail("destination parent identity changed")
    finally:
        os.close(descriptor)


def atomic_publish_stream(source_fd, output_fd, output_parent, output_metadata, basename,
                          file_mode, owner_uid):
    verify_requested_parent(output_parent, output_metadata)
    try:
        os.stat(basename, dir_fd=output_fd, follow_symlinks=False)
    except FileNotFoundError:
        pass
    else:
        fail("output path exists or appeared during capture: {}".format(os.fsdecode(basename)))
    temporary = None
    temporary_fd = -1
    publication_possible = False
    published_identity = None
    try:
        for _ in range(128):
            temporary = b".savechanges-output." + os.urandom(16).hex().encode("ascii")
            try:
                temporary_fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                                       0o600, dir_fd=output_fd)
                break
            except FileExistsError:
                temporary = None
        if temporary is None:
            fail("cannot reserve output temporary file")
        os.lseek(source_fd, 0, os.SEEK_SET)
        while True:
            check_cancelled()
            block = os.read(source_fd, 1024 * 1024)
            if not block:
                break
            offset = 0
            while offset < len(block):
                check_cancelled()
                offset += os.write(temporary_fd, block[offset:])
        if owner_uid is not None:
            os.fchown(temporary_fd, owner_uid, -1)
        os.fchmod(temporary_fd, file_mode)
        os.fsync(temporary_fd)
        held = os.fstat(temporary_fd)
        named = os.stat(temporary, dir_fd=output_fd, follow_symlinks=False)
        if (held.st_dev, held.st_ino) != (named.st_dev, named.st_ino):
            fail("output temporary identity changed")
        check_cancelled()
        publication_possible = True
        method = rename_noreplace(output_fd, temporary, basename)
        pause_after_publish()
        published = os.stat(basename, dir_fd=output_fd, follow_symlinks=False)
        if (published.st_dev, published.st_ino) != (held.st_dev, held.st_ino):
            fail("published output identity changed")
        published_identity = (held.st_dev, held.st_ino)
        if method == "link":
            os.unlink(temporary, dir_fd=output_fd)
        temporary = None
        if TEST_MODE and os.environ.get("SAVECHANGES_TEST_FAIL_OUTPUT_DIR_FSYNC") == "1":
            raise OSError(errno.EIO, "injected output directory fsync failure")
        try:
            os.fsync(output_fd)
        except OSError as error:
            if error.errno not in (errno.EINVAL, errno.ENOTSUP, errno.EOPNOTSUPP):
                raise
        return (published.st_dev, published.st_ino)
    except BaseException:
        if publication_possible:
            try:
                current = os.stat(basename, dir_fd=output_fd, follow_symlinks=False)
                expected = (held.st_dev, held.st_ino)
                if (current.st_dev, current.st_ino) == expected:
                    os.unlink(basename, dir_fd=output_fd)
                    try:
                        os.fsync(output_fd)
                    except OSError as error:
                        if error.errno not in (errno.EINVAL, errno.ENOTSUP, errno.EOPNOTSUPP):
                            raise
            except FileNotFoundError:
                pass
        raise
    finally:
        if temporary is not None and temporary_fd >= 0:
            try:
                named = os.stat(temporary, dir_fd=output_fd, follow_symlinks=False)
                held = os.fstat(temporary_fd)
                if (named.st_dev, named.st_ino) == (held.st_dev, held.st_ino):
                    os.unlink(temporary, dir_fd=output_fd)
            except OSError:
                pass
        if temporary_fd >= 0:
            os.close(temporary_fd)


def atomic_publish_bytes(data, output_fd, output_parent, output_metadata, basename,
                         file_mode, owner_uid, temp_fd):
    name = b"publish-source." + os.urandom(12).hex().encode("ascii")
    descriptor = os.open(name, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=temp_fd)
    try:
        offset = 0
        while offset < len(data):
            check_cancelled()
            offset += os.write(descriptor, data[offset:])
        return atomic_publish_stream(descriptor, output_fd, output_parent, output_metadata,
                                     basename, file_mode, owner_uid)
    finally:
        os.close(descriptor)
        os.unlink(name, dir_fd=temp_fd)


def remove_if_identity(directory_fd, basename, identity):
    try:
        current = os.stat(basename, dir_fd=directory_fd, follow_symlinks=False)
        if (current.st_dev, current.st_ino) == identity:
            os.unlink(basename, dir_fd=directory_fd)
            try:
                os.fsync(directory_fd)
            except OSError as error:
                if error.errno not in (errno.EINVAL, errno.ENOTSUP, errno.EOPNOTSUPP):
                    return False
    except FileNotFoundError:
        return True
    except OSError:
        return False
    return True


def verify_published_identity(directory_fd, basename, identity):
    current = os.stat(basename, dir_fd=directory_fd, follow_symlinks=False)
    if (current.st_dev, current.st_ino) != identity:
        fail("published output identity changed before commit")


def create_private_temp(parent_path, test_mode, owner_uid):
    canonical, parent_fd, parent_metadata = canonical_directory(parent_path)
    if not test_mode:
        mode = stat.S_IMODE(parent_metadata.st_mode)
        root_parent = (parent_metadata.st_uid == 0 and
                       not (mode & 0o022 and not mode & stat.S_ISVTX))
        caller_parent = (owner_uid is not None and
                         parent_metadata.st_uid == owner_uid and mode == 0o700)
        if not (root_parent or caller_parent):
            os.close(parent_fd)
            fail("temporary parent must be trusted root storage or caller-owned mode 0700")
    name = None
    temp_fd = -1
    created_identity = None
    old_mask = None
    mask_restored = False
    if hasattr(signal, "pthread_sigmask"):
        old_mask = signal.pthread_sigmask(
            signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM, signal.SIGUSR1})
    try:
        for _ in range(128):
            candidate = b"savechanges." + os.urandom(16).hex().encode("ascii")
            try:
                os.mkdir(candidate, 0o700, dir_fd=parent_fd)
                name = candidate
                created = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
                created_identity = (created.st_dev, created.st_ino)
                break
            except FileExistsError:
                pass
        if name is None:
            fail("cannot create private temporary directory")
        temp_fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                          dir_fd=parent_fd)
        os.fchmod(temp_fd, 0o700)
        held = os.fstat(temp_fd)
        named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        expected_uid = os.geteuid()
        if (not stat.S_ISDIR(held.st_mode) or stat.S_IMODE(held.st_mode) != 0o700 or
                held.st_uid != expected_uid or
                (held.st_dev, held.st_ino) != (named.st_dev, named.st_ino)):
            fail("private temporary directory identity or permissions are invalid")
        if old_mask is not None:
            signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
            mask_restored = True
        check_cancelled()
        return canonical, parent_fd, name, temp_fd
    except BaseException:
        if temp_fd >= 0:
            os.close(temp_fd)
        try:
            named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False) if name else None
            if (named is not None and created_identity is not None and
                    (named.st_dev, named.st_ino) == created_identity):
                os.rmdir(name, dir_fd=parent_fd)
        except OSError:
            pass
        os.close(parent_fd)
        raise
    finally:
        if old_mask is not None and not mask_restored:
            signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)


def clear_directory(fd):
    for text_name in os.listdir(fd):
        metadata = os.stat(text_name, dir_fd=fd, follow_symlinks=False)
        if stat.S_ISDIR(metadata.st_mode):
            child = os.open(text_name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            try:
                clear_directory(child)
            finally:
                os.close(child)
            os.rmdir(text_name, dir_fd=fd)
        else:
            os.unlink(text_name, dir_fd=fd)


def cleanup_private_temp(temp_fd, parent_fd, name):
    clear_directory(temp_fd)
    held = os.fstat(temp_fd)
    named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if (held.st_dev, held.st_ino) != (named.st_dev, named.st_ino):
        fail("private temporary directory identity changed during cleanup")
    os.rmdir(name, dir_fd=parent_fd)
    try:
        os.fsync(parent_fd)
    except OSError as error:
        if error.errno not in (errno.EINVAL, errno.ENOTSUP, errno.EOPNOTSUPP):
            raise


def xattr_footprint(path, symlink=False):
    try:
        names = (list_xattrs(path, follow_symlinks=False) if symlink else
                 list_xattrs(path))
    except OSError as error:
        if error.errno in (errno.ENOTSUP, errno.EOPNOTSUPP):
            return 0, 0, 0
        if error.errno == errno.EPERM:
            fail("staged xattrs cannot be measured")
        raise
    count = 0
    name_bytes = 0
    value_bytes = 0
    for name in names:
        value = (get_xattr(path, name, follow_symlinks=False) if symlink else
                 get_xattr(path, name))
        count += 1
        name_bytes += len(os.fsencode(name))
        value_bytes += len(value)
    return count, name_bytes, value_bytes


def staged_metrics(tree_fd, backend):
    root_metadata, entries = scan_tree(tree_fd, backend)
    regular_inodes = set()
    all_inodes = {(root_metadata.st_dev, root_metadata.st_ino)}
    logical_size = 0
    regular_paths = 0
    directories = 1
    symlinks = 0
    symlink_bytes = 0
    whiteouts = 0
    filename_bytes = 0
    root_path = os.fsencode("/proc/self/fd/{}".format(tree_fd))
    xattr_count, xattr_name_bytes, xattr_value_bytes = xattr_footprint(root_path)
    xattr_inodes = set(all_inodes)
    for entry in entries:
        metadata = entry["stat"]
        identity = (metadata.st_dev, metadata.st_ino)
        all_inodes.add(identity)
        filename_bytes += len(entry["path"].rsplit(b"/", 1)[-1])
        entry_path = root_path + b"/" + entry["path"]
        if identity not in xattr_inodes:
            symlink = stat.S_ISLNK(metadata.st_mode)
            count, names, values = xattr_footprint(entry_path, symlink=symlink)
            xattr_count += count
            xattr_name_bytes += names
            xattr_value_bytes += values
            xattr_inodes.add(identity)
        if entry["kind"] == "whiteout":
            whiteouts += 1
        elif stat.S_ISREG(metadata.st_mode):
            regular_paths += 1
            if identity not in regular_inodes:
                regular_inodes.add(identity)
                logical_size += metadata.st_size
        elif stat.S_ISDIR(metadata.st_mode):
            directories += 1
        elif stat.S_ISLNK(metadata.st_mode):
            symlinks += 1
            symlink_bytes += len(os.readlink(entry_path))
    footprint = {
        "product_kind": "minios-extraction-footprint",
        "schema_version": 1,
        "regular_file_bytes": logical_size,
        "regular_file_inodes": len(regular_inodes),
        "directory_count": directories,
        "symlink_count": symlinks,
        "symlink_target_bytes": symlink_bytes,
        "whiteout_count": whiteouts,
        "inode_count": len(all_inodes),
        "directory_entry_count": len(entries),
        "filename_bytes": filename_bytes,
        "hardlink_reference_count": regular_paths - len(regular_inodes),
        "xattr_count": xattr_count,
        "xattr_name_bytes": xattr_name_bytes,
        "xattr_value_bytes": xattr_value_bytes,
    }
    return len(entries), logical_size, footprint


def planned_staging_bound(root_fd, root_metadata, entries, selected):
    planned_paths = set()
    for entry in selected:
        components = entry["path"].split(b"/")
        for index in range(1, len(components) + 1):
            planned_paths.add(b"/".join(components[:index]))
    inventory = {entry["path"]: entry for entry in entries}
    root_path = os.fsencode("/proc/self/fd/{}".format(root_fd))
    identities = {(root_metadata.st_dev, root_metadata.st_ino)}
    count, name_bytes, value_bytes = xattr_footprint(root_path)
    metadata_bound = 4096 + name_bytes + value_bytes + count * 256
    regular_bytes = 0
    for path in planned_paths:
        entry = inventory.get(path)
        if entry is None:
            fail("capture plan contains an absent parent")
        metadata = entry["stat"]
        identity = (metadata.st_dev, metadata.st_ino)
        metadata_bound += len(path.rsplit(b"/", 1)[-1]) + 4096
        if identity in identities:
            continue
        identities.add(identity)
        entry_path = root_path + b"/" + path
        symlink = stat.S_ISLNK(metadata.st_mode)
        count, name_bytes, value_bytes = xattr_footprint(entry_path, symlink=symlink)
        metadata_bound += name_bytes + value_bytes + count * 256
        if entry["kind"] == "regular":
            regular_bytes += metadata.st_size
        elif symlink:
            metadata_bound += len(os.readlink(entry_path))
    return regular_bytes + metadata_bound, len(identities)


def module_size_bound(footprint):
    metadata_bytes = (
        footprint["symlink_target_bytes"] + footprint["filename_bytes"] +
        footprint["xattr_name_bytes"] + footprint["xattr_value_bytes"] +
        (footprint["inode_count"] + footprint["directory_entry_count"] +
         footprint["xattr_count"]) * 4096)
    return footprint["regular_file_bytes"] + metadata_bytes + 16 * 1024 * 1024


def execute(arguments):
    global JSON_MODE, TEST_MODE
    if len(arguments) != 20:
        fail("invalid privileged engine invocation")
    (mode, profile, compression, output_path, changes_path, selection_path,
      metadata_path, temp_parent, owner_text, test_text, mksquashfs_path,
      unsquashfs_path, mountinfo_path, cmdline_path, boot_id_path,
       running_source_path, cancel_path, json_text, aufs_sysfs_path, mounted_root) = arguments
    JSON_MODE = json_text == "1"
    test_mode = test_text == "1"
    TEST_MODE = test_mode
    owner_uid = int(owner_text) if owner_text else None
    original_uid = owner_uid if owner_uid is not None else os.geteuid()
    enable_subreaper()
    configure_cancel_marker(cancel_path, original_uid)
    mksquashfs = trusted_tool(mksquashfs_path, test_mode) if mode == "module" else None
    unsquashfs = trusted_tool(unsquashfs_path, test_mode) if mode == "module" else None
    output_parent, output_fd, output_metadata, output_basename = split_output(output_path)
    metadata_basename = None
    if metadata_path:
        metadata_parent, metadata_fd, metadata_parent_metadata, metadata_basename = split_output(metadata_path)
        try:
            if (metadata_parent_metadata.st_dev, metadata_parent_metadata.st_ino) != (
                    output_metadata.st_dev, output_metadata.st_ino):
                fail("capture metadata output must use the module output directory")
        finally:
            os.close(metadata_fd)
        if metadata_basename == output_basename:
            fail("module and metadata outputs must differ")
    try:
        os.stat(output_basename, dir_fd=output_fd, follow_symlinks=False)
    except FileNotFoundError:
        pass
    else:
        fail("output already exists")
    if metadata_basename is not None:
        try:
            os.stat(metadata_basename, dir_fd=output_fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            fail("metadata output already exists")

    changes_canonical, root_fd = open_input_directory(changes_path)
    if changes_canonical == b"/":
        fail("refusing filesystem root as changes directory")
    backend, upperdir, lowerdirs = detect_union(
        mountinfo_path, cmdline_path, aufs_sysfs_path, mounted_root)
    root_fd = unwrap_changes(root_fd, backend, upperdir)
    capture_root_path = os.path.realpath(os.readlink(
        os.fsencode("/proc/self/fd/{}".format(root_fd))))
    nested_mounts = nested_mount_paths(mountinfo_path, capture_root_path)

    destination = b""
    try:
        if os.path.commonpath((changes_canonical, output_parent)) == changes_canonical:
            relative_parent = os.path.relpath(output_parent, changes_canonical)
            relative_parent = b"" if relative_parent == b"." else relative_parent
            destination = relative_parent + (b"/" if relative_parent else b"") + output_basename
    except ValueError:
        pass

    includes = []
    excludes = []
    selection_digest = None
    if selection_path:
        includes, excludes, selection_digest = read_selection(selection_path)

    temp_parent_fd = -1
    temp_fd = -1
    temp_name = None
    metadata_identity = None
    output_identity = None
    capture_complete = False
    try:
        temp_parent_path, temp_parent_fd, temp_name, temp_fd = create_private_temp(
            temp_parent, test_mode, owner_uid)
        if path_at_or_below(temp_parent_path, capture_root_path):
            fail("work parent must be outside the changes root")
        machine_phase("prepare")
        phase("capture-inventory", "Inventorying session changes")
        root_metadata, entries = scan_tree(root_fd, backend, nested_mounts)
        boot_id = read_boot_id(boot_id_path)
        fingerprint = source_fingerprint(root_metadata, backend, boot_id)
        base_fingerprint = (running_base_fingerprint(
            lowerdirs, backend, mountinfo_path, test_mode, running_source_path)
                            if mode == "module" else None)
        child_env = {"PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
                     "LC_ALL": "C.UTF-8", "LANG": "C.UTF-8"}
        if test_mode:
            for name in ("MKSQUASHFS_STATE", "MKSQUASHFS_FAIL", "MKSQUASHFS_RACE_TARGET",
                         "MKSQUASHFS_SLEEP", "MKSQUASHFS_SLEEP_MARKER", "MKSQUASHFS_STUBBORN",
                         "MKSQUASHFS_LEADER_EXIT", "MKSQUASHFS_NO_QUIET",
                         "UNSQUASHFS_FAIL_PATTERN"):
                if name in os.environ:
                    child_env[name] = os.environ[name]
        if mode == "inventory":
            document = inventory_document(root_metadata, entries, backend, fingerprint, destination)
            data = (json.dumps(document, ensure_ascii=False, allow_nan=False, sort_keys=True,
                               separators=(",", ":")) + "\n").encode("utf-8")
            machine_phase("publish")
            output_identity = atomic_publish_bytes(
                data, output_fd, output_parent, output_metadata, output_basename,
                0o600, owner_uid, temp_fd)
            result = {
                    "type": "result",
                    "product_kind": "minios-tool-result",
                    "schema_version": 1,
                    "tool": "savechanges",
                    "operation": "inventory",
                    "output": output_path,
                    "output_identity": {
                        "device": output_identity[0], "inode": output_identity[1],
                    },
                    "entry_count": len(entries),
                    "union_backend": backend,
                }
            cleanup_private_temp(temp_fd, temp_parent_fd, temp_name)
            os.close(temp_fd)
            temp_fd = -1
            os.close(temp_parent_fd)
            temp_parent_fd = -1
            verify_published_identity(output_fd, output_basename, output_identity)
            enter_commit_boundary()
            capture_complete = True
            emit_complete("Session inventory completed", result)
            return

        selected, stripped_opaque, unsafe_count = make_plan(
            root_fd, entries, backend, profile, destination, includes, excludes)
        if unsafe_count:
            warning("Unsafe filesystem objects omitted: {}".format(unsafe_count))
        information("Capture profile/backend/entries: {}/{}/{}".format(profile, backend, len(selected)))
        staged_bound, staged_inodes = planned_staging_bound(
            root_fd, root_metadata, entries, selected)
        module_bound = staged_bound + 16 * 1024 * 1024
        temp_required = staged_bound + module_bound + 16 * 1024 * 1024
        output_required = module_bound + 1024 * 1024
        temp_vfs = os.fstatvfs(temp_fd)
        output_vfs = os.fstatvfs(output_fd)
        temp_free = temp_vfs.f_bavail * temp_vfs.f_frsize
        output_free = output_vfs.f_bavail * output_vfs.f_frsize
        output_inodes = 1 + (1 if metadata_basename is not None else 0)
        if os.fstat(temp_fd).st_dev == output_metadata.st_dev:
            if min(temp_free, output_free) < temp_required + output_required:
                fail("insufficient shared staging and destination space")
            if (temp_vfs.f_files and temp_vfs.f_favail <
                    staged_inodes + 1 + output_inodes):
                fail("insufficient shared staging and destination inodes")
        else:
            if temp_free < temp_required:
                fail("insufficient private temporary space")
            if output_free < output_required:
                fail("insufficient destination space")
            if temp_vfs.f_files and temp_vfs.f_favail < staged_inodes + 1:
                fail("insufficient private temporary inodes")
            if output_vfs.f_files and output_vfs.f_favail < output_inodes:
                fail("insufficient destination inodes")

        phase("capture-copy", "Copying session changes into root-owned private storage")
        pause_before_copy(test_mode)
        os.mkdir(b"tree", 0o700, dir_fd=temp_fd)
        staging = os.fsencode("/proc/self/fd/{}/tree".format(temp_fd))
        copy_plan(root_fd, root_metadata, entries, selected, stripped_opaque,
                  profile, backend, staging)
        tree_fd = os.open(b"tree", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                          dir_fd=temp_fd)
        try:
            capture_entry_count, regular_bytes, extraction_footprint = staged_metrics(
                tree_fd, backend)
            extraction_footprint["compressor"] = compression
            extraction_footprint["block_size"] = 1024 * 1024
        finally:
            os.close(tree_fd)
        if STRIPPED_XATTRS:
            warning("Unsafe or non-allowlisted xattrs omitted: {}".format(STRIPPED_XATTRS))

        module_bound = module_size_bound(extraction_footprint)
        temp_vfs = os.fstatvfs(temp_fd)
        output_vfs = os.fstatvfs(output_fd)
        temp_free = temp_vfs.f_bavail * temp_vfs.f_frsize
        output_free = output_vfs.f_bavail * output_vfs.f_frsize
        if os.fstat(temp_fd).st_dev == output_metadata.st_dev:
            if min(temp_free, output_free) < module_bound * 2 + 1024 * 1024:
                fail("insufficient shared module and publication space after staging")
        else:
            if temp_free < module_bound:
                fail("insufficient private module space after staging")
            if output_free < module_bound + 1024 * 1024:
                fail("insufficient destination publication space after staging")

        phase("capture-compress", "Compressing and fully testing captured session changes")
        module_path = "/proc/self/fd/{}/module.squashfs".format(temp_fd)
        _help_status, help_output = run_tool_output(
            [mksquashfs, "-help-option", "quiet"], child_env=child_env)
        quiet = "-quiet" in (help_output or "")
        block = "1024K" if quiet else "1024k"
        command = [mksquashfs, os.fsdecode(staging), module_path, "-comp", compression,
                   "-b", block, "-always-use-fragments", "-noappend", "-xattrs"]
        if quiet:
            command.append("-quiet")
        if compression == "zstd":
            command.extend(["-Xcompression-level", "19"])
        elif compression == "xz":
            command.extend(["-Xbcj", "x86"])
        if run_tool(command, pass_fds=(temp_fd,), child_env=child_env,
                    stdout=sys.stderr if JSON_MODE else subprocess.DEVNULL) != 0:
            fail("mksquashfs failed for compression {}".format(compression))
        machine_phase("verify")
        module_fd = os.open(b"module.squashfs", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=temp_fd)
        try:
            module_stat = os.fstat(module_fd)
            if not stat.S_ISREG(module_stat.st_mode) or module_stat.st_size <= 0:
                fail("mksquashfs did not create a nonempty regular module")
            if run_tool([unsquashfs, "-s", module_path], pass_fds=(temp_fd,),
                        stdout=subprocess.DEVNULL, child_env=child_env) != 0:
                fail("created module has an invalid SquashFS superblock")
            if run_tool([unsquashfs, "-ll", module_path], pass_fds=(temp_fd,),
                        stdout=subprocess.DEVNULL, child_env=child_env) != 0:
                fail("created module failed SquashFS listing verification")
            digest = hashlib.sha256()
            while True:
                check_cancelled()
                block_data = os.read(module_fd, 1024 * 1024)
                if not block_data:
                    break
                digest.update(block_data)
            module_digest = digest.hexdigest()
            capture_metadata = {
                "product_kind": "minios-session-capture-metadata",
                "schema_version": 2,
                "profile": profile,
                "union_backend": backend,
                "source_fingerprint": fingerprint,
                "boot_id": boot_id,
                "base_module_fingerprint": base_fingerprint,
                "module": {
                    "size": module_stat.st_size,
                    "sha256": module_digest,
                    "entry_count": capture_entry_count,
                    "uncompressed_size": regular_bytes,
                    "extraction_footprint": extraction_footprint,
                },
                "selection_sha256": selection_digest,
            }
            if metadata_basename is not None:
                machine_phase("publish")
                metadata_data = (json.dumps(capture_metadata, sort_keys=True,
                                            separators=(",", ":")) + "\n").encode("utf-8")
                metadata_identity = atomic_publish_bytes(
                    metadata_data, output_fd, output_parent, output_metadata, metadata_basename,
                    0o600, owner_uid, temp_fd)
            elif JSON_MODE:
                machine_phase("publish")
            os.lseek(module_fd, 0, os.SEEK_SET)
            output_mode = 0o644 if profile == "legacy" else 0o600
            try:
                output_identity = atomic_publish_stream(
                    module_fd, output_fd, output_parent, output_metadata,
                    output_basename, output_mode, owner_uid)
            except Exception:
                if metadata_identity is not None:
                    if not remove_if_identity(output_fd, metadata_basename, metadata_identity):
                        fail("capture metadata rollback failed")
                raise
        finally:
            os.close(module_fd)
        result = {
                "type": "result",
                "product_kind": "minios-tool-result",
                "schema_version": 1,
                "tool": "savechanges",
                "operation": "capture-module",
                "output": output_path,
                "output_identity": {
                    "device": output_identity[0], "inode": output_identity[1],
                },
                "compressed_size": module_stat.st_size,
                "uncompressed_size": regular_bytes,
                "entry_count": capture_entry_count,
                "extraction_footprint": extraction_footprint,
                "sha256": module_digest,
                "profile": profile,
                "union_backend": backend,
            }
        cleanup_private_temp(temp_fd, temp_parent_fd, temp_name)
        os.close(temp_fd)
        temp_fd = -1
        os.close(temp_parent_fd)
        temp_parent_fd = -1
        verify_published_identity(output_fd, output_basename, output_identity)
        if metadata_identity is not None:
            verify_published_identity(output_fd, metadata_basename, metadata_identity)
        enter_commit_boundary()
        capture_complete = True
        emit_complete("Session capture completed", result)
    finally:
        terminate_child(CURRENT_CHILD, CURRENT_PGID)
        if not capture_complete:
            if output_identity is not None:
                if not remove_if_identity(output_fd, output_basename, output_identity):
                    print("E: published module rollback failed", file=sys.stderr, flush=True)
            if metadata_identity is not None:
                if not remove_if_identity(output_fd, metadata_basename, metadata_identity):
                    print("E: capture metadata rollback failed", file=sys.stderr, flush=True)
        if temp_fd >= 0:
            try:
                cleanup_private_temp(temp_fd, temp_parent_fd, temp_name)
            finally:
                os.close(temp_fd)
                os.close(temp_parent_fd)
        try:
            os.close(root_fd)
        except OSError:
            pass
        try:
            os.close(output_fd)
        except OSError:
            pass


signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)
signal.signal(signal.SIGUSR1, signal_handler)

try:
    if len(sys.argv) < 2 or sys.argv[1] != "execute":
        fail("invalid helper command")
    execute(sys.argv[2:])
except Cancelled:
    if JSON_MODE:
        json_event({"type": "phase", "phase": "cancelled"})
    else:
        print("P:cancelled", flush=True)
    print("E: capture cancelled", file=sys.stderr, flush=True)
    raise SystemExit(130)
except CaptureError as error:
    print("E: {}".format(error), file=sys.stderr, flush=True)
    raise SystemExit(1)
except (OSError, TypeError, UnicodeError, ValueError) as error:
    print("E: capture filesystem error: {}".format(error), file=sys.stderr, flush=True)
    raise SystemExit(1)
finally:
    shutdown_cancel_monitor()
