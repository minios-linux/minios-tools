#!/usr/bin/env bats

setup() {
    SB="$BATS_TEST_DIRNAME/../bin/sb"
    TEST_ROOT="${MINIOS_TOOLS_TEST_TMPDIR:-${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-${TMPDIR:-/tmp}}}}/sb job $BATS_TEST_NUMBER"
    mkdir -p "$TEST_ROOT"
    export MINIOS_AUFS_BRANCH_LOCK="$TEST_ROOT/aufs-branches.lock"
    : >"$MINIOS_AUFS_BRANCH_LOCK"
}

load_sb_functions() {
    local source_file="$TEST_ROOT/sb-functions"
    sed '/^if \[\[ $# -eq 0 \]\]; then$/,$d' "$SB" >"$source_file"
    set --
    # shellcheck disable=SC1090
    source "$source_file"
    protocol_helper_path() {
        printf '%s\n' "$BATS_TEST_DIRNAME/../lib/minios_protocol.py"
    }
    converter_engine_path() {
        printf '%s\n' "$BATS_TEST_DIRNAME/../lib/minios_convert_engine.py"
    }
}

@test "help and version remain rootless queries" {
    run "$SB" help
    [ "$status" -eq 0 ]
    [[ $output == *"Usage:"* ]]

    run "$SB" version
    [ "$status" -eq 0 ]
    [[ $output == "sb 1.0.3" ]]
}
@test "list reaches the read-only live-state path before privilege checks" {
    run "$SB" list --json
    [[ $output != *"This script must be run as root."* ]]
}

@test "JSON list preserves order and delimiter-sensitive paths" {
    load_sb_functions
    root_union_type() { printf '%s\n' aufs; }
    print_branches() {
        [ "$1" = "nul" ] || return 1
        printf '%s\0%s\0' '/run/initramfs/memory/bundles/00 core.sb' '/media/source with space/00 core.sb'
        printf '%s\0%s\0' '/run/initramfs/memory/bundles/01-tab.sb' $'/media/source\twith-tab/01-tab.sb'
        printf '%s\0%s\0' '/run/initramfs/memory/bundles/02-null-source.sb' ''
    }

    run print_branches_json
    [ "$status" -eq 0 ]

    run python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["schema_version"] == 1; assert d["union_backend"] == "aufs"; assert [m["name"] for m in d["modules"]] == ["00 core.sb","01-tab.sb","02-null-source.sb"]; assert d["modules"][1]["source"] == "/media/source\twith-tab/01-tab.sb"; assert d["modules"][2]["source"] is None' "$output"
    [ "$status" -eq 0 ]
}
@test "JSON list publishes no result after producer failure" {
    load_sb_functions
    root_union_type() { printf '%s\n' overlayfs; }
    print_branches() {
        printf '%s\0%s\0' '/run/initramfs/memory/bundles/00-core.sb' '/source/00-core.sb'
        printf '%s\n' 'injected branch failure' >&2
        return 1
    }

    run print_branches_json
    [ "$status" -ne 0 ]
    [[ $output == *"injected branch failure"* ]]
    [[ $output != *'"type":"result"'* ]]
}

@test "runtime mutation gate uses the mounted root instead of kernel support" {
    load_sb_functions
    root_union_type() { printf '%s\n' overlayfs; }

    run aufs_support
    [ "$status" -ne 0 ]
    [[ $output == *"Runtime module changes require an AUFS root"* ]]
}

@test "aufs-ng branch manifest replaces unavailable AUFS sysfs" {
    load_sb_functions
    BUNDLES="$TEST_ROOT/bundles"
    mkdir -p "$BUNDLES/00-core.sb" "$BUNDLES/02-apps.sb"
    AUFS_BRANCH_MANIFEST="$TEST_ROOT/aufs-branches"
    printf '%s=rw\n%s=rr+wh\n%s=rr+wh\n' \
        "$TEST_ROOT/changes" "$BUNDLES/02-apps.sb" "$BUNDLES/00-core.sb" \
        >"$AUFS_BRANCH_MANIFEST"
    root_union_type() { printf '%s\n' aufs; }
    findmnt() {
        case "$*" in
        *'-o OPTIONS'*) printf '%s\n' rw,si=ng ;;
        *) return 0 ;;
        esac
    }
    print_branch_entry() { printf '%s\n' "$1"; }

    run print_branches
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "$BUNDLES/00-core.sb" ]
    [ "${lines[1]}" = "$BUNDLES/02-apps.sb" ]
}

