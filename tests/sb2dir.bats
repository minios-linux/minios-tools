#!/usr/bin/env bats

setup() {
    DIR2SB="$BATS_TEST_DIRNAME/../bin/dir2sb"
    SB2DIR="$BATS_TEST_DIRNAME/../bin/sb2dir"
    STUBS="$BATS_TEST_DIRNAME/stubs"
    SYSTEM_PATH=$PATH
    TEST_ROOT="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-${TMPDIR:-/tmp}}}/sb2dir job $BATS_TEST_NUMBER"
    OUT="$TEST_ROOT/output dir"
    TOOLS="$TEST_ROOT/tools"
    mkdir -p "$OUT" "$TOOLS"
    cp -- "$STUBS/mksquashfs" "$TOOLS/mksquashfs"
    cp -- "$STUBS/unsquashfs" "$TOOLS/unsquashfs"
    chmod 0755 "$TOOLS/mksquashfs" "$TOOLS/unsquashfs"
}

require_real_tools() {
    command -v mksquashfs >/dev/null 2>&1 || skip 'mksquashfs is not installed'
    command -v unsquashfs >/dev/null 2>&1 || skip 'unsquashfs is not installed'
}

make_stub_module() {
    local module=$1
    mkdir -p "${module%/*}"
    printf 'stub SquashFS module\n' >"$module"
    local tree="$module.stub-tree"
    mkdir -p "$tree/nested"
    printf 'top\n' >"$tree/top.txt"
    printf 'deep\n' >"$tree/nested/deep.txt"
}

run_stub() {
    run env PATH="$TOOLS:$SYSTEM_PATH" NO_COLOR=1 "$SB2DIR" "$@"
}

run_real() {
    run env PATH="$SYSTEM_PATH" NO_COLOR=1 "$SB2DIR" "$@"
}

# --- argument and validation surface -------------------------------------

@test "missing operands print usage and fail" {
    run_stub "$TEST_ROOT/module.sb"
    [ "$status" -eq 1 ]
    [[ $output == *Usage:* ]]
}

@test "unknown option is rejected" {
    run_stub --bogus "$TEST_ROOT/module.sb" "$OUT/tree"
    [ "$status" -eq 1 ]
    [[ $output == *"Unknown option"* ]]
}

@test "version prints the program name and version" {
    run_stub --version
    [ "$status" -eq 0 ]
    [[ $output == "sb2dir "* ]]
}

@test "privileged flags require root" {
    (( EUID == 0 )) && skip 'requires an unprivileged user'
    make_stub_module "$TEST_ROOT/module.sb"
    run_stub --allow-special "$TEST_ROOT/module.sb" "$OUT/tree"
    [ "$status" -eq 1 ]
    [[ $output == *"requires root"* ]]
}

@test "a missing or unreadable source module is reported" {
    run_stub "$TEST_ROOT/absent.sb" "$OUT/tree"
    [ "$status" -eq 2 ]
    [[ $output == *"not a readable file"* ]]
}

# --- non-destructive contract --------------------------------------------

@test "an existing target directory is never overwritten" {
    make_stub_module "$TEST_ROOT/module.sb"
    mkdir -p "$OUT/exists"
    printf 'keep\n' >"$OUT/exists/original.txt"
    run_stub "$TEST_ROOT/module.sb" "$OUT/exists"
    [ "$status" -eq 4 ]
    [ -f "$OUT/exists/original.txt" ]
}

@test "the source module is left unchanged" {
    make_stub_module "$TEST_ROOT/module.sb"
    local before
    before=$(sha256sum "$TEST_ROOT/module.sb" | cut -d' ' -f1)
    run_stub "$TEST_ROOT/module.sb" "$OUT/tree"
    [ "$status" -eq 0 ]
    [ "$before" = "$(sha256sum "$TEST_ROOT/module.sb" | cut -d' ' -f1)" ]
}

# --- staging, machine result, and list-argv ------------------------------

@test "extraction publishes a new directory atomically" {
    make_stub_module "$TEST_ROOT/module.sb"
    run_stub "$TEST_ROOT/module.sb" "$OUT/tree"
    [ "$status" -eq 0 ]
    [ -f "$OUT/tree/top.txt" ]
    [ -f "$OUT/tree/nested/deep.txt" ]
    run find "$OUT" -maxdepth 1 -name '.sb2dir.*'
    [ -z "$output" ]
}

