#!/usr/bin/env python3
from __future__ import print_function

import hashlib
import io
import json
import os
import sys
import tempfile

ROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(ROOT, "lib"))
import minios_squashfs_session as squashfs_backend
from minios_squashfs_session import SquashfsSaveError, SquashfsSessionSaver


def footprint(uncompressed=2048, entries=12):
    regular = 1 if entries else 0
    return {
        "product_kind": "minios-extraction-footprint",
        "schema_version": 1,
        "regular_file_bytes": uncompressed,
        "regular_file_inodes": regular,
        "directory_count": 1,
        "symlink_count": 0,
        "symlink_target_bytes": 0,
        "whiteout_count": 0,
        "inode_count": 1 + regular,
        "directory_entry_count": entries,
        "filename_bytes": entries * 6,
        "hardlink_reference_count": max(0, entries - regular),
        "xattr_count": 0,
        "xattr_name_bytes": 0,
        "xattr_value_bytes": 0,
        "compressor": "zstd",
        "block_size": 1024 * 1024,
    }


def setup_session(root, policy="shutdown", generation="7"):
    changes = os.path.join(root, "changes")
    session = os.path.join(changes, "1")
    os.makedirs(session, mode=0o700)
    old = b"hsqs-old-snapshot"
    with open(os.path.join(session, "changes.sb"), "wb") as stream:
        stream.write(old)
    with open(os.path.join(changes, "session.conf"), "w") as stream:
        stream.write("default=1\nrunning=1\nsession_mode[1]=squashfs\n")
        stream.write("session_policy[1]={}\n".format(policy))
        stream.write("session_generation[1]={}\n".format(generation))
        stream.write("session_old_digest[1]=deadbeef\nsession_state[1]=dirty\n")
    return changes, session, old


def fake_capture(payload=b"hsqs-new-snapshot", mutate=None, expected_work_parent=None):
    def capture(output_path, work_parent, progress_callback=None):
        assert work_parent == (expected_work_parent or os.path.dirname(output_path))
        with open(output_path, "wb") as stream:
            stream.write(payload)
        metadata = os.stat(output_path)
        result = {
            "type": "result",
            "product_kind": "minios-tool-result",
            "schema_version": 1,
            "tool": "savechanges",
            "operation": "capture-module",
            "output": output_path,
            "output_identity": {"device": metadata.st_dev, "inode": metadata.st_ino},
            "compressed_size": len(payload),
            "uncompressed_size": 2048,
            "entry_count": 12,
            "extraction_footprint": footprint(),
            "sha256": hashlib.sha256(payload).hexdigest(),
            "profile": "exact",
            "union_backend": "overlayfs",
        }
        if mutate is not None:
            mutate(result, output_path)
        return result
    return capture


def saver_for(changes):
    saver = SquashfsSessionSaver(sessions_dir=changes)
    saver._validate_runtime = lambda session_id: {"boot_id": "boot-test"}
    saver._run_savechanges = fake_capture()
    return saver


def read_json(changes):
    with open(os.path.join(changes, "session.json"), encoding="utf-8") as stream:
        return json.load(stream)

def case_save():
    with tempfile.TemporaryDirectory() as root:
        changes, session, _old = setup_session(root)
        saver = saver_for(changes)
        result = saver.save("1")
        assert result["generation"] == 8
        assert result["shutdown_finalized"] is False
        with open(os.path.join(session, "changes.sb"), "rb") as stream:
            assert stream.read() == b"hsqs-new-snapshot"
        metadata = read_json(changes)
        record = metadata["sessions"]["1"]
        assert metadata["running"] == "1"
        assert record["generation"] == "8"
        assert record["digest"] == hashlib.sha256(b"hsqs-new-snapshot").hexdigest()
        assert record["capture_boot_id"] == "boot-test"
        assert not any(key.startswith("old_") for key in record)
        assert not any(name.startswith(".changes.sb.new-") for name in os.listdir(session))


def case_ram_workspace():
    with tempfile.TemporaryDirectory() as root:
        changes, session, _old = setup_session(root)
        scratch = os.path.join(root, "volatile-work-parent")
        os.mkdir(scratch)
        saver = saver_for(changes)
        saver._ram_work_parent = lambda: scratch
        saver._run_savechanges = fake_capture(expected_work_parent=scratch)
        result = saver.save("1")
        assert result["generation"] == 8
        with open(os.path.join(session, "changes.sb"), "rb") as stream:
            assert stream.read() == b"hsqs-new-snapshot"


