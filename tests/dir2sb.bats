#!/usr/bin/env bats

setup() {
    DIR2SB="$BATS_TEST_DIRNAME/../bin/dir2sb"
    SB2DIR="$BATS_TEST_DIRNAME/../bin/sb2dir"
    STUBS="$BATS_TEST_DIRNAME/stubs"
    SYSTEM_PATH=$PATH
    TEST_ROOT="${MINIOS_TOOLS_TEST_TMPDIR:-${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-${TMPDIR:-/tmp}}}}/dir2sb job $BATS_TEST_NUMBER"
    SRC="$TEST_ROOT/source tree"
    OUT="$TEST_ROOT/output dir"
    STATE="$TEST_ROOT/state"
    TOOLS="$TEST_ROOT/tools"
    mkdir -p "$SRC" "$OUT" "$TOOLS"
    chmod 0700 "$TEST_ROOT" "$OUT"
    cp -- "$STUBS/mksquashfs" "$TOOLS/mksquashfs"
    cp -- "$STUBS/unsquashfs" "$TOOLS/unsquashfs"
    chmod 0755 "$TOOLS/mksquashfs" "$TOOLS/unsquashfs"
}

write_file() {
    local path=$1
    shift
    mkdir -p "${path%/*}"
    printf '%s\n' "$*" >"$path"
}

require_real_tools() {
    command -v mksquashfs >/dev/null 2>&1 || skip 'mksquashfs is not installed'
    command -v unsquashfs >/dev/null 2>&1 || skip 'unsquashfs is not installed'
}

run_stub() {
    run env PATH="$TOOLS:$SYSTEM_PATH" NO_COLOR=1 MKSQUASHFS_STATE="$STATE" \
        "$DIR2SB" "$@"
}

run_real() {
    run env PATH="$SYSTEM_PATH" NO_COLOR=1 "$DIR2SB" "$@"
}

# --- argument and validation surface -------------------------------------

@test "missing operands print usage and fail" {
    run_stub "$SRC"
    [ "$status" -eq 1 ]
    [[ $output == *Usage:* ]]
}

@test "unknown option is rejected" {
    run_stub --bogus "$SRC" "$OUT/x.sb"
    [ "$status" -eq 1 ]
    [[ $output == *"Unknown option"* ]]
}

@test "invalid compression type is rejected before any work" {
    run_stub --comp bogus "$SRC" "$OUT/x.sb"
    [ "$status" -eq 1 ]
    [[ $output == *"Invalid compression"* ]]
    [ ! -e "$OUT/x.sb" ]
}

@test "version prints the program name and version" {
    run_stub --version
    [ "$status" -eq 0 ]
    [[ $output == "dir2sb "* ]]
}

@test "privileged flags require root" {
    (( EUID == 0 )) && skip 'requires an unprivileged user'
    run_stub --keep-ownership "$SRC" "$OUT/x.sb"
    [ "$status" -eq 1 ]
    [[ $output == *"requires root"* ]]
}

# --- non-destructive contract --------------------------------------------

@test "an existing target is never overwritten" {
    write_file "$SRC/file.txt" data
    printf 'original\n' >"$OUT/exists.sb"
    run_stub "$SRC" "$OUT/exists.sb"
    [ "$status" -eq 4 ]
    [ "$(cat "$OUT/exists.sb")" = original ]
}

@test "a missing source directory is reported" {
    run_stub "$TEST_ROOT/absent" "$OUT/x.sb"
    [ "$status" -eq 2 ]
    [[ $output == *"not a directory"* ]]
}

@test "the source tree is left unchanged" {
    write_file "$SRC/keep.txt" keep
    local before
    before=$(find "$SRC" | sort)
    run_stub "$SRC" "$OUT/module.sb"
    [ "$status" -eq 0 ]
    [ "$before" = "$(find "$SRC" | sort)" ]
}

@test "source path replacement cannot redirect the compressor" {
    write_file "$SRC/keep.txt" original
    run env PATH="$TOOLS:$SYSTEM_PATH" NO_COLOR=1 MKSQUASHFS_STATE="$STATE" \
        MKSQUASHFS_REPLACE_SOURCE="$SRC" \
        "$DIR2SB" "$SRC" "$OUT/module.sb"
    [ "$status" -eq 0 ]
    [ "$(cat "$STATE/tree/keep.txt")" = original ]
    [ ! -e "$STATE/tree/not-source.txt" ]
}

# --- list-argv and root-tree semantics -----------------------------------

