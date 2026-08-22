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
    chmod 0700 "$TEST_ROOT" "$OUT"
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

@test "directory publication fails closed without atomic no-replace rename" {
    local engine="$BATS_TEST_DIRNAME/../lib/minios_convert_engine.py"
    run env ENGINE="$engine" PARENT="$OUT" python3 -c '
import importlib.util
import os

spec = importlib.util.spec_from_file_location("engine", os.environ["ENGINE"])
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)
assert engine._syscall_abi("x86_64", "i386-linux-gnu", 4) == "i386"
assert engine._syscall_abi("i686", "x86_64-linux-gnu", 8) == "x86_64"
parent_fd = os.open(os.environ["PARENT"], os.O_RDONLY | os.O_DIRECTORY)
try:
    os.mkdir("stage", dir_fd=parent_fd)
    engine._RENAMEAT2 = None
    try:
        engine.rename_noreplace(
            parent_fd, "stage", parent_fd, "target", False)
    except engine.EngineError as error:
        assert error.status == 5
    else:
        raise AssertionError("directory publication did not fail closed")
    assert os.path.isdir(os.path.join(os.environ["PARENT"], "stage"))
    assert not os.path.exists(os.path.join(os.environ["PARENT"], "target"))
finally:
    os.rmdir("stage", dir_fd=parent_fd)
    os.close(parent_fd)
'
    [ "$status" -eq 0 ]
}

@test "direct renameat2 syscall publishes when libc has no wrapper" {
    local engine="$BATS_TEST_DIRNAME/../lib/minios_convert_engine.py"
    run env ENGINE="$engine" PARENT="$OUT" python3 -c '
import importlib.util
import os

spec = importlib.util.spec_from_file_location("engine", os.environ["ENGINE"])
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)
parent_fd = os.open(os.environ["PARENT"], os.O_RDONLY | os.O_DIRECTORY)
try:
    os.mkdir("stage", dir_fd=parent_fd)
    engine._RENAMEAT2 = engine._load_renameat2(force_syscall=True)
    assert engine._RENAMEAT2 is not None
    engine.rename_noreplace(
        parent_fd, "stage", parent_fd, "target", False)
    assert not os.path.exists(os.path.join(os.environ["PARENT"], "stage"))
    assert os.path.isdir(os.path.join(os.environ["PARENT"], "target"))
finally:
    os.rmdir("target", dir_fd=parent_fd)
    os.close(parent_fd)
'
    [ "$status" -eq 0 ]
}

@test "hard-link fallback rolls back when staging unlink fails" {
    local engine="$BATS_TEST_DIRNAME/../lib/minios_convert_engine.py"
    run env ENGINE="$engine" PARENT="$OUT" python3 -c '
import errno
import importlib.util
import os

spec = importlib.util.spec_from_file_location("engine", os.environ["ENGINE"])
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)
parent = os.environ["PARENT"]
parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
try:
    descriptor = os.open("stage", os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                         0o600, dir_fd=parent_fd)
    os.close(descriptor)
    original_unlink = engine.os.unlink
    calls = [0]
    def fail_source_once(name, *args, **kwargs):
        calls[0] += 1
        if calls[0] == 1:
            raise OSError(errno.EIO, "injected unlink failure")
        return original_unlink(name, *args, **kwargs)
    engine._RENAMEAT2 = None
    engine.os.unlink = fail_source_once
    try:
        engine.rename_noreplace(
            parent_fd, "stage", parent_fd, "target", True)
    except OSError:
        pass
    else:
        raise AssertionError("unlink failure was ignored")
    assert os.path.isfile(os.path.join(parent, "stage"))
    assert not os.path.exists(os.path.join(parent, "target"))
finally:
    engine.os.unlink = original_unlink
    try:
        os.unlink("stage", dir_fd=parent_fd)
    except FileNotFoundError:
        pass
    os.close(parent_fd)
'
    [ "$status" -eq 0 ]
}