@test "rootless AUFS readers open the runtime lock read-only" {
    load_sb_functions
    AUFS_BRANCH_LOCK="$TEST_ROOT/aufs-branches.lock"
    : >"$AUFS_BRANCH_LOCK"
    chmod 0444 "$AUFS_BRANCH_LOCK"

    aufs_manifest_lock -s

    [ "$AUFS_MANIFEST_LOCKED" = true ]
}

@test "aufs-ng branch manifest tracks dynamic add and remove" {
    load_sb_functions
    AUFS_BRANCH_MANIFEST="$TEST_ROOT/aufs-branches"
    printf '%s\n%s\n' "$TEST_ROOT/changes=rw" "$TEST_ROOT/00-core.sb=rr+wh" \
        >"$AUFS_BRANCH_MANIFEST"

    aufs_manifest_add "$TEST_ROOT/05-extra.sb"
    [ "$(stat -c %a "$AUFS_BRANCH_MANIFEST")" = 644 ]
    [ "$(sed -n '2p' "$AUFS_BRANCH_MANIFEST")" = "$TEST_ROOT/05-extra.sb=rr+wh" ]
    aufs_manifest_remove "$TEST_ROOT/05-extra.sb"
    [ "$(stat -c %a "$AUFS_BRANCH_MANIFEST")" = 644 ]
    ! grep -Fq 05-extra "$AUFS_BRANCH_MANIFEST"
}

@test "aufs-ng manifest matches boot-time branch aliases" {
    load_sb_functions
    AUFS_BRANCH_MANIFEST="$TEST_ROOT/aufs-branches"
    printf '%s\n%s\n' '/memory/changes=rw' '/memory/bundles/05-extra.sb=rr+wh' \
        >"$AUFS_BRANCH_MANIFEST"

    aufs_manifest_remove '/run/initramfs/memory/bundles/05-extra.sb'

    [ "$(wc -l <"$AUFS_BRANCH_MANIFEST")" -eq 1 ]
    ! grep -Fq 05-extra "$AUFS_BRANCH_MANIFEST"
}

@test "aufs-ng branch manifest serializes concurrent additions" {
    load_sb_functions
    source_file="$TEST_ROOT/sb-functions"
    manifest="$TEST_ROOT/concurrent-aufs-branches"
    printf '%s\n%s\n' "$TEST_ROOT/changes=rw" "$TEST_ROOT/00-core.sb=rr+wh" >"$manifest"

    pids=()
    for index in $(seq 1 12); do
        MINIOS_AUFS_BRANCH_MANIFEST="$manifest" bash -c \
            '. "$1"; aufs_manifest_add "$2"' _ "$source_file" "$TEST_ROOT/$index-extra.sb" &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do
        wait "$pid"
    done

    [ "$(wc -l <"$manifest")" -eq 14 ]
    for index in $(seq 1 12); do
        grep -Fqx "$TEST_ROOT/$index-extra.sb=rr+wh" "$manifest"
    done
}

@test "failed aufs-ng inventory update rolls back activation" {
    load_sb_functions
    LIVE="$TEST_ROOT/live"
    BUNDLES="$LIVE/bundles"
    RAMSTORE="$LIVE/modules"
    AUFS_BRANCH_MANIFEST="$TEST_ROOT/missing-aufs-branches"
    module="$TEST_ROOT/05-extra.sb"
    log="$TEST_ROOT/mount.log"
    mkdir -p "$BUNDLES"
    : >"$module"
    df() { printf '%s\n' '/dev/test 1 1 1 1% /'; }
    print_branches() { return 0; }
    mount() { printf '%s\n' "$*" >>"$log"; return 0; }
    umount() { return 0; }
    aufs_sysfs_available() { return 1; }

    run activate "$module"

    [ "$status" -ne 0 ]
    [[ $output == *"Cannot update AUFS branch inventory"* ]]
    grep -Fq "remount,del:$BUNDLES/05-extra.sb" "$log"
    [ ! -d "$BUNDLES/05-extra.sb" ]
}