@test "the mksquashfs invocation is list-based and normalizes ownership" {
    write_file "$SRC/weird name.txt" spaced
    run_stub "$SRC" "$OUT/space out.sb"
    [ "$status" -eq 0 ]
    [ -e "$OUT/space out.sb" ]
    mapfile -d '' -t args <"$STATE/args"
    local joined="${args[*]}"
    [[ $joined == *-noappend* ]]
    [[ $joined == *-all-root* ]]
    [[ $joined == *zstd* ]]
    # The resolved source and the reserved staging file are passed positionally.
    [[ ${args[0]} == . ]]
    [[ ${args[1]} == *"/.dir2sb."* ]]
}

@test "keep-ownership omits the all-root normalization" {
    (( EUID == 0 )) || skip 'requires root to preserve ownership'
    write_file "$SRC/file.txt" data
    run_stub --keep-ownership "$SRC" "$OUT/owned.sb"
    [ "$status" -eq 0 ]
    mapfile -d '' -t args <"$STATE/args"
    [[ ${args[*]} != *-all-root* ]]
}

# --- machine-readable result and phases ----------------------------------

@test "json mode emits ordered phases and an identity/digest result" {
    write_file "$SRC/file.txt" data
    run_stub --json "$SRC" "$OUT/module.sb"
    [ "$status" -eq 0 ]
    [[ $output == *'"phase":"prepare"'* ]]
    [[ $output == *'"phase":"compress"'* ]]
    [[ $output == *'"phase":"verify"'* ]]
    [[ $output == *'"phase":"publish"'* ]]
    [[ $output == *'"phase":"complete"'* ]]
    [[ $output == *'"product": "dir2sb"'* ]]
    [[ $output == *'"sha256":'* ]]
    [[ $output == *'"inode":'* ]]
}

@test "json mode emits only JSON objects" {
    write_file "$SRC/file.txt" data
    run_stub --json "$SRC" "$OUT/module.sb"
    [ "$status" -eq 0 ]
    while IFS= read -r line; do
        env LINE="$line" python3 -c 'import json, os; assert isinstance(json.loads(os.environ["LINE"]), dict)'
    done <<<"$output"
}

# --- failure and cancellation --------------------------------------------

@test "a failing mksquashfs leaves no output or staging file" {
    write_file "$SRC/file.txt" data
    run env PATH="$TOOLS:$SYSTEM_PATH" NO_COLOR=1 MKSQUASHFS_FAIL=true \
        "$DIR2SB" "$SRC" "$OUT/module.sb"
    [ "$status" -eq 5 ]
    [ ! -e "$OUT/module.sb" ]
    run find "$OUT" -name '.dir2sb.*'
    [ -z "$output" ]
}

@test "an invalid staged module is never published" {
    write_file "$SRC/file.txt" data
    run env PATH="$TOOLS:$SYSTEM_PATH" NO_COLOR=1 \
        MKSQUASHFS_INVALID_OUTPUT=true \
        "$DIR2SB" "$SRC" "$OUT/module.sb"
    [ "$status" -eq 5 ]
    [ ! -e "$OUT/module.sb" ]
    run find "$OUT" -name '.dir2sb.*'
    [ -z "$output" ]
}

@test "post-build verification rejects newly introduced special files" {
    write_file "$SRC/file.txt" data
    run env PATH="$TOOLS:$SYSTEM_PATH" NO_COLOR=1 \
        MKSQUASHFS_INJECT_SPECIAL=true \
        "$DIR2SB" "$SRC" "$OUT/module.sb"
    [ "$status" -eq 5 ]
    [[ $output == *"special files"* ]]
    [ ! -e "$OUT/module.sb" ]
    run find "$OUT" -name '.dir2sb.*'
    [ -z "$output" ]
}

@test "post-build verification fails closed when its log cannot be created" {
    write_file "$SRC/file.txt" data
    cat >"$TOOLS/mktemp" <<'SH'
#!/bin/sh
case "$*" in
*.dir2sb-verify.*) exit 1 ;;
esac
exec /usr/bin/mktemp "$@"
SH
    chmod 0755 "$TOOLS/mktemp"

    run env PATH="$TOOLS:$SYSTEM_PATH" NO_COLOR=1 \
        "$DIR2SB" "$SRC" "$OUT/module.sb"
    [ "$status" -eq 5 ]
    [[ $output == *"temporary verification log"* ]]
    [ ! -e "$OUT/module.sb" ]
}

