#!/usr/bin/env python3
"""Machine-readable protocol helpers for MiniOS Tools shell frontends."""
from __future__ import print_function

import decimal
import json
import os
import re
import sys


class ProtocolError(Exception):
    pass


def emit(value):
    print(json.dumps(
        value, ensure_ascii=True, allow_nan=False, sort_keys=True,
        separators=(",", ":")))


def result(tool, operation, **fields):
    value = {
        "type": "result",
        "product_kind": "minios-tool-result",
        "schema_version": 1,
        "tool": tool,
        "operation": operation,
    }
    value.update(fields)
    emit(value)
def read_records(width):
    fields = sys.stdin.buffer.read().split(b"\0")
    if fields and fields[-1] == b"":
        fields.pop()
    if len(fields) % width:
        raise ProtocolError("invalid record stream")
    return [fields[index:index + width]
            for index in range(0, len(fields), width)]


def numeric_prefix(name):
    match = re.match(
        r"^[ \t]*([+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+))", name)
    if not match:
        return decimal.Decimal(0)
    return decimal.Decimal(match.group(1))


def command_phase(arguments):
    if len(arguments) != 1:
        raise ProtocolError("phase requires NAME")
    emit({"event": "phase", "phase": arguments[0]})


def command_sb_list(arguments):
    if len(arguments) != 1:
        raise ProtocolError("sb-list requires UNION")
    modules = []
    for mount_raw, source_raw in read_records(2):
        mount = os.fsdecode(mount_raw)
        source = os.fsdecode(source_raw) if source_raw else None
        modules.append({
            "name": os.path.basename(mount),
            "mount": mount,
            "source": source,
        })
    result("sb", "list", union_backend=arguments[0], modules=modules)
def command_sb_next_boot(arguments):
    if len(arguments) != 4:
        raise ProtocolError(
            "sb-next-boot requires MODE DATA_ROOT EXTENSION ADD_AVAILABLE")
    mode, data_root, extension, add_available = arguments
    if mode not in ("text", "json") or add_available not in ("0", "1"):
        raise ProtocolError("invalid sb-next-boot arguments")
    chosen = {}
    for source_raw, origin_raw, removable_raw in read_records(3):
        source = os.fsdecode(source_raw)
        origin = os.fsdecode(origin_raw)
        if origin not in ("base", "modules", "persistence"):
            raise ProtocolError("invalid module origin")
        if removable_raw not in (b"0", b"1"):
            raise ProtocolError("invalid removable flag")
        name = os.path.basename(source)
        chosen[name] = {
            "name": name,
            "source": source,
            "origin": origin,
            "removable": removable_raw == b"1",
        }
    modules = sorted(
        chosen.values(), key=lambda item: (numeric_prefix(item["name"]), item["name"]))
    if mode == "text":
        for item in modules:
            print("{}\t{}\t{}".format(
                item["name"], item["origin"], item["source"]))
        return
    result("sb", "next-boot", data_root=data_root,
           bundle_extension=extension, add_available=add_available == "1",
           modules=modules)
def command_sb_mutation(arguments):
    if len(arguments) != 3:
        raise ProtocolError("sb-mutation requires OPERATION NAME PATH")
    operation, name, path = arguments
    if operation not in ("next-boot-add", "next-boot-remove"):
        raise ProtocolError("invalid sb mutation operation")
    result("sb", operation, name=name, path=path)


def command_sb_inspect(arguments):
    if len(arguments) != 5:
        raise ProtocolError(
            "sb-inspect requires MODE MODULE_PATH SIZE PREFIX LISTING")
    mode, module_path, size_text, prefix, listing_path = arguments
    if mode not in ("text", "json"):
        raise ProtocolError("invalid sb-inspect mode")
    try:
        size = int(size_text)
    except ValueError:
        raise ProtocolError("invalid module size")
    prefix_raw = os.fsencode(prefix)
    marker = prefix_raw + b"/"
    entries = []
    root_seen = False
    with open(listing_path, "rb") as stream:
        for line in stream.read().splitlines():
            if not root_seen:
                if line == prefix_raw:
                    root_seen = True
                    continue
                if (not line or re.match(br"^Parallel unsquashfs: Using [0-9]+ processors$", line) or
                        re.match(br"^[0-9]+ inodes? \([0-9]+ blocks?\) to write$", line)):
                    continue
                raise ProtocolError("ambiguous unsquashfs listing")
            if not line.startswith(marker):
                raise ProtocolError("ambiguous unsquashfs listing")
            relative = os.fsdecode(line[len(marker):])
            if not relative:
                raise ProtocolError("empty module entry")
            entries.append(relative)
    if not root_seen:
        raise ProtocolError("module root missing from unsquashfs listing")
    if mode == "text":
        for entry in entries:
            print(entry)
        return
    result("sb", "inspect", path=module_path, size=size,
           entry_count=len(entries), entries=entries)