@test "bundle matching follows bext instead of assuming sb" {
    load_sb_functions

    module_name_matches '00-core.mymod' mymod
    ! module_name_matches '00-core.sb' mymod
    ! grep -Fq 'case "$BAS" in *.sb)' "$SB"
}

@test "next-boot collapses source overrides and preserves boot layer order" {
    load_sb_functions
    data="$TEST_ROOT/data/minios"
    mkdir -p "$data/modules/group" "$data/changes/minios/modules"
    : >"$data/config.conf"
    for file in 00-core.mymod 50-dup.mymod; do : >"$data/$file"; done
    : >"$data/modules/group/20-addon.mymod"
    : >"$data/modules/50-dup.mymod"
    : >"$data/changes/minios/modules/50-dup.mymod"
    : >"$data/changes/minios/modules/60-extra.mymod"

    discover_data_root() { printf '%s\n' "$data"; }
    extra_modules_root() { printf '%s\n' "$data/changes/minios/modules"; }
    boot_arg_value() {
        [ "$1" = bext ] && printf '%s\n' mymod
    }

    run print_next_boot json
    [ "$status" -eq 0 ]
    run python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["bundle_extension"] == "mymod"; assert [m["name"] for m in d["modules"]] == ["00-core.mymod","20-addon.mymod","50-dup.mymod","60-extra.mymod"]; assert d["modules"][2]["origin"] == "persistence"' "$output"
    [ "$status" -eq 0 ]
}

@test "next-boot applies the same load and noload filters" {
    load_sb_functions
    data="$TEST_ROOT/data/minios"
    mkdir -p "$data/modules"
    : >"$data/config.conf"
    for file in 00-core.sb 01-kernel.sb 05-apps.sb 06-browser.sb; do : >"$data/$file"; done

    discover_data_root() { printf '%s\n' "$data"; }
    extra_modules_root() { return 1; }
    boot_arg_value() {
        case "$1" in
        load) printf '%s\n' '00-06' ;;
        noload) printf '%s\n' '05,06' ;;
        esac
    }

    run print_next_boot json
    [ "$status" -eq 0 ]
    run python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert [m["name"] for m in d["modules"]] == ["00-core.sb","01-kernel.sb"]' "$output"
    [ "$status" -eq 0 ]
}

@test "next-boot discovery can use a mounted MiniOS tree without invented layouts" {
    load_sb_functions
    LIVE="$TEST_ROOT/no-native-layout"
    target="$TEST_ROOT/mounted media"
    data="$target/minios"
    mkdir -p "$data/boot"
    : >"$data/00-core.sb"
    findmnt() {
        printf '%s\n' "$target"
    }

    run discover_data_root
    [ "$status" -eq 0 ]
    [ "$output" = "$data" ]
}

@test "persistence module source is used only when changes is a mountpoint" {
    load_sb_functions
    data="$TEST_ROOT/data/minios"
    root="$data/changes/minios/modules"
    mkdir -p "$root"

    findmnt() { return 1; }
    run extra_modules_root "$data"
    [ "$status" -ne 0 ]

    findmnt() { return 0; }
    run extra_modules_root "$data"
    [ "$status" -eq 0 ]
    [ "$output" = "$root" ]
}

@test "next-boot JSON publishes no result after candidate failure" {
    load_sb_functions
    data="$TEST_ROOT/data/minios"
    mkdir -p "$data/boot"
    : >"$data/00-core.sb"
    discover_data_root() { printf '%s\n' "$data"; }
    next_boot_candidates() {
        printf '%s\0%s\0' "$data/00-core.sb" base
        printf '%s\n' 'injected next-boot failure' >&2
        return 1
    }

    run print_next_boot json
    [ "$status" -ne 0 ]
    [[ $output == *"injected next-boot failure"* ]]
    [[ $output != *'"type":"result"'* ]]
}

