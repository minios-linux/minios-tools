#!/usr/bin/env bats

setup() {
    BIN="$BATS_TEST_DIRNAME/../bin"
    BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-${TMPDIR:-/tmp}}/build-wrappers-$BATS_TEST_NUMBER}"
    mkdir -p "$BATS_TEST_TMPDIR"
}

@test "build wrapper version queries are non-destructive" {
    run "$BIN/apt2sb" --version
    [ "$status" -eq 0 ]
    [[ $output == "apt2sb 1.2.4" ]]

    run "$BIN/script2sb" --version
    [ "$status" -eq 0 ]
    [[ $output == "script2sb 1.2.5" ]]

    run "$BIN/chroot2sb" --version
    [ "$status" -eq 0 ]
    [[ $output == "chroot2sb 1.0.4" ]]
}

@test "apt target release requires a value and install command" {
    run "$BIN/apt2sb" upgrade --target-release bionic
    [ "$status" -eq 1 ]
    [[ $output == *"valid only for install"* ]]

    run "$BIN/apt2sb" install --target-release
    [ "$status" -eq 1 ]
    [[ $output == *"requires an argument"* ]]
}

@test "wrapper sources propagate inner failures" {
    run grep -F 'Package operation failed; no module was created.' "$BIN/apt2sb"
    [ "$status" -eq 0 ]
    run grep -F 'Installation script failed; no module was created.' "$BIN/script2sb"
    [ "$status" -eq 0 ]
    run grep -F 'Chroot command failed; no module was created.' "$BIN/chroot2sb"
    [ "$status" -eq 0 ]
}

@test "build wrappers bind savechanges to their temporary mounted union" {
    local tool
    for tool in apt2sb script2sb chroot2sb; do
        run grep -F 'savechanges --mounted-root "$UNION"' "$BIN/$tool"
        [ "$status" -eq 0 ]
    done
}

@test "savechanges selects the inner standard OverlayFS changes directory" {
    run grep -F '[[ -d $candidate/changes && -d $candidate/workdir ]]' "$BIN/savechanges"
    [ "$status" -eq 0 ]
    run grep -F 'printf '\''%s\n'\'' "$candidate/changes"' "$BIN/savechanges"
    [ "$status" -eq 0 ]
}

@test "directory seeds keep legacy copy and use safe machine copy" {
    run grep -F 'run_convert_engine copy-tree "$DIRECTORY" "$UNION"' "$BIN/script2sb"
    [ "$status" -eq 0 ]
    run grep -F 'cp -a "$DIRECTORY"/. "$UNION/"' "$BIN/script2sb"
    [ "$status" -eq 0 ]
    run grep -F 'cp -a "$DIRECTORY"/. "$UNION/"' "$BIN/chroot2sb"
    [ "$status" -eq 0 ]
}

@test "unexpected wrapper operands fail instead of looping" {
    run timeout 2 "$BIN/script2sb" unexpected
    [ "$status" -eq 1 ]
    [[ $output == *"Unexpected argument: unexpected"* ]]

    run timeout 2 "$BIN/chroot2sb" unexpected
    [ "$status" -eq 1 ]
    [[ $output == *"Unexpected argument: unexpected"* ]]
}

@test "wrapper options reject missing values" {
    local tool option
    for tool in apt2sb script2sb chroot2sb; do
        for option in --name --level --comp --bext; do
            if [[ $tool == apt2sb ]]; then
                run "$BIN/$tool" install "$option"
            else
                run "$BIN/$tool" "$option"
            fi
            [ "$status" -eq 1 ]
            [[ $output == *"requires an argument"* ]]
        done
    done

    run "$BIN/script2sb" --script
    [ "$status" -eq 1 ]
    [[ $output == *"requires an argument"* ]]
}