def case_reset_metadata():
    for reset_boot_id in ("boot-test", "previous-boot"):
        with tempfile.TemporaryDirectory() as root:
            changes, _session, _old = setup_session(root)
            with open(os.path.join(changes, "session.conf"), "a") as stream:
                stream.write("session_version[1]=old\nsession_edition[1]=old\n")
                stream.write("session_reset_boot_id[1]={}\n".format(reset_boot_id))
                stream.write("session_reset_version[1]=new\nsession_reset_edition[1]=new\n")
            saver_for(changes).save("1")
            record = read_json(changes)["sessions"]["1"]
            expected = "new" if reset_boot_id == "boot-test" else "old"
            assert record["version"] == expected
            assert record["edition"] == expected
            assert not any(key.startswith("reset_") for key in record)


def case_ram_mount_covering():
    path = "/run/initramfs/memory"
    livekit = "24 1 0:24 / /run rw - tmpfs tmpfs rw\n"
    dracut = livekit + "25 24 0:25 / /run/initramfs/memory rw - tmpfs tmpfs rw\n"
    unsafe = livekit + "25 24 8:1 / /run/initramfs/memory rw - ext4 /dev/sda rw\n"
    assert SquashfsSessionSaver._tmpfs_covers(path, io.StringIO(livekit))
    assert SquashfsSessionSaver._tmpfs_covers(path, io.StringIO(dracut))
    assert not SquashfsSessionSaver._tmpfs_covers(path, io.StringIO(unsafe))


def case_ram_space_fallback():
    with tempfile.TemporaryDirectory() as root:
        changes, session, _old = setup_session(root)
        scratch = os.path.join(root, "volatile-work-parent")
        os.mkdir(scratch)
        saver = saver_for(changes)
        saver._ram_work_parent = lambda: scratch
        disk_capture = fake_capture()
        attempts = []
        def capture(output_path, work_parent, progress_callback=None):
            attempts.append(work_parent)
            if work_parent == scratch:
                raise SquashfsSaveError(
                    "savechanges failed: insufficient private temporary space")
            return disk_capture(output_path, work_parent, progress_callback)
        saver._run_savechanges = capture
        result = saver.save("1")
        assert attempts == [scratch, session]
        assert result["generation"] == 8


def case_ram_failure_is_not_retried():
    with tempfile.TemporaryDirectory() as root:
        changes, session, previous = setup_session(root)
        scratch = os.path.join(root, "volatile-work-parent")
        os.mkdir(scratch)
        saver = saver_for(changes)
        saver._ram_work_parent = lambda: scratch
        attempts = []
        def capture(output_path, work_parent, progress_callback=None):
            attempts.append(work_parent)
            # An error after a candidate output exists must never retry over it.
            with open(output_path, "wb") as stream:
                stream.write(b"partial")
            raise SquashfsSaveError("insufficient private temporary space")
        saver._run_savechanges = capture
        try:
            saver.save("1")
        except SquashfsSaveError:
            pass
        else:
            raise AssertionError("accepted partial RAM output")
        assert attempts == [scratch]
        with open(os.path.join(session, "changes.sb"), "rb") as stream:
            assert stream.read() == previous
        assert not any(name.startswith(".changes.sb.new-") for name in os.listdir(session))


def case_finalize():
    with tempfile.TemporaryDirectory() as root:
        changes, _session, _old = setup_session(root)
        saver = saver_for(changes)
        result = saver.save("1", finalize_shutdown=True)
        assert result["shutdown_finalized"] is True
        metadata = read_json(changes)
        assert "running" not in metadata
        assert metadata["sessions"]["1"]["state"] == "clean"
        assert metadata["sessions"]["1"]["generation"] == "8"

def case_manual_shutdown_rejected():
    with tempfile.TemporaryDirectory() as root:
        changes, session, old = setup_session(root, policy="manual")
        saver = saver_for(changes)
        try:
            saver.save("1", finalize_shutdown=True)
        except SquashfsSaveError as error:
            assert "not configured for shutdown saving" in str(error)
        else:
            raise AssertionError("manual policy unexpectedly saved at shutdown")
        with open(os.path.join(session, "changes.sb"), "rb") as stream:
            assert stream.read() == old


def case_identity_mismatch():
    with tempfile.TemporaryDirectory() as root:
        changes, session, old = setup_session(root)
        saver = saver_for(changes)
        def corrupt(result, _output_path):
            result["output_identity"]["inode"] += 1
        saver._run_savechanges = fake_capture(mutate=corrupt)
        try:
            saver.save("1")
        except SquashfsSaveError:
            pass
        else:
            raise AssertionError("identity mismatch was accepted")
        with open(os.path.join(session, "changes.sb"), "rb") as stream:
            assert stream.read() == old
        assert not any(name.startswith(".changes.sb.new-") for name in os.listdir(session))