@test "inspect protocol accepts only the legacy unsquashfs 4.3 preamble" {
    helper="$BATS_TEST_DIRNAME/../lib/minios_protocol.py"
    listing="$TEST_ROOT/legacy-listing"
    printf '%s\n' \
        'Parallel unsquashfs: Using 4 processors' \
        '2 inodes (1 blocks) to write' \
        '' \
        '__MINIOS_INSPECT__' \
        '__MINIOS_INSPECT__/etc' >"$listing"
    run python3 -I "$helper" sb-inspect json /tmp/example.sb 123 __MINIOS_INSPECT__ "$listing"
    [ "$status" -eq 0 ]
    [[ $output == *'"entries":["etc"]'* ]]

    sed -i '1s/.*/unexpected preamble/' "$listing"
    run python3 -I "$helper" sb-inspect json /tmp/example.sb 123 __MINIOS_INSPECT__ "$listing"
    [ "$status" -ne 0 ]
}

@test "inspect is rootless and returns a versioned module listing" {
    tree="$TEST_ROOT/inspect tree"
    module="$TEST_ROOT/inspect module.sb"
    mkdir -p "$tree/etc" "$tree/empty"
    printf '%s\n' value >"$tree/etc/example.conf"
    mksquashfs "$tree" "$module" -noappend >/dev/null

    run "$SB" inspect "$module" --json
    [ "$status" -eq 0 ]
    run python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["operation"] == "inspect"; assert d["schema_version"] == 1; assert d["path"] == sys.argv[2]; assert d["size"] > 0; assert d["entry_count"] == len(d["entries"]); assert d["entries"] == ["empty","etc","etc/example.conf"]' "$output" "$module"
    [ "$status" -eq 0 ]
}

@test "inspect human mode lists relative module paths" {
    tree="$TEST_ROOT/human tree"
    module="$TEST_ROOT/human module.sb"
    mkdir -p "$tree/usr/bin"
    printf '%s\n' tool >"$tree/usr/bin/example"
    mksquashfs "$tree" "$module" -noappend >/dev/null

    run "$SB" inspect "$module"
    [ "$status" -eq 0 ]
    [ "$output" = $'usr\nusr/bin\nusr/bin/example' ]
}

@test "inspect publishes no JSON for an invalid module" {
    module="$TEST_ROOT/invalid module.sb"
    stdout_file="$TEST_ROOT/invalid.stdout"
    stderr_file="$TEST_ROOT/invalid.stderr"
    printf '%s\n' not-squashfs >"$module"

    set +e
    "$SB" inspect "$module" --json >"$stdout_file" 2>"$stderr_file"
    result=$?
    set -e
    [ "$result" -ne 0 ]
    [ ! -s "$stdout_file" ]
    [ -s "$stderr_file" ]
}

@test "inspect rejects a line-ambiguous unsquashfs listing" {
    tree="$TEST_ROOT/odd tree"
    module="$TEST_ROOT/odd module.sb"
    stdout_file="$TEST_ROOT/odd.stdout"
    mkdir -p "$tree"
    printf '%s\n' value >"$tree/"$'line\nbreak'
    mksquashfs "$tree" "$module" -noappend >/dev/null

    set +e
    "$SB" inspect "$module" --json >"$stdout_file" 2>/dev/null
    result=$?
    set -e
    [ "$result" -ne 0 ]
    [ ! -s "$stdout_file" ]
}

@test "next-boot reports add availability and per-module removability" {
    load_sb_functions
    data="$TEST_ROOT/data/minios"
    mkdir -p "$data/modules"
    : >"$data/config.conf"
    : >"$data/00-core.sb"
    : >"$data/modules/50-user.sb"

    discover_data_root() { printf '%s\n' "$data"; }
    boot_arg_value() { return 1; }
    findmnt() { return 1; }
    storage_path_is_durable_writable() { [ "$1" = "$data" ]; }

    run print_next_boot json
    [ "$status" -eq 0 ]
    run python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["add_available"] is True; m={x["name"]:x for x in d["modules"]}; assert m["00-core.sb"]["removable"] is False; assert m["50-user.sb"]["removable"] is True' "$output"
    [ "$status" -eq 0 ]
}