@test "workspace cleanup refuses a replacement directory" {
    local engine="$BATS_TEST_DIRNAME/../lib/minios_convert_engine.py"
    run env ENGINE="$engine" PARENT="$OUT" python3 -c '
import importlib.util
import os

spec = importlib.util.spec_from_file_location("engine", os.environ["ENGINE"])
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)
parent = os.environ["PARENT"]
parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
try:
    os.mkdir("work", 0o700, dir_fd=parent_fd)
    metadata = os.stat("work", dir_fd=parent_fd, follow_symlinks=False)
    os.rename("work", "owned-old", src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
    os.mkdir("work", 0o700, dir_fd=parent_fd)
    marker = os.open("work/keep", os.O_WRONLY | os.O_CREAT, 0o600,
                     dir_fd=parent_fd)
    os.close(marker)
    try:
        engine.command_cleanup_workspace([
            parent, "work", str(metadata.st_dev), str(metadata.st_ino)])
    except engine.EngineError as error:
        assert error.status == 5
    else:
        raise AssertionError("replacement workspace was adopted")
    assert os.path.isfile(os.path.join(parent, "work", "keep"))
finally:
    engine.remove_tree(parent_fd, "work")
    engine.remove_tree(parent_fd, "owned-old")
    os.close(parent_fd)
'
    [ "$status" -eq 0 ]
}

@test "post-publication fsync failures roll back owned outputs" {
    local engine="$BATS_TEST_DIRNAME/../lib/minios_convert_engine.py"
    run env ENGINE="$engine" PARENT="$OUT" python3 -c '
import errno
import importlib.util
import os

spec = importlib.util.spec_from_file_location("engine", os.environ["ENGINE"])
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)
parent = os.environ["PARENT"]

def workspace(name):
    path = os.path.join(parent, name)
    os.mkdir(path, 0o700)
    metadata = os.stat(path)
    return path, str(metadata.st_dev), str(metadata.st_ino)

file_work, file_dev, file_ino = workspace("file-work")
with open(os.path.join(file_work, "module"), "wb") as stream:
    stream.write(b"module")
original_fsync = engine.fsync_directory
engine.fsync_directory = lambda unused: (_ for _ in ()).throw(
    OSError(errno.EIO, "injected fsync failure"))
try:
    engine.command_publish_file([
        parent, "file-work", file_dev, file_ino, "module", "module.sb",
        "zstd", "1", "0"])
except OSError:
    pass
else:
    raise AssertionError("file publication unexpectedly succeeded")
assert not os.path.exists(os.path.join(parent, "module.sb"))
engine.fsync_directory = original_fsync
engine.command_cleanup_workspace([parent, "file-work", file_dev, file_ino])

dir_work, dir_dev, dir_ino = workspace("dir-work")
os.mkdir(os.path.join(dir_work, "tree"), 0o755)
with open(os.path.join(dir_work, "tree", "file"), "w") as stream:
    stream.write("data")
source = os.path.join(parent, "source.sb")
with open(source, "wb") as stream:
    stream.write(b"source")
calls = [0]
def fail_parent_fsync(unused):
    calls[0] += 1
    if calls[0] == 2:
        raise OSError(errno.EIO, "injected fsync failure")
engine.fsync_directory = fail_parent_fsync
try:
    engine.command_publish_dir([
        parent, "dir-work", dir_dev, dir_ino, "tree", "tree", source,
        "0", "0"])
except OSError:
    pass
else:
    raise AssertionError("directory publication unexpectedly succeeded")
assert not os.path.exists(os.path.join(parent, "tree"))
engine.fsync_directory = original_fsync
engine.command_cleanup_workspace([parent, "dir-work", dir_dev, dir_ino])
os.unlink(source)
'
    [ "$status" -eq 0 ]
}

@test "rollback preserves a replacement published target" {
    local engine="$BATS_TEST_DIRNAME/../lib/minios_convert_engine.py"
    run env ENGINE="$engine" PARENT="$OUT" python3 -c '
import errno
import importlib.util
import os

spec = importlib.util.spec_from_file_location("engine", os.environ["ENGINE"])
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)
parent = os.environ["PARENT"]
work = os.path.join(parent, "work")
os.mkdir(work, 0o700)
metadata = os.stat(work)
with open(os.path.join(work, "module"), "wb") as stream:
    stream.write(b"owned")

def replace_then_fail(unused):
    target = os.path.join(parent, "module.sb")
    if os.path.exists(target):
        os.rename(target, target + ".owned")
        with open(target, "wb") as stream:
            stream.write(b"replacement")
    raise OSError(errno.EIO, "injected fsync failure")