@test "a leader-exit compressor group is terminated before publication" {
    write_file "$SRC/file.txt" data
    local marker="$TEST_ROOT/leader-marker"
    run env PATH="$TOOLS:$SYSTEM_PATH" NO_COLOR=1 \
        MKSQUASHFS_SLEEP=true MKSQUASHFS_LEADER_EXIT=true \
        MKSQUASHFS_SLEEP_MARKER="$marker" \
        "$DIR2SB" "$SRC" "$OUT/module.sb"
    [ "$status" -eq 5 ]
    local descendant
    descendant=$(sed -n '2p' "$marker")
    for _ in {1..100}; do kill -0 "$descendant" 2>/dev/null || break; sleep 0.05; done
    ! kill -0 "$descendant" 2>/dev/null
    [ ! -e "$OUT/module.sb" ]
}

@test "SIGTERM cancels the conversion, cleans up, and reaps the tool" {
    write_file "$SRC/file.txt" data
    local marker="$TEST_ROOT/marker"
    env PATH="$TOOLS:$SYSTEM_PATH" NO_COLOR=1 \
        MKSQUASHFS_SLEEP=true MKSQUASHFS_SLEEP_MARKER="$marker" \
        "$DIR2SB" "$SRC" "$OUT/module.sb" &
    local pid=$!
    for _ in {1..100}; do [ -s "$marker" ] && break; sleep 0.05; done
    local child
    child=$(head -n1 "$marker")
    kill -TERM "$pid"
    local status=0
    wait "$pid" || status=$?
    [ "$status" -eq 130 ]
    for _ in {1..100}; do kill -0 "$child" 2>/dev/null || break; sleep 0.05; done
    ! kill -0 "$child" 2>/dev/null
    [ ! -e "$OUT/module.sb" ]
    run find "$OUT" -name '.dir2sb.*'
    [ -z "$output" ]
}

# --- special-object rejection --------------------------------------------

@test "device nodes, sockets, and FIFOs are rejected rootlessly" {
    write_file "$SRC/file.txt" data
    mkfifo "$SRC/pipe" 2>/dev/null || skip 'the test filesystem disallows FIFOs'
    run_stub "$SRC" "$OUT/module.sb"
    [ "$status" -eq 3 ]
    [ ! -e "$OUT/module.sb" ]
}

# --- real-tool round-trip conformance ------------------------------------

@test "real tools round-trip files, modes, links, and empty directories" {
    require_real_tools
    write_file "$SRC/top.txt" top
    write_file "$SRC/nested/deep.txt" deep
    chmod 0640 "$SRC/top.txt"
    ln -s top.txt "$SRC/link"
    mkdir -p "$SRC/empty"
    run_real --json "$SRC" "$OUT/module.sb"
    [ "$status" -eq 0 ]
    run env PATH="$SYSTEM_PATH" NO_COLOR=1 "$SB2DIR" "$OUT/module.sb" "$OUT/restored"
    [ "$status" -eq 0 ]
    run diff -r "$SRC" "$OUT/restored"
    [ "$status" -eq 0 ]
    [ "$(stat -c '%a' "$OUT/restored/top.txt")" = 640 ]
    [ -L "$OUT/restored/link" ]
    [ -d "$OUT/restored/empty" ]
}

@test "real tools place the source contents at the module root" {
    require_real_tools
    write_file "$SRC/marker.txt" marker
    run_real "$SRC" "$OUT/module.sb"
    [ "$status" -eq 0 ]
    run env PATH="$SYSTEM_PATH" unsquashfs -ll "$OUT/module.sb"
    [ "$status" -eq 0 ]
    # No accidental extra top-level directory named after the source.
    [[ $output == *"/marker.txt"* ]]
    [[ $output != *"/source tree/"* ]]
}

@test "real round-trip preserves user extended attributes" {
    require_real_tools
    command -v setfattr >/dev/null 2>&1 || skip 'setfattr is unavailable'
    write_file "$SRC/file.txt" data
    setfattr -n user.demo -v value "$SRC/file.txt" 2>/dev/null ||
        skip 'the test filesystem disallows user xattrs'
    run_real "$SRC" "$OUT/module.sb"
    [ "$status" -eq 0 ]
    run env PATH="$SYSTEM_PATH" NO_COLOR=1 "$SB2DIR" "$OUT/module.sb" "$OUT/restored"
    [ "$status" -eq 0 ]
    run getfattr --absolute-names -n user.demo --only-values "$OUT/restored/file.txt"
    [ "$status" -eq 0 ]
    [ "$output" = value ]
}