@test "next-boot add prefers a durable separate persistence store" {
    load_sb_functions
    data="$TEST_ROOT/data/minios"
    mkdir -p "$data/changes"
    findmnt() { return 0; }
    storage_path_is_durable_writable() { return 0; }

    run next_boot_add_target "$data"
    [ "$status" -eq 0 ]
    [ "$output" = "$data/changes/minios/modules" ]
}

@test "module copy publishes atomically and never replaces an existing target" {
    load_sb_functions
    tree="$TEST_ROOT/copy tree"
    source_module="$TEST_ROOT/source.sb"
    target_dir="$TEST_ROOT/target"
    mkdir -p "$tree" "$target_dir"
    printf '%s\n' original >"$tree/file"
    mksquashfs "$tree" "$source_module" -noappend >/dev/null
    converter_engine_path() {
        printf '%s\n' "$BATS_TEST_DIRNAME/../lib/minios_convert_engine.py"
    }

    publish_module_copy "$source_module" "$target_dir" 50-user.sb
    cmp "$source_module" "$target_dir/50-user.sb"
    before=$(sha256sum "$target_dir/50-user.sb" | awk '{print $1}')

    run publish_module_copy "$source_module" "$target_dir" 50-user.sb
    [ "$status" -ne 0 ]
    after=$(sha256sum "$target_dir/50-user.sb" | awk '{print $1}')
    [ "$before" = "$after" ]
    [ -z "$(find "$target_dir" -maxdepth 1 -name '.minios-module-*.tmp' -print -quit)" ]
}

@test "next-boot add rejects a module excluded by boot filters" {
    load_sb_functions
    data="$TEST_ROOT/data/minios"
    tree="$TEST_ROOT/filter tree"
    module="$TEST_ROOT/50-blocked.sb"
    mkdir -p "$data/boot" "$tree"
    printf '%s\n' value >"$tree/file"
    mksquashfs "$tree" "$module" -noappend >/dev/null
    discover_data_root() { printf '%s\n' "$data"; }
    boot_arg_value() { [ "$1" = noload ] && printf '%s\n' '50-blocked'; }
    next_boot_add_target() { printf '%s\n' "$data/modules"; }

    run next_boot_add json "$module"
    [ "$status" -ne 0 ]
    [[ $output == *"excluded by the current load/noload"* ]]
    [ ! -e "$data/modules/50-blocked.sb" ]
}

@test "next-boot add publishes a valid module to the selected store" {
    load_sb_functions
    data="$TEST_ROOT/data/minios"
    tree="$TEST_ROOT/add tree"
    module="$TEST_ROOT/50-user.sb"
    mkdir -p "$data/boot" "$tree"
    printf '%s\n' value >"$tree/file"
    mksquashfs "$tree" "$module" -noappend >/dev/null
    discover_data_root() { printf '%s\n' "$data"; }
    boot_arg_value() { return 1; }
    next_boot_add_target() { printf '%s\n' "$data/modules"; }
    converter_engine_path() {
        printf '%s\n' "$BATS_TEST_DIRNAME/../lib/minios_convert_engine.py"
    }

    run next_boot_add json "$module"
    [ "$status" -eq 0 ]
    [ -f "$data/modules/50-user.sb" ]
    cmp "$module" "$data/modules/50-user.sb"
    run python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["operation"] == "next-boot-add"; assert d["name"] == "50-user.sb"; assert d["path"].endswith("/modules/50-user.sb")' "$output"
    [ "$status" -eq 0 ]
}

@test "next-boot remove deletes a writable user module but refuses base" {
    load_sb_functions
    data="$TEST_ROOT/data/minios"
    mkdir -p "$data/modules"
    : >"$data/config.conf"
    : >"$data/00-core.sb"
    : >"$data/modules/50-user.sb"
    discover_data_root() { printf '%s\n' "$data"; }
    boot_arg_value() { return 1; }
    findmnt() { return 1; }
    storage_path_is_durable_writable() { [ "$1" = "$data" ]; }
    converter_engine_path() {
        printf '%s\n' "$BATS_TEST_DIRNAME/../lib/minios_convert_engine.py"
    }

    run next_boot_remove json 50-user.sb
    [ "$status" -eq 0 ]
    [ ! -e "$data/modules/50-user.sb" ]
    run python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["operation"] == "next-boot-remove"; assert d["name"] == "50-user.sb"' "$output"
    [ "$status" -eq 0 ]

    run next_boot_remove json 00-core.sb
    [ "$status" -ne 0 ]
    [[ $output == *"read-only in the next-boot composition"* ]]
    [ -f "$data/00-core.sb" ]
}