def case_generation_changed():
    with tempfile.TemporaryDirectory() as root:
        changes, session, _old = setup_session(root)
        saver = saver_for(changes)
        capture = fake_capture()
        current_path = os.path.join(session, "changes.sb")
        def replace_current(output_path, work_parent, progress_callback=None):
            result = capture(output_path, work_parent, progress_callback)
            replacement = current_path + ".replacement"
            with open(replacement, "wb") as stream:
                stream.write(b"hsqs-replacement")
            os.replace(replacement, current_path)
            return result
        saver._run_savechanges = replace_current
        try:
            saver.save("1")
        except SquashfsSaveError as error:
            assert "changed during capture" in str(error)
        else:
            raise AssertionError("generation replacement was accepted")
        with open(current_path, "rb") as stream:
            assert stream.read() == b"hsqs-replacement"


def case_metadata_failure():
    with tempfile.TemporaryDirectory() as root:
        changes, session, _old = setup_session(root)
        saver = saver_for(changes)
        saver._write_metadata = lambda _metadata: (_ for _ in ()).throw(OSError("metadata failed"))
        try:
            saver.save("1")
        except SquashfsSaveError as error:
            assert "published" in str(error) and "metadata" in str(error)
        else:
            raise AssertionError("metadata failure was accepted")
        with open(os.path.join(session, "changes.sb"), "rb") as stream:
            assert stream.read() == b"hsqs-new-snapshot"


def case_runtime_state_dynblk_field():
    with tempfile.TemporaryDirectory() as root:
        changes, _session, _old = setup_session(root)
        boot_state = os.path.join(root, "boot-state")
        boot_id = os.path.join(root, "boot-id")
        selected = os.stat(changes)
        boot_identity = "01234567-89ab-cdef-0123-456789abcdef"
        with open(boot_id, "w", encoding="ascii") as stream:
            stream.write(boot_identity + "\n")
        state = (
            "boot_id={}\nboot_level=ok\nmode=squashfs\nsession=1\n"
            "durable=1\nwritable=1\nsessions_device={}\nsessions_inode={}\n"
            "active_generation=current\ndynblk_device=none\n"
            "encryption=none\ncrypt_mapper=none\nloop_device=none\n".format(
                boot_identity, selected.st_dev, selected.st_ino))
        with open(boot_state, "w", encoding="utf-8") as stream:
            stream.write(state)
        os.chmod(boot_state, 0o600)
        saver = SquashfsSessionSaver(
            sessions_dir=changes, boot_state_file=boot_state, boot_id_file=boot_id)
        saver._detect_filesystem = lambda: "ext4"
        old_paths = squashfs_backend.SESSION_PATHS
        squashfs_backend.SESSION_PATHS = (changes,)
        try:
            assert saver._validate_runtime("1")["dynblk_device"] == "none"
            with open(boot_state, "w", encoding="utf-8") as stream:
                stream.write(state.replace("dynblk_device=none", "dynblk_device=/dev/dynblk0"))
            try:
                saver._validate_runtime("1")
            except SquashfsSaveError as error:
                assert "not active in this boot" in str(error)
            else:
                raise AssertionError("SquashFS accepted a dynblk device in runtime state")
            with open(boot_state, "w", encoding="utf-8") as stream:
                stream.write(state.replace("encryption=none", "encryption=luks"))
            try:
                saver._validate_runtime("1")
            except SquashfsSaveError as error:
                assert "not active in this boot" in str(error)
            else:
                raise AssertionError("SquashFS accepted encrypted runtime state")
        finally:
            squashfs_backend.SESSION_PATHS = old_paths


CASES = {
    "save": case_save,
    "reset-metadata": case_reset_metadata,
    "ram-workspace": case_ram_workspace,
    "ram-mount-covering": case_ram_mount_covering,
    "ram-space-fallback": case_ram_space_fallback,
    "ram-no-retry-after-output": case_ram_failure_is_not_retried,
    "finalize": case_finalize,
    "manual-shutdown": case_manual_shutdown_rejected,
    "identity": case_identity_mismatch,
    "generation": case_generation_changed,
    "metadata": case_metadata_failure,
    "runtime-state-dynblk-field": case_runtime_state_dynblk_field,
}


if __name__ == "__main__":
    CASES[sys.argv[1]]()
