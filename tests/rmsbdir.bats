#!/usr/bin/env bats

setup() {
    RMSBDIR="$BATS_TEST_DIRNAME/../bin/rmsbdir"
    SB="$BATS_TEST_DIRNAME/../bin/sb"
    SYSTEM_PATH=$PATH
    TEST_ROOT="${MINIOS_TOOLS_TEST_TMPDIR:-${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-${TMPDIR:-/tmp}}}}/rmsbdir job $BATS_TEST_NUMBER"
    TARGET="$TEST_ROOT/unpacked module.sb"
    TOOLS="$TEST_ROOT/tools"
    DESTRUCTIVE_MARKER="$TEST_ROOT/destructive-command-ran"
    mkdir -p "$TARGET" "$TOOLS"
    printf 'keep\n' >"$TARGET/must-survive"

    # Keep variables literal for expansion when each generated stub runs.
    # shellcheck disable=SC2016
    printf '#!/bin/sh\n: >"$DESTRUCTIVE_MARKER"\nexit 99\n' >"$TOOLS/umount"
    # shellcheck disable=SC2016
    printf '#!/bin/sh\n: >"$DESTRUCTIVE_MARKER"\nexit 99\n' >"$TOOLS/rm"
    # A compatibility alias must not dispatch through an attacker-controlled PATH.
    # shellcheck disable=SC2016
    printf '#!/bin/sh\n: >"$DESTRUCTIVE_MARKER"\nexit 99\n' >"$TOOLS/rmsbdir"
    for command in id gettext basename readlink dirname; do
        # shellcheck disable=SC2016
        printf '#!/bin/sh\n: >"$DESTRUCTIVE_MARKER"\nexit 99\n' >"$TOOLS/$command"
    done
    chmod 0755 "$TOOLS/umount" "$TOOLS/rm" "$TOOLS/rmsbdir" \
        "$TOOLS/id" "$TOOLS/gettext" "$TOOLS/basename" "$TOOLS/readlink" \
        "$TOOLS/dirname"
    ln -s "$SB" "$TOOLS/sb-link"
}

run_rmsbdir() {
    run env PATH="$TOOLS:$SYSTEM_PATH" DESTRUCTIVE_MARKER="$DESTRUCTIVE_MARKER" \
        "$RMSBDIR" "$@"
}

run_sb() {
    run env PATH="$TOOLS:$BATS_TEST_DIRNAME/../bin:$SYSTEM_PATH" \
        DESTRUCTIVE_MARKER="$DESTRUCTIVE_MARKER" "$SB" "$@"
}

assert_refused_without_changes() {
    [ "$status" -eq 1 ]
    [[ $output == *"no longer removes unpacked module directories"* ]]
    [ -f "$TARGET/must-survive" ]
    [ ! -e "$DESTRUCTIVE_MARKER" ]
}

@test "rmsbdir refuses removal without invoking umount or rm" {
    run_rmsbdir "$TARGET"
    assert_refused_without_changes
}

@test "rmsbdir supports an option terminator for path arguments" {
    run_rmsbdir -- "$TARGET"
    assert_refused_without_changes
}

@test "sb rm refuses removal without root or live configuration" {
    run_sb rm "$TARGET"
    assert_refused_without_changes
    [[ $output != *"config.conf"* ]]
}

@test "sb rmdir refuses removal without root or live configuration" {
    run_sb rmdir "$TARGET"
    assert_refused_without_changes
    [[ $output != *"config.conf"* ]]
}

@test "sb aliases refuse before hostile PATH and symlink resolution" {
    run env PATH="$TOOLS:$SYSTEM_PATH" DESTRUCTIVE_MARKER="$DESTRUCTIVE_MARKER" \
        "$TOOLS/sb-link" rm "$TARGET"
    assert_refused_without_changes
}

@test "help and version remain non-destructive queries" {
    run_rmsbdir --help
    [ "$status" -eq 0 ]
    [[ $output == *"Usage:"* ]]

    run_rmsbdir --version
    [ "$status" -eq 0 ]
    [[ $output == "rmsbdir 1.1.0" ]]
    [ -f "$TARGET/must-survive" ]
    [ ! -e "$DESTRUCTIVE_MARKER" ]
}
