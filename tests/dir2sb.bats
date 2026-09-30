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

@test "the mksquashfs invocation uses selective ownership actions" {
    write_file "$SRC/weird name.txt" spaced
    run_stub "$SRC" "$OUT/space out.sb"
    [ "$status" -eq 0 ]
    [ -e "$OUT/space out.sb" ]
    mapfile -d '' -t args <"$STATE/args"
    local joined="${args[*]}"
    [[ $joined == *-noappend* ]]
    [[ $joined != *-all-root* ]]
    [[ $joined == *'uid_range(1000,60000)'* ]]
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
    [[ ${args[*]} != *-action* ]]
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

@test "caller marker cancels a privileged compressor across the UID boundary" {
    (( EUID != 0 )) || skip 'requires an unprivileged caller'
    command -v sudo >/dev/null || skip 'sudo unavailable'
    sudo -n /usr/bin/test 1 = 1 2>/dev/null || skip 'passwordless sudo unavailable'
    write_file "$SRC/file.txt" data
    local ready="$TEST_ROOT/ready" cancel="$TEST_ROOT/cancel"
    sudo -n env PATH="$TOOLS:$SYSTEM_PATH" NO_COLOR=1 \
        MKSQUASHFS_SLEEP=true MKSQUASHFS_SLEEP_MARKER="$ready" \
        "$DIR2SB" --cancel-file "$cancel" "$SRC" "$OUT/module.sb" &
    local pid=$!
    for _ in {1..100}; do [ -s "$ready" ] && break; sleep 0.05; done
    [ -s "$ready" ]
    touch "$cancel"
    local status=0
    wait "$pid" || status=$?
    [ "$status" -eq 130 ]
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

@test "real tools normalize user IDs except home and opt while preserving service IDs" {
    require_real_tools
    (( EUID == 0 )) || skip 'requires root to create mixed-owner fixtures'
    local path
    for path in usr/bin/tool etc/user.conf boot/file root/file lib64/file \
        opt/app/file home/user/file var/lib/app/file srv/app/file custom/file; do
        write_file "$SRC/$path" data
    done
    chown -R 1000:1001 "$SRC"
    write_file "$SRC/etc/service.conf" service
    chown 33:44 "$SRC/etc/service.conf"
    write_file "$SRC/usr/bin/nobody-file" nobody
    chown 65534:65534 "$SRC/usr/bin/nobody-file"
    write_file "$SRC/usr/bin/dynamic-file" dynamic
    chown 61184:61184 "$SRC/usr/bin/dynamic-file"
    write_file "$SRC/etc/mixed.conf" mixed
    chown 1000:44 "$SRC/etc/mixed.conf"
    chmod 0640 "$SRC/etc/mixed.conf"
    ln -s ../../home/user/file "$SRC/usr/bin/link"
    chown -h 1000:1001 "$SRC/usr/bin/link"
    ln "$SRC/home/user/file" "$SRC/usr/bin/hardlink"
    local before
    before=$(find "$SRC" -printf '%P %U:%G %m %l\n' | sort)
    run_real --comp gzip "$SRC" "$OUT/owners.sb"
    [ "$status" -eq 0 ]
    [ "$before" = "$(find "$SRC" -printf '%P %U:%G %m %l\n' | sort)" ]
    run unsquashfs -no-progress -d "$OUT/owners" "$OUT/owners.sb"
    [ "$status" -eq 0 ]
    for path in . usr usr/bin usr/bin/tool etc etc/user.conf boot boot/file \
        root root/file lib64 lib64/file opt home var srv usr/bin/link usr/bin/hardlink \
        var/lib var/lib/app/file srv/app srv/app/file custom custom/file; do
        [ "$(stat -c '%u:%g' "$OUT/owners/$path")" = 0:0 ]
    done
    for path in opt/app opt/app/file home/user home/user/file; do
        local owner
        owner=$(stat -c '%u:%g' "$OUT/owners/$path")
        [ "$owner" = 1000:1001 ] || { printf '%s: %s\n' "$path" "$owner"; return 1; }
    done
    [ "$(stat -c '%u:%g' "$OUT/owners/etc/service.conf")" = 33:44 ]
    [ "$(stat -c '%u:%g' "$OUT/owners/usr/bin/nobody-file")" = 65534:65534 ]
    [ "$(stat -c '%u:%g' "$OUT/owners/usr/bin/dynamic-file")" = 61184:61184 ]
    [ "$(stat -c '%u:%g:%a' "$OUT/owners/etc/mixed.conf")" = 0:44:640 ]
    [ "$(readlink "$OUT/owners/usr/bin/link")" = ../../home/user/file ]
}

@test "real keep-ownership preserves even standard system directory owners" {
    require_real_tools
    (( EUID == 0 )) || skip 'requires root to create mixed-owner fixtures'
    write_file "$SRC/usr/bin/tool" data
    chown -R 1000:1001 "$SRC"
    run_real --comp gzip --keep-ownership "$SRC" "$OUT/owners.sb"
    [ "$status" -eq 0 ]
    run unsquashfs -no-progress -d "$OUT/owners" "$OUT/owners.sb"
    [ "$status" -eq 0 ]
    [ "$(stat -c '%u:%g' "$OUT/owners")" = 1000:1001 ]
    [ "$(stat -c '%u:%g' "$OUT/owners/usr/bin/tool")" = 1000:1001 ]
}

@test "extracted modules automatically preserve metadata through a real round-trip" {
    require_real_tools
    (( EUID == 0 )) || skip 'requires privileged extraction and mixed-owner fixtures'
    write_file "$SRC/etc/private/key" secret
    write_file "$SRC/var/lib/service/data" service
    write_file "$SRC/usr/bin/user-owned" user
    write_file "$SRC/opt/app/file" opt
    chown -R 33:44 "$SRC/var/lib/service"
    chown 1234:2345 "$SRC/usr/bin/user-owned" "$SRC/opt/app/file"
    chmod 0700 "$SRC/etc/private"
    chmod 0600 "$SRC/etc/private/key"
    chmod 4750 "$SRC/usr/bin/user-owned"
    ln "$SRC/var/lib/service/data" "$SRC/var/lib/service/link"
    ln -s var/lib/service "$SRC/service-link"
    mkdir "$SRC/empty"
    find "$SRC" -exec touch -h -d @1700000000 {} +
    local before
    before=$(find "$SRC" -printf '%P %U:%G %m %y %l %T@\n' | sort)
    run mksquashfs "$SRC" "$OUT/original.sb" -comp gzip -noappend -no-progress
    [ "$status" -eq 0 ]
    run "$SB2DIR" --keep-ownership --allow-special "$OUT/original.sb" "$OUT/extracted"
    [ "$status" -eq 0 ]
    [ -f "$OUT/extracted/.minios-module-origin.json" ]
    # No --keep-ownership here: provenance must select preservation itself.
    run_real --comp gzip "$OUT/extracted" "$OUT/repacked.sb"
    [ "$status" -eq 0 ]
    run unsquashfs -no-progress -d "$OUT/restored" "$OUT/repacked.sb"
    [ "$status" -eq 0 ]
    [ ! -e "$OUT/restored/.minios-module-origin.json" ]
    [ "$before" = "$(find "$OUT/restored" -printf '%P %U:%G %m %y %l %T@\n' | sort)" ]
    [ "$(stat -c %i "$OUT/restored/var/lib/service/data")" = \
      "$(stat -c %i "$OUT/restored/var/lib/service/link")" ]
    [ "$(cat "$OUT/restored/etc/private/key")" = secret ]
}

@test "rootless extraction is marked and cannot silently become a system module" {
    require_real_tools
    (( EUID != 0 )) || skip 'requires unprivileged extraction'
    write_file "$SRC/file" data
    run_real --comp gzip "$SRC" "$OUT/original.sb"
    [ "$status" -eq 0 ]
    run "$SB2DIR" "$OUT/original.sb" "$OUT/extracted"
    [ "$status" -eq 0 ]
    run_real --comp gzip "$OUT/extracted" "$OUT/repacked.sb"
    [ "$status" -eq 3 ]
    [[ $output == *'extracted without preserving ownership'* ]]
    [ ! -e "$OUT/repacked.sb" ]
}

@test "privileged module round-trip preserves capabilities xattrs and devices" {
    require_real_tools
    (( EUID == 0 )) || skip 'requires privileged filesystem attributes'
    local tool
    for tool in setfattr getfattr setcap getcap; do
        command -v "$tool" >/dev/null || skip "$tool is unavailable"
    done
    write_file "$SRC/usr/bin/tool" executable
    chmod 0755 "$SRC/usr/bin/tool"
    setcap cap_net_bind_service=ep "$SRC/usr/bin/tool"
    setfattr -n user.minios-test -v preserved "$SRC/usr/bin/tool"
    mkdir "$SRC/dev"
    mknod "$SRC/dev/test-null" c 1 3 || skip 'device nodes unsupported'
    mkfifo "$SRC/dev/test-pipe"
    local attrs
    attrs=$(getfattr --only-values -n security.capability "$SRC/usr/bin/tool" | base64)
    run mksquashfs "$SRC" "$OUT/original.sb" -comp gzip -noappend -no-progress
    [ "$status" -eq 0 ]
    run "$SB2DIR" --keep-ownership --allow-special "$OUT/original.sb" "$OUT/extracted"
    [ "$status" -eq 0 ]
    run_real --comp gzip "$OUT/extracted" "$OUT/repacked.sb"
    [ "$status" -eq 0 ]
    run unsquashfs -no-progress -d "$OUT/restored" "$OUT/repacked.sb"
    [ "$status" -eq 0 ]
    [ "$attrs" = "$(getfattr --only-values -n security.capability "$OUT/restored/usr/bin/tool" | base64)" ]
    [ "$(getfattr --only-values -n user.minios-test "$OUT/restored/usr/bin/tool")" = preserved ]
    [ "$(stat -c '%t:%T:%a:%u:%g' "$SRC/dev/test-null")" = \
      "$(stat -c '%t:%T:%a:%u:%g' "$OUT/restored/dev/test-null")" ]
    [ -p "$OUT/restored/dev/test-pipe" ]
}

@test "invalid or linked origin records are never silently excluded" {
    write_file "$SRC/.minios-module-origin.json" '{}'
    run_stub "$SRC" "$OUT/invalid.sb"
    [ "$status" -eq 3 ]
    [ ! -e "$OUT/invalid.sb" ]
    rm "$SRC/.minios-module-origin.json"
    ln -s /dev/null "$SRC/.minios-module-origin.json"
    run_stub "$SRC" "$OUT/linked.sb"
    [ "$status" -ne 0 ]
    [ ! -e "$OUT/linked.sb" ]
}

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
    run diff -r --exclude=.minios-module-origin.json "$SRC" "$OUT/restored"
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
