#!/usr/bin/env bats

setup() {
    SAVECHANGES="$BATS_TEST_DIRNAME/../bin/savechanges"
    STUBS="$BATS_TEST_DIRNAME/stubs"
    SYSTEM_PATH=$PATH
    TEST_ROOT="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-${TMPDIR:-/tmp}}}/savechanges job $BATS_TEST_NUMBER"
    CHANGES="$TEST_ROOT/writable changes"
    OUTPUT_DIR="$TEST_ROOT/output dir"
    TMP_ROOT="$TEST_ROOT/private tmp"
    SELECTION="$TEST_ROOT/session selection.json"
    TEST_TOOLS="$TEST_ROOT/tools"
    TEST_MKSQUASHFS="$TEST_TOOLS/mksquashfs"
    TEST_UNSQUASHFS="$TEST_TOOLS/unsquashfs"
    TEST_MOUNTINFO="$TEST_ROOT/mountinfo"
    TEST_CMDLINE="$TEST_ROOT/cmdline"
    TEST_BOOT_ID="$TEST_ROOT/boot-id"
    TEST_AUFS_SYSFS="$TEST_ROOT/aufs-sysfs"

    mkdir -p "$CHANGES" "$OUTPUT_DIR" "$TMP_ROOT" "$TEST_TOOLS" "$TEST_AUFS_SYSFS"
    cp -- "$STUBS/mksquashfs" "$TEST_MKSQUASHFS"
    cp -- "$STUBS/unsquashfs" "$TEST_UNSQUASHFS"
    chmod 0755 "$TEST_MKSQUASHFS" "$TEST_UNSQUASHFS"
    printf '%s\n' 'BOOT_IMAGE=/minios/boot/vmlinuz' >"$TEST_CMDLINE"
    printf '%s\n' '11111111-2222-3333-4444-555555555555' >"$TEST_BOOT_ID"
}

write_file() {
    local path=$1
    shift
    mkdir -p "${path%/*}"
    printf '%s\n' "$*" >"$path"
}