@test "module copy validates the staged bytes before publication" {
    load_sb_functions
    source_file="$TEST_ROOT/not-squashfs.sb"
    target_dir="$TEST_ROOT/invalid-target"
    mkdir -p "$target_dir"
    printf '%s\n' invalid >"$source_file"
    converter_engine_path() {
        printf '%s\n' "$BATS_TEST_DIRNAME/../lib/minios_convert_engine.py"
    }

    run publish_module_copy "$source_file" "$target_dir" 50-invalid.sb
    [ "$status" -ne 0 ]
    [ ! -e "$target_dir/50-invalid.sb" ]
    [ -z "$(find "$target_dir" -maxdepth 1 -name '.minios-module-*.tmp' -print -quit)" ]
}

@test "privileged module path helpers refuse symlinked directory components" {
    load_sb_functions
    root="$TEST_ROOT/root"
    outside="$TEST_ROOT/outside"
    mkdir -p "$root" "$outside/remove"
    ln -s "$outside" "$root/minios"
    printf '%s\n' keep >"$outside/remove/50-user.sb"
    ln -s "$outside/remove" "$root/remove"
    converter_engine_path() {
        printf '%s\n' "$BATS_TEST_DIRNAME/../lib/minios_convert_engine.py"
    }

    run ensure_relative_directory "$root" minios/modules
    [ "$status" -ne 0 ]
    [ ! -e "$outside/modules" ]

    run secure_remove_module "$root/remove/50-user.sb"
    [ "$status" -ne 0 ]
    [ -f "$outside/remove/50-user.sb" ]
}

@test "sb contains no inline Python source" {
    ! grep -Eq -- '-I[[:space:]]+-c|^[[:space:]]*import[[:space:]]+(json|os|sys|pwd|decimal)' "$SB"
}

@test "protocol helper emits a stable phase record" {
    run python3 -I "$BATS_TEST_DIRNAME/../lib/minios_protocol.py" phase prepare
    [ "$status" -eq 0 ]
    [ "$output" = '{"event":"phase","phase":"prepare"}' ]
}

@test "runtime panel restart uses the same stop and restore flow as deactivation" {
    load_sb_functions
    log="$TEST_ROOT/restart-panel.log"

    capture_xfce_panel_context() {
        printf '%s\n' capture >>"$log"
        XFCE_PANEL_RESTART=true
    }
    stop_xfce_panel() { printf '%s\n' stop >>"$log"; }
    restore_xfce_panel() {
        printf '%s\n' restore >>"$log"
        XFCE_PANEL_RESTART=false
    }

    restart_xfce_panel

    [ "$(cat "$log")" = $'capture\nstop\nrestore' ]
}

@test "deactivate validates the active module before touching the desktop panel" {
    load_sb_functions
    BUNDLES="$TEST_ROOT/bundles"
    mkdir -p "$BUNDLES"
    log="$TEST_ROOT/panel.log"

    aufs_manifest_lock() { return 0; }
    print_branches() { return 0; }
    capture_xfce_panel_context() { printf '%s\n' capture >>"$log"; }
    stop_xfce_panel() { printf '%s\n' stop >>"$log"; }

    run deactivate missing.sb

    [ "$status" -ne 0 ]
    [[ $output == *"Can't find active MiniOS bundle missing.sb"* ]]
    [ ! -e "$log" ]
}

