#!/bin/bash
phase_log=""

emit_phase() {
    local phase="$1"
    local state="$2"
    local status="${3:--}"
    local message="[IWANNABRUTE] PHASE=$phase STATE=$state EXIT=$status"
    echo "$message" > /dev/console
    if [[ -n "$phase_log" ]]; then
        echo "$message" >> "$phase_log"
    fi
}

run_phase() {
    local phase="$1"
    shift
    local status
    emit_phase "$phase" START
    "$@" >> /dev/console 2>&1
    status=$?
    emit_phase "$phase" EXIT "$status"
    return "$status"
}

fail_phase() {
    emit_phase "$1" FATAL "$2"
    exit "$2"
}

wait_for_data_device() {
    local attempt
    for ((attempt=1; attempt<=60; attempt++)); do
        if [[ -b /dev/disk0s1s2 || -b /dev/disk0s2s1 ]]; then
            echo "Data partition device appeared after $attempt second(s)." > /dev/console
            return 0
        fi
        sleep 1
    done
    echo "Timed out waiting for an A4 data partition device." > /dev/console
    return 1
}

mount_and_verify_data() {
    local attempt
    for attempt in 1 2 3; do
        echo "Mounting data partition (attempt $attempt/3)..." > /dev/console
        /bin/mount.sh >> /dev/console 2>&1
        if [[ -s /mnt2/keybags/systembag ]]; then
            echo "Verified /mnt2/keybags/systembag." > /dev/console
            return 0
        fi
        echo "Data mount did not expose /mnt2/keybags/systembag." > /dev/console
        mount > /dev/console 2>&1
        sleep 3
    done
    return 1
}

echo "32-bit Bruteforce SSH Ramdisk by meowcat454, AJAIZ and platinumstuff" > /dev/console
echo "--------------------------------" > /dev/console
emit_phase SETUP START

run_phase MOUNT_ROOTFS mount -o rw,union,update /
root_mount_status=$?
if [[ "$root_mount_status" -ne 0 ]]; then
    # A4 restore ramdisks can remain read-only while the data partitions,
    # SSH daemon, and bruteforce payload still work.
    emit_phase MOUNT_ROOTFS NONFATAL "$root_mount_status"
fi

run_phase SET_AUTOBOOT nvram auto-boot=1 ||
    fail_phase SET_AUTOBOOT "$?"

# restored_external initializes USB mux and runs sshd in inetd mode. Starting a
# standalone sshd first occupies port 22 and makes restored_external exit.
emit_phase START_RESTORED START
/usr/local/bin/restored_external.sshrd >> /dev/console 2>&1 &
restored_pid=$!
sleep 2
if kill -0 "$restored_pid" 2>/dev/null; then
    emit_phase START_RESTORED RUNNING 0
    emit_phase START_SSHD MANAGED_BY_RESTORED 0
else
    wait "$restored_pid"
    restored_status=$?
    emit_phase START_RESTORED EXIT "$restored_status"
    fail_phase START_RESTORED "$restored_status"
fi

run_phase WAIT_DATA_DEVICE wait_for_data_device ||
    fail_phase WAIT_DATA_DEVICE "$?"

run_phase MOUNT_DATA mount_and_verify_data ||
    fail_phase MOUNT_DATA "$?"

if [[ -d /mnt1/private/etc ]]; then
    persistent_phase_log="/mnt1/private/etc/iwannabrute-phases.log"
    : > "$persistent_phase_log"
    persist_status=$?
    if [[ "$persist_status" -eq 0 ]]; then
        phase_log="$persistent_phase_log"
    fi
    emit_phase PERSIST_PHASE_LOG EXIT "$persist_status"
else
    emit_phase PERSIST_PHASE_LOG EXIT 1
fi

# The bundled bruteforce process performs the first AES access; there is no
# separate AES probe binary. This marker records the attempted boundary, not a
# confirmed successful connection to IOAESAccelerator.
emit_phase AES_ACCESS ATTEMPT
emit_phase BRUTEFORCE START
/usr/bin/bruteforce >> /dev/console 2>&1
bruteforce_status=$?
emit_phase BRUTEFORCE EXIT "$bruteforce_status"
emit_phase AES_ACCESS PROCESS_EXIT "$bruteforce_status"
if [[ "$bruteforce_status" -ne 0 ]]; then
    fail_phase BRUTEFORCE "$bruteforce_status"
fi

emit_phase CLEAR_DISABLED_STATE START

disabled_status=0
if cd /mnt2/mobile/Library/Preferences/; then
    for file in com.apple.springboard.plist.???????; do
        if [[ -f "$file" ]]; then
            rm -f "$file" > /dev/null || disabled_status=1
        fi
    done
    if [[ -f com.apple.springboard.plist ]]; then
        mv -f com.apple.springboard.plist com.apple.springboard.plist.bak > /dev/null ||
            disabled_status=1
    fi
else
    disabled_status=1
fi
rm -f /mnt2/mobile/Library/SpringBoard/LockoutStateJournal.plist > /dev/null ||
    disabled_status=1
emit_phase CLEAR_DISABLED_STATE EXIT "$disabled_status"
emit_phase SETUP EXIT "$disabled_status"
exit "$disabled_status"