engine.fsync_directory = replace_then_fail
try:
    engine.command_publish_file([
        parent, "work", str(metadata.st_dev), str(metadata.st_ino),
        "module", "module.sb", "zstd", "1", "0"])
except engine.EngineError as error:
    assert error.status == 5
else:
    raise AssertionError("replacement target was adopted")
with open(os.path.join(parent, "module.sb"), "rb") as stream:
    assert stream.read() == b"replacement"
'
    [ "$status" -eq 0 ]
}

@test "the source module is left unchanged" {
    make_stub_module "$TEST_ROOT/module.sb"
    local before
    before=$(sha256sum "$TEST_ROOT/module.sb" | cut -d' ' -f1)
    run_stub "$TEST_ROOT/module.sb" "$OUT/tree"
    [ "$status" -eq 0 ]
    [ "$before" = "$(sha256sum "$TEST_ROOT/module.sb" | cut -d' ' -f1)" ]
}

@test "source module replacement cannot change extraction or reported digest" {
    make_stub_module "$TEST_ROOT/module.sb"
    local before
    before=$(sha256sum "$TEST_ROOT/module.sb" | cut -d' ' -f1)
    run env PATH="$TOOLS:$SYSTEM_PATH" NO_COLOR=1 \
        UNSQUASHFS_REPLACE_SOURCE="$TEST_ROOT/module.sb" \
        "$SB2DIR" --json "$TEST_ROOT/module.sb" "$OUT/tree"
    [ "$status" -eq 0 ]
    [ -f "$OUT/tree/top.txt" ]
    [[ $output == *"$before"* ]]
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
    [[ $output == *'"phase":"prepare"'* ]]
    [[ $output == *'"phase":"extract"'* ]]
    [[ $output == *'"phase":"publish"'* ]]
    [[ $output == *'"phase":"complete"'* ]]
    [[ $output == *'"product": "sb2dir"'* ]]
    [[ $output == *'"source_sha256":'* ]]
    [[ $output == *'"entries":'* ]]
}

