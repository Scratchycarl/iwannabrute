#!/bin/bash
phase_log="/iwannabrute-phases.log"

emit_phase() {
    local phase="$1"
    local state="$2"
    local status="${3:--}"
    local message="[IWANNABRUTE] PHASE=$phase STATE=$state EXIT=$status"
    echo "$message" > /dev/console
    echo "$message" >> "$phase_log"
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

echo "32-bit Bruteforce SSH Ramdisk by meowcat454, AJAIZ and platinumstuff" > /dev/console
echo "--------------------------------" > /dev/console
emit_phase SETUP START

run_phase MOUNT_ROOTFS mount -o rw,union,update / ||
    fail_phase MOUNT_ROOTFS "$?"

run_phase SET_AUTOBOOT nvram auto-boot=1 ||
    fail_phase SET_AUTOBOOT "$?"

run_phase START_SSHD /sbin/sshd ||
    fail_phase START_SSHD "$?"

run_phase START_RESTORED /usr/local/bin/restored_external.sshrd ||
    fail_phase START_RESTORED "$?"

run_phase MOUNT_DATA /bin/mount.sh ||
    fail_phase MOUNT_DATA "$?"

if [[ -d /mnt1/private/etc ]]; then
    persistent_phase_log="/mnt1/private/etc/iwannabrute-phases.log"
    cp "$phase_log" "$persistent_phase_log"
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
