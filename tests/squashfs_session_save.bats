setup() {
    ROOT=$(CDPATH= cd -- "$BATS_TEST_DIRNAME/.." && pwd)
    WORK=$(mktemp -d)
    BACKEND_CASE="$BATS_TEST_DIRNAME/squashfs_backend_case.py"
    SHUTDOWN="$ROOT/bin/minios-squashfs-shutdown-save"
}

teardown() {
    rm -rf "$WORK"
}

@test "common backend atomically publishes a running SquashFS session" {
    run python3 "$BACKEND_CASE" save
    [ "$status" -eq 0 ]
}

@test "common backend finalizes shutdown metadata with the same save" {
    run python3 "$BACKEND_CASE" finalize
    [ "$status" -eq 0 ]
}

@test "common backend rejects manual shutdown policy before capture" {
    run python3 "$BACKEND_CASE" manual-shutdown
    [ "$status" -eq 0 ]
}

@test "common backend rejects capture identity mismatch without rotation" {
    run python3 "$BACKEND_CASE" identity
    [ "$status" -eq 0 ]
}

@test "common backend aborts if the current generation changes during capture" {
    run python3 "$BACKEND_CASE" generation
    [ "$status" -eq 0 ]
}

@test "published session data is never rolled back after metadata failure" {
    run python3 "$BACKEND_CASE" metadata
    [ "$status" -eq 0 ]
}

shutdown_environment() {
    local policy=${1:-shutdown}
    BOOT_STATE="$WORK/boot-state"
    SESSIONS="$WORK/changes"
    MARKER="$WORK/shutdown-save-complete"
    CONSOLE="$WORK/console"
    SAVE_COMMAND="$WORK/minios-squashfs-save"
    CALLED="$WORK/called"
    mkdir -p "$SESSIONS"
    printf '%s\n' 'boot_level=ok' 'mode=squashfs' 'session=1' >"$BOOT_STATE"
    printf '%s\n' 'default=1' 'running=1' 'session_mode[1]=squashfs' \
        "session_policy[1]=$policy" >"$SESSIONS/session.conf"
    cat >"$SAVE_COMMAND" <<EOF
#!/bin/sh
echo "\$*" >"$CALLED"
echo '{"phase":"inventory","type":"phase"}'
echo '{"phase":"compress","type":"phase"}'
echo '{"phase":"verify","type":"phase"}'
echo '{"message":"saved","success":true}'
EOF
    chmod 755 "$SAVE_COMMAND"
}

@test "shutdown helper saves through Tools and publishes the initramfs marker" {
    shutdown_environment shutdown
    run env \
        MINIOS_SHUTDOWN_BOOT_STATE="$BOOT_STATE" \
        MINIOS_SHUTDOWN_SESSIONS_DIR="$SESSIONS" \
        MINIOS_SHUTDOWN_MARKER="$MARKER" \
        MINIOS_SHUTDOWN_SAVE_COMMAND="$SAVE_COMMAND" \
        MINIOS_SHUTDOWN_CONSOLE="$CONSOLE" \
        "$SHUTDOWN"
    [ "$status" -eq 0 ]
    [ "$(cat "$CALLED")" = "1 --shutdown-finalize --json --progress" ]
    [ "$(cat "$MARKER")" = "session=1" ]
    grep -Fq 'Scanning session changes' "$CONSOLE"
    grep -Fq 'Compressing session' "$CONSOLE"
    grep -Fq 'Verifying session' "$CONSOLE"
    grep -Fq '[\033[0;32mOK' "$CONSOLE" || grep -Fq 'saved.' "$CONSOLE"
}

@test "shutdown helper surfaces backend failure details" {
    shutdown_environment shutdown
    cat >"$SAVE_COMMAND" <<EOF
#!/bin/sh
echo '{"phase":"inventory","type":"phase"}'
echo '{"message":"directory identity changed during inventory","success":false}'
exit 1
EOF
    chmod 755 "$SAVE_COMMAND"
    run env MINIOS_SHUTDOWN_BOOT_STATE="$BOOT_STATE" \
        MINIOS_SHUTDOWN_SESSIONS_DIR="$SESSIONS" \
        MINIOS_SHUTDOWN_MARKER="$MARKER" \
        MINIOS_SHUTDOWN_SAVE_COMMAND="$SAVE_COMMAND" \
        MINIOS_SHUTDOWN_CONSOLE="$CONSOLE" "$SHUTDOWN"
    [ "$status" -ne 0 ]
    grep -Fq 'directory identity changed during inventory' "$CONSOLE"
    [ ! -e "$MARKER" ]
}

@test "manual SquashFS policy skips shutdown save" {
    shutdown_environment manual
    run env MINIOS_SHUTDOWN_BOOT_STATE="$BOOT_STATE" \
        MINIOS_SHUTDOWN_SESSIONS_DIR="$SESSIONS" \
        MINIOS_SHUTDOWN_MARKER="$MARKER" \
        MINIOS_SHUTDOWN_SAVE_COMMAND="$SAVE_COMMAND" \
        MINIOS_SHUTDOWN_CONSOLE="$CONSOLE" "$SHUTDOWN"
    [ "$status" -eq 0 ]
    [ ! -e "$CALLED" ]
    [ ! -e "$MARKER" ]
}

@test "Tools provides the core shutdown helper without package-owned systemd lifecycle" {
    [ -x "$SHUTDOWN" ]
    [ ! -e "$ROOT/share/systemd/minios-squashfs-shutdown-save.service" ]
    ! grep -Fq 'dh_installsystemd' "$ROOT/debian/rules"
}