@test "json mode emits only JSON objects" {
    make_stub_module "$TEST_ROOT/module.sb"
    run_stub --json "$TEST_ROOT/module.sb" "$OUT/tree"
    [ "$status" -eq 0 ]
    while IFS= read -r line; do
        env LINE="$line" python3 -c 'import json, os; assert isinstance(json.loads(os.environ["LINE"]), dict)'
    done <<<"$output"
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

@test "unsquashfs status 2 never publishes a partial tree" {
    make_stub_module "$TEST_ROOT/module.sb"
    run env PATH="$TOOLS:$SYSTEM_PATH" NO_COLOR=1 UNSQUASHFS_STATUS=2 \
        "$SB2DIR" "$TEST_ROOT/module.sb" "$OUT/tree"
    [ "$status" -eq 5 ]
    [ ! -e "$OUT/tree" ]
    run find "$OUT" -maxdepth 1 -name '.sb2dir.*'
    [ -z "$output" ]
}

@test "a failed special-file listing never starts extraction" {
    make_stub_module "$TEST_ROOT/module.sb"
    local marker="$TEST_ROOT/extraction-started"
    run env PATH="$TOOLS:$SYSTEM_PATH" NO_COLOR=1 \
        UNSQUASHFS_LIST_STATUS=2 UNSQUASHFS_EXTRACT_MARKER="$marker" \
        "$SB2DIR" "$TEST_ROOT/module.sb" "$OUT/tree"
    [ "$status" -eq 5 ]
    [ ! -e "$marker" ]
    [ ! -e "$OUT/tree" ]
}

@test "a leader-exit extractor group is terminated before publication" {
    make_stub_module "$TEST_ROOT/module.sb"
    cat >"$TOOLS/unsquashfs" <<'FAKE'
#!/bin/bash
set -u
if [[ ${1:-} == -help || ${1:-} == --help ]]; then
    printf '%s\n' '-u[ser-xattrs] only extract user xattrs'
    exit 0
fi
for arg in "$@"; do
    if [[ $arg == -ll ]]; then
        printf -- '-rw-r--r-- root/root 4 date time squashfs-root/top.txt\n'
        exit 0
    fi
done
destination=""
while (( $# > 0 )); do
    case $1 in
    -d) destination=$2; shift 2 ;;
    *) shift ;;
    esac
done
mkdir -p "$destination"
printf 'partial\n' >"$destination/top.txt"
/usr/bin/python3 -c 'import signal, time
signal.signal(signal.SIGINT, signal.SIG_IGN)
signal.signal(signal.SIGTERM, signal.SIG_IGN)
while True:
    time.sleep(1)' &
descendant=$!
printf '%s\n' "$descendant" >"$SB2DIR_LEADER_MARKER"
exit 0
FAKE
    chmod 0755 "$TOOLS/unsquashfs"
    local marker="$TEST_ROOT/leader-marker"
    run env PATH="$TOOLS:$SYSTEM_PATH" NO_COLOR=1 \
        SB2DIR_LEADER_MARKER="$marker" \
        "$SB2DIR" "$TEST_ROOT/module.sb" "$OUT/tree"
    [ "$status" -eq 5 ]
    local descendant
    descendant=$(cat "$marker")
    for _ in {1..100}; do kill -0 "$descendant" 2>/dev/null || break; sleep 0.05; done
    ! kill -0 "$descendant" 2>/dev/null
    [ ! -e "$OUT/tree" ]
}

@test "SIGTERM cancels the extraction, cleans up, and reaps the tool" {
    make_stub_module "$TEST_ROOT/module.sb"
    cat >"$TOOLS/unsquashfs" <<'FAKE'
#!/bin/bash
set -u
if [[ ${1:-} == -help || ${1:-} == --help ]]; then
    printf '%s\n' '-u[ser-xattrs] only extract user xattrs'
    exit 0
fi
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

@test "special-file precheck rejects the module before extraction" {
    make_stub_module "$TEST_ROOT/module.sb"
    mkfifo "$TEST_ROOT/module.sb.stub-tree/pipe" 2>/dev/null || skip 'the test filesystem disallows FIFOs'
    local extract_marker="$TEST_ROOT/extraction-started"
    run env PATH="$TOOLS:$SYSTEM_PATH" NO_COLOR=1 \
        UNSQUASHFS_EXTRACT_MARKER="$extract_marker" \
        "$SB2DIR" "$TEST_ROOT/module.sb" "$OUT/tree"
    [ "$status" -eq 3 ]
    [ ! -e "$extract_marker" ]
    [ ! -e "$OUT/tree" ]
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

@test "rootless extraction requests user-only xattrs on Bionic-compatible tools" {
    (( EUID == 0 )) && skip 'requires an unprivileged user'
    make_stub_module "$TEST_ROOT/module.sb"
    local argv_log="$TEST_ROOT/unsquashfs.argv"
    run env PATH="$TOOLS:$SYSTEM_PATH" NO_COLOR=1 \
        UNSQUASHFS_ARGV_LOG="$argv_log" \
        "$SB2DIR" "$TEST_ROOT/module.sb" "$OUT/tree"
    [ "$status" -eq 0 ]
    run sh -c 'tr "\0" "\n" <"$1" | grep -Fx -- -user-xattrs' sh "$argv_log"
    [ "$status" -eq 0 ]
}

@test "rootless real extraction preserves user xattrs" {
    require_real_tools
    (( EUID == 0 )) && skip 'requires an unprivileged user'
    local src="$TEST_ROOT/xattr-src"
    mkdir -p "$src"
    printf 'data\n' >"$src/file"
    if ! python3 -I -c 'import os,sys; os.setxattr(sys.argv[1], b"user.minios-test", b"kept")' "$src/file"; then
        skip 'the test filesystem disallows user xattrs'
    fi
    run env PATH="$SYSTEM_PATH" NO_COLOR=1 "$DIR2SB" "$src" "$TEST_ROOT/xattr.sb"
    [ "$status" -eq 0 ]
    run_real "$TEST_ROOT/xattr.sb" "$OUT/xattr-tree"
    [ "$status" -eq 0 ]
    run python3 -I -c 'import os,sys; assert os.getxattr(sys.argv[1], b"user.minios-test") == b"kept"' "$OUT/xattr-tree/file"
    [ "$status" -eq 0 ]
}