@test "root build commands refuse unsupported live sessions early" {
    (( EUID == 0 )) || skip "requires root"
    [ ! -d /run/initramfs/memory/bundles ] || skip "running in a livekit MiniOS session"
    [ ! -d /lib/live/mount/bundles ] || skip "running in a live MiniOS session"

    local install_script="$BATS_TEST_TMPDIR/install.sh"
    printf '#!/bin/sh\nexit 0\n' >"$install_script"

    run "$BIN/apt2sb" install bash
    [ "$status" -eq 1 ]
    [[ $output == *"requires a supported MiniOS live session"* ]]

    run "$BIN/script2sb" --script "$install_script"
    [ "$status" -eq 1 ]
    [[ $output == *"requires a supported MiniOS live session"* ]]

    run "$BIN/chroot2sb"
    [ "$status" -eq 1 ]
    [[ $output == *"requires a supported MiniOS live session"* ]]
}

@test "apt2sb documents its machine-readable mode" {
    run "$BIN/apt2sb" --help
    [ "$status" -eq 0 ]
    [[ $output == *"--json"* ]]
}

@test "apt2sb JSON preflight failure keeps stdout clean" {
    (( EUID != 0 )) || skip "requires an unprivileged caller"
    stdout_file="$BATS_TEST_TMPDIR/apt2sb.stdout"
    stderr_file="$BATS_TEST_TMPDIR/apt2sb.stderr"
    set +e
    "$BIN/apt2sb" install --json bash >"$stdout_file" 2>"$stderr_file"
    result=$?
    set -e
    [ "$result" -ne 0 ]
    [ ! -s "$stdout_file" ]
    [ -s "$stderr_file" ]
}

@test "protocol helper wraps savechanges as an apt2sb result" {
    helper="$BATS_TEST_DIRNAME/../lib/minios_protocol.py"
    input="$BATS_TEST_TMPDIR/savechanges.ndjson"
    printf '%s\n' \
        '{"event":"phase","phase":"capture"}' \
        '{"type":"result","product_kind":"minios-tool-result","schema_version":1,"tool":"savechanges","operation":"capture-module","output":"/tmp/packages.sb","compressed_size":4096,"uncompressed_size":8192,"entry_count":7,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' \
        >"$input"
    run python3 -I "$helper" apt2sb-result install zstd 2 "$input"
    [ "$status" -eq 0 ]
    run python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["tool"] == "apt2sb"; assert d["operation"] == "install"; assert d["output"] == "/tmp/packages.sb"; assert d["package_count"] == 2; assert d["compressed_size"] == 4096' "$output"
    [ "$status" -eq 0 ]
}

@test "Bash frontends contain no inline Python programs" {
    ! grep -RIE --include='*' -- '-I[[:space:]]+-c|^[[:space:]]*import[[:space:]]+(json|os|sys|pwd|decimal)' "$BIN"
}

@test "script2sb documents its machine-readable mode" {
    run "$BIN/script2sb" --help
    [ "$status" -eq 0 ]
    [[ $output == *"--json"* ]]
}

@test "script2sb JSON preflight failure keeps stdout clean" {
    (( EUID != 0 )) || skip "requires an unprivileged caller"
    install_script="$BATS_TEST_TMPDIR/install-json.sh"
    stdout_file="$BATS_TEST_TMPDIR/script2sb.stdout"
    stderr_file="$BATS_TEST_TMPDIR/script2sb.stderr"
    printf '#!/bin/sh\nexit 0\n' >"$install_script"
    set +e
    "$BIN/script2sb" --json --script "$install_script" >"$stdout_file" 2>"$stderr_file"
    result=$?
    set -e
    [ "$result" -ne 0 ]
    [ ! -s "$stdout_file" ]
    [ -s "$stderr_file" ]
}