@test "json mode emits ordered phases and a source digest result" {
    make_stub_module "$TEST_ROOT/module.sb"
    run_stub --json "$TEST_ROOT/module.sb" "$OUT/tree"
    [ "$status" -eq 0 ]
    [[ $output == *"P:prepare"* ]]
    [[ $output == *"P:extract"* ]]
    [[ $output == *"P:publish"* ]]
    [[ $output == *"P:complete"* ]]
    [[ $output == *'"product": "sb2dir"'* ]]
    [[ $output == *'"source_sha256":'* ]]
    [[ $output == *'"entries":'* ]]
}

@test "source and target names with spaces round-trip" {
    make_stub_module "$TEST_ROOT/weird module.sb"
    run_stub "$TEST_ROOT/weird module.sb" "$OUT/spaced tree"
    [ "$status" -eq 0 ]
    [ -f "$OUT/spaced tree/top.txt" ]
}

# --- failure and cancellation --------------------------------------------

@test "a failing unsquashfs leaves no target or staging directory" {
    make_stub_module "$TEST_ROOT/module.sb"
    run env PATH="$TOOLS:$SYSTEM_PATH" NO_COLOR=1 \
        UNSQUASHFS_FAIL_PATTERN=module.sb \
        "$SB2DIR" "$TEST_ROOT/module.sb" "$OUT/tree"
    [ "$status" -eq 5 ]
    [ ! -e "$OUT/tree" ]
    run find "$OUT" -maxdepth 1 -name '.sb2dir.*'
    [ -z "$output" ]
}

@test "SIGTERM cancels the extraction, cleans up, and reaps the tool" {
    make_stub_module "$TEST_ROOT/module.sb"
    cat >"$TOOLS/unsquashfs" <<'FAKE'
#!/bin/bash
set -u
for arg in "$@"; do
    if [[ $arg == -ll ]]; then
        printf -- '-rw-r--r-- root/root 4 date time squashfs-root/top.txt\n'
        exit 0
    fi
done
printf '%s\n' "$$" >"$SB2DIR_CANCEL_MARKER"
trap 'exit 143' TERM
trap 'exit 130' INT
while :; do sleep 1; done
FAKE
    chmod 0755 "$TOOLS/unsquashfs"
    local marker="$TEST_ROOT/marker"
    env PATH="$TOOLS:$SYSTEM_PATH" NO_COLOR=1 SB2DIR_CANCEL_MARKER="$marker" \
        "$SB2DIR" "$TEST_ROOT/module.sb" "$OUT/tree" &
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
    [ ! -e "$OUT/tree" ]
    run find "$OUT" -maxdepth 1 -name '.sb2dir.*'
    [ -z "$output" ]
}

# --- real-tool round-trip and special objects ----------------------------

@test "real tools extract a module and refuse an existing target" {
    require_real_tools
    local src="$TEST_ROOT/src"
    mkdir -p "$src/sub"
    printf 'alpha\n' >"$src/a.txt"
    printf 'beta\n' >"$src/sub/b.txt"
    run env PATH="$SYSTEM_PATH" NO_COLOR=1 "$DIR2SB" "$src" "$TEST_ROOT/module.sb"
    [ "$status" -eq 0 ]
    run_real "$TEST_ROOT/module.sb" "$OUT/tree"
    [ "$status" -eq 0 ]
    run diff -r "$src" "$OUT/tree"
    [ "$status" -eq 0 ]
    run_real "$TEST_ROOT/module.sb" "$OUT/tree"
    [ "$status" -eq 4 ]
}

@test "a module carrying special files is rejected rootlessly" {
    require_real_tools
    (( EUID == 0 )) || skip 'creating device nodes requires root'
    local src="$TEST_ROOT/src"
    mkdir -p "$src"
    printf 'data\n' >"$src/file.txt"
    mknod "$src/console" c 5 1 || skip 'the test filesystem disallows device nodes'
    run env PATH="$SYSTEM_PATH" NO_COLOR=1 "$DIR2SB" --allow-special "$src" "$TEST_ROOT/module.sb"
    [ "$status" -eq 0 ]
    run_real "$TEST_ROOT/module.sb" "$OUT/plain"
    [ "$status" -eq 3 ]
    run_real --allow-special "$TEST_ROOT/module.sb" "$OUT/special"
    [ "$status" -eq 0 ]
    [ -c "$OUT/special/console" ]
}