@test "deactivate keeps the panel stopped until post-removal refresh completes" {
    load_sb_functions
    BUNDLES="$TEST_ROOT/bundles"
    RAMSTORE="$TEST_ROOT/ramstore"
    AUFS_BRANCH_MANIFEST="$TEST_ROOT/no-manifest"
    mkdir -p "$BUNDLES/test.sb" "$RAMSTORE"
    log="$TEST_ROOT/deactivate.log"
    rmdir_calls=0

    aufs_manifest_lock() { return 0; }
    aufs_manifest_remove() { printf '%s\n' manifest-remove >>"$log"; return 0; }
    capture_xfce_panel_context() { printf '%s\n' capture >>"$log"; XFCE_PANEL_RESTART=true; }
    stop_xfce_panel() { printf '%s\n' stop >>"$log"; }
    restore_xfce_panel() { printf '%s\n' restore >>"$log"; XFCE_PANEL_RESTART=false; }
    rmdir() {
        ((rmdir_calls+=1))
        (( rmdir_calls <= 2 )) && return 1
        command rmdir "$1"
    }
    mount() { printf '%s\n' mount-del >>"$log"; return 0; }
    findmnt() { printf '%s\n' /dev/loop9; }
    backing_file_for_loop() { printf '%s\n' "$TEST_ROOT/source.sb"; }
    umount() { printf '%s\n' umount >>"$log"; return 0; }
    losetup() { return 0; }

    deactivate test.sb

    [ "$XFCE_PANEL_RESTART" = true ]
    [ "$(cat "$log")" = $'capture\nstop\nmanifest-remove\nmount-del\numount' ]
    printf '%s\n' fix-system >>"$log"
    restore_xfce_panel
    trap - EXIT
    [ "$(cat "$log")" = $'capture\nstop\nmanifest-remove\nmount-del\numount\nfix-system\nrestore' ]
}

@test "restored Xfce panel does not inherit the AUFS inventory lock fd" {
    load_sb_functions
    result="$TEST_ROOT/panel-fds"
    fake_setpriv="$TEST_ROOT/setpriv"
    fake_panel="$TEST_ROOT/xfce4-panel"
    cat >"$fake_setpriv" <<'SH'
#!/bin/bash
while [[ $1 == --* ]]; do shift; done
exec "$@"
SH
    cat >"$fake_panel" <<SH
#!/bin/bash
if [ -e /proc/\$\$/fd/9 ]; then printf '%s\n' open; else printf '%s\n' closed; fi >"$result"
printf '%s\n' "\$*" >>"$result"
SH
    chmod +x "$fake_setpriv" "$fake_panel"

    XFCE_PANEL_RESTART=true
    XFCE_PANEL_UID=$(id -u)
    XFCE_PANEL_GID=$(id -g)
    XFCE_PANEL_EXE="$fake_panel"
    XFCE_PANEL_SETPRIV="$fake_setpriv"
    XFCE_PANEL_ENV_BIN=$(command -v env)
    XFCE_PANEL_ENV=("HOME=$TEST_ROOT")
    XFCE_PANEL_ARGS=(--display :42 --sm-client-id test-client)
    exec 9>"$TEST_ROOT/lock"

    restore_xfce_panel
    for _ in $(seq 1 50); do [ -s "$result" ] && break; sleep 0.02; done

    [ "$(sed -n '1p' "$result")" = closed ]
    [ "$(sed -n '2p' "$result")" = '--display :42 --sm-client-id test-client' ]
    exec 9>&-
}

@test "deactivate restores the Xfce panel when AUFS rejects branch removal" {
    load_sb_functions
    BUNDLES="$TEST_ROOT/bundles"
    AUFS_BRANCH_MANIFEST="$TEST_ROOT/no-manifest"
    mkdir -p "$BUNDLES/test.sb"
    log="$TEST_ROOT/deactivate-failure.log"

    aufs_manifest_lock() { return 0; }
    aufs_manifest_remove() { printf '%s\n' manifest-remove >>"$log"; return 0; }
    capture_xfce_panel_context() { printf '%s\n' capture >>"$log"; XFCE_PANEL_RESTART=true; }
    stop_xfce_panel() { printf '%s\n' stop >>"$log"; }
    restore_xfce_panel() { printf '%s\n' restore >>"$log"; XFCE_PANEL_RESTART=false; }
    rmdir() { return 1; }
    mount() { printf '%s\n' mount-rejected >>"$log"; return 1; }

    run deactivate test.sb

    [ "$status" -ne 0 ]
    [[ $output == *"still in use"* ]]
    [ "$(cat "$log")" = $'capture\nstop\nmanifest-remove\nmount-rejected\nrestore' ]
}