@test "protocol helper wraps savechanges as a script2sb result" {
    helper="$BATS_TEST_DIRNAME/../lib/minios_protocol.py"
    input="$BATS_TEST_TMPDIR/script-savechanges.ndjson"
    printf '%s\n' \
        '{"event":"phase","phase":"capture"}' \
        '{"type":"result","product_kind":"minios-tool-result","schema_version":1,"tool":"savechanges","operation":"capture-module","output":"/tmp/script.sb","compressed_size":4096,"uncompressed_size":8192,"entry_count":5,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' \
        >"$input"
    run python3 -I "$helper" script2sb-result zstd 1 "$input"
    [ "$status" -eq 0 ]
    run python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["tool"] == "script2sb"; assert d["operation"] == "create"; assert d["seed_directory"] is True; assert d["output"] == "/tmp/script.sb"' "$output"
    [ "$status" -eq 0 ]
}

@test "caller-bound copy-tree copies dotfiles and symlinks" {
    engine="$BATS_TEST_DIRNAME/../lib/minios_convert_engine.py"
    source="$BATS_TEST_TMPDIR/tree-source"
    target="$BATS_TEST_TMPDIR/tree-target"
    mkdir -p "$source/sub" "$target"
    printf '%s\n' hidden >"$source/.hidden"
    printf '%s\n' file >"$source/sub/file"
    ln -s sub/file "$source/link"
    run python3 -I "$engine" copy-tree "$source" "$target" ''
    [ "$status" -eq 0 ]
    [ "$(cat "$target/.hidden")" = hidden ]
    [ "$(cat "$target/sub/file")" = file ]
    [ "$(readlink "$target/link")" = sub/file ]
}

@test "chroot2sb documents the split interactive lifecycle" {
    run "$BIN/chroot2sb" --help
    [ "$status" -eq 0 ]
    [[ $output == *"prepare"* ]]
    [[ $output == *"shell"* ]]
    [[ $output == *"finish"* ]]
    [[ $output == *"cancel"* ]]
}

@test "chroot2sb prepare JSON preflight failure keeps stdout clean" {
    (( EUID != 0 )) || skip "requires an unprivileged caller"
    stdout_file="$BATS_TEST_TMPDIR/chroot2sb.stdout"
    stderr_file="$BATS_TEST_TMPDIR/chroot2sb.stderr"
    set +e
    "$BIN/chroot2sb" prepare --json -n /tmp/test.sb >"$stdout_file" 2>"$stderr_file"
    result=$?
    set -e
    [ "$result" -ne 0 ]
    [ ! -s "$stdout_file" ]
    [ -s "$stderr_file" ]
}

@test "protocol helper emits chroot prepare finish and cancel results" {
    helper="$BATS_TEST_DIRNAME/../lib/minios_protocol.py"
    input="$BATS_TEST_TMPDIR/chroot-savechanges.ndjson"
    printf '%s\n' \
        '{"type":"result","product_kind":"minios-tool-result","schema_version":1,"tool":"savechanges","operation":"capture-module","output":"/tmp/chroot.sb","compressed_size":4096,"uncompressed_size":8192,"entry_count":3,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' \
        >"$input"
    run python3 -I "$helper" chroot2sb-prepare session.abc /tmp/chroot.sb zstd 1
    [ "$status" -eq 0 ]
    [[ $output == *'"operation":"prepare"'* ]]
    [[ $output == *'"session_id":"session.abc"'* ]]
    run python3 -I "$helper" chroot2sb-result zstd 1 "$input"
    [ "$status" -eq 0 ]
    [[ $output == *'"operation":"finish"'* ]]
    [[ $output == *'"output":"/tmp/chroot.sb"'* ]]
    run python3 -I "$helper" chroot2sb-cancel session.abc
    [ "$status" -eq 0 ]
    [[ $output == *'"operation":"cancel"'* ]]
}