def read_capture_result(ndjson_path):
    capture = None
    with open(ndjson_path, "r", encoding="utf-8") as stream:
        for line in stream:
            line = line.strip()
            if not line:
                continue
            try:
                value = json.loads(line)
            except ValueError:
                raise ProtocolError("savechanges emitted invalid JSON")
            if (isinstance(value, dict) and value.get("type") == "result" and
                    value.get("product_kind") == "minios-tool-result" and
                    value.get("schema_version") == 1 and
                    value.get("tool") == "savechanges" and
                    value.get("operation") == "capture-module"):
                capture = value
    if capture is None:
        raise ProtocolError("savechanges result is missing")
    required = ("output", "compressed_size", "uncompressed_size",
                "entry_count", "sha256")
    if any(key not in capture for key in required):
        raise ProtocolError("savechanges result is incomplete")
    return capture


def capture_fields(capture):
    return {
        "output": capture["output"],
        "compressed_size": capture["compressed_size"],
        "uncompressed_size": capture["uncompressed_size"],
        "entry_count": capture["entry_count"],
        "sha256": capture["sha256"],
    }


def command_apt2sb_result(arguments):
    if len(arguments) != 4:
        raise ProtocolError(
            "apt2sb-result requires OPERATION COMPRESSION PACKAGE_COUNT SAVECHANGES_NDJSON")
    operation, compression, package_count_text, ndjson_path = arguments
    if operation not in ("install", "upgrade"):
        raise ProtocolError("invalid apt2sb operation")
    try:
        package_count = int(package_count_text)
    except ValueError:
        raise ProtocolError("invalid package count")
    fields = capture_fields(read_capture_result(ndjson_path))
    fields.update(compression=compression, package_count=package_count)
    result("apt2sb", operation, **fields)


def command_script2sb_result(arguments):
    if len(arguments) != 3:
        raise ProtocolError(
            "script2sb-result requires COMPRESSION HAS_SEED SAVECHANGES_NDJSON")
    compression, has_seed, ndjson_path = arguments
    if has_seed not in ("0", "1"):
        raise ProtocolError("invalid script2sb seed flag")
    fields = capture_fields(read_capture_result(ndjson_path))
    fields.update(compression=compression, seed_directory=has_seed == "1")
    result("script2sb", "create", **fields)


def command_chroot2sb_prepare(arguments):
    if len(arguments) != 4:
        raise ProtocolError(
            "chroot2sb-prepare requires SESSION OUTPUT COMPRESSION HAS_SEED")
    session_id, output, compression, has_seed = arguments
    if not session_id or not output or has_seed not in ("0", "1"):
        raise ProtocolError("invalid chroot2sb prepare result")
    result("chroot2sb", "prepare", session_id=session_id, output=output,
           compression=compression, seed_directory=has_seed == "1")


def command_chroot2sb_result(arguments):
    if len(arguments) != 3:
        raise ProtocolError(
            "chroot2sb-result requires COMPRESSION HAS_SEED SAVECHANGES_NDJSON")
    compression, has_seed, ndjson_path = arguments
    if has_seed not in ("0", "1"):
        raise ProtocolError("invalid chroot2sb seed flag")
    fields = capture_fields(read_capture_result(ndjson_path))
    fields.update(compression=compression, seed_directory=has_seed == "1")
    result("chroot2sb", "finish", **fields)


def command_chroot2sb_cancel(arguments):
    if len(arguments) != 1 or not arguments[0]:
        raise ProtocolError("chroot2sb-cancel requires SESSION")
    result("chroot2sb", "cancel", session_id=arguments[0])


COMMANDS = {
    "phase": command_phase,
    "sb-list": command_sb_list,
    "sb-next-boot": command_sb_next_boot,
    "sb-mutation": command_sb_mutation,
    "sb-inspect": command_sb_inspect,
    "apt2sb-result": command_apt2sb_result,
    "script2sb-result": command_script2sb_result,
    "chroot2sb-prepare": command_chroot2sb_prepare,
    "chroot2sb-result": command_chroot2sb_result,
    "chroot2sb-cancel": command_chroot2sb_cancel,
}


def main(argv):
    if len(argv) < 2 or argv[1] not in COMMANDS:
        sys.stderr.write("unknown protocol command\n")
        return 2
    try:
        COMMANDS[argv[1]](argv[2:])
    except (ProtocolError, OSError) as error:
        sys.stderr.write(str(error) + "\n")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