prepare_union_fixture() {
    local backend=$1
    local changes=$2
    local effective=$changes
    local escaped
    local -a entries

    if [[ $backend == overlayfs ]]; then
        for _ in {1..16}; do
            shopt -s nullglob dotglob
            entries=("$effective"/*)
            shopt -u nullglob dotglob
            if (( ${#entries[@]} == 2 )) && [[ -d $effective/changes && -d $effective/workdir ]]; then
                effective=$effective/changes
            else
                break
            fi
        done
        [[ -z ${SAVECHANGES_TEST_UPPERDIR:-} ]] || effective=$SAVECHANGES_TEST_UPPERDIR
        escaped=${effective// /\\040}
        printf '24 1 0:1 / / rw - overlay overlay rw,lowerdir=/lower/01-kernel.sb:/lower/00-core.sb,upperdir=%s,workdir=/work\n' \
            "$escaped" >"$TEST_MOUNTINFO"
    elif [[ $backend == aufs ]]; then
        [[ -z ${SAVECHANGES_TEST_UPPERDIR:-} ]] || effective=$SAVECHANGES_TEST_UPPERDIR
        escaped=${effective// /\\040}
        lower_branches=${SAVECHANGES_TEST_LOWER_BRANCHES:-/lower/00-core.sb=rr+wh}
        printf '24 1 0:1 / / rw - aufs none rw,si=test,br:%s=rw:%s\n' \
            "$escaped" "$lower_branches" >"$TEST_MOUNTINFO"
        if [[ -n ${SAVECHANGES_TEST_LOWER_BACKING:-} ]]; then
            escaped=${SAVECHANGES_TEST_LOWER_BACKING// /\\040}
            printf '25 24 0:2 / /lower/00-core.sb ro - squashfs %s ro\n' \
                "$escaped" >>"$TEST_MOUNTINFO"
        fi
    else
        printf '%s\n' '24 1 0:1 / / rw - ext4 /dev/test rw' >"$TEST_MOUNTINFO"
    fi
    printf '%s\n' "${SAVECHANGES_TEST_CMDLINE_CONTENT:-BOOT_IMAGE=/minios/boot/vmlinuz}" >"$TEST_CMDLINE"
}

prepare_aufs_sysfs_fixture() {
    local session_id=$1
    local changes=$2
    local session="$TEST_AUFS_SYSFS/si_$session_id"
    mkdir -p "$session"
    printf '%s=rw\n' "$changes" >"$session/br0"
    printf '%s=rr+wh\n' '/lower/01-kernel.sb' >"$session/br1"
    printf '%s=rr+wh\n' '/lower/00-core.sb' >"$session/br2"
}

assert_process_gone() {
    local process_id=$1
    for _ in {1..100}; do
        kill -0 "$process_id" 2>/dev/null || return 0
        sleep 0.05
    done
    kill -KILL "$process_id" 2>/dev/null || true
    return 1
}

run_module() {
    local target=$1
    local state=$2
    local changes=${SAVECHANGES_TEST_CHANGES:-$CHANGES}
    shift 2
    prepare_union_fixture "${SAVECHANGES_TEST_UNION:-overlayfs}" "$changes"
    run env \
        PATH="$STUBS:$SYSTEM_PATH" \
        TMPDIR="${SAVECHANGES_TEST_TMPDIR:-$TMP_ROOT}" \
        MINIOS_TOOLS_TEST_ALLOW_NON_ROOT=1 \
        MINIOS_TOOLS_TEST_ROOT="$TEST_ROOT" \
        MINIOS_TOOLS_TEST_MOUNTINFO="$TEST_MOUNTINFO" \
        MINIOS_TOOLS_TEST_CMDLINE="$TEST_CMDLINE" \
        MINIOS_TOOLS_TEST_BOOT_ID="$TEST_BOOT_ID" \
        MINIOS_TOOLS_TEST_AUFS_SYSFS="$TEST_AUFS_SYSFS" \
        MINIOS_TOOLS_TEST_RUNNING_SOURCE="${MINIOS_TOOLS_TEST_RUNNING_SOURCE:-}" \
        MINIOS_TOOLS_TEST_MKSQUASHFS="$TEST_MKSQUASHFS" \
        MINIOS_TOOLS_TEST_UNSQUASHFS="$TEST_UNSQUASHFS" \
        MKSQUASHFS_STATE="$state" \
        MKSQUASHFS_FAIL="${MKSQUASHFS_FAIL:-false}" \
        MKSQUASHFS_RACE_TARGET="${MKSQUASHFS_RACE_TARGET:-}" \
        MKSQUASHFS_SLEEP="${MKSQUASHFS_SLEEP:-false}" \
        MKSQUASHFS_SLEEP_MARKER="${MKSQUASHFS_SLEEP_MARKER:-}" \
        MKSQUASHFS_STUBBORN="${MKSQUASHFS_STUBBORN:-false}" \
        MKSQUASHFS_LEADER_EXIT="${MKSQUASHFS_LEADER_EXIT:-false}" \
        MKSQUASHFS_NO_QUIET="${MKSQUASHFS_NO_QUIET:-false}" \
        UNSQUASHFS_FAIL_PATTERN="${UNSQUASHFS_FAIL_PATTERN:-__never__}" \
        SAVECHANGES_TEST_FAIL_OUTPUT_DIR_FSYNC="${SAVECHANGES_TEST_FAIL_OUTPUT_DIR_FSYNC:-0}" \
        SAVECHANGES_TEST_PAUSE_AFTER_PUBLISH="${SAVECHANGES_TEST_PAUSE_AFTER_PUBLISH:-}" \
        NO_COLOR=1 \
        "$SAVECHANGES" "$@" "$target" "$changes"
}

run_inventory() {
    local target=$1
    shift
    prepare_union_fixture "${SAVECHANGES_TEST_UNION:-overlayfs}" "$CHANGES"
    run env \
        PATH="$STUBS:$SYSTEM_PATH" \
        TMPDIR="$TMP_ROOT" \
        MINIOS_TOOLS_TEST_ALLOW_NON_ROOT=1 \
        MINIOS_TOOLS_TEST_ROOT="$TEST_ROOT" \
        MINIOS_TOOLS_TEST_MOUNTINFO="$TEST_MOUNTINFO" \
        MINIOS_TOOLS_TEST_CMDLINE="$TEST_CMDLINE" \
        MINIOS_TOOLS_TEST_BOOT_ID="$TEST_BOOT_ID" \
        MINIOS_TOOLS_TEST_AUFS_SYSFS="$TEST_AUFS_SYSFS" \
        NO_COLOR=1 \
        "$SAVECHANGES" "$@" --inventory-json "$target" "$CHANGES"
}

assert_output_contains() {
    [[ $output == *"$1"* ]]
}

@test "exact preserves session data while clean removes privacy-sensitive classes" {
    write_file "$CHANGES/etc/default/minios" defaults
    write_file "$CHANGES/usr/bin/session-tool" software
    write_file "$CHANGES/var/lib/dpkg/status" packages
    write_file "$CHANGES/home/live/Documents/note.txt" private-home
    write_file "$CHANGES/root/admin.txt" private-root
    write_file "$CHANGES/var/log/session.log" private-log
    write_file "$CHANGES/var/cache/app/cache.db" private-cache
    write_file "$CHANGES/etc/machine-id" machine-identity
    write_file "$CHANGES/etc/ssh/ssh_host_ed25519_key" host-key
    write_file "$CHANGES/etc/NetworkManager/system-connections/wifi.nmconnection" wifi-secret
    write_file "$CHANGES/etc/ssl/private/server.key" private-key
    write_file "$CHANGES/etc/skel/.mozilla/profile/cookies.sqlite" browser-data
    write_file "$CHANGES/etc/skel/.local/share/keyrings/login.keyring" keyring-data
    write_file "$CHANGES/etc/skel/.bash_history" history-data
    write_file "$CHANGES/etc/fstab" machine-mount-identity
    write_file "$CHANGES/var/mail/live" private-mail
    write_file "$CHANGES/var/lib/docker/volumes/project/data" container-user-data
    write_file "$CHANGES/var/lib/snapd/device/private-keys-v1/device-key" snap-identity
    write_file "$CHANGES/var/lib/snapd/snaps/application.snap" installed-snap
    write_file "$CHANGES/run/session/runtime" runtime
    write_file "$CHANGES/.wh..wh.orph/internal" overlay-metadata
    mkdir -p "$CHANGES/empty exact directory"

    exact_output="$OUTPUT_DIR/exact.sb"
    exact_state="$TEST_ROOT/exact state"
    run_module "$exact_output" "$exact_state" --profile exact
    [ "$status" -eq 0 ]
    [ "$(stat -c '%a' "$exact_output")" = 600 ]
    [ -f "$exact_state/tree/etc/default/minios" ]
    [ -f "$exact_state/tree/usr/bin/session-tool" ]
    [ -f "$exact_state/tree/home/live/Documents/note.txt" ]
    [ -f "$exact_state/tree/var/log/session.log" ]
    [ -f "$exact_state/tree/etc/machine-id" ]
    [ -d "$exact_state/tree/empty exact directory" ]
    [ ! -e "$exact_state/tree/run/session/runtime" ]
    [ ! -e "$exact_state/tree/.wh..wh.orph" ]

    clean_output="$OUTPUT_DIR/clean.sb"
    clean_state="$TEST_ROOT/clean state"
    run_module "$clean_output" "$clean_state" --profile clean
    [ "$status" -eq 0 ]
    [ ! -e "$clean_state/tree/etc/default/minios" ]
    [ -f "$clean_state/tree/usr/bin/session-tool" ]
    [ -f "$clean_state/tree/var/lib/dpkg/status" ]
    [ ! -e "$clean_state/tree/home" ]
    [ ! -e "$clean_state/tree/root" ]
    [ ! -e "$clean_state/tree/var/log" ]
    [ ! -e "$clean_state/tree/var/cache" ]
    [ ! -e "$clean_state/tree/etc/machine-id" ]
    [ ! -e "$clean_state/tree/etc/ssh/ssh_host_ed25519_key" ]
    [ ! -e "$clean_state/tree/etc/NetworkManager/system-connections/wifi.nmconnection" ]
    [ ! -e "$clean_state/tree/etc/ssl/private" ]
    [ ! -e "$clean_state/tree/etc/skel/.mozilla" ]
    [ ! -e "$clean_state/tree/etc/skel/.local/share/keyrings" ]
    [ ! -e "$clean_state/tree/etc/skel/.bash_history" ]
    [ ! -e "$clean_state/tree/etc/fstab" ]
    [ ! -e "$clean_state/tree/var/mail" ]
    [ ! -e "$clean_state/tree/var/lib/docker" ]
    [ ! -e "$clean_state/tree/var/lib/snapd/device" ]
    [ -f "$clean_state/tree/var/lib/snapd/snaps/application.snap" ]
}

@test "exact fails closed instead of omitting unsupported filesystem objects" {
    write_file "$CHANGES/usr/bin/value" value
    mkfifo "$CHANGES/unsafe fifo"
    target="$OUTPUT_DIR/unsafe-exact.sb"

    run_module "$target" "$TEST_ROOT/unsafe exact state" --profile exact

    [ "$status" -ne 0 ]
    assert_output_contains 'exact capture cannot preserve unsupported filesystem objects: 1'
    [ ! -e "$target" ]

    clean_state="$TEST_ROOT/unsafe clean state"
    run_module "$OUTPUT_DIR/unsafe-clean.sb" "$clean_state" --profile clean
    [ "$status" -eq 0 ]
    [ ! -e "$clean_state/tree/unsafe fifo" ]
}

@test "exact excludes runtime device objects before unsupported-object validation" {
    mkdir -p "$CHANGES/dev" "$CHANGES/etc"
    mkfifo "$CHANGES/dev/runtime-fifo"
    write_file "$CHANGES/etc/value" kept

    run_module "$OUTPUT_DIR/runtime-device.sb" "$TEST_ROOT/runtime device state" --profile exact
    [ "$status" -eq 0 ]
    [ -f "$TEST_ROOT/runtime device state/tree/etc/value" ]
    [ ! -e "$TEST_ROOT/runtime device state/tree/dev/runtime-fifo" ]

    mkfifo "$CHANGES/etc/unsupported-fifo"
    run_module "$OUTPUT_DIR/non-runtime-device.sb" "$TEST_ROOT/non-runtime device state" --profile exact
    [ "$status" -ne 0 ]
    assert_output_contains 'exact capture cannot preserve unsupported filesystem objects: 1'
}

@test "exact fails closed on hard-linked non-regular inode topology" {
    mkdir -p "$CHANGES/usr/share"
    ln -s target "$CHANGES/usr/share/link-one"
    ln -P "$CHANGES/usr/share/link-one" "$CHANGES/usr/share/link-two" ||
        skip 'hard-linked symbolic links are unavailable'

    run_module "$OUTPUT_DIR/hardlinked-symlink.sb" \
        "$TEST_ROOT/hardlinked symlink state" --profile exact

    [ "$status" -ne 0 ]
    assert_output_contains 'exact capture cannot preserve hard-linked non-regular objects'
    [ ! -e "$OUTPUT_DIR/hardlinked-symlink.sb" ]
}

@test "exact ignores non-regular hardlinks outside the captured tree" {
    mkdir -p "$CHANGES/usr/share"
    ln -s target "$CHANGES/usr/share/link-one"
    ln -P "$CHANGES/usr/share/link-one" "$TEST_ROOT/outside-link" ||
        skip 'hard-linked symbolic links are unavailable'

    state="$TEST_ROOT/external hardlink state"
    run_module "$OUTPUT_DIR/external-hardlink.sb" "$state" --profile exact

    [ "$status" -eq 0 ]
    [ -L "$state/tree/usr/share/link-one" ]
    [ "$(readlink "$state/tree/usr/share/link-one")" = target ]
}

@test "no profile retains the historical exclusions" {
    write_file "$CHANGES/home/live/kept.txt" home-data
    write_file "$CHANGES/var/log/omitted.log" log-data
    write_file "$CHANGES/var/cache/app/omitted" cache-data
    write_file "$CHANGES/etc/default/kept" defaults
    mkdir -p "$CHANGES/empty legacy directory"

    state="$TEST_ROOT/legacy state"
    run_module "$OUTPUT_DIR/legacy.sb" "$state"

    [ "$status" -eq 0 ]
    [ "$(stat -c '%a' "$OUTPUT_DIR/legacy.sb")" = 644 ]
    [ -f "$state/tree/home/live/kept.txt" ]
    [ -f "$state/tree/etc/default/kept" ]
    [ ! -e "$state/tree/var/log" ]
    [ ! -e "$state/tree/var/cache" ]
    [ ! -e "$state/tree/empty legacy directory" ]
}

@test "selected includes descendants parents and associated whiteouts while excludes win" {
    write_file "$CHANGES/etc/app/config.ini" selected-config
    write_file "$CHANGES/etc/app/private/password" excluded-secret
    write_file "$CHANGES/etc/app/other.txt" selected-other
    : >"$CHANGES/etc/.wh.app"
    : >"$CHANGES/etc/app/.wh.deleted"
    : >"$CHANGES/etc/app/.wh.private"
    write_file "$CHANGES/etc/other/value" another-selection
    : >"$CHANGES/etc/.wh.other"
    : >"$CHANGES/etc/other/.wh..wh..opq"
    write_file "$CHANGES/etc/default/app" safe-target
    write_file "$CHANGES/home/live/Documents/keep.txt" selected-home
    write_file "$CHANGES/home/live/Documents/skip.txt" excluded-home
    write_file "$CHANGES/opt/unrelated" unrelated
    ln -s ../default/app "$CHANGES/etc/app/safe-link"
    write_file "$SELECTION" '{"product_kind":"minios-session-selection","schema_version":1,"include_paths":["etc/app","etc/other","home/live/Documents"],"exclude_paths":["etc/app/private","home/live/Documents/skip.txt"]}'

    state="$TEST_ROOT/selected state"
    SAVECHANGES_TEST_UNION=aufs run_module "$OUTPUT_DIR/selected.sb" "$state" \
        --profile=selected --selection="$SELECTION"

    [ "$status" -eq 0 ]
    [ -d "$state/tree/etc" ]
    [ -d "$state/tree/etc/app" ]
    [ -f "$state/tree/etc/app/config.ini" ]
    [ -f "$state/tree/etc/app/other.txt" ]
    [ -L "$state/tree/etc/app/safe-link" ]
    [ ! -e "$state/tree/etc/.wh.app" ]
    [ -f "$state/tree/etc/.wh.other" ]
    [ -f "$state/tree/etc/other/.wh..wh..opq" ]
    [ -f "$state/tree/etc/app/.wh.deleted" ]
    [ ! -e "$state/tree/etc/app/private" ]
    [ ! -e "$state/tree/etc/app/.wh.private" ]
    [ -f "$state/tree/home/live/Documents/keep.txt" ]
    [ ! -e "$state/tree/home/live/Documents/skip.txt" ]
    [ ! -e "$state/tree/opt" ]
}

@test "selected rejects a symbolic link escaping the changes root" {
    mkdir -p "$CHANGES/etc/app"
    ln -s /etc/shadow "$CHANGES/etc/app/escape"
    write_file "$SELECTION" '{"product_kind":"minios-session-selection","schema_version":1,"include_paths":["etc/app"],"exclude_paths":[]}'

    run_module "$OUTPUT_DIR/escape.sb" "$TEST_ROOT/escape state" \
        --profile selected --selection "$SELECTION"

    [ "$status" -ne 0 ]
    assert_output_contains 'symbolic link is not confined'
    [ ! -e "$OUTPUT_DIR/escape.sb" ]
}

@test "strict selection JSON rejects unknown duplicate malformed and traversing input" {
    write_file "$CHANGES/etc/app/value" value
    local document
    local -a invalid_documents=(
        '{"product_kind":"minios-session-selection","schema_version":1,"include_paths":["etc/app"],"exclude_paths":[],"unknown":true}'
        '{"product_kind":"minios-session-selection","schema_version":1,"include_paths":["etc/app","etc/app"],"exclude_paths":[]}'
        '{"product_kind":"minios-session-selection","schema_version":1,"include_paths":["etc/app"],"exclude_paths":["etc/app"]}'
        '{"product_kind":"minios-session-selection","schema_version":1,"include_paths":["../etc/shadow"],"exclude_paths":[]}'
        '{"product_kind":"minios-session-selection","schema_version":1,"include_paths":["/etc/shadow"],"exclude_paths":[]}'
        '{"product_kind":"minios-session-selection","schema_version":1,"include_paths":["etc//app"],"exclude_paths":[]}'
        '{"product_kind":"minios-session-selection","schema_version":1,"include_paths":["etc/./app"],"exclude_paths":[]}'
        '{"product_kind":"minios-session-selection","schema_version":1,"include_paths":["etc\napp"],"exclude_paths":[]}'
        '{"product_kind":"minios-session-selection","schema_version":1,"include_paths":["etc\u0000app"],"exclude_paths":[]}'
        '{"product_kind":"minios-session-selection","schema_version":1,"schema_version":1,"include_paths":[],"exclude_paths":[]}'
    )

    for document in "${invalid_documents[@]}"; do
        write_file "$SELECTION" "$document"
        run_module "$OUTPUT_DIR/invalid.sb" "$TEST_ROOT/invalid state" \
            --profile selected --selection "$SELECTION"
        [ "$status" -ne 0 ]
        [ ! -e "$OUTPUT_DIR/invalid.sb" ]
    done

    printf '\xff{"product_kind":"minios-session-selection"}\n' >"$SELECTION"
    run_module "$OUTPUT_DIR/invalid-utf8.sb" "$TEST_ROOT/invalid utf8 state" \
        --profile selected --selection "$SELECTION"
    [ "$status" -ne 0 ]
    assert_output_contains 'invalid selection JSON'

    write_file "$TEST_ROOT/real-selection.json" '{"product_kind":"minios-session-selection","schema_version":1,"include_paths":[],"exclude_paths":[]}'
    ln -s "$TEST_ROOT/real-selection.json" "$TEST_ROOT/selection-link.json"
    run_module "$OUTPUT_DIR/selection-link.sb" "$TEST_ROOT/selection link state" \
        --profile selected --selection "$TEST_ROOT/selection-link.json"
    [ "$status" -ne 0 ]
    assert_output_contains 'capture filesystem error'
}

@test "selected rejects unmatched includes and unknown union metadata fails closed" {
    write_file "$CHANGES/etc/app/value" value
    missing_marker='home/selection-path-must-never-appear'
    write_file "$SELECTION" "{\"product_kind\":\"minios-session-selection\",\"schema_version\":1,\"include_paths\":[\"$missing_marker\"],\"exclude_paths\":[]}"

    run_module "$OUTPUT_DIR/unmatched.sb" "$TEST_ROOT/unmatched state" \
        --profile selected --selection "$SELECTION"
    [ "$status" -ne 0 ]
    assert_output_contains 'unmatched count: 1'
    [[ $output != *"$missing_marker"* ]]
    [ ! -e "$OUTPUT_DIR/unmatched.sb" ]

    write_file "$CHANGES/etc/.wh.deleted" ambiguous-whiteout
    SAVECHANGES_TEST_UNION=unknown run_module \
        "$OUTPUT_DIR/unknown.sb" "$TEST_ROOT/unknown state" --profile exact
    [ "$status" -ne 0 ]
    assert_output_contains 'union whiteout cannot be represented safely'
    [ ! -e "$OUTPUT_DIR/unknown.sb" ]
}

@test "isolated capture engine ignores malicious Python modules in the working directory" {
    poison="$TEST_ROOT/poison modules"
    marker="$TEST_ROOT/poison-executed"
    mkdir -p "$poison"
    for module in ctypes hashlib json; do
        printf 'open("%s", "a").write("%s\\n")\n' "$marker" "$module" >"$poison/$module.py"
    done
    write_file "$CHANGES/etc/default/value" value

    original_directory=$PWD
    cd "$poison"
    run_inventory "$OUTPUT_DIR/isolated-inventory.json"
    cd "$original_directory"

    [ "$status" -eq 0 ]
    [ -s "$OUTPUT_DIR/isolated-inventory.json" ]
    [ ! -e "$marker" ]
}

@test "spaces and newlines are copied without line parsing" {
    space_path='data directory/file with spaces.txt'
    newline_path=$'data directory/file with\nnewline.txt'
    write_file "$CHANGES/$space_path" spaced
    write_file "$CHANGES/$newline_path" newline

    state="$TEST_ROOT/path state"
    run_module "$OUTPUT_DIR/paths.sb" "$state" --profile exact

    [ "$status" -eq 0 ]
    [ -f "$state/tree/$space_path" ]
    [ -f "$state/tree/$newline_path" ]
}

@test "existing and racing destinations are never overwritten" {
    existing="$OUTPUT_DIR/existing.sb"
    write_file "$existing" original
    run_module "$existing" "$TEST_ROOT/existing state" --profile exact
    [ "$status" -ne 0 ]
    [ "$(<"$existing")" = original ]

    racing="$OUTPUT_DIR/racing.sb"
    MKSQUASHFS_RACE_TARGET="$racing" run_module "$racing" "$TEST_ROOT/racing state" --profile exact
    [ "$status" -ne 0 ]
    assert_output_contains 'output path exists or appeared'
    [ "$(<"$racing")" = 'racing output' ]
}

@test "post-publication fsync failure removes the owned output and permits retry" {
    write_file "$CHANGES/etc/default/value" value
    target="$OUTPUT_DIR/fsync-failure.sb"

    SAVECHANGES_TEST_FAIL_OUTPUT_DIR_FSYNC=1 \
        run_module "$target" "$TEST_ROOT/fsync failure state" --json --profile exact

    [ "$status" -ne 0 ]
    [[ $output != *'"type":"result"'* ]]
    [ ! -e "$target" ]

    SAVECHANGES_TEST_FAIL_OUTPUT_DIR_FSYNC=0 \
        run_module "$target" "$TEST_ROOT/fsync retry state" --json --profile exact
    [ "$status" -eq 0 ]
    [ -s "$target" ]
}

@test "symlinked output parents are rejected" {
    write_file "$CHANGES/etc/default/value" value
    ln -s "$OUTPUT_DIR" "$TEST_ROOT/output-link"

    run_module "$TEST_ROOT/output-link/symlink-parent.sb" \
        "$TEST_ROOT/symlink-parent state" --profile exact

    [ "$status" -ne 0 ]
    [ ! -e "$OUTPUT_DIR/symlink-parent.sb" ]
}

@test "post-publication replacement is preserved and never adopted for rollback" {
    write_file "$CHANGES/etc/default/value" value
    prepare_union_fixture overlayfs "$CHANGES"
    target="$OUTPUT_DIR/replaced-after-publish.sb"
    owned="$OUTPUT_DIR/replaced-after-publish.owned"
    barrier="$TEST_ROOT/post-publish barrier"
    events="$TEST_ROOT/post-publish.events"
    diagnostics="$TEST_ROOT/post-publish.diagnostics"

    env \
        PATH="$STUBS:$SYSTEM_PATH" \
        TMPDIR="$TMP_ROOT" \
        MINIOS_TOOLS_TEST_ALLOW_NON_ROOT=1 \
        MINIOS_TOOLS_TEST_ROOT="$TEST_ROOT" \
        MINIOS_TOOLS_TEST_MOUNTINFO="$TEST_MOUNTINFO" \
        MINIOS_TOOLS_TEST_CMDLINE="$TEST_CMDLINE" \
        MINIOS_TOOLS_TEST_BOOT_ID="$TEST_BOOT_ID" \
        MINIOS_TOOLS_TEST_MKSQUASHFS="$TEST_MKSQUASHFS" \
        MINIOS_TOOLS_TEST_UNSQUASHFS="$TEST_UNSQUASHFS" \
        SAVECHANGES_TEST_PAUSE_AFTER_PUBLISH="$barrier" \
        NO_COLOR=1 \
        "$SAVECHANGES" --json --profile exact "$target" "$CHANGES" \
        >"$events" 2>"$diagnostics" &
    script_pid=$!
    for _ in {1..200}; do
        [[ -e $barrier.ready ]] && break
        sleep 0.05
    done
    [ -e "$barrier.ready" ]
    mv "$target" "$owned"
    printf '%s\n' replacement >"$target"
    : >"$barrier.continue"
    result=0
    wait "$script_pid" || result=$?

    [ "$result" -ne 0 ]
    [ "$(<"$target")" = replacement ]
    [ -s "$owned" ]
    run grep -Fq '"type":"result"' "$events"
    [ "$status" -ne 0 ]
}

@test "a destination inside the changes root is not captured into itself" {
    write_file "$CHANGES/etc/default/value" value
    target="$CHANGES/inside output.sb"
    state="$TEST_ROOT/inside state"

    run_module "$target" "$state" --profile exact

    [ "$status" -eq 0 ]
    [ -s "$target" ]
    [ ! -e "$state/tree/inside output.sb" ]
}

@test "nested OverlayFS changes and workdir wrappers are unwrapped without capturing workdirs" {
    outer="$TEST_ROOT/overlay wrapper"
    mkdir -p "$outer/changes/changes/etc/default" "$outer/changes/workdir" "$outer/workdir"
    write_file "$outer/changes/changes/etc/default/nested" nested-value
    state="$TEST_ROOT/overlay state"

    SAVECHANGES_TEST_CHANGES="$outer" run_module "$OUTPUT_DIR/overlay.sb" "$state" --profile exact

    [ "$status" -eq 0 ]
    [ -f "$state/tree/etc/default/nested" ]
    [ ! -e "$state/tree/changes" ]
    [ ! -e "$state/tree/workdir" ]
}

@test "mounted root overrides cmdline union intent and changes shape is verified" {
    write_file "$CHANGES/etc/default/value" value
    inventory="$OUTPUT_DIR/mounted-root.json"

    SAVECHANGES_TEST_CMDLINE_CONTENT='BOOT_IMAGE=/minios/boot/vmlinuz union=aufs' \
        run_inventory "$inventory"
    [ "$status" -eq 0 ]
    assert_output_contains 'using mounted overlayfs'
    run python3 -I -c 'import json,sys; assert json.load(open(sys.argv[1]))["union_backend"] == "overlayfs"' \
        "$inventory"
    [ "$status" -eq 0 ]

    wrong_upper="$TEST_ROOT/not the mounted upper"
    mkdir -p "$wrong_upper"
    SAVECHANGES_TEST_UPPERDIR="$wrong_upper" run_module \
        "$OUTPUT_DIR/wrong-upper.sb" "$TEST_ROOT/wrong upper state" --profile exact
    [ "$status" -ne 0 ]
    assert_output_contains 'does not resolve to the mounted OverlayFS upperdir'
    [ ! -e "$OUTPUT_DIR/wrong-upper.sb" ]

    SAVECHANGES_TEST_UNION=aufs SAVECHANGES_TEST_UPPERDIR="$wrong_upper" run_module \
        "$OUTPUT_DIR/wrong-aufs.sb" "$TEST_ROOT/wrong aufs state" --profile exact
    [ "$status" -ne 0 ]
    assert_output_contains 'does not resolve to the mounted AUFS writable branch'
    [ ! -e "$OUTPUT_DIR/wrong-aufs.sb" ]
}

@test "AUFS sysfs branches provide writable and ordered lower layers when mountinfo has only si" {
    prepare_aufs_sysfs_fixture test "$CHANGES"
    printf '24 1 0:1 / / rw - aufs aufs rw,si=test,trunc_xino\n' >"$TEST_MOUNTINFO"
    printf '%s\n' 'BOOT_IMAGE=/minios/boot/vmlinuz union=aufs' >"$TEST_CMDLINE"

    run env \
        PATH="$STUBS:$SYSTEM_PATH" \
        TMPDIR="$TMP_ROOT" \
        MINIOS_TOOLS_TEST_ALLOW_NON_ROOT=1 \
        MINIOS_TOOLS_TEST_ROOT="$TEST_ROOT" \
        MINIOS_TOOLS_TEST_MOUNTINFO="$TEST_MOUNTINFO" \
        MINIOS_TOOLS_TEST_CMDLINE="$TEST_CMDLINE" \
        MINIOS_TOOLS_TEST_BOOT_ID="$TEST_BOOT_ID" \
        MINIOS_TOOLS_TEST_AUFS_SYSFS="$TEST_AUFS_SYSFS" \
        NO_COLOR=1 \
        "$SAVECHANGES" --inventory-json "$OUTPUT_DIR/aufs-sysfs.json" "$CHANGES"
    [ "$status" -eq 0 ]
    run python3 -I -c 'import json,sys; value=json.load(open(sys.argv[1])); assert value["union_backend"] == "aufs"' \
        "$OUTPUT_DIR/aufs-sysfs.json"
    [ "$status" -eq 0 ]
}

@test "aufs-ng branch inventory replaces unavailable AUFS sysfs" {
    manifest="$TEST_ROOT/aufs-ng-branches"
    printf '%s=rw\n%s=rr+wh\n%s=rr+wh\n' \
        "$CHANGES" /lower/01-kernel.sb /lower/00-core.sb >"$manifest"
    chmod 0600 "$manifest"
    printf '24 1 0:1 / / rw - aufs aufs rw,si=ng\n' >"$TEST_MOUNTINFO"
    printf '%s\n' 'BOOT_IMAGE=/minios/boot/vmlinuz union=aufs' >"$TEST_CMDLINE"

    run env \
        PATH="$STUBS:$SYSTEM_PATH" \
        TMPDIR="$TMP_ROOT" \
        MINIOS_TOOLS_TEST_ALLOW_NON_ROOT=1 \
        MINIOS_TOOLS_TEST_ROOT="$TEST_ROOT" \
        MINIOS_TOOLS_TEST_MOUNTINFO="$TEST_MOUNTINFO" \
        MINIOS_TOOLS_TEST_CMDLINE="$TEST_CMDLINE" \
        MINIOS_TOOLS_TEST_BOOT_ID="$TEST_BOOT_ID" \
        MINIOS_TOOLS_TEST_AUFS_SYSFS="$TEST_AUFS_SYSFS" \
        NO_COLOR=1 \
        "$SAVECHANGES" --aufs-branches "$manifest" \
        --inventory-json "$OUTPUT_DIR/aufs-ng.json" "$CHANGES"
    [ "$status" -eq 0 ]
    run python3 -I -c 'import json,sys; value=json.load(open(sys.argv[1])); assert value["union_backend"] == "aufs"' \
        "$OUTPUT_DIR/aufs-ng.json"
    [ "$status" -eq 0 ]
}

@test "AUFS branch inventory is revalidated by the capture engine" {
    manifest="$TEST_ROOT/insecure-aufs-ng-branches"
    printf '%s=rw\n%s=rr+wh\n' "$CHANGES" /lower/00-core.sb >"$manifest"
    chmod 0666 "$manifest"
    printf '24 1 0:1 / / rw - aufs aufs rw,si=ng\n' >"$TEST_MOUNTINFO"

    run env \
        PATH="$STUBS:$SYSTEM_PATH" \
        TMPDIR="$TMP_ROOT" \
        MINIOS_TOOLS_TEST_ALLOW_NON_ROOT=1 \
        MINIOS_TOOLS_TEST_ROOT="$TEST_ROOT" \
        MINIOS_TOOLS_TEST_MOUNTINFO="$TEST_MOUNTINFO" \
        MINIOS_TOOLS_TEST_CMDLINE="$TEST_CMDLINE" \
        MINIOS_TOOLS_TEST_BOOT_ID="$TEST_BOOT_ID" \
        MINIOS_TOOLS_TEST_AUFS_SYSFS="$TEST_AUFS_SYSFS" \
        NO_COLOR=1 \
        "$SAVECHANGES" --aufs-branches "$manifest" \
        --inventory-json "$OUTPUT_DIR/insecure-aufs-ng.json" "$CHANGES"

    [ "$status" -ne 0 ]
    [[ $output == *"insecure AUFS branch inventory"* ]]
    [ ! -e "$OUTPUT_DIR/insecure-aufs-ng.json" ]
}

@test "AUFS branch inventory is opened after acquiring the shared lock" {
    manifest="$TEST_ROOT/locked-aufs-ng-branches"
    lock="$TEST_ROOT/aufs-branches.lock"
    result="$OUTPUT_DIR/locked-aufs-ng.json"
    log="$TEST_ROOT/locked-aufs-ng.log"
    printf '%s=rw\n%s=rr+wh\n' /stale/changes /lower/00-core.sb >"$manifest"
    chmod 0600 "$manifest"
    printf '24 1 0:1 / / rw - aufs aufs rw,si=ng\n' >"$TEST_MOUNTINFO"
    exec 9>"$lock"
    flock -x 9

    env \
        PATH="$STUBS:$SYSTEM_PATH" \
        TMPDIR="$TMP_ROOT" \
        MINIOS_TOOLS_TEST_ALLOW_NON_ROOT=1 \
        MINIOS_TOOLS_TEST_ROOT="$TEST_ROOT" \
        MINIOS_TOOLS_TEST_MOUNTINFO="$TEST_MOUNTINFO" \
        MINIOS_TOOLS_TEST_CMDLINE="$TEST_CMDLINE" \
        MINIOS_TOOLS_TEST_BOOT_ID="$TEST_BOOT_ID" \
        MINIOS_TOOLS_TEST_AUFS_SYSFS="$TEST_AUFS_SYSFS" \
        NO_COLOR=1 \
        "$SAVECHANGES" --aufs-branches "$manifest" --inventory-json "$result" "$CHANGES" \
        >"$log" 2>&1 &
    capture_pid=$!
    sleep 0.2
    printf '%s=rw\n%s=rr+wh\n' "$CHANGES" /lower/00-core.sb >"$manifest.new"
    chmod 0600 "$manifest.new"
    mv -f "$manifest.new" "$manifest"
    flock -u 9
    exec 9>&-

    wait "$capture_pid"
    run python3 -I -c 'import json,sys; value=json.load(open(sys.argv[1])); assert value["union_backend"] == "aufs"' \
        "$result"
    [ "$status" -eq 0 ]
}

@test "explicit mounted root binds a wrapper upperdir without accepting the system root" {
    mounted_root="$TEST_ROOT/wrapper union"
    mkdir -p "$mounted_root"
    escaped_root=${mounted_root// /\\040}
    escaped_changes=${CHANGES// /\\040}
    printf '24 1 0:1 / %s rw - overlay overlay rw,lowerdir=/lower/00-core.sb,upperdir=%s,workdir=/work\n' \
        "$escaped_root" "$escaped_changes" >"$TEST_MOUNTINFO"

    run env \
        PATH="$STUBS:$SYSTEM_PATH" \
        TMPDIR="$TMP_ROOT" \
        MINIOS_TOOLS_TEST_ALLOW_NON_ROOT=1 \
        MINIOS_TOOLS_TEST_ROOT="$TEST_ROOT" \
        MINIOS_TOOLS_TEST_MOUNTINFO="$TEST_MOUNTINFO" \
        MINIOS_TOOLS_TEST_CMDLINE="$TEST_CMDLINE" \
        MINIOS_TOOLS_TEST_BOOT_ID="$TEST_BOOT_ID" \
        MINIOS_TOOLS_TEST_AUFS_SYSFS="$TEST_AUFS_SYSFS" \
        NO_COLOR=1 \
        "$SAVECHANGES" --mounted-root "$mounted_root" \
        --inventory-json "$OUTPUT_DIR/wrapper-inventory.json" "$CHANGES"
    [ "$status" -eq 0 ]
    run python3 -I -c 'import json,sys; assert json.load(open(sys.argv[1]))["union_backend"] == "overlayfs"' \
        "$OUTPUT_DIR/wrapper-inventory.json"
    [ "$status" -eq 0 ]
}

@test "same-device nested mount paths are omitted using mountinfo authority" {
    write_file "$CHANGES/usr/share/kept" kept
    write_file "$CHANGES/usr/share/nested/private" private
    prepare_union_fixture overlayfs "$CHANGES"
    escaped_nested=${CHANGES// /\\040}/usr/share/nested
    printf '25 24 0:1 /bound %s rw - ext4 /dev/test rw\n' "$escaped_nested" >>"$TEST_MOUNTINFO"
    state="$TEST_ROOT/nested mount state"

    run env PATH="$STUBS:$SYSTEM_PATH" TMPDIR="$TMP_ROOT" \
        MINIOS_TOOLS_TEST_ALLOW_NON_ROOT=1 MINIOS_TOOLS_TEST_ROOT="$TEST_ROOT" \
        MINIOS_TOOLS_TEST_MOUNTINFO="$TEST_MOUNTINFO" \
        MINIOS_TOOLS_TEST_CMDLINE="$TEST_CMDLINE" \
        MINIOS_TOOLS_TEST_BOOT_ID="$TEST_BOOT_ID" \
        MINIOS_TOOLS_TEST_MKSQUASHFS="$TEST_MKSQUASHFS" \
        MINIOS_TOOLS_TEST_UNSQUASHFS="$TEST_UNSQUASHFS" \
        MKSQUASHFS_STATE="$state" NO_COLOR=1 \
        "$SAVECHANGES" --profile exact "$OUTPUT_DIR/nested-mount.sb" "$CHANGES"

    [ "$status" -eq 0 ]
    [ -f "$state/tree/usr/share/kept" ]
    [ ! -e "$state/tree/usr/share/nested" ]
}

@test "real-session OverlayFS context xattrs are discarded for exact and clean" {
    fixture="$CHANGES/usr/share/overlay-xattr-fixture"
    mkdir -p "$fixture"
    if ! python3 -I -c '
import os, sys
root = os.fsencode(sys.argv[1])
changes = os.fsencode(sys.argv[2])
origin = bytes.fromhex("00fb1d00010000000000000000000000") + b"o" * 13
os.setxattr(changes, b"user.overlay.uuid", bytes.fromhex("cd22b0f11163434f94e64bb0d188e575"))
os.setxattr(changes, b"user.overlay.impure", b"y")
for index in range(106):
    path = os.path.join(root, ("entry-%03d" % index).encode())
    os.mkdir(path)
    os.setxattr(path, b"user.overlay.origin", origin)
    if index < 54:
        os.setxattr(path, b"user.overlay.impure", b"y")
    if index < 8:
        os.setxattr(path, b"user.overlay.opaque", b"y")
' "$fixture" "$CHANGES"; then
        skip 'user OverlayFS fixture xattrs are unavailable'
    fi

    exact_state="$TEST_ROOT/vm xattr exact state"
    run_module "$OUTPUT_DIR/vm-xattr-exact.sb" "$exact_state" --profile exact
    [ "$status" -eq 0 ]
    assert_output_contains 'Unsafe or non-allowlisted xattrs omitted: 162'
    run python3 -I -c '
import os, sys
root = os.fsencode(sys.argv[1])
routine = {"user.overlay.origin", "user.overlay.impure", "user.overlay.uuid"}
opaque = 0
for current, directories, files in os.walk(root):
    for path in [current] + [os.path.join(current, item) for item in files]:
        names = set(os.listxattr(path, follow_symlinks=False))
        assert not names.intersection(routine)
        opaque += "user.overlay.opaque" in names
assert opaque == 8, opaque
' "$exact_state/tree"
    [ "$status" -eq 0 ]

    clean_state="$TEST_ROOT/vm xattr clean state"
    run_module "$OUTPUT_DIR/vm-xattr-clean.sb" "$clean_state" --profile clean
    [ "$status" -eq 0 ]
    assert_output_contains 'Unsafe or non-allowlisted xattrs omitted: 162'
    run python3 -I -c '
import os, sys
root = os.fsencode(sys.argv[1])
routine = {"user.overlay.origin", "user.overlay.impure", "user.overlay.uuid"}
opaque = 0
for current, directories, files in os.walk(root):
    names = set(os.listxattr(current, follow_symlinks=False))
    assert not names.intersection(routine)
    opaque += "user.overlay.opaque" in names
assert opaque == 8, opaque
' "$clean_state/tree"
    [ "$status" -eq 0 ]
}

@test "aufs-ng copy-up origin xattr is discarded for exact capture" {
    [ "$EUID" -eq 0 ] || skip 'trusted aufs-ng xattrs require root'
    source_file="$CHANGES/etc/default/copied-up"
    write_file "$source_file" changed
    python3 -I -c 'import os,sys; os.setxattr(sys.argv[1], b"trusted.aufs_ng.origin", b"origin")' \
        "$source_file" || skip 'trusted aufs-ng xattrs are unavailable'
    state="$TEST_ROOT/aufs-ng xattr state"

    SAVECHANGES_TEST_UNION=aufs run_module "$OUTPUT_DIR/aufs-ng-xattr.sb" "$state" --profile exact

    [ "$status" -eq 0 ]
    run python3 -I -c 'import os,sys; assert "trusted.aufs_ng.origin" not in os.listxattr(sys.argv[1])' \
        "$state/tree/etc/default/copied-up"
    [ "$status" -eq 0 ]
}

@test "dependency-bearing and unknown OverlayFS xattrs fail closed including root metadata" {
    write_file "$CHANGES/usr/share/session-app/value" value
    if ! python3 -I -c 'import os,sys; os.setxattr(sys.argv[1], b"user.overlay.redirect", b"target")' "$CHANGES"; then
        skip 'user OverlayFS fixture xattrs are unavailable'
    fi

    run_module "$OUTPUT_DIR/redirect.sb" "$TEST_ROOT/redirect state" --profile exact
    [ "$status" -ne 0 ]
    assert_output_contains 'dependency-bearing union xattr'
    python3 -I -c 'import os,sys; os.removexattr(sys.argv[1], b"user.overlay.redirect")' "$CHANGES"

    local attribute
    for attribute in metacopy index future-semantics; do
        python3 -I -c 'import os,sys; os.setxattr(sys.argv[1], os.fsencode("user.overlay." + sys.argv[2]), b"y")' \
            "$CHANGES/usr/share/session-app/value" "$attribute"
        run_module "$OUTPUT_DIR/$attribute.sb" "$TEST_ROOT/$attribute state" --profile clean
        [ "$status" -ne 0 ]
        if [[ $attribute == future-semantics ]]; then
            assert_output_contains 'unknown union xattr'
        else
            assert_output_contains 'dependency-bearing union xattr'
        fi
        python3 -I -c 'import os,sys; os.removexattr(sys.argv[1], os.fsencode("user.overlay." + sys.argv[2]))' \
            "$CHANGES/usr/share/session-app/value" "$attribute"
    done
}

@test "exact capture fails when xattr authority is permission denied" {
    write_file "$CHANGES/usr/bin/value" value

    SAVECHANGES_TEST_XATTR_EPERM=1 run_module "$OUTPUT_DIR/xattr-eperm.sb" \
        "$TEST_ROOT/xattr eperm state" --profile exact

    [ "$status" -ne 0 ]
    assert_output_contains 'cannot verify OverlayFS opacity metadata'
    [ ! -e "$OUTPUT_DIR/xattr-eperm.sb" ]
}

@test "exact capture verifies staging metadata after successful syscalls" {
    write_file "$CHANGES/usr/bin/value" value
    chmod 0755 "$CHANGES"

    SAVECHANGES_TEST_METADATA_NOOP=1 run_module "$OUTPUT_DIR/metadata-noop.sb" \
        "$TEST_ROOT/metadata noop state" --profile exact

    [ "$status" -ne 0 ]
    assert_output_contains 'staging filesystem did not preserve required metadata'
    [ ! -e "$OUTPUT_DIR/metadata-noop.sb" ]
}

@test "child-only selected opacity keeps unrelated lower siblings visible on replay" {
    lower="$TEST_ROOT/lower tree"
    write_file "$lower/etc/opaque/kept" lower-kept
    write_file "$lower/etc/opaque/unselected" lower-unselected
    write_file "$CHANGES/etc/opaque/kept" upper-kept
    if ! python3 -I -c 'import os,sys; os.setxattr(sys.argv[1], b"user.overlay.opaque", b"y")' \
        "$CHANGES/etc/opaque"; then
        skip 'user OverlayFS opacity xattr is unavailable'
    fi

    write_file "$SELECTION" '{"product_kind":"minios-session-selection","schema_version":1,"include_paths":["etc/opaque/kept"],"exclude_paths":[]}'
    child_state="$TEST_ROOT/child opacity state"
    run_module "$OUTPUT_DIR/child-opacity.sb" "$child_state" \
        --profile selected --selection "$SELECTION"
    [ "$status" -eq 0 ]
    run python3 -I -c 'import os,sys; assert "user.overlay.opaque" not in os.listxattr(sys.argv[1])' \
        "$child_state/tree/etc/opaque"
    [ "$status" -eq 0 ]

    replay="$TEST_ROOT/child replay"
    run python3 -I -c '
import os, shutil, sys
lower, upper, replay = sys.argv[1:]
shutil.copytree(lower, replay)
opaque = "user.overlay.opaque" in os.listxattr(os.path.join(upper, "etc/opaque"))
if opaque:
    shutil.rmtree(os.path.join(replay, "etc/opaque"))
for current, directories, files in os.walk(upper):
    relative = os.path.relpath(current, upper)
    target = replay if relative == "." else os.path.join(replay, relative)
    os.makedirs(target, exist_ok=True)
    for name in files:
        shutil.copy2(os.path.join(current, name), os.path.join(target, name))
assert open(os.path.join(replay, "etc/opaque/kept")).read().strip() == "upper-kept"
assert open(os.path.join(replay, "etc/opaque/unselected")).read().strip() == "lower-unselected"
' "$lower" "$child_state/tree" "$replay"
    [ "$status" -eq 0 ]

    write_file "$SELECTION" '{"product_kind":"minios-session-selection","schema_version":1,"include_paths":["etc/opaque"],"exclude_paths":[]}'
    directory_state="$TEST_ROOT/directory opacity state"
    run_module "$OUTPUT_DIR/directory-opacity.sb" "$directory_state" \
        --profile selected --selection "$SELECTION"
    [ "$status" -eq 0 ]
    run python3 -I -c 'import os,sys; assert os.getxattr(sys.argv[1], b"user.overlay.opaque") == b"y"' \
        "$directory_state/tree/etc/opaque"
    [ "$status" -eq 0 ]
}

@test "profile xattr policy preserves required overlay opacity and strips clean extras" {
    regular="$CHANGES/usr/bin/session-tool"
    opaque_directory="$CHANGES/usr/share/session-app"
    write_file "$regular" software
    write_file "$opaque_directory/keep" keep
    write_file "$opaque_directory/private/value" private
    if ! python3 -I -c 'import os,sys; os.setxattr(sys.argv[1], b"user.capture-test", b"private-value"); os.setxattr(sys.argv[2], b"user.overlay.opaque", b"y")' \
        "$regular" "$opaque_directory"; then
        skip 'user xattrs are unavailable on the test filesystem'
    fi

    exact_state="$TEST_ROOT/exact xattr state"
    run_module "$OUTPUT_DIR/exact-xattr.sb" "$exact_state" --profile exact
    [ "$status" -eq 0 ]
    run python3 -I -c 'import os,sys; assert os.getxattr(sys.argv[1], b"user.capture-test") == b"private-value"; assert os.getxattr(sys.argv[2], b"user.overlay.opaque") == b"y"' \
        "$exact_state/tree/usr/bin/session-tool" "$exact_state/tree/usr/share/session-app"
    [ "$status" -eq 0 ]

    clean_state="$TEST_ROOT/clean xattr state"
    run_module "$OUTPUT_DIR/clean-xattr.sb" "$clean_state" --profile clean
    [ "$status" -eq 0 ]
    assert_output_contains 'Unsafe or non-allowlisted xattrs omitted'
    run python3 -I -c 'import os,sys; assert "user.capture-test" not in os.listxattr(sys.argv[1]); assert os.getxattr(sys.argv[2], b"user.overlay.opaque") == b"y"' \
        "$clean_state/tree/usr/bin/session-tool" "$clean_state/tree/usr/share/session-app"
    [ "$status" -eq 0 ]

    write_file "$SELECTION" '{"product_kind":"minios-session-selection","schema_version":1,"include_paths":["usr/share/session-app/keep"],"exclude_paths":["usr/share/session-app/private"]}'
    selected_state="$TEST_ROOT/selected xattr state"
    run_module "$OUTPUT_DIR/selected-xattr.sb" "$selected_state" \
        --profile selected --selection "$SELECTION"
    [ "$status" -eq 0 ]
    run python3 -I -c 'import os,sys; assert "user.overlay.opaque" not in os.listxattr(sys.argv[1])' \
        "$selected_state/tree/usr/share/session-app"
    [ "$status" -eq 0 ]
}

@test "OverlayFS character whiteouts are retained when device creation is available" {
    (( EUID == 0 )) || skip 'character-device whiteouts require root'
    mkdir -p "$CHANGES/etc"
    mknod "$CHANGES/etc/.wh.deleted" c 0 0 || skip 'the test filesystem disallows device nodes'
    ln "$CHANGES/etc/.wh.deleted" "$CHANGES/etc/.wh.removed" ||
        skip 'hard-linked character whiteouts are unavailable'
    python3 -I -c 'import os,sys; os.setxattr(sys.argv[1], b"user.capture-test", b"whiteout")' \
        "$CHANGES/etc/.wh.deleted" || skip 'whiteout xattrs are unavailable'

    state="$TEST_ROOT/overlay whiteout state"
    run_module "$OUTPUT_DIR/overlay-whiteout.sb" "$state" --profile exact
    [ "$status" -eq 0 ]
    [ -c "$state/tree/etc/.wh.deleted" ]
    [ -c "$state/tree/etc/.wh.removed" ]
    [ "$(stat -c '%t:%T' "$state/tree/etc/.wh.deleted")" = '0:0' ]
    [ "$(stat -c '%t:%T' "$state/tree/etc/.wh.removed")" = '0:0' ]
    [ "$(stat -c '%h' "$state/tree/etc/.wh.deleted")" = 1 ]
    [ "$(stat -c '%h' "$state/tree/etc/.wh.removed")" = 1 ]
    run python3 -I -c 'import os,sys; assert os.getxattr(sys.argv[1], b"user.capture-test") == b"whiteout"' \
        "$state/tree/etc/.wh.deleted"
    [ "$status" -eq 0 ]

    SAVECHANGES_TEST_UNION=unknown run_module \
        "$OUTPUT_DIR/ambiguous-whiteout.sb" "$TEST_ROOT/ambiguous whiteout state" --profile exact
    [ "$status" -ne 0 ]
    assert_output_contains 'union whiteout cannot be represented safely'
}

@test "retained source and destination descriptors defeat ancestor replacement" {
    write_file "$CHANGES/etc/default/value" original
    prepare_union_fixture overlayfs "$CHANGES"
    input_target="$OUTPUT_DIR/input-ancestor.sb"
    input_state="$TEST_ROOT/input ancestor state"
    input_barrier="$TEST_ROOT/input ancestor barrier"
    input_log="$TEST_ROOT/input ancestor.log"
    env \
        PATH="$STUBS:$SYSTEM_PATH" \
        TMPDIR="$TMP_ROOT" \
        MINIOS_TOOLS_TEST_ALLOW_NON_ROOT=1 \
        MINIOS_TOOLS_TEST_ROOT="$TEST_ROOT" \
        MINIOS_TOOLS_TEST_MOUNTINFO="$TEST_MOUNTINFO" \
        MINIOS_TOOLS_TEST_CMDLINE="$TEST_CMDLINE" \
        MINIOS_TOOLS_TEST_BOOT_ID="$TEST_BOOT_ID" \
        MINIOS_TOOLS_TEST_MKSQUASHFS="$TEST_MKSQUASHFS" \
        MINIOS_TOOLS_TEST_UNSQUASHFS="$TEST_UNSQUASHFS" \
        MKSQUASHFS_STATE="$input_state" \
        SAVECHANGES_TEST_PAUSE_BEFORE_COPY="$input_barrier" \
        NO_COLOR=1 \
        "$SAVECHANGES" --profile exact "$input_target" "$CHANGES" >"$input_log" 2>&1 &
    script_pid=$!
    for _ in {1..200}; do
        [[ -e $input_barrier.ready ]] && break
        sleep 0.05
    done
    [ -e "$input_barrier.ready" ]
    attacker_changes="$TEST_ROOT/attacker changes"
    write_file "$attacker_changes/etc/default/value" attacker
    mv -- "$CHANGES" "$CHANGES.moved"
    ln -s -- "$attacker_changes" "$CHANGES"
    : >"$input_barrier.continue"
    result=0
    wait "$script_pid" || result=$?
    [ "$result" -eq 0 ]
    [ "$(<"$input_state/tree/etc/default/value")" = original ]
    [ -s "$input_target" ]
    rm -- "$CHANGES"
    mv -- "$CHANGES.moved" "$CHANGES"

    output_target="$OUTPUT_DIR/output-ancestor.sb"
    output_state="$TEST_ROOT/output ancestor state"
    output_barrier="$TEST_ROOT/output ancestor barrier"
    output_log="$TEST_ROOT/output ancestor.log"
    env \
        PATH="$STUBS:$SYSTEM_PATH" \
        TMPDIR="$TMP_ROOT" \
        MINIOS_TOOLS_TEST_ALLOW_NON_ROOT=1 \
        MINIOS_TOOLS_TEST_ROOT="$TEST_ROOT" \
        MINIOS_TOOLS_TEST_MOUNTINFO="$TEST_MOUNTINFO" \
        MINIOS_TOOLS_TEST_CMDLINE="$TEST_CMDLINE" \
        MINIOS_TOOLS_TEST_BOOT_ID="$TEST_BOOT_ID" \
        MINIOS_TOOLS_TEST_MKSQUASHFS="$TEST_MKSQUASHFS" \
        MINIOS_TOOLS_TEST_UNSQUASHFS="$TEST_UNSQUASHFS" \
        MKSQUASHFS_STATE="$output_state" \
        SAVECHANGES_TEST_PAUSE_BEFORE_COPY="$output_barrier" \
        NO_COLOR=1 \
        "$SAVECHANGES" --profile exact "$output_target" "$CHANGES" >"$output_log" 2>&1 &
    script_pid=$!
    for _ in {1..200}; do
        [[ -e $output_barrier.ready ]] && break
        sleep 0.05
    done
    [ -e "$output_barrier.ready" ]
    output_victim="$TEST_ROOT/output victim"
    mkdir -p "$output_victim"
    write_file "$output_victim/sentinel" untouched
    mv -- "$OUTPUT_DIR" "$OUTPUT_DIR.moved"
    ln -s -- "$output_victim" "$OUTPUT_DIR"
    : >"$output_barrier.continue"
    result=0
    wait "$script_pid" || result=$?
    [ "$result" -ne 0 ]
    [ "$(<"$output_victim/sentinel")" = untouched ]
    [ ! -e "$output_victim/output-ancestor.sb" ]
    [ ! -e "$OUTPUT_DIR.moved/output-ancestor.sb" ]
}

@test "inventory is strict metadata-only JSON with profile defaults" {
    secret_content='PASSWORD-CONTENT-DO-NOT-LEAK username-from-content'
    symlink_target='/outside/SYMLINK-TARGET-DO-NOT-LEAK'
    write_file "$CHANGES/etc/default/app" defaults
    write_file "$CHANGES/home/live/secret.txt" "$secret_content"
    write_file "$CHANGES/var/log/session.log" log
    write_file "$CHANGES/etc/machine-id" identity
    write_file "$CHANGES/run/live/runtime" runtime
    ln -s "$symlink_target" "$CHANGES/etc/default/link"
    inventory="$OUTPUT_DIR/inventory.json"

    run_inventory "$inventory"
    [ "$status" -eq 0 ]
    inventory_log=$output
    [ "$(stat -c '%a' "$inventory")" = 600 ]
    [[ $(<"$inventory") != *"$secret_content"* ]]
    [[ $(<"$inventory") != *"$symlink_target"* ]]

    run python3 -c '
import json, os, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    value = json.load(stream)
assert value["product_kind"] == "minios-session-inventory"
assert value["schema_version"] == 2
assert len(value["source_fingerprint"]) == 64
assert value["union_backend"] == "overlayfs"
assert "changes_root" not in value
entries = {item["path"]: item for item in value["entries"]}
assert entries["etc/default/app"]["type"] == "regular"
assert entries["etc/default/app"]["size"] == os.path.getsize(os.path.join(sys.argv[2], "etc/default/app"))
assert entries["etc/default/app"]["default_clean"] is False
assert entries["home/live/secret.txt"]["category"] == "user-data"
assert entries["home/live/secret.txt"]["sensitive"] is True
assert entries["home/live/secret.txt"]["default_exact"] is True
assert entries["home/live/secret.txt"]["default_clean"] is False
assert entries["var/log/session.log"]["category"] == "logs-cache"
assert entries["etc/machine-id"]["category"] == "machine-identity"
assert entries["run/live/runtime"]["default_exact"] is False
assert entries["etc/default/link"]["type"] == "symlink"
assert "size" not in entries["etc/default/link"]
' "$inventory" "$CHANGES"
    [ "$status" -eq 0 ]
    [[ $inventory_log == *'P:capture-inventory'* ]]
    [[ $inventory_log == *'P:capture-complete'* ]]
    [[ $inventory_log != *'P:capture-copy'* ]]
    [[ $inventory_log != *'P:capture-compress'* ]]
}

@test "module capture emits all stable phases and validates the published image" {
    write_file "$CHANGES/usr/bin/value" value
    run_module "$OUTPUT_DIR/phases.sb" "$TEST_ROOT/phases state" --profile clean --no-color

    [ "$status" -eq 0 ]
    for phase_id in capture-inventory capture-copy capture-compress capture-complete; do
        assert_output_contains "P:$phase_id"
    done
    [[ $output != *$'\e['* ]]
    [ -s "$OUTPUT_DIR/phases.sb" ]
}

@test "human mode suppresses compressor stdout when quiet is unavailable" {
    write_file "$CHANGES/etc/default/value" value

    MKSQUASHFS_NO_QUIET=true run_module "$OUTPUT_DIR/no-quiet.sb" \
        "$TEST_ROOT/no-quiet state" --profile exact

    [ "$status" -eq 0 ]
    [[ $output != *'mksquashfs child stdout'* ]]
    assert_output_contains 'P:capture-complete'
}

@test "json mode emits pure NDJSON phases and a complete capture result" {
    write_file "$CHANGES/usr/bin/value" value
    write_file "$CHANGES/etc/default/config" config-data
    target="$OUTPUT_DIR/result.sb"
    events="$TEST_ROOT/events.ndjson"
    diagnostics="$TEST_ROOT/diagnostics.log"
    prepare_union_fixture overlayfs "$CHANGES"

    set +e
    env \
        PATH="$STUBS:$SYSTEM_PATH" \
        TMPDIR="$TMP_ROOT" \
        MINIOS_TOOLS_TEST_ALLOW_NON_ROOT=1 \
        MINIOS_TOOLS_TEST_ROOT="$TEST_ROOT" \
        MINIOS_TOOLS_TEST_MOUNTINFO="$TEST_MOUNTINFO" \
        MINIOS_TOOLS_TEST_CMDLINE="$TEST_CMDLINE" \
        MINIOS_TOOLS_TEST_BOOT_ID="$TEST_BOOT_ID" \
        MINIOS_TOOLS_TEST_MKSQUASHFS="$TEST_MKSQUASHFS" \
        MINIOS_TOOLS_TEST_UNSQUASHFS="$TEST_UNSQUASHFS" \
        MKSQUASHFS_STATE="$TEST_ROOT/json state" \
        NO_COLOR=1 \
        "$SAVECHANGES" --json --profile exact "$target" "$CHANGES" \
        >"$events" 2>"$diagnostics"
    result=$?
    set -e

    [ "$result" -eq 0 ]
    [ -s "$target" ]
    run grep -Eq '^[PIWE]:' "$events"
    [ "$status" -ne 0 ]
    grep -Fq 'I: Capture profile/backend/entries:' "$diagnostics"
    run python3 -c '
import hashlib, json, os, sys
events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert [event["phase"] for event in events if event["type"] == "phase"] == [
    "prepare", "inventory", "capture", "compress", "verify", "publish", "complete"]
result = events[-1]
assert result["type"] == "result"
assert result["product_kind"] == "minios-tool-result"
assert result["schema_version"] == 1
assert result["tool"] == "savechanges"
assert result["operation"] == "capture-module"
assert result["output"] == sys.argv[2]
assert result["compressed_size"] == os.path.getsize(sys.argv[2])
assert result["uncompressed_size"] == sum(
    os.path.getsize(path) for path in sys.argv[3:])
assert result["entry_count"] == 6
footprint = result["extraction_footprint"]
assert footprint["product_kind"] == "minios-extraction-footprint"
assert footprint["schema_version"] == 1
assert footprint["compressor"] == "zstd"
assert footprint["block_size"] == 1024 * 1024
assert footprint["regular_file_bytes"] == result["uncompressed_size"]
assert footprint["regular_file_inodes"] == 2
assert footprint["directory_count"] == 5
assert footprint["symlink_count"] == 0
assert footprint["whiteout_count"] == 0
assert footprint["inode_count"] == 7
assert footprint["directory_entry_count"] == result["entry_count"]
assert footprint["hardlink_reference_count"] == 0
assert result["sha256"] == hashlib.sha256(open(sys.argv[2], "rb").read()).hexdigest()
assert result["profile"] == "exact"
assert result["union_backend"] == "overlayfs"
assert result["output_identity"]["device"] >= 0
assert result["output_identity"]["inode"] > 0
' "$events" "$target" "$CHANGES/usr/bin/value" "$CHANGES/etc/default/config"
    [ "$status" -eq 0 ]
}

@test "work parent is validated used and cleaned" {
    write_file "$CHANGES/etc/default/value" value
    work_parent="$TEST_ROOT/capture work"
    mkdir "$work_parent"
    chmod 0700 "$work_parent"

    SAVECHANGES_TEST_TMPDIR="$TEST_ROOT/missing default tmp" \
        run_module "$OUTPUT_DIR/work-parent.sb" "$TEST_ROOT/work-parent state" \
        --profile exact --work-parent "$work_parent"

    [ "$status" -eq 0 ]
    shopt -s nullglob dotglob
    leftovers=("$work_parent"/*)
    [ "${#leftovers[@]}" -eq 0 ]

    run_module "$OUTPUT_DIR/outside-work-parent.sb" "$TEST_ROOT/outside state" \
        --profile exact --work-parent /tmp
    [ "$status" -ne 0 ]
    assert_output_contains 'Test work parent is outside the test root'
    [ ! -e "$OUTPUT_DIR/outside-work-parent.sb" ]

    ln -s "$work_parent" "$TEST_ROOT/work-parent-link"
    run_module "$OUTPUT_DIR/symlink-work-parent.sb" "$TEST_ROOT/symlink state" \
        --profile exact --work-parent "$TEST_ROOT/work-parent-link"
    [ "$status" -ne 0 ]
    [ ! -e "$OUTPUT_DIR/symlink-work-parent.sb" ]

    run_module "$OUTPUT_DIR/inside-work-parent.sb" "$TEST_ROOT/inside state" \
        --profile exact --work-parent "$CHANGES"
    [ "$status" -ne 0 ]
    assert_output_contains 'work parent must be outside the changes root'
    [ ! -e "$OUTPUT_DIR/inside-work-parent.sb" ]
}

@test "same-filesystem preflight accounts for staging module and publication together" {
    available=$(python3 -I -c 'import os,sys; value=os.statvfs(sys.argv[1]); print(value.f_bavail * value.f_frsize)' "$TEST_ROOT")
    (( available > 128 * 1024 * 1024 )) || skip 'test filesystem has insufficient free space for the bound test'
    sparse_size=$(( (available - 32 * 1024 * 1024) / 3 ))
    mkdir -p "$CHANGES/usr/share"
    truncate -s "$sparse_size" "$CHANGES/usr/share/sparse-value"
    target="$OUTPUT_DIR/shared-space.sb"

    run_module "$target" "$TEST_ROOT/shared-space state" --profile exact

    [ "$status" -ne 0 ]
    assert_output_contains 'insufficient shared staging and destination space'
    [ ! -e "$target" ]
}

@test "capture metadata includes session transaction sizing fields" {
    write_file "$CHANGES/etc/default/value" metadata-value
    target="$OUTPUT_DIR/metadata.sb"
    metadata="$OUTPUT_DIR/metadata.json"

    run_module "$target" "$TEST_ROOT/metadata state" \
        --profile exact --metadata-json "$metadata"

    [ "$status" -eq 0 ]
    run python3 -c '
import json, os, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
module = value["module"]
assert module["size"] == os.path.getsize(sys.argv[2])
assert module["entry_count"] == 3
assert module["uncompressed_size"] == os.path.getsize(sys.argv[3])
assert module["extraction_footprint"]["schema_version"] == 1
assert module["extraction_footprint"]["regular_file_bytes"] == module["uncompressed_size"]
' "$metadata" "$target" "$CHANGES/etc/default/value"
    [ "$status" -eq 0 ]
}

@test "extraction footprint counts hardlinks symlinks and empty directories" {
    mkdir -p "$CHANGES/data/empty"
    write_file "$CHANGES/data/file" payload-data
    ln "$CHANGES/data/file" "$CHANGES/data/hardlink"
    ln -s file "$CHANGES/data/link"
    target="$OUTPUT_DIR/footprint.sb"
    metadata="$OUTPUT_DIR/footprint.json"

    run_module "$target" "$TEST_ROOT/footprint state" \
        --profile exact --metadata-json "$metadata"

    [ "$status" -eq 0 ]
    run python3 -c '
import json, os, sys
module = json.load(open(sys.argv[1], encoding="utf-8"))["module"]
footprint = module["extraction_footprint"]
assert module["entry_count"] == 5
assert module["uncompressed_size"] == os.path.getsize(sys.argv[2])
assert footprint["regular_file_bytes"] == module["uncompressed_size"]
assert footprint["regular_file_inodes"] == 1
assert footprint["directory_count"] == 3
assert footprint["symlink_count"] == 1
assert footprint["symlink_target_bytes"] == len("file")
assert footprint["whiteout_count"] == 0
assert footprint["inode_count"] == 5
assert footprint["directory_entry_count"] == 5
assert footprint["hardlink_reference_count"] == 1
' "$metadata" "$CHANGES/data/file"
    [ "$status" -eq 0 ]
}

@test "AUFS whiteouts are semantic and hardlinked xattrs count once in the footprint" {
    mkdir -p "$CHANGES/data"
    write_file "$CHANGES/data/file" payload-data
    ln "$CHANGES/data/file" "$CHANGES/data/hardlink"
    touch "$CHANGES/data/.wh.deleted"
    if ! python3 -I -c 'import os,sys; os.setxattr(sys.argv[1], b"user.capture-test", b"value")' \
        "$CHANGES/data/file"; then
        skip 'user xattrs are unavailable on the test filesystem'
    fi
    metadata="$OUTPUT_DIR/aufs-footprint.json"

    SAVECHANGES_TEST_UNION=aufs run_module "$OUTPUT_DIR/aufs-footprint.sb" \
        "$TEST_ROOT/aufs footprint state" --profile exact --metadata-json "$metadata"

    [ "$status" -eq 0 ]
    run python3 -c '
import json, sys
footprint = json.load(open(sys.argv[1], encoding="utf-8"))["module"]["extraction_footprint"]
assert footprint["regular_file_bytes"] == len("payload-data\n")
assert footprint["regular_file_inodes"] == 1
assert footprint["directory_count"] == 2
assert footprint["whiteout_count"] == 1
assert footprint["inode_count"] == 4
assert footprint["directory_entry_count"] == 4
assert footprint["hardlink_reference_count"] == 1
assert footprint["xattr_count"] == 1
assert footprint["xattr_name_bytes"] == len("user.capture-test")
assert footprint["xattr_value_bytes"] == len("value")
' "$metadata"
    [ "$status" -eq 0 ]
}

@test "AUFS shared whiteout inode is accepted only with the complete root anchor set" {
    mkdir -p "$CHANGES/data" "$CHANGES/other"
    : >"$CHANGES/.wh..wh.aufs"
    ln "$CHANGES/.wh..wh.aufs" "$CHANGES/data/.wh.deleted"
    ln "$CHANGES/.wh..wh.aufs" "$CHANGES/other/.wh.removed"

    SAVECHANGES_TEST_UNION=aufs run_module "$OUTPUT_DIR/linked-aufs.sb" \
        "$TEST_ROOT/linked aufs state" --profile exact
    [ "$status" -eq 0 ]

    rm -f "$CHANGES/.wh..wh.aufs"
    SAVECHANGES_TEST_UNION=aufs run_module "$OUTPUT_DIR/unanchored-aufs.sb" \
        "$TEST_ROOT/unanchored aufs state" --profile exact
    [ "$status" -ne 0 ]
    assert_output_contains 'invalid AUFS whiteout representation'
    [ ! -e "$OUTPUT_DIR/unanchored-aufs.sb" ]
}

@test "malformed AUFS whiteout representations fail closed" {
    mkdir -p "$CHANGES/data"
    write_file "$CHANGES/data/.wh.deleted" unexpected-payload

    SAVECHANGES_TEST_UNION=aufs run_module "$OUTPUT_DIR/malformed-aufs.sb" \
        "$TEST_ROOT/malformed aufs state" --profile exact

    [ "$status" -ne 0 ]
    assert_output_contains 'invalid AUFS whiteout representation'
    [ ! -e "$OUTPUT_DIR/malformed-aufs.sb" ]

    local invalid
    for invalid in .wh. .wh.. .wh... .wh..wh.future; do
        rm -f "$CHANGES/data/.wh.deleted"
        : >"$CHANGES/data/$invalid"
        SAVECHANGES_TEST_UNION=aufs run_module "$OUTPUT_DIR/invalid-target-$invalid.sb" \
            "$TEST_ROOT/invalid target $invalid state" --profile exact
        [ "$status" -ne 0 ]
        assert_output_contains 'invalid AUFS whiteout target'
        [ ! -e "$OUTPUT_DIR/invalid-target-$invalid.sb" ]
        rm -f "$CHANGES/data/$invalid"
    done
}

@test "AUFS base fingerprint contains only mounted read-only branches" {
    write_file "$CHANGES/etc/value" value
    running_source="$TEST_ROOT/running source/minios"
    write_file "$running_source/00-core.sb" replaced-source-core
    write_file "$running_source/01-extra.sb" unmounted-extra
    mounted_backing="$TEST_ROOT/mounted backing/00-core.sb"
    write_file "$mounted_backing" mounted-core
    metadata="$OUTPUT_DIR/aufs-binding.json"

    MINIOS_TOOLS_TEST_RUNNING_SOURCE="$running_source" \
        SAVECHANGES_TEST_LOWER_BACKING="$mounted_backing" \
        SAVECHANGES_TEST_UNION=aufs run_module "$OUTPUT_DIR/aufs-binding.sb" \
        "$TEST_ROOT/aufs binding state" --profile exact --metadata-json "$metadata"

    [ "$status" -eq 0 ]
    run python3 -c '
import hashlib, json, os, sys
metadata_path, module_path = sys.argv[1:]
name = os.path.basename(module_path).encode()
size = os.path.getsize(module_path)
module_digest = hashlib.sha256(open(module_path, "rb").read()).hexdigest()
digest = hashlib.sha256()
digest.update(b"minios-base-modules-v2\0")
digest.update(name + b"\0" + str(size).encode() + b"\0" +
              module_digest.encode() + b"\0")
assert json.load(open(metadata_path, encoding="utf-8"))["base_module_fingerprint"] == digest.hexdigest()
' "$metadata" "$mounted_backing"
    [ "$status" -eq 0 ]

}

@test "base fingerprint ignores numbered SquashFS session snapshots" {
    write_file "$CHANGES/etc/value" value
    running_source="$TEST_ROOT/running source/minios"
    write_file "$running_source/00-core.sb" source-core
    write_file "$running_source/changes/1/changes.sb" session-one
    write_file "$running_source/changes/2/changes.sb" session-two
    mounted_backing="$TEST_ROOT/mounted backing/00-core.sb"
    write_file "$mounted_backing" mounted-core

    MINIOS_TOOLS_TEST_RUNNING_SOURCE="$running_source" \
        SAVECHANGES_TEST_LOWER_BACKING="$mounted_backing" \
        SAVECHANGES_TEST_UNION=aufs run_module "$OUTPUT_DIR/session-snapshots.sb" \
        "$TEST_ROOT/session snapshot state" --profile exact

    [ "$status" -eq 0 ]
    [ -s "$OUTPUT_DIR/session-snapshots.sb" ]
}

@test "base fingerprint matches branch aliases and custom extensions" {
    write_file "$CHANGES/etc/value" value
    running_source="$TEST_ROOT/running source/minios"
    write_file "$running_source/00-core.mymod" running-core
    mounted_backing="$TEST_ROOT/mounted backing/00-core.mymod"
    write_file "$mounted_backing" mounted-core
    metadata="$OUTPUT_DIR/aliased-binding.json"
    escaped_changes=${CHANGES// /\\040}
    escaped_backing=${mounted_backing// /\\040}
    printf '24 1 0:1 / / rw - overlay overlay rw,lowerdir=/memory/bundles/00-core.mymod,upperdir=%s,workdir=/work\n' \
        "$escaped_changes" >"$TEST_MOUNTINFO"
    printf '25 24 0:2 / /run/initramfs/memory/bundles/00-core.mymod ro - squashfs %s ro\n' \
        "$escaped_backing" >>"$TEST_MOUNTINFO"

    state="$TEST_ROOT/aliased binding state"
    run env \
        PATH="$STUBS:$SYSTEM_PATH" \
        TMPDIR="$TMP_ROOT" \
        MINIOS_TOOLS_TEST_ALLOW_NON_ROOT=1 \
        MINIOS_TOOLS_TEST_ROOT="$TEST_ROOT" \
        MINIOS_TOOLS_TEST_MOUNTINFO="$TEST_MOUNTINFO" \
        MINIOS_TOOLS_TEST_CMDLINE="$TEST_CMDLINE" \
        MINIOS_TOOLS_TEST_BOOT_ID="$TEST_BOOT_ID" \
        MINIOS_TOOLS_TEST_AUFS_SYSFS="$TEST_AUFS_SYSFS" \
        MINIOS_TOOLS_TEST_RUNNING_SOURCE="$running_source" \
        MINIOS_TOOLS_TEST_MKSQUASHFS="$TEST_MKSQUASHFS" \
        MINIOS_TOOLS_TEST_UNSQUASHFS="$TEST_UNSQUASHFS" \
        MKSQUASHFS_STATE="$state" \
        NO_COLOR=1 \
        "$SAVECHANGES" --profile exact --metadata-json "$metadata" \
        "$OUTPUT_DIR/aliased-binding.sb" "$CHANGES"
    [ "$status" -eq 0 ]
    run python3 -c '
import hashlib, json, os, sys
metadata_path, module_path = sys.argv[1:]
name = b"00-core.mymod"
payload = open(module_path, "rb").read()
digest = hashlib.sha256()
digest.update(b"minios-base-modules-v2\0")
digest.update(name + b"\0" + str(len(payload)).encode() + b"\0" +
              hashlib.sha256(payload).hexdigest().encode() + b"\0")
assert json.load(open(metadata_path, encoding="utf-8"))["base_module_fingerprint"] == digest.hexdigest()
' "$metadata" "$mounted_backing"
    [ "$status" -eq 0 ]
}

@test "base fingerprints bind effective mounted branch order" {
    write_file "$CHANGES/etc/value" value
    running_source="$TEST_ROOT/ordered source/minios"
    write_file "$running_source/00-core.sb" core
    write_file "$running_source/01-app.sb" app
    first_metadata="$OUTPUT_DIR/first-order.json"
    second_metadata="$OUTPUT_DIR/second-order.json"

    MINIOS_TOOLS_TEST_RUNNING_SOURCE="$running_source" \
        SAVECHANGES_TEST_LOWER_BRANCHES='/lower/00-core.sb=rr+wh:/lower/01-app.sb=rr+wh' \
        SAVECHANGES_TEST_UNION=aufs run_module "$OUTPUT_DIR/first-order.sb" \
        "$TEST_ROOT/first order state" --profile exact --metadata-json "$first_metadata"
    [ "$status" -eq 0 ]

    MINIOS_TOOLS_TEST_RUNNING_SOURCE="$running_source" \
        SAVECHANGES_TEST_LOWER_BRANCHES='/lower/01-app.sb=rr+wh:/lower/00-core.sb=rr+wh' \
        SAVECHANGES_TEST_UNION=aufs run_module "$OUTPUT_DIR/second-order.sb" \
        "$TEST_ROOT/second order state" --profile exact --metadata-json "$second_metadata"
    [ "$status" -eq 0 ]

    run python3 -c '
import json, sys
first = json.load(open(sys.argv[1], encoding="utf-8"))["base_module_fingerprint"]
second = json.load(open(sys.argv[2], encoding="utf-8"))["base_module_fingerprint"]
assert first != second
' "$first_metadata" "$second_metadata"
    [ "$status" -eq 0 ]
}

@test "json failures and query conflicts emit no result" {
    write_file "$CHANGES/etc/default/value" value
    MKSQUASHFS_FAIL=true run_module "$OUTPUT_DIR/json-failure.sb" \
        "$TEST_ROOT/json failure state" --json --profile exact

    [ "$status" -ne 0 ]
    [[ $output != *'"type":"result"'* ]]
    [ ! -e "$OUTPUT_DIR/json-failure.sb" ]

    query_stdout="$TEST_ROOT/query.stdout"
    query_stderr="$TEST_ROOT/query.stderr"
    set +e
    "$SAVECHANGES" --help --json >"$query_stdout" 2>"$query_stderr"
    result=$?
    set -e
    [ "$result" -ne 0 ]
    [ ! -s "$query_stdout" ]
    grep -Fq -- '--json cannot be combined' "$query_stderr"
}

@test "mksquashfs and SquashFS validation failures never publish output" {
    write_file "$CHANGES/etc/default/value" value
    target="$OUTPUT_DIR/failure.sb"

    MKSQUASHFS_FAIL=true run_module "$target" "$TEST_ROOT/mksquashfs failure state" --profile exact
    [ "$status" -ne 0 ]
    assert_output_contains 'mksquashfs failed'
    [ ! -e "$target" ]

    MKSQUASHFS_FAIL=false
    UNSQUASHFS_FAIL_PATTERN=module.squashfs run_module "$target" "$TEST_ROOT/validation failure state" --profile exact
    [ "$status" -ne 0 ]
    assert_output_contains 'invalid SquashFS superblock'
    [ ! -e "$target" ]
}

@test "cancel marker contract rejects existing insecure symlinked and traversing paths" {
    cancel_parent="$TEST_ROOT/cancel parent secret"
    other_parent="$TEST_ROOT/other cancel parent"
    marker="$cancel_parent/cancel"
    mkdir -p "$cancel_parent" "$other_parent"
    chmod 0700 "$cancel_parent" "$other_parent"

    : >"$marker"
    run_inventory "$OUTPUT_DIR/existing.json" --cancel-file "$marker"
    [ "$status" -ne 0 ]
    assert_output_contains 'cancel marker must not initially exist'
    [[ $output != *"$cancel_parent"* ]]
    rm "$marker"

    chmod 0750 "$cancel_parent"
    run_inventory "$OUTPUT_DIR/insecure.json" --cancel-file "$marker"
    [ "$status" -ne 0 ]
    assert_output_contains 'cancel marker parent must be mode 0700'
    chmod 0700 "$cancel_parent"

    run_inventory "$OUTPUT_DIR/traversal.json" \
        --cancel-file "$cancel_parent/../other cancel parent/cancel"
    [ "$status" -ne 0 ]
    assert_output_contains 'invalid cancel marker path'

    ln -s "$cancel_parent" "$TEST_ROOT/cancel-link"
    run_inventory "$OUTPUT_DIR/symlink.json" --cancel-file "$TEST_ROOT/cancel-link/cancel"
    [ "$status" -ne 0 ]
    assert_output_contains 'invalid cancel marker parent'
    [ ! -e "$OUTPUT_DIR/existing.json" ]
    [ ! -e "$OUTPUT_DIR/insecure.json" ]
    [ ! -e "$OUTPUT_DIR/traversal.json" ]
    [ ! -e "$OUTPUT_DIR/symlink.json" ]
}

@test "cancel marker kills a leader-exit tool group and removes private output" {
    write_file "$CHANGES/etc/default/value" value
    target="$OUTPUT_DIR/cancelled.sb"
    cancel_parent="$TEST_ROOT/cancel directory"
    cancel_file="$cancel_parent/cancel"
    started="$TEST_ROOT/leader-exit.started"
    log="$TEST_ROOT/savechanges.cancel.log"
    mkdir "$cancel_parent"
    chmod 0700 "$cancel_parent"
    prepare_union_fixture overlayfs "$CHANGES"

    set +e
    env \
        PATH="$STUBS:$SYSTEM_PATH" \
        TMPDIR="$TMP_ROOT" \
        MINIOS_TOOLS_TEST_ALLOW_NON_ROOT=1 \
        MINIOS_TOOLS_TEST_ROOT="$TEST_ROOT" \
        MINIOS_TOOLS_TEST_MOUNTINFO="$TEST_MOUNTINFO" \
        MINIOS_TOOLS_TEST_CMDLINE="$TEST_CMDLINE" \
        MINIOS_TOOLS_TEST_BOOT_ID="$TEST_BOOT_ID" \
        MINIOS_TOOLS_TEST_MKSQUASHFS="$TEST_MKSQUASHFS" \
        MINIOS_TOOLS_TEST_UNSQUASHFS="$TEST_UNSQUASHFS" \
        MKSQUASHFS_STATE="$TEST_ROOT/cancel state" \
        MKSQUASHFS_SLEEP=true \
        MKSQUASHFS_SLEEP_MARKER="$started" \
        MKSQUASHFS_LEADER_EXIT=true \
        NO_COLOR=1 \
        "$SAVECHANGES" --profile exact --cancel-file "$cancel_file" \
        "$target" "$CHANGES" >"$log" 2>&1 &
    script_pid=$!
    for _ in {1..200}; do
        [[ -e $started ]] && break
        sleep 0.02
    done
    [ -e "$started" ]
    mapfile -t child_pids <"$started"
    [ "${#child_pids[@]}" -eq 2 ]
    for _ in {1..100}; do
        kill -0 "${child_pids[0]}" 2>/dev/null || break
        sleep 0.01
    done
    ! kill -0 "${child_pids[0]}" 2>/dev/null
    : >"$cancel_file"
    result=0
    wait "$script_pid" || result=$?
    set -e

    [ "$result" -eq 130 ]
    grep -Fqx 'P:cancelled' "$log"
    [[ $(<"$log") != *"$cancel_parent"* ]]
    for child_pid in "${child_pids[@]}"; do
        assert_process_gone "$child_pid"
    done
    [ ! -e "$target" ]
    shopt -s nullglob dotglob
    leftovers=("$TMP_ROOT"/*)
    [ "${#leftovers[@]}" -eq 0 ]
}

@test "cancel marker interrupts privileged in-process copy work" {
    write_file "$CHANGES/etc/default/value" value
    target="$OUTPUT_DIR/cancelled-copy.sb"
    cancel_parent="$TEST_ROOT/copy cancel directory"
    cancel_file="$cancel_parent/cancel"
    pause_marker="$TEST_ROOT/copy pause"
    log="$TEST_ROOT/savechanges.copy-cancel.log"
    mkdir "$cancel_parent"
    chmod 0700 "$cancel_parent"
    prepare_union_fixture overlayfs "$CHANGES"

    set +e
    env \
        PATH="$STUBS:$SYSTEM_PATH" \
        TMPDIR="$TMP_ROOT" \
        MINIOS_TOOLS_TEST_ALLOW_NON_ROOT=1 \
        MINIOS_TOOLS_TEST_ROOT="$TEST_ROOT" \
        MINIOS_TOOLS_TEST_MOUNTINFO="$TEST_MOUNTINFO" \
        MINIOS_TOOLS_TEST_CMDLINE="$TEST_CMDLINE" \
        MINIOS_TOOLS_TEST_BOOT_ID="$TEST_BOOT_ID" \
        MINIOS_TOOLS_TEST_MKSQUASHFS="$TEST_MKSQUASHFS" \
        MINIOS_TOOLS_TEST_UNSQUASHFS="$TEST_UNSQUASHFS" \
        SAVECHANGES_TEST_PAUSE_BEFORE_COPY="$pause_marker" \
        NO_COLOR=1 \
        "$SAVECHANGES" --profile exact --cancel-file "$cancel_file" \
        "$target" "$CHANGES" >"$log" 2>&1 &
    script_pid=$!
    for _ in {1..200}; do
        [[ -e $pause_marker.ready ]] && break
        sleep 0.02
    done
    [ -e "$pause_marker.ready" ]
    : >"$cancel_file"
    result=0
    wait "$script_pid" || result=$?
    set -e

    [ "$result" -eq 130 ]
    grep -Fqx 'P:capture-copy' "$log"
    grep -Fqx 'P:cancelled' "$log"
    [ ! -e "$target" ]
    shopt -s nullglob dotglob
    leftovers=("$TMP_ROOT"/*)
    [ "${#leftovers[@]}" -eq 0 ]
}

@test "replacing the retained cancel parent fails closed and stops active child tools" {
    write_file "$CHANGES/etc/default/value" value
    target="$OUTPUT_DIR/cancel-parent-race.sb"
    cancel_parent="$TEST_ROOT/raced cancel parent"
    cancel_file="$cancel_parent/cancel"
    started="$TEST_ROOT/raced-parent.started"
    log="$TEST_ROOT/savechanges.cancel-parent.log"
    mkdir "$cancel_parent"
    chmod 0700 "$cancel_parent"
    prepare_union_fixture overlayfs "$CHANGES"

    set +e
    env \
        PATH="$STUBS:$SYSTEM_PATH" \
        TMPDIR="$TMP_ROOT" \
        MINIOS_TOOLS_TEST_ALLOW_NON_ROOT=1 \
        MINIOS_TOOLS_TEST_ROOT="$TEST_ROOT" \
        MINIOS_TOOLS_TEST_MOUNTINFO="$TEST_MOUNTINFO" \
        MINIOS_TOOLS_TEST_CMDLINE="$TEST_CMDLINE" \
        MINIOS_TOOLS_TEST_BOOT_ID="$TEST_BOOT_ID" \
        MINIOS_TOOLS_TEST_MKSQUASHFS="$TEST_MKSQUASHFS" \
        MINIOS_TOOLS_TEST_UNSQUASHFS="$TEST_UNSQUASHFS" \
        MKSQUASHFS_STATE="$TEST_ROOT/raced parent state" \
        MKSQUASHFS_SLEEP=true \
        MKSQUASHFS_SLEEP_MARKER="$started" \
        NO_COLOR=1 \
        "$SAVECHANGES" --profile exact --cancel-file "$cancel_file" \
        "$target" "$CHANGES" >"$log" 2>&1 &
    script_pid=$!
    for _ in {1..200}; do
        [[ -e $started ]] && break
        sleep 0.02
    done
    [ -e "$started" ]
    child_pid=$(<"$started")
    mv "$cancel_parent" "$cancel_parent.moved"
    mkdir "$cancel_parent"
    chmod 0700 "$cancel_parent"
    result=0
    wait "$script_pid" || result=$?
    set -e

    [ "$result" -eq 130 ]
    grep -Fqx 'P:cancelled' "$log"
    assert_process_gone "$child_pid"
    [ ! -e "$target" ]
    shopt -s nullglob dotglob
    leftovers=("$TMP_ROOT"/*)
    [ "${#leftovers[@]}" -eq 0 ]
}

@test "an unprivileged inventory caller cancels a root helper only through its marker" {
    (( EUID != 0 )) || skip 'requires an unprivileged parent'
    command -v sudo >/dev/null 2>&1 || skip 'sudo is unavailable'
    sudo -n true >/dev/null 2>&1 || skip 'passwordless sudo is unavailable'
    changes="$TEST_ROOT/root boundary changes"
    cancel_parent="$TEST_ROOT/root boundary cancel"
    cancel_file="$cancel_parent/cancel"
    target="$OUTPUT_DIR/root-boundary.json"
    log="$TEST_ROOT/root-boundary.log"
    wrong_parent="$TEST_ROOT/root-owned cancel"
    mkdir -p "$changes" "$cancel_parent" "$wrong_parent"
    chmod 0700 "$cancel_parent"
    chmod 0700 "$wrong_parent"
    sudo -n chown 0:0 "$wrong_parent"
    run sudo -n env PKEXEC_UID="$EUID" "$SAVECHANGES" --no-color \
        --cancel-file "$wrong_parent/cancel" --inventory-json \
        "$OUTPUT_DIR/wrong-owner.json" "$changes"
    [ "$status" -ne 0 ]
    assert_output_contains 'owned by the original user'
    [ ! -e "$OUTPUT_DIR/wrong-owner.json" ]
    sudo -n chown "$EUID:$(id -g)" "$wrong_parent"
    python3 -c '
import os, sys
root = sys.argv[1]
for index in range(20000):
    path = os.path.join(root, "entry-{:05d}".format(index))
    open(path, "wb").close()
' "$changes"

    set +e
    sudo -n env PKEXEC_UID="$EUID" "$SAVECHANGES" --no-color \
        --cancel-file "$cancel_file" --inventory-json "$target" "$changes" \
        >"$log" 2>&1 &
    root_pid=$!
    for _ in {1..500}; do
        grep -Fqx 'P:capture-inventory' "$log" 2>/dev/null && break
        sleep 0.01
    done
    grep -Fqx 'P:capture-inventory' "$log"
    [ "$(stat -c '%u' "/proc/$root_pid")" -eq 0 ]
    if kill -TERM "$root_pid" 2>/dev/null; then
        false
    fi
    : >"$cancel_file"
    result=0
    wait "$root_pid" || result=$?
    set -e

    [ "$result" -eq 130 ]
    grep -Fqx 'P:cancelled' "$log"
    assert_process_gone "$root_pid"
    [ ! -e "$target" ]
    [[ $(<"$log") != *"$cancel_parent"* ]]
}

@test "TERM escalates for a stubborn mksquashfs and removes private and partial output" {
    write_file "$CHANGES/etc/default/value" value
    target="$OUTPUT_DIR/interrupted.sb"
    marker="$TEST_ROOT/mksquashfs.started"
    log="$TEST_ROOT/savechanges.signal.log"
    prepare_union_fixture overlayfs "$CHANGES"

    set +e
    env \
        PATH="$STUBS:$SYSTEM_PATH" \
        TMPDIR="$TMP_ROOT" \
        MINIOS_TOOLS_TEST_ALLOW_NON_ROOT=1 \
        MINIOS_TOOLS_TEST_ROOT="$TEST_ROOT" \
        MINIOS_TOOLS_TEST_MOUNTINFO="$TEST_MOUNTINFO" \
        MINIOS_TOOLS_TEST_CMDLINE="$TEST_CMDLINE" \
        MINIOS_TOOLS_TEST_BOOT_ID="$TEST_BOOT_ID" \
        MINIOS_TOOLS_TEST_MKSQUASHFS="$TEST_MKSQUASHFS" \
        MINIOS_TOOLS_TEST_UNSQUASHFS="$TEST_UNSQUASHFS" \
        MKSQUASHFS_STATE="$TEST_ROOT/signal state" \
        MKSQUASHFS_SLEEP=true \
        MKSQUASHFS_SLEEP_MARKER="$marker" \
        MKSQUASHFS_STUBBORN=true \
        NO_COLOR=1 \
        "$SAVECHANGES" --profile exact "$target" "$CHANGES" >"$log" 2>&1 &
    script_pid=$!
    for _ in {1..100}; do
        [[ -e $marker ]] && break
        sleep 0.05
    done
    [ -e "$marker" ]
    mapfile -t child_pids <"$marker"
    [ "${#child_pids[@]}" -eq 2 ]
    shopt -s nullglob
    active_temp_dirs=("$TMP_ROOT"/savechanges.*)
    [ "${#active_temp_dirs[@]}" -eq 1 ]
    [ "$(stat -c '%a' "${active_temp_dirs[0]}")" = 700 ]
    kill -TERM "$script_pid"
    result=0
    wait "$script_pid" || result=$?
    set -e

    [ "$result" -eq 130 ]
    for child_pid in "${child_pids[@]}"; do
        assert_process_gone "$child_pid"
    done
    [ ! -e "$target" ]
    shopt -s nullglob dotglob
    leftovers=("$TMP_ROOT"/*)
    [ "${#leftovers[@]}" -eq 0 ]
}

@test "capture and inventory retain a production root gate" {
    target="$OUTPUT_DIR/root-gate.sb"
    if (( EUID == 0 )); then
        command -v setpriv >/dev/null 2>&1 || skip 'setpriv is unavailable for a non-root EUID check'
        chmod -R a+rX "$TEST_ROOT"
        chmod 0777 "$OUTPUT_DIR" "$TMP_ROOT"
        run setpriv --reuid=65534 --regid=65534 --clear-groups \
            env PATH="$STUBS:$SYSTEM_PATH" TMPDIR="$TMP_ROOT" NO_COLOR=1 \
            "$SAVECHANGES" --profile exact "$target" "$CHANGES"
    else
        run env PATH="$STUBS:$SYSTEM_PATH" TMPDIR="$TMP_ROOT" NO_COLOR=1 \
            "$SAVECHANGES" --profile exact "$target" "$CHANGES"
    fi
    [ "$status" -ne 0 ]
    assert_output_contains 'must be run as root'
    [ ! -e "$target" ]
}

@test "an installed-style script cannot enable source test overrides" {
    installed_root="$TEST_ROOT/installed tree"
    installed_script="$installed_root/bin/savechanges"
    mkdir -p "${installed_script%/*}"
    cp -- "$SAVECHANGES" "$installed_script"
    chmod 0755 "$installed_script"

    run env \
        MINIOS_TOOLS_TEST_ALLOW_NON_ROOT=1 \
        MINIOS_TOOLS_TEST_ROOT="$TEST_ROOT" \
        MINIOS_TOOLS_TEST_MOUNTINFO="$TEST_MOUNTINFO" \
        MINIOS_TOOLS_TEST_CMDLINE="$TEST_CMDLINE" \
        MINIOS_TOOLS_TEST_BOOT_ID="$TEST_BOOT_ID" \
        MINIOS_TOOLS_TEST_MKSQUASHFS="$TEST_MKSQUASHFS" \
        MINIOS_TOOLS_TEST_UNSQUASHFS="$TEST_UNSQUASHFS" \
        "$installed_script" --profile exact "$OUTPUT_DIR/installed.sb" "$CHANGES"
    [ "$status" -ne 0 ]
    assert_output_contains 'must be run as root'
    [ ! -e "$OUTPUT_DIR/installed.sb" ]
}

@test "real SquashFS tools conditionally produce a readable module" {
    command -v mksquashfs >/dev/null 2>&1 || skip 'mksquashfs is not installed'
    command -v unsquashfs >/dev/null 2>&1 || skip 'unsquashfs is not installed'
    write_file "$CHANGES/etc/default/real-value" real-value
    xattr_supported=false
    if python3 -I -c 'import os,sys; os.setxattr(sys.argv[1], b"user.capture-test", b"real-xattr")' \
        "$CHANGES/etc/default/real-value"; then
        xattr_supported=true
    fi
    target="$OUTPUT_DIR/real.sb"
    real_tools="$TEST_ROOT/real tools"
    mkdir -p "$real_tools"
    cp -- "$(command -v mksquashfs)" "$real_tools/mksquashfs"
    cp -- "$(command -v unsquashfs)" "$real_tools/unsquashfs"
    chmod 0755 "$real_tools/mksquashfs" "$real_tools/unsquashfs"
    prepare_union_fixture overlayfs "$CHANGES"

    run env \
        PATH="$SYSTEM_PATH" \
        TMPDIR="$TMP_ROOT" \
        MINIOS_TOOLS_TEST_ALLOW_NON_ROOT=1 \
        MINIOS_TOOLS_TEST_ROOT="$TEST_ROOT" \
        MINIOS_TOOLS_TEST_MOUNTINFO="$TEST_MOUNTINFO" \
        MINIOS_TOOLS_TEST_CMDLINE="$TEST_CMDLINE" \
        MINIOS_TOOLS_TEST_BOOT_ID="$TEST_BOOT_ID" \
        MINIOS_TOOLS_TEST_MKSQUASHFS="$real_tools/mksquashfs" \
        MINIOS_TOOLS_TEST_UNSQUASHFS="$real_tools/unsquashfs" \
        NO_COLOR=1 \
        "$SAVECHANGES" --profile exact "$target" "$CHANGES"
    [ "$status" -eq 0 ]
    [ -s "$target" ]

    run unsquashfs -s "$target"
    [ "$status" -eq 0 ]
    extracted="$TEST_ROOT/real extracted"
    run unsquashfs -d "$extracted" "$target"
    [ "$status" -eq 0 ]
    [ "$(<"$extracted/etc/default/real-value")" = real-value ]
    if [[ $xattr_supported == true ]]; then
        run python3 -I -c 'import os,sys; assert os.getxattr(sys.argv[1], b"user.capture-test") == b"real-xattr"' \
            "$extracted/etc/default/real-value"
        [ "$status" -eq 0 ]
    fi
}