@test "converter workspace identity check rejects replacement" {
    engine="$BATS_TEST_DIRNAME/../lib/minios_convert_engine.py"
    parent=$(mktemp -d -p /var/tmp chroot-workspace-test.XXXXXX 2>/dev/null || mktemp -d)
    identity=$(python3 -I "$engine" create-workspace "$parent" .chroot-test.)
    [ "$?" -eq 0 ]
    read -r name device inode <<<"$identity"
    python3 -I "$engine" check-workspace "$parent" "$name" "$device" "$inode"
    [ "$?" -eq 0 ]
    mv "$parent/$name" "$parent/original-workspace"
    mkdir -m 700 "$parent/$name"
    run python3 -I "$engine" check-workspace "$parent" "$name" "$device" "$inode"
    [ "$status" -ne 0 ]
    rm -rf "$parent"
}

@test "chroot lifecycle binds opaque sessions to locks and workspace identity" {
    run grep -F 'SESSION_ROOT="/run/minios-tools/chroot2sb"' "$BIN/chroot2sb"
    [ "$status" -eq 0 ]
    run grep -F 'flock -n "$SESSION_LOCK_FD"' "$BIN/chroot2sb"
    [ "$status" -eq 0 ]
    run grep -F 'run_convert_engine check-workspace' "$BIN/chroot2sb"
    [ "$status" -eq 0 ]
    run grep -F 'chroot "$UNION"' "$BIN/chroot2sb"
    [ "$status" -eq 0 ]
}

@test "installed-relative helpers work outside /usr" {
    command -v mksquashfs >/dev/null 2>&1 || skip "mksquashfs unavailable"
    command -v unsquashfs >/dev/null 2>&1 || skip "unsquashfs unavailable"
    root="$BATS_TEST_TMPDIR/relocated-tools"
    mkdir -p "$root/usr/bin" "$root/usr/lib/minios-tools" "$root/source"
    chmod 700 "$root"
    printf 'test\n' >"$root/source/file"
    mksquashfs "$root/source" "$root/example.sb" -noappend -no-progress >/dev/null
    cp "$BIN/sb" "$BIN/sb2dir" "$BIN/dir2sb" "$root/usr/bin/"
    cp "$BATS_TEST_DIRNAME/../lib/minios_protocol.py" \
       "$BATS_TEST_DIRNAME/../lib/minios_convert_engine.py" \
       "$root/usr/lib/minios-tools/"
    run "$root/usr/bin/sb" inspect "$root/example.sb" --json
    [ "$status" -eq 0 ]
    [[ $output == *'"tool":"sb"'* ]]
    [[ $output == *'"operation":"inspect"'* ]]
    run "$root/usr/bin/sb2dir" --json "$root/example.sb" "$root/extracted"
    [ "$status" -eq 0 ]
    [ "$(cat "$root/extracted/file")" = test ]
    run "$root/usr/bin/dir2sb" --json "$root/extracted" "$root/repacked.sb"
    [ "$status" -eq 0 ]
    unsquashfs -s "$root/repacked.sb" >/dev/null
}

@test "helper-using frontends include installed-relative libdir" {
    local tool
    for tool in sb apt2sb script2sb chroot2sb; do
        run grep -F '"$SCRIPT_DIR/../lib/minios-tools/$NAME"' "$BIN/$tool"
        [ "$status" -eq 0 ]
    done
    for tool in dir2sb sb2dir; do
        run grep -F '"$SCRIPT_DIR/../lib/minios-tools/minios_convert_engine.py"' "$BIN/$tool"
        [ "$status" -eq 0 ]
    done
    run grep -F '"${SCRIPT_PATH%/*}/../lib/minios-tools/minios_savechanges_engine.py"' \
        "$BIN/savechanges"
    [ "$status" -eq 0 ]
}

@test "AUFS build wrappers pass explicit branch inventories to savechanges" {
    for tool in apt2sb script2sb chroot2sb; do
        grep -Fq -- '--aufs-branches' "$BIN/$tool"
        grep -Fq 'write_aufs_branch_inventory' "$BIN/$tool"
    done
}
