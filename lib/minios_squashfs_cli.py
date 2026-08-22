#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Save the running MiniOS SquashFS session."""
from __future__ import print_function

import argparse
import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, SCRIPT_DIR)

from minios_squashfs_session import SquashfsSaveError, SquashfsSessionSaver


def emit(value):
    print(json.dumps(value, ensure_ascii=True, allow_nan=False,
                     sort_keys=True, separators=(",", ":")), flush=True)


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="minios-squashfs-save",
        description="Save the running MiniOS SquashFS session")
    parser.add_argument("session_id")
    parser.add_argument("--json", action="store_true", dest="json_output")
    parser.add_argument("--progress", action="store_true")
    parser.add_argument("--shutdown-finalize", action="store_true")
    args = parser.parse_args(argv)
    if os.geteuid() != 0:
        message = "This command requires root privileges"
        if args.json_output:
            emit({"success": False, "message": message})
        else:
            print(message, file=sys.stderr)
        return 1
    if args.progress and not args.json_output:
        print("--progress requires --json", file=sys.stderr)
        return 2

    def progress(phase):
        if args.progress:
            emit({"type": "phase", "phase": phase})

    try:
        capture = SquashfsSessionSaver().save(
            args.session_id,
            finalize_shutdown=args.shutdown_finalize,
            progress_callback=progress if args.progress else None)
        message = "Session {} saved successfully".format(args.session_id)
        if args.json_output:
            emit({"success": True, "message": message, "capture": capture})
        else:
            print(message)
        return 0
    except SquashfsSaveError as error:
        message = str(error)
        if args.json_output:
            emit({"success": False, "message": message})
        else:
            print(message, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
