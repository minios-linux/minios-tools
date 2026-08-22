#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Runtime SquashFS session save backend for MiniOS."""
from __future__ import print_function

import contextlib
import errno
import fcntl
import hashlib
import json
import os
import re
import signal
import stat
import subprocess
import tempfile
import time
from datetime import datetime, timezone

SAVECHANGES_COMMAND = "/usr/bin/savechanges"
BOOT_STATE_FILE = "/run/initramfs/minios-persistence/boot-state"
BOOT_ID_FILE = "/proc/sys/kernel/random/boot_id"
SESSION_PATHS = (
    "/run/initramfs/memory/data/minios/changes",
    "/lib/live/mount/medium/minios/changes",
)
EXACT_STAGING_FILESYSTEMS = (
    "ext2", "ext3", "ext4", "btrfs", "xfs", "f2fs", "reiserfs",
)
SAVECHANGES_PHASES = (
    "prepare", "inventory", "capture", "compress", "verify", "publish", "complete",
)


class SquashfsSaveError(Exception):
    pass


class MetadataCommitUncertain(OSError):
    pass


def _validate_session_id(session_id):
    if not isinstance(session_id, str) or not re.fullmatch(r"[0-9]+", session_id):
        raise SquashfsSaveError("Invalid session ID")
    return session_id


def _strict_json_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON field")
        value[key] = item
    return value


def _reject_json_constant(value):
    raise ValueError("invalid JSON constant: {}".format(value))


def _sync_directory(descriptor):
    try:
        os.fsync(descriptor)
    except OSError as error:
        unsupported = (errno.EINVAL, errno.ENOTSUP,
                       getattr(errno, "EOPNOTSUPP", errno.ENOTSUP))
        if error.errno not in unsupported:
            raise


class SquashfsSessionSaver:
    def __init__(self, sessions_dir=None, boot_state_file=BOOT_STATE_FILE,
                 boot_id_file=BOOT_ID_FILE, savechanges_command=SAVECHANGES_COMMAND):
        self.sessions_dir = os.path.realpath(sessions_dir) if sessions_dir else self._find_sessions_dir()
        self.boot_state_file = boot_state_file
        self.boot_id_file = boot_id_file
        self.savechanges_command = savechanges_command
        self._lock_fd = None

    @staticmethod
    def _find_sessions_dir():
        found = []
        for path in SESSION_PATHS:
            try:
                metadata = os.stat(path, follow_symlinks=False)
            except OSError:
                continue
            if stat.S_ISDIR(metadata.st_mode):
                found.append(os.path.realpath(path))
        unique = []
        for path in found:
            if path not in unique:
                unique.append(path)
        if len(unique) > 1:
            raise SquashfsSaveError("Selected persistence storage is ambiguous")
        return unique[0] if unique else None

    def _session_path(self, session_id):
        session_id = _validate_session_id(session_id)
        if not self.sessions_dir:
            raise SquashfsSaveError("Sessions directory not found")
        root = os.path.realpath(self.sessions_dir)
        candidate = os.path.join(root, session_id)
        if os.path.commonpath([root, os.path.realpath(candidate)]) != root:
            raise SquashfsSaveError("Invalid session path")
        if not os.path.isdir(candidate) or os.path.islink(candidate):
            raise SquashfsSaveError("Session {} does not exist".format(session_id))
        return candidate

    @contextlib.contextmanager
    def _mutation_lock(self):
        if not self.sessions_dir:
            raise SquashfsSaveError("Sessions directory not found")
        lock_path = os.path.join(self.sessions_dir, ".session.lock")
        flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(lock_path, flags, 0o600)
        try:
            metadata = os.fstat(descriptor)
            if (not stat.S_ISREG(metadata.st_mode) or
                    metadata.st_uid != os.geteuid() or metadata.st_nlink != 1):
                raise SquashfsSaveError("Unsafe session lock file")
            os.fchmod(descriptor, 0o600)
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            self._lock_fd = descriptor
            yield
        finally:
            self._lock_fd = None
            try:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
            finally:
                os.close(descriptor)

    def _read_metadata(self):
        if not self.sessions_dir:
            raise SquashfsSaveError("Sessions directory not found")
        conf_path = os.path.join(self.sessions_dir, "session.conf")
        metadata = {"default": None, "sessions": {}}
        try:
            stream = open(conf_path, "r", encoding="utf-8")
        except OSError as error:
            raise SquashfsSaveError("Session metadata is unavailable: {}".format(error))
        with stream:
            for raw_line in stream:
                line = raw_line.rstrip("\n")
                if not line:
                    continue
                if "\r" in line or "\0" in line:
                    raise SquashfsSaveError("Session metadata is malformed")
                if line.startswith("default="):
                    metadata["default"] = line.split("=", 1)[1] or None
                    continue
                if line.startswith("running="):
                    metadata["running"] = line.split("=", 1)[1] or None
                    continue
                match = re.fullmatch(r"session_([a-z][a-z0-9_]*)\[([0-9]+)\]=(.*)", line)
                if not match:
                    raise SquashfsSaveError("Session metadata is malformed")
                field, session_id, value = match.groups()
                metadata["sessions"].setdefault(session_id, {})[field] = value
        for selector in ("default", "running"):
            value = metadata.get(selector)
            if value is not None and not re.fullmatch(r"[0-9]+", value):
                raise SquashfsSaveError("Session metadata is malformed")
        return metadata

    @staticmethod
    def _serialize_metadata(metadata, format_name):
        if format_name == "json":
            return json.dumps(metadata, indent=2, sort_keys=False) + "\n"
        lines = ["default={}".format(metadata.get("default") or "")]
        if metadata.get("running"):
            lines.append("running={}".format(metadata["running"]))
        for session_id, fields in metadata.get("sessions", {}).items():
            for field, value in fields.items():
                text = str(value)
                if any(character in text for character in ("\r", "\n", "\0")):
                    raise SquashfsSaveError("Session metadata is malformed")
                lines.append("session_{}[{}]={}".format(field, session_id, text))
        return "\n".join(lines) + "\n"

    def _atomic_write(self, path, payload):
        temporary = None
        descriptor, temporary = tempfile.mkstemp(
            prefix=".session-metadata-", dir=self.sessions_dir)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                stream.write(payload)
                stream.flush()
                os.fsync(stream.fileno())
            os.chmod(temporary, 0o600)
            os.replace(temporary, path)
            temporary = None
            directory_fd = os.open(self.sessions_dir, os.O_RDONLY | os.O_DIRECTORY)
            try:
                _sync_directory(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            if temporary and os.path.exists(temporary):
                os.unlink(temporary)

    def _write_metadata(self, metadata):
        conf_path = os.path.join(self.sessions_dir, "session.conf")
        json_path = os.path.join(self.sessions_dir, "session.json")
        conf_payload = self._serialize_metadata(metadata, "conf")
        json_payload = self._serialize_metadata(metadata, "json")

        # Never leave a stale JSON copy that would override a newer conf file.
        if os.path.exists(json_path):
            os.unlink(json_path)
            directory_fd = os.open(self.sessions_dir, os.O_RDONLY | os.O_DIRECTORY)
            try:
                _sync_directory(directory_fd)
            finally:
                os.close(directory_fd)
        self._atomic_write(conf_path, conf_payload)
        try:
            self._atomic_write(json_path, json_payload)
        except OSError:
            # session.conf is the durable runtime representation; JSON is a convenience copy.
            pass

    def _current_boot_id(self):
        try:
            with open(self.boot_id_file, "r", encoding="ascii") as stream:
                value = stream.read().strip()
        except OSError as error:
            raise SquashfsSaveError("Running boot identity is unavailable: {}".format(error))
        if not re.fullmatch(r"[0-9a-fA-F-]+", value or ""):
            raise SquashfsSaveError("Running boot identity is invalid")
        return value

    def _read_boot_state(self):
        try:
            metadata = os.stat(self.boot_state_file, follow_symlinks=False)
        except OSError as error:
            raise SquashfsSaveError("Persistence runtime state is unavailable: {}".format(error))
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid() or
                metadata.st_nlink != 1 or stat.S_IMODE(metadata.st_mode) & 0o022):
            raise SquashfsSaveError("Persistence runtime state is not trusted")
        allowed = {
            "boot_id", "boot_level", "mode", "session", "durable", "writable",
            "sessions_device", "sessions_inode", "active_generation",
        }
        state = {}
        with open(self.boot_state_file, "r", encoding="utf-8") as stream:
            for raw_line in stream:
                line = raw_line.rstrip("\n")
                if not line or "\r" in line or "=" not in line:
                    raise SquashfsSaveError("Persistence runtime state is malformed")
                key, value = line.split("=", 1)
                if key not in allowed or key in state:
                    raise SquashfsSaveError("Persistence runtime state is malformed")
                state[key] = value
        return state

    def _detect_filesystem(self):
        target = os.path.realpath(self.sessions_dir)
        best = None
        try:
            stream = open("/proc/self/mountinfo", "r", encoding="utf-8")
        except OSError as error:
            raise SquashfsSaveError("Filesystem information is unavailable: {}".format(error))
        with stream:
            for line in stream:
                fields = line.rstrip("\n").split(" ")
                try:
                    separator = fields.index("-")
                except ValueError:
                    continue
                mount_point = fields[4].replace("\\040", " ")
                if target == mount_point or target.startswith(mount_point.rstrip("/") + "/"):
                    if best is None or len(mount_point) > len(best[0]):
                        best = (mount_point, fields, separator)
        if best is None:
            raise SquashfsSaveError("Failed to determine persistence filesystem")
        _mount_point, fields, separator = best
        filesystem = fields[separator + 1].lower()
        mount_options = fields[5].split(",")
        super_options = fields[separator + 3].split(",") if len(fields) > separator + 3 else []
        if "ro" in mount_options or "ro" in super_options:
            raise SquashfsSaveError("Selected persistence storage is read-only")
        if filesystem not in EXACT_STAGING_FILESYSTEMS:
            raise SquashfsSaveError(
                "Selected persistence storage cannot preserve exact capture metadata")
        return filesystem

    def _validate_runtime(self, session_id):
        state = self._read_boot_state()
        boot_id = self._current_boot_id()
        required = {
            "boot_id": boot_id,
            "boot_level": "ok",
            "mode": "squashfs",
            "session": session_id,
            "durable": "1",
            "writable": "1",
            "active_generation": "current",
        }
        if any(state.get(key) != value for key, value in required.items()):
            raise SquashfsSaveError(
                "The requested SquashFS session is not active in this boot")

        selected = os.stat(self.sessions_dir, follow_symlinks=False)
        aliases = []
        for path in SESSION_PATHS:
            try:
                candidate = os.stat(path, follow_symlinks=False)
            except OSError:
                continue
            aliases.append((candidate.st_dev, candidate.st_ino))
        identity = (selected.st_dev, selected.st_ino)
        if identity not in aliases or any(item != identity for item in aliases):
            raise SquashfsSaveError("Selected persistence storage is ambiguous")
        if (state.get("sessions_device") != str(selected.st_dev) or
                state.get("sessions_inode") != str(selected.st_ino)):
            raise SquashfsSaveError("Selected persistence storage changed after activation")
        self._detect_filesystem()
        return state

    @staticmethod
    def _stop_capture_process(process):
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + 12.0
        group_alive = True
        while time.monotonic() < deadline:
            process.poll()
            try:
                os.killpg(process.pid, 0)
            except ProcessLookupError:
                group_alive = False
            if process.poll() is not None and not group_alive:
                break
            time.sleep(0.05)
        if group_alive:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                group_alive = False
        kill_deadline = time.monotonic() + 2.0
        while group_alive and time.monotonic() < kill_deadline:
            try:
                os.killpg(process.pid, 0)
            except ProcessLookupError:
                group_alive = False
                break
            time.sleep(0.05)
        process.wait()

    def _run_savechanges(self, output_path, work_parent, progress_callback=None):
        try:
            command_stat = os.stat(self.savechanges_command, follow_symlinks=False)
        except OSError as error:
            raise SquashfsSaveError("Trusted savechanges command is unavailable: {}".format(error))
        if (not stat.S_ISREG(command_stat.st_mode) or command_stat.st_uid != os.geteuid() or
                stat.S_IMODE(command_stat.st_mode) & 0o022 or
                not os.access(self.savechanges_command, os.X_OK)):
            raise SquashfsSaveError("Trusted savechanges command is unavailable")
        argv = [
            self.savechanges_command, "--json", "--profile", "exact",
            "--work-parent", work_parent, output_path,
        ]
        environment = {
            "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
            "LC_ALL": "C.UTF-8",
            "LANG": "C.UTF-8",
        }
        events = []
        with tempfile.TemporaryFile() as error_file:
            process = subprocess.Popen(
                argv, stdout=subprocess.PIPE, stderr=error_file,
                universal_newlines=True, start_new_session=True, env=environment)
            try:
                for line in process.stdout:
                    if not line.strip():
                        raise ValueError("savechanges emitted an empty machine-output line")
                    event = json.loads(
                        line, object_pairs_hook=_strict_json_object,
                        parse_constant=_reject_json_constant)
                    if not isinstance(event, dict):
                        raise ValueError("savechanges emitted an invalid event")
                    events.append(event)
                    if event.get("type") == "phase" and progress_callback is not None:
                        progress_callback(event.get("phase"))
                process.wait()
            except BaseException:
                self._stop_capture_process(process)
                raise
            if process.returncode == 130:
                raise SquashfsSaveError("Session save was cancelled")
            if process.returncode != 0:
                error_file.seek(0)
                detail = error_file.read(65536).decode("utf-8", "replace").strip()
                message = "savechanges failed with status {}".format(process.returncode)
                if detail:
                    message = "{}: {}".format(message, detail.splitlines()[-1])
                raise SquashfsSaveError(message)
        if len(events) != len(SAVECHANGES_PHASES) + 1:
            raise SquashfsSaveError("savechanges emitted an incomplete result")
        phases = events[:-1]
        if ([event.get("phase") for event in phases] != list(SAVECHANGES_PHASES) or
                any(event.get("type") != "phase" for event in phases)):
            raise SquashfsSaveError("savechanges emitted an invalid phase sequence")
        result = events[-1]
        required = {
            "type": "result",
            "product_kind": "minios-tool-result",
            "schema_version": 1,
            "tool": "savechanges",
            "operation": "capture-module",
            "output": output_path,
            "profile": "exact",
        }
        if any(result.get(key) != value for key, value in required.items()):
            raise SquashfsSaveError("savechanges emitted an invalid result")
        if result.get("union_backend") not in ("aufs", "overlayfs"):
            raise SquashfsSaveError("savechanges emitted an invalid union backend")
        for field in ("compressed_size", "uncompressed_size", "entry_count"):
            value = result.get(field)
            if type(value) is not int or value < (1 if field == "compressed_size" else 0):
                raise SquashfsSaveError("savechanges emitted an invalid sizing result")
        if not isinstance(result.get("sha256"), str) or not re.fullmatch(
                r"[0-9a-f]{64}", result["sha256"]):
            raise SquashfsSaveError("savechanges emitted an invalid digest")
        identity = result.get("output_identity")
        if not isinstance(identity, dict):
            raise SquashfsSaveError("savechanges emitted an invalid output identity")
        for field in ("device", "inode"):
            value = identity.get(field)
            if type(value) is not int or value < (1 if field == "inode" else 0):
                raise SquashfsSaveError("savechanges emitted an invalid output identity")
        footprint = result.get("extraction_footprint")
        footprint_fields = {
            "product_kind", "schema_version", "regular_file_bytes",
            "regular_file_inodes", "directory_count", "symlink_count",
            "symlink_target_bytes", "whiteout_count", "inode_count",
            "directory_entry_count", "filename_bytes", "hardlink_reference_count",
            "xattr_count", "xattr_name_bytes", "xattr_value_bytes", "compressor",
            "block_size",
        }
        if not isinstance(footprint, dict) or set(footprint) != footprint_fields:
            raise SquashfsSaveError("savechanges emitted an invalid extraction footprint")
        if (footprint["product_kind"] != "minios-extraction-footprint" or
                type(footprint["schema_version"]) is not int or
                footprint["schema_version"] != 1 or
                not isinstance(footprint["compressor"], str) or
                footprint["compressor"] not in ("zstd", "gzip", "lzo", "xz")):
            raise SquashfsSaveError("savechanges emitted an invalid extraction footprint")
        count_fields = footprint_fields - {
            "product_kind", "schema_version", "compressor", "block_size",
        }
        if (any(type(footprint[field]) is not int or footprint[field] < 0
                for field in count_fields) or
                type(footprint["block_size"]) is not int or
                footprint["block_size"] < 4096 or footprint["block_size"] > 1024 * 1024 or
                footprint["block_size"] & (footprint["block_size"] - 1) or
                footprint["directory_count"] < 1 or footprint["inode_count"] < 1 or
                footprint["regular_file_bytes"] != result["uncompressed_size"] or
                footprint["directory_entry_count"] != result["entry_count"]):
            raise SquashfsSaveError("savechanges emitted an invalid extraction footprint")
        regular_inodes = footprint["regular_file_inodes"]
        directories = footprint["directory_count"]
        symlinks = footprint["symlink_count"]
        whiteouts = footprint["whiteout_count"]
        hardlinks = footprint["hardlink_reference_count"]
        if ((hardlinks and not regular_inodes) or
                footprint["directory_entry_count"] != (
                    directories - 1 + regular_inodes + hardlinks + symlinks + whiteouts) or
                footprint["inode_count"] != (
                    directories + regular_inodes + symlinks + whiteouts) or
                footprint["filename_bytes"] < footprint["directory_entry_count"] or
                footprint["symlink_target_bytes"] < symlinks or
                footprint["xattr_name_bytes"] < footprint["xattr_count"]):
            raise SquashfsSaveError("savechanges emitted an invalid extraction footprint")
        return result

    @staticmethod
    def _artifact_digest(directory_fd, name):
        digest = hashlib.sha256()
        artifact_fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory_fd)
        try:
            while True:
                block = os.read(artifact_fd, 1024 * 1024)
                if not block:
                    break
                digest.update(block)
        finally:
            os.close(artifact_fd)
        return digest.hexdigest()
    def _validate_capture(self, directory_fd, name, result):
        captured = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        identity = (
            result["output_identity"]["device"],
            result["output_identity"]["inode"],
        )
        if (not stat.S_ISREG(captured.st_mode) or captured.st_nlink != 1 or
                captured.st_uid != os.geteuid() or
                (captured.st_dev, captured.st_ino) != identity or
                captured.st_size != result["compressed_size"]):
            raise SquashfsSaveError("Captured SquashFS identity or size changed")
        module_fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory_fd)
        try:
            if os.read(module_fd, 4) != b"hsqs":
                raise SquashfsSaveError("Captured file is not a SquashFS image")
            os.fsync(module_fd)
        finally:
            os.close(module_fd)
        if self._artifact_digest(directory_fd, name) != result["sha256"]:
            raise SquashfsSaveError("Captured SquashFS digest does not match its result")
        return identity

    @staticmethod
    def _remove_capture(directory_fd, name, identity=None):
        try:
            current = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        except FileNotFoundError:
            return
        if (not stat.S_ISREG(current.st_mode) or current.st_uid != os.geteuid() or
                current.st_nlink != 1):
            return
        if identity is not None and (current.st_dev, current.st_ino) != identity:
            return
        os.unlink(name, dir_fd=directory_fd)
        _sync_directory(directory_fd)

    def save(self, session_id, finalize_shutdown=False, progress_callback=None):
        session_id = _validate_session_id(session_id)
        session_path = self._session_path(session_id)
        new_name = ".changes.sb.new-{}".format(os.urandom(16).hex())
        current_name = "changes.sb"
        result = None
        capture_validated = False
        published = False
        directory_fd = -1
        try:
            with self._mutation_lock():
                metadata = self._read_metadata()
                session_data = metadata.get("sessions", {}).get(session_id)
                if session_data is None:
                    raise SquashfsSaveError("Session {} does not exist".format(session_id))
                if session_data.get("mode") != "squashfs":
                    raise SquashfsSaveError("Session {} is not a SquashFS session".format(session_id))
                if metadata.get("running") != session_id:
                    raise SquashfsSaveError("Only the running SquashFS session can be saved")
                if finalize_shutdown and session_data.get("policy", "manual") != "shutdown":
                    raise SquashfsSaveError(
                        "Session {} is not configured for shutdown saving".format(session_id))
                runtime_state = self._validate_runtime(session_id)

                directory_fd = os.open(
                    session_path, os.O_RDONLY | os.O_DIRECTORY |
                    getattr(os, "O_NOFOLLOW", 0))
                directory_stat = os.fstat(directory_fd)
                if (not stat.S_ISDIR(directory_stat.st_mode) or
                        directory_stat.st_uid != os.geteuid() or
                        stat.S_IMODE(directory_stat.st_mode) & 0o022):
                    raise SquashfsSaveError("Unsafe SquashFS session directory")
                try:
                    current = os.stat(current_name, dir_fd=directory_fd,
                                      follow_symlinks=False)
                except FileNotFoundError:
                    current_identity = None
                else:
                    if (not stat.S_ISREG(current.st_mode) or
                            current.st_uid != os.geteuid() or current.st_nlink != 1):
                        raise SquashfsSaveError("Unsafe SquashFS session artifact")
                    current_identity = (current.st_dev, current.st_ino)

                new_path = os.path.join(session_path, new_name)
                result = self._run_savechanges(
                    new_path, session_path, progress_callback=progress_callback)
                result_identity = self._validate_capture(directory_fd, new_name, result)
                capture_validated = True
                _sync_directory(directory_fd)

                try:
                    current = os.stat(current_name, dir_fd=directory_fd,
                                      follow_symlinks=False)
                    observed_identity = (current.st_dev, current.st_ino)
                except FileNotFoundError:
                    observed_identity = None
                if observed_identity != current_identity:
                    raise SquashfsSaveError("SquashFS generation changed during capture")

                generation_text = str(session_data.get("generation", "0"))
                if not re.fullmatch(r"[0-9]+", generation_text):
                    raise SquashfsSaveError("Invalid SquashFS generation metadata")
                generation = int(generation_text) + 1
                previous_handlers = {}
                for signum in (signal.SIGINT, signal.SIGTERM):
                    previous_handlers[signum] = signal.signal(signum, signal.SIG_IGN)
                try:
                    os.replace(new_name, current_name,
                               src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
                    published = True
                    _sync_directory(directory_fd)

                    for key in list(session_data):
                        if key.startswith("old_"):
                            session_data.pop(key, None)
                    session_data.update({
                        "policy": session_data.get("policy", "manual"),
                        "saved": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                        "digest": result["sha256"],
                        "compressed": str(result["compressed_size"]),
                        "uncompressed": str(result["uncompressed_size"]),
                        "entries": str(result["entry_count"]),
                        "footprint": json.dumps(
                            result["extraction_footprint"], sort_keys=True,
                            separators=(",", ":")),
                        "generation": str(generation),
                        "union": result["union_backend"],
                        "capture_boot_id": runtime_state["boot_id"],
                    })
                    if finalize_shutdown:
                        metadata.pop("running", None)
                        session_data["state"] = "clean"
                    self._write_metadata(metadata)
                finally:
                    for signum, handler in previous_handlers.items():
                        signal.signal(signum, handler)
                capture = dict(result)
                capture["session_id"] = session_id
                capture["generation"] = generation
                capture["saved"] = session_data["saved"]
                capture["shutdown_finalized"] = bool(finalize_shutdown)
                return capture
        except BaseException as error:
            if directory_fd >= 0 and not published:
                identity = None
                if result is not None and capture_validated:
                    identity = (
                        result["output_identity"]["device"],
                        result["output_identity"]["inode"],
                    )
                try:
                    self._remove_capture(directory_fd, new_name, identity)
                except OSError:
                    pass
            if isinstance(error, (KeyboardInterrupt, SystemExit)):
                raise
            if published:
                raise SquashfsSaveError(
                    "Session data was published, but metadata update failed: {}".format(error))
            if isinstance(error, SquashfsSaveError):
                raise
            raise SquashfsSaveError("Failed to save session: {}".format(error))
        finally:
            if directory_fd >= 0:
                os.close(directory_fd)
