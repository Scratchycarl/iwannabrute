#!/bin/bash

script_version="2.0"
ramdisk_cache_version="2.0-a4.5"

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

require_file() {
    [[ -s "$1" ]] || die "Required file is missing or empty: $1"
}

run_checked() {
    local description="$1"
    shift
    echo "[RUN] $description"
    "$@"
    local status=$?
    [[ $status -eq 0 ]] || die "$description failed with exit status $status."
}

cleanup_build_mount() {
    if [[ -n "$active_mountpoint" && -d "$active_mountpoint" ]]; then
        echo "[CLEANUP] Detaching $active_mountpoint"
        sudo hdiutil detach "$active_mountpoint" >/dev/null 2>&1 || true
        active_mountpoint=""
    fi
    if [[ -n "$temporary_aespatcher" && -f "$temporary_aespatcher" ]]; then
        rm -f "$temporary_aespatcher"
    fi
}

init_diagnostic_log() {
    mkdir -p logs || die "Unable to create the logs directory."
    diagnostic_log="$(pwd)/logs/a4-$(date '+%Y%m%d-%H%M%S').log"
    touch "$diagnostic_log" || die "Unable to create diagnostic log: $diagnostic_log"
    exec > >(tee -a "$diagnostic_log") 2>&1
    echo "[INFO] Diagnostic log: $diagnostic_log"
    echo "[INFO] Started: $(date '+%Y-%m-%d %H:%M:%S %z')"
}

build_ios5_aespatcher() {
    temporary_aespatcher="$project_root/tmp-aespatched-ios5-$$"
    echo "[RUN] Compile the iOS 5 AES patcher"
    clang++ -std=c++11 -O2 -Wall -Wextra -arch x86_64 \
        "$project_root/bin/Darwin/aespatched.cpp" \
        -o "$temporary_aespatcher"
    local status=$?
    [[ $status -eq 0 ]] || die "Compiling the iOS 5 AES patcher failed with exit status $status."
    require_file "$temporary_aespatcher"
    run_checked "Validate the iOS 5 AES patcher" "$temporary_aespatcher" --self-test
    file "$temporary_aespatcher" | grep -q "x86_64" ||
        die "The compiled iOS 5 AES patcher is not an x86_64 executable."
    echo "[OK] Reproducible iOS 5 AES patcher is ready."
}

preflight_a4() {
    [[ "$platform" == "macos" ]] || die "A4 support requires macOS."
    [[ "$platform_arch" == "x86_64" ]] || die "A4 support requires an Intel Mac (x86_64); detected $platform_arch."

    case "$deviceid:$ios_version" in
        "iPhone3,2:7.1.2"|"iPod4,1:6.1.6"|"iPad1,1:5.1.1") ;;
        *) die "Unsupported A4 firmware selection: $deviceid $ios_version. Supported pairs are iPhone3,2 7.1.2, iPod4,1 6.1.6, and iPad1,1 5.1.1." ;;
    esac

    local command_name
    for command_name in awk curl file grep hdiutil sed tar tee tr xargs; do
        command -v "$command_name" >/dev/null 2>&1 ||
            die "Required A4 build command is not installed: $command_name"
    done

    local asset
    for asset in \
        bin/Darwin/aespatched \
        bin/Darwin/iBoot32Patcher \
        bin/Darwin/ipwnder \
        bin/Darwin/irecovery \
        bin/Darwin/jq \
        bin/Darwin/partialZipBrowser \
        bin/Darwin/xpwntool \
        resources/bruteforce \
        resources/device_infos \
        resources/firmware.json \
        resources/restored_external \
        resources/setup.sh \
        resources/ssh.tar.gz; do
        require_file "$asset"
    done

    file bin/Darwin/ipwnder | grep -q "x86_64" ||
        die "bin/Darwin/ipwnder is not an Intel-compatible executable."
    command -v hdiutil >/dev/null 2>&1 || die "hdiutil is required to build the A4 ramdisk."
    if [[ "$deviceid" == "iPad1,1" ]]; then
        require_file bin/Darwin/aespatched.cpp
        command -v clang++ >/dev/null 2>&1 ||
            die "clang++ from Xcode Command Line Tools is required for iPad1,1."
    fi
    echo "[OK] A4 preflight passed for $deviceid $ios_version on $platform_arch."
}

mk_bruteforce_ramdisk() {
    local device="$1"
    local version="$2"
    local boardcfg firmware_info ipsw_link BuildID iOS_Vers key_page
    local images temp_type temp_type2 key_field component component_file
    local component_iv component_key i

    echo "Making bruteforce ramdisk for $device $version..."
    boardcfg=$("$jq" -r --arg device "$device" '.devices[$device].BoardConfig // empty' resources/firmware.json)
    [[ -n "$boardcfg" ]] || die "No BoardConfig metadata found for $device."

    firmware_info=$(curl -fsS "https://api.ipsw.me/v2.1/$device/$version/info.json") ||
        die "Failed to download firmware metadata for $device $version."
    ipsw_link=$(printf '%s' "$firmware_info" | "$jq" -r '.[0].url // empty')
    BuildID=$(printf '%s' "$firmware_info" | "$jq" -r '.[0].buildid // empty')
    [[ "$ipsw_link" == https://* && -n "$BuildID" ]] ||
        die "Firmware metadata is incomplete for $device $version."
    if [[ "$device" == "iPad1,1" ]]; then
        [[ "$version" == "5.1.1" && "$BuildID" == "9B206" && "$boardcfg" == "k48ap" ]] ||
            die "Unexpected iPad1,1 firmware metadata: version=$version build=$BuildID board=$boardcfg."
        build_ios5_aespatcher
    fi
    iOS_Vers="${version%%.*}"
    echo "[OK] Firmware metadata: build $BuildID, board $boardcfg"

    mkdir -p "ramdisks/bruteforce-$device-$version/work" ||
        die "Unable to create the ramdisk work directory."
    cd "ramdisks/bruteforce-$device-$version/work" ||
        die "Unable to enter the ramdisk work directory."
    echo "$ramdisk_cache_version" > ../version || die "Unable to write the ramdisk cache version."

    echo "Downloading firmware keys..."
    key_page=$(
        curl -fsSG "https://theapplewiki.com/api.php" \
            --data-urlencode "action=query" \
            --data-urlencode "list=search" \
            --data-urlencode "srsearch=\"$BuildID\" \"$device\"" \
            --data-urlencode "srnamespace=2304" \
            --data-urlencode "format=json" \
            --data-urlencode "formatversion=2" |
            ../../../bin/Darwin/jq -r '.query.search[0].title // empty'
    )
    [[ -n "$key_page" ]] ||
        die "Failed to find firmware keys for $device $version ($BuildID)."

    curl -fsSG "https://theapplewiki.com/api.php" \
        --data-urlencode "action=query" \
        --data-urlencode "prop=revisions" \
        --data-urlencode "rvprop=content" \
        --data-urlencode "rvslots=main" \
        --data-urlencode "titles=$key_page" \
        --data-urlencode "format=json" \
        --data-urlencode "formatversion=2" |
        ../../../bin/Darwin/jq -r '.query.pages[0].revisions[0].slots.main.content // empty' \
        > temp_keys.txt
    require_file temp_keys.txt
    echo "[OK] Firmware keys page: $key_page"

    run_checked "Download BuildManifest.plist" \
        ../../../bin/Darwin/partialZipBrowser -g BuildManifest.plist "$ipsw_link"
    require_file BuildManifest.plist

    images="iBSS.iBEC.applelogo.DeviceTree.kernelcache.RestoreRamDisk"
    for i in {1..6}; do
        temp_type2=$(echo "$images" | awk -v var="$i" -F. '{print $var}')
        temp_type=$(echo "$temp_type2" | tr '[:upper:]' '[:lower:]')
        case "$temp_type2" in
            applelogo) key_field="AppleLogo" ;;
            kernelcache) key_field="Kernelcache" ;;
            RestoreRamDisk) key_field="RestoreRamdisk" ;;
            *) key_field="$temp_type2" ;;
        esac

        component_iv=$(sed -n "s/^[[:space:]]*|[[:space:]]*${key_field}IV[[:space:]]*=[[:space:]]*//p" temp_keys.txt | xargs)
        component_key=$(sed -n "s/^[[:space:]]*|[[:space:]]*${key_field}Key[[:space:]]*=[[:space:]]*//p" temp_keys.txt | xargs)
        [[ "$component_iv" =~ ^[[:xdigit:]]{32}$ && "$component_key" =~ ^[[:xdigit:]]{64}$ ]] ||
            die "Missing or invalid $temp_type2 firmware keys for $device $version ($BuildID)."

        if [[ "$temp_type2" == "RestoreRamDisk" ]]; then
            component=$(grep -i "$boardcfg" BuildManifest.plist -A 3000 | grep "$temp_type2" -A 100 | grep dmg -m 1 | sed 's/<string>//; s/<\/string>//' | xargs)
        else
            component=$(grep -i "$boardcfg" BuildManifest.plist -A 3000 | grep "$temp_type2" | grep string -m 1 | sed 's/<string>//; s/<\/string>//' | xargs)
        fi
        [[ -n "$component" ]] || die "BuildManifest has no $temp_type2 component for board $boardcfg."

        run_checked "Download $component" \
            ../../../bin/Darwin/partialZipBrowser -g "$component" "$ipsw_link"
        component_file="${component##*/}"
        require_file "$component_file"

        if [[ "$temp_type2" == "RestoreRamDisk" ]]; then
            run_checked "Decrypt RestoreRamDisk" \
                ../../../bin/Darwin/xpwntool "$component_file" RestoreRamDisk.dec.img3 \
                -iv "$component_iv" -k "$component_key" -decrypt
            require_file RestoreRamDisk.dec.img3
        else
            run_checked "Decrypt $temp_type2" \
                ../../../bin/Darwin/xpwntool "$component_file" "$temp_type2.dec.img3" \
                -iv "$component_iv" -k "$component_key" -decrypt
            require_file "$temp_type2.dec.img3"
        fi
    done

    echo "Making ramdisk..."
    bootargs="-v amfi=0xff cs_enforcement_disable=1 msgbuf=1048576 wdt=-1"

    if [[ "$is_64" == "true" ]]; then
        die "This A4 ramdisk builder only supports 32-bit devices."
    else
        run_checked "Extract RestoreRamDisk image" \
            ../../../bin/Darwin/xpwntool RestoreRamDisk.dec.img3 RestoreRamDisk.raw.dmg
        require_file RestoreRamDisk.raw.dmg
        run_checked "Resize RestoreRamDisk image" hdiutil resize -size 30MB RestoreRamDisk.raw.dmg
        mkdir -p ramdisk_mountpoint || die "Unable to create ramdisk mountpoint."
        run_checked "Mount RestoreRamDisk image" \
            sudo hdiutil attach -mountpoint ramdisk_mountpoint/ -owners off RestoreRamDisk.raw.dmg
        active_mountpoint="$(pwd)/ramdisk_mountpoint"
        [[ -d ramdisk_mountpoint/usr ]] || die "RestoreRamDisk mounted without a /usr directory."

        tar -xvf ../../../resources/ssh.tar.gz -C ramdisk_mountpoint/
        [[ $? -eq 0 ]] || die "Failed to extract SSH payload into RestoreRamDisk."
        if [[ "$iOS_Vers" -gt 7 ]]; then
            echo "iOS 8 or later detected, patching restored_external..."
            run_checked "Back up restored_external" \
                cp ramdisk_mountpoint/usr/local/bin/restored_external ramdisk_mountpoint/usr/local/bin/restored_external.real
        fi

        run_checked "Disable ramdisk reboot command" \
            mv ramdisk_mountpoint/sbin/reboot ramdisk_mountpoint/sbin/reboot_bak
        run_checked "Disable ramdisk halt command" \
            mv ramdisk_mountpoint/sbin/halt ramdisk_mountpoint/sbin/halt_bak
        rm -f ramdisk_mountpoint/usr/local/bin/restored_external.real
        run_checked "Install restored_external payload" \
            cp ../../../resources/restored_external ramdisk_mountpoint/usr/local/bin/restored_external.sshrd
        run_checked "Install bruteforce payload" \
            cp ../../../resources/bruteforce ramdisk_mountpoint/usr/bin/
        run_checked "Install device information payload" \
            cp ../../../resources/device_infos ramdisk_mountpoint/usr/bin/
        run_checked "Install setup payload" \
            cp ../../../resources/setup.sh ramdisk_mountpoint/usr/local/bin/restored_external
        if [[ "$device" == "iPad1,1" ]]; then
            printf '%s\n' "iPad1,1" > ramdisk_mountpoint/iwannabrute.profile ||
                die "Failed to write the iPad1,1 ramdisk profile marker."
        fi
        run_checked "Set ramdisk payload permissions" \
            chmod +x \
                ramdisk_mountpoint/usr/local/bin/restored_external \
                ramdisk_mountpoint/usr/local/bin/restored_external.sshrd \
                ramdisk_mountpoint/usr/bin/bruteforce \
                ramdisk_mountpoint/usr/bin/device_infos

        run_checked "Detach RestoreRamDisk image" hdiutil detach ramdisk_mountpoint
        active_mountpoint=""
        run_checked "Repack RestoreRamDisk image" \
            ../../../bin/Darwin/xpwntool RestoreRamDisk.raw.dmg ramdisk.dmg -t RestoreRamDisk.dec.img3
        require_file ramdisk.dmg
        mv -v ramdisk.dmg ../ || die "Failed to cache ramdisk.dmg."

        run_checked "Extract iBSS" ../../../bin/Darwin/xpwntool iBSS.dec.img3 iBSS.raw
        run_checked "Patch pwned iBSS" ../../../bin/Darwin/iBoot32Patcher iBSS.raw iBSS.patched -r
        require_file iBSS.patched
        cp iBSS.patched ../pwnediBSS || die "Failed to cache pwnediBSS."
        run_checked "Repack iBSS" ../../../bin/Darwin/xpwntool iBSS.patched iBSS -t iBSS.dec.img3
        require_file iBSS
        mv -v iBSS ../ || die "Failed to cache iBSS."

        run_checked "Extract iBEC" ../../../bin/Darwin/xpwntool iBEC.dec.img3 iBEC.raw
        run_checked "Patch ramdisk iBEC" \
            ../../../bin/Darwin/iBoot32Patcher iBEC.raw iBEC.patched -r -d -b "rd=md0 $bootargs"
        run_checked "Patch boot iBEC" \
            ../../../bin/Darwin/iBoot32Patcher iBEC.raw iBEC_boot.patched -r -d -b "$bootargs"
        run_checked "Repack ramdisk iBEC" \
            ../../../bin/Darwin/xpwntool iBEC.patched iBEC -t iBEC.dec.img3
        run_checked "Repack boot iBEC" \
            ../../../bin/Darwin/xpwntool iBEC_boot.patched iBEC_boot -t iBEC.dec.img3
        require_file iBEC
        require_file iBEC_boot
        mv -v iBEC ../ || die "Failed to cache iBEC."
        mv -v iBEC_boot ../ || die "Failed to cache iBEC_boot."
        mv -v applelogo.dec.img3 ../applelogo || die "Failed to cache applelogo."
        mv -v DeviceTree.dec.img3 ../devicetree || die "Failed to cache devicetree."
        mv -v kernelcache.dec.img3 ../kernelcache || die "Failed to cache kernelcache."
        cd ..
        rm -rf work

        echo "Patching kernel..."
        if [[ "$device" == "iPad1,1" ]]; then
            run_checked "Extract uncompressed iPad kernelcache" \
                ../../bin/Darwin/xpwntool kernelcache kernelcache.raw
            run_checked "Apply iOS 5 A4 AES kernel patch" \
                "$temporary_aespatcher" ios5 kernelcache.raw kernelcache.dec
        else
            run_checked "Apply A4 AES kernel patch" \
                ../../bin/Darwin/aespatched kernelcache kernelcache.dec
        fi
        require_file kernelcache.dec
        mv kernelcache kernelcache.orig || die "Failed to preserve the original kernelcache."
        run_checked "Repack patched kernelcache" \
            ../../bin/Darwin/xpwntool kernelcache.dec kernelcache -t kernelcache.orig
        require_file kernelcache
        cd ../../
    fi
    echo "[OK] Ramdisk build completed for $device $version."
}

install_depends() {
    echo "Installing dependencies..."
    rm -f "../resources/firstrun"

    if [[ $platform == "linux" ]]; then
        echo "iwannabrute does not support linux at the moment =(."
    elif [[ $platform == "macos" ]]; then
        echo "* iwannabrute will be installing dependencies and setting up permissions of tools"
        xattr -cr ./bin/Darwin
        echo "Installing Xcode Command Line Tools"
        xcode-select --install
        echo "* Make sure to install requirements from Homebrew/MacPorts: https://github.com/LukeZGD/Legacy-iOS-Kit/wiki/How-to-Use"
        pause
    fi
    echo "$platform_ver" > "./resources/firstrun"

    echo "Install script done! Please run the script again to proceed"
    echo "If your iOS device is plugged in, unplug and replug your device"
    exit
}

pause() {
    echo "Press Enter/Return to continue (or press Ctrl+C to cancel)"
    read -s
}

set_tool_paths() {
    : '
    sets variables: platform, platform_ver, dir
    also checks architecture (linux) and macos version
    also set distro, debian_ver, ubuntu_ver, fedora_ver variables for linux

    list of tools set here:
    bspatch, jq, scp, ssh, sha1sum (for macos: shasum -a 1), zenity

    these ones "need" sudo for linux arm, not for others:
    futurerestore, gaster, idevicerestore, ipwnder, irecovery

    tools set here will be executed using:
    $name_of_tool

    the rest of the tools not listed here will be executed using:
    "$dir/$name_of_tool"
    '
    if [[ $OSTYPE == "darwin"* ]]; then
        platform="macos"
        platform_ver="${1:-$(sw_vers -productVersion)}"
        dir="./bin/Darwin"

        platform_arch="$(uname -m)"
        if [[ $platform_arch == "arm64" ]]; then
            echo "Please note that arm64 macs are semi-untested."
        fi

        # macos version check
        mac_majver="${platform_ver:0:2}"
        if [[ $mac_majver == 10 ]]; then
            mac_minver=${platform_ver:3}
            mac_minver=${mac_minver%.*}
            # go here if need to disable os x 10.11 support for now
            if (( mac_minver < 11 )); then
                warn "Your macOS version ($platform_ver - $platform_arch) is not supported. Expect features to not work properly."
                print "* Supported versions are macOS 10.11 and newer. (10.12 and newer recommended)"
                pause
            fi
        fi

        # kill macos daemons
        killall -STOP AMPDevicesAgent AMPDeviceDiscoveryAgent MobileDeviceUpdater
    else
        echo "Your platform ($OSTYPE) is not supported." "* Supported platforms: macOS"
        exit
    fi


    echo "Running on platform: $platform ($platform_ver - $platform_arch)"
    if [[ ! -d $dir ]]; then
        echo "Failed to find bin directory ($dir), cannot continue." \
        "* Git clone iwannabrute again"
    fi
    if [[ $device_sudoloop == 1 ]]; then
        sudo chmod +x $dir/*
        if [[ $? != 0 ]]; then
            echo "Failed to set up execute permissions of binaries, cannot continue. Try to move iwannabrute somewhere else."
        fi
    else
        chmod +x $dir/*
    fi

    futurerestore+="$dir/futurerestore"
    ideviceactivation+="$dir/ideviceactivation"
    idevicediagnostics+="$dir/idevicediagnostics"
    ideviceinfo="$dir/ideviceinfo"
    ideviceinstaller+="$dir/ideviceinstaller"
    idevicerestore+="$dir/idevicerestore"
    ifuse="$(command -v ifuse)"
    irecovery+="$dir/irecovery"
    irecovery2+="$dir/irecovery2"
    irecovery3+="../$dir/irecovery"
    jq="$dir/jq"

    if [[ $(ssh -V 2>&1 | grep -c SSH_8.8) == 1 || $(ssh -V 2>&1 | grep -c SSH_8.9) == 1 ||
          $(ssh -V 2>&1 | grep -c SSH_9.) == 1 || $(ssh -V 2>&1 | grep -c SSH_1) == 1 ]]; then
        echo "    PubkeyAcceptedAlgorithms +ssh-rsa" >> ssh_config
    elif [[ $(ssh -V 2>&1 | grep -c SSH_6) == 1 ]]; then
        cat ./resources/ssh_config | sed "s,Add,#Add,g" | sed "s,HostKeyA,#HostKeyA,g" > ssh_config
    fi
    scp2+=" -F ./ssh_config"
    ssh2+=" -F ./ssh_config"

}

check_ramdisk_cache(){
    ramdisk_path="ramdisks/bruteforce-$deviceid-$ios_version"
    local required_cache_files="iBSS iBEC iBEC_boot pwnediBSS applelogo devicetree kernelcache ramdisk.dmg version"
    local cache_file
    local cache_valid=true

    if [ -d "$ramdisk_path" ]; then
        echo "Ramdisk exists, checking ramdisk integrity..."
        for cache_file in $required_cache_files; do
            if [[ ! -s "$ramdisk_path/$cache_file" ]]; then
                echo "[WARN] Ramdisk cache is missing $cache_file."
                cache_valid=false
            fi
        done
        if [[ "$cache_valid" == "true" ]]; then
            echo "Ramdisk is alright, checking version..."
            local ramdisk_version
            ramdisk_version=$(cat "$ramdisk_path/version")
            if [[ "$ramdisk_version" == "$ramdisk_cache_version" ]]; then
                echo "Ramdisk is up to date. Continuing..."
                return
            else
                echo "Ramdisk is outdated."
            fi
        else
            echo "Ramdisk is incomplete."
        fi
    else
        echo "Ramdisk does not exist."
    fi

    echo "Creating a clean ramdisk cache..."
    rm -rf "$ramdisk_path" || die "Unable to remove the incomplete ramdisk cache."
    mk_bruteforce_ramdisk "$deviceid" "$ios_version"

    for cache_file in $required_cache_files; do
        require_file "$ramdisk_path/$cache_file"
    done
    echo "[OK] Ramdisk cache is complete."
}

device_is_pwnd() {
    "$project_root/bin/Darwin/irecovery" -q 2>&1 | grep -q "PWND"
}

wait_for_pwnd() {
    local attempts="${1:-10}"
    local attempt
    for ((attempt=1; attempt<=attempts; attempt++)); do
        if device_is_pwnd; then
            echo "[OK] Verified PWND state."
            return 0
        fi
        echo "[WAIT] PWND verification $attempt/$attempts"
        sleep 1
    done
    return 1
}

pwn_device() {
    if [ "$is_fake_device" = true ]; then
        die "Cannot pwn a fake device."
    fi

    if device_is_pwnd; then
        echo "Device already in pwnDFU mode."
        if [[ "$is_a4" == "true" ]]; then
            echo "[OK] Skipping all exploit tools for already-pwned A4 device."
        else
            ipwndfu send_ibss
        fi
        return
    fi

    case $pwnder in
    a5)
        echo ""
        echo ""
        echo "Detected A5 device."
        echo "You need to have an Arduino and USB Host Shield for checkm8-a5."
        echo "Use LukeZGD fork of checkm8-a5: https://github.com/LukeZGD/checkm8-a5"
        echo "You may also use checkm8-a5 for the Pi Pico: https://www.reddit.com/r/LegacyJailbreak/comments/1djuprf/working_checkm8a5_on_the_raspberry_pi_pico/"
        echo "Pwn device using checkm8-a5 and then connect it."
        if ! device_is_pwnd; then
            echo "[*] Waiting for device in pwnDFU mode"
        fi
    
        while ! device_is_pwnd; do
            sleep 1
        done

        echo "Device in pwnDFU mode detected!"
        ipwndfu send_ibss
        ;;
    ipwndfu)
        echo "Using ipwndfu for pwning..."
        ipwndfu pwn
        ;;
    ipwnder|ipwnder32)
        echo "Using ipwnder for pwning..."
        run_ipwnder
        wait_for_pwnd 15 || die "ipwnder completed but the device never reported a verified PWND state."
        ;;
    *)
        die "No pwnDFU method is configured for $deviceid."
        ;;
    esac
}

ipwndfu() {
    local tool_pwned=0
    local python2="$(command -v python2)"
    local pyenv="$(command -v pyenv)"
    local pyenv2="$HOME/.pyenv/versions/2.7.18/bin/python2"

    if [[ -z "$pyenv" && -e "$HOME/.pyenv/bin/pyenv" ]]; then
        pyenv="$HOME/.pyenv/bin/pyenv"
    fi
    if [[ $platform == "macos" ]] && (( mac_majver < 12 )); then
        python2="/usr/bin/python"
        echo "Using macOS system python2"
        echo "* You may also install python2 from pyenv if something is wrong with system python2"
        echo "* Install pyenv by running: curl https://pyenv.run | bash"
        echo "* Install python2 from pyenv by running: pyenv install 2.7.18"
    elif [[ -n "$python2" && $device_sudoloop == 1 ]]; then
        p2_sudo="sudo"
    elif [[ -z "$python2" && ! -e "$pyenv2" ]]; then
        echo "python2 is not installed. Attempting to install python2 before continuing"
        echo "* Install python2 from pyenv by running: pyenv install 2.7.18"
        if [[ -z "$pyenv" ]]; then
            echo "pyenv is not installed. Attempting to install pyenv before continuing"
            echo "* Install pyenv by running: curl https://pyenv.run | bash"
            echo "Installing pyenv"
            curl https://pyenv.run | bash
            pyenv="$HOME/.pyenv/bin/pyenv"
            if [[ ! -e "$pyenv" ]]; then
                echo "Cannot detect pyenv, its installation may have failed." \
                "* Try installing pyenv manually before retrying."
            fi
        fi
        echo "Installing python2 using pyenv"
        echo "* This may take a while, but should not take longer than a few minutes."
        "$pyenv" install 2.7.18
        if [[ ! -e "$pyenv2" ]]; then
            echo "Cannot detect python2 from pyenv, its installation may have failed."
            echo "* Try installing pyenv and/or python2 manually:"
            echo "    pyenv:   > curl https://pyenv.run | bash"
            echo "    python2: > \"$pyenv\" install 2.7.18"
            echo "Cannot detect python2 for ipwndfu, cannot continue."
        fi
    fi
    if [[ -e "$pyenv2" ]]; then
        echo "python2 from pyenv detected, this will be used"
        if [[ $device_sudoloop == 1 ]]; then
            p2_sudo="sudo"
        fi
        python2="$pyenv2"
    fi

    mkdir resources/ipwndfu 2>/dev/null

    local ipwndfu_comm="1d22fd01b0daf52bbcf1ce730022d4212d87f967"
    local ipwndfu_sha1="30f0802078ab6ff83d6b918e13f09a652a96d6dc"
    if [[ ! -s resources/ipwndfu || $(cat resources/ipwndfu/sha1check) != "$ipwndfu_sha1" ]]; then
        rm -rf resources/ipwndfu-*
        download_file https://github.com/LukeZGD/ipwndfu/archive/$ipwndfu_comm.zip ipwndfu.zip $ipwndfu_sha1
        unzip -q ipwndfu.zip -d resources
        rm -rf resources/ipwndfu
        mv resources/ipwndfu-* resources/ipwndfu
        echo "$ipwndfu_sha1" > resources/ipwndfu/sha1check
        rm -rf resources/ipwndfu-*
    fi
    # create a lib symlink in the home directory for macos, needed by ipwndfu/pyusb
    # no need to do this for homebrew x86_64 since /usr/local/lib is being checked along with ~/lib, but lets do the symlink anyway
    if [[ $platform == "macos" ]]; then
        if [[ -e "$HOME/lib" && -e "$HOME/lib.bak" ]]; then
            rm -rf "$HOME/lib"
        elif [[ -e "$HOME/lib" ]]; then
            mv "$HOME/lib" "$HOME/lib.bak"
        fi
        # prioritize macports here since it has longer support
        if [[ -e /opt/local/lib/libusb-1.0.dylib ]]; then
            echo "Detected libusb installed via MacPorts"
            ln -sf /opt/local/lib "$HOME/lib"
        elif [[ -e /opt/homebrew/lib/libusb-1.0.dylib ]]; then
            echo "Detected libusb installed via Homebrew (arm64)"
            ln -sf /opt/homebrew/lib "$HOME/lib"
        elif [[ -e /usr/local/lib/libusb-1.0.dylib ]]; then
            echo "Detected libusb installed via Homebrew (x86_64)"
            ln -sf /usr/local/lib "$HOME/lib"
        else
            echo "No libusb detected. ipwndfu might fail especially on arm64 (Apple Silicon) devices."
        fi
    fi

    pushd resources/ipwndfu >/dev/null

    case $1 in
        "send_ibss" )
            echo "Sending iBSS using ipwndfu..."
            rm pwnediBSS
            cd ../../
            cp ramdisks/bruteforce-$deviceid-$ios_version/pwnediBSS resources/ipwndfu/pwnediBSS
            cd resources/ipwndfu
            $p2_sudo "$python2" ipwndfu -l pwnediBSS
            cd ../../
        ;;

        "pwn" )
            tool_pwndfu="ipwndfu"
            echo "Placing device to pwnDFU Mode using ipwndfu"
            $p2_sudo "$python2" ipwndfu -p
            echo "Sending iBSS using ipwndfu..."
            rm pwnediBSS
            cd ../../
            cp ramdisks/bruteforce-$deviceid-$ios_version/pwnediBSS resources/ipwndfu/pwnediBSS
            cd resources/ipwndfu
            $p2_sudo "$python2" ipwndfu -l pwnediBSS
            cd ../../
        ;;

        "pwn_noibss" )
            tool_pwndfu="ipwndfu"
            echo "Placing device to pwnDFU Mode using ipwndfu"
            $p2_sudo "$python2" ipwndfu -p
        ;;
    esac

}

run_ipwnder() {
    echo "Pwning device using ipwnder"
    run_checked "Run ipwnder" ./bin/Darwin/ipwnder
}

download_file() {
    # usage: download_file {link} {target location} {sha1}
    local filename="$(basename $2)"
    echo "Downloading $filename..."
    curl -L $1 -o $2
    if [[ ! -s $2 ]]; then
        echo "Downloading $2 failed. Please run the script again"
    fi
    if [[ -z $3 ]]; then
        return
    fi
    local sha1=$($sha1sum $2 | awk '{print $1}')
    if [[ $sha1 != "$3" ]]; then
        echo "Verifying $filename failed. The downloaded file may be corrupted or incomplete. Please run the script again" \
        "* SHA1sum mismatch. Expected $3, got $sha1"
    fi
}

get_device_info() {
    fake_deviceid=""
    build_only=false
    ramdisk_cache_version="2.0-a4.5"
    for arg in "$@"; do
        case $arg in
            fake-deviceid=*)
                fake_deviceid="${arg#*=}"
                ;;
            build-only)
                build_only=true
                ;;
        esac
    done
    if [[ -n "$fake_deviceid" ]]; then
        echo "[*] Using fake device: $fake_deviceid"
        is_fake_device=true
        deviceid="$fake_deviceid"
    else
        if ! (system_profiler SPUSBDataType 2> /dev/null | grep ' Apple Mobile Device (DFU Mode)' > /dev/null); then
            echo "[*] Waiting for device in DFU mode"
        fi

        while ! (system_profiler SPUSBDataType 2> /dev/null | grep ' Apple Mobile Device (DFU Mode)' > /dev/null); do
            sleep 1
        done

        deviceid=$(bin/Darwin/irecovery -q | grep PRODUCT | sed 's/PRODUCT: //')
        [[ -n "$deviceid" ]] || die "irecovery did not report a device product identifier."
    fi
    case $deviceid in
        "iPhone3,2") device_name="iPhone 4 (GSM, Rev A)" default_version="7.1.2" pwnder="ipwnder32" is_a4=true ;;
        "iPhone4,1") device_name="iPhone 4S" default_version="9.0.2" pwnder="a5";;
        "iPhone5,1") device_name="iPhone 5 (GSM)" default_version="9.0.2" pwnder="ipwndfu";;
        "iPhone5,2") device_name="iPhone 5 (Global)" default_version="9.0.2" pwnder="ipwndfu";;
        "iPhone5,3") device_name="iPhone 5C (GSM)" default_version="9.0.2" pwnder="ipwndfu";;
        "iPhone5,4") device_name="iPhone 5C (Global)" default_version="9.0.2" pwnder="ipwndfu";;
        "iPad1,1") device_name="iPad 1" default_version="5.1.1" pwnder="ipwnder32" is_a4=true ramdisk_cache_version="2.0-a4.8" ;;
        "iPad2,1") device_name="iPad 2 (Wi-Fi)" default_version="9.0.2" pwnder="a5";;
        "iPad2,2") device_name="iPad 2 (GSM)" default_version="9.0.2" pwnder="a5";;
        "iPad2,3") device_name="iPad 2 (CDMA)" default_version="9.0.2" pwnder="a5";;
        "iPad2,4") device_name="iPad 2 (Wi-Fi, Rev A)" default_version="9.0.2" pwnder="a5";;
        "iPad2,5") device_name="iPad mini 1 (Wi-Fi)" default_version="9.0.2" pwnder="a5";;
        "iPad2,6") device_name="iPad mini 1 (GSM)" default_version="9.0.2" pwnder="a5";;
        "iPad2,7") device_name="iPad mini 1 (Global)" default_version="9.0.2" pwnder="a5";;
        "iPad3,1") device_name="iPad 3 (Wi-Fi)" default_version="9.0.2" pwnder="a5";;
        "iPad3,2") device_name="iPad 3 (CDMA)" default_version="9.0.2" pwnder="a5";;
        "iPad3,3") device_name="iPad 3 (GSM)" default_version="9.0.2" pwnder="a5";;
        "iPad3,4") device_name="iPad 4 (Wi-Fi)" default_version="9.0.2" pwnder="ipwndfu";;
        "iPad3,5") device_name="iPad 4 (GSM)" default_version="9.0.2" pwnder="ipwndfu";;
        "iPad3,6") device_name="iPad 4 (Global)" default_version="9.0.2" pwnder="ipwndfu";;
        "iPod4,1") device_name="iPod touch 4" default_version="6.1.6" pwnder="ipwnder32" is_a4=true ;;
        "iPod5,1") device_name="iPod touch 5" default_version="9.0.2" pwnder="a5";;
        *) device_name="Unsupported device" unsupported=true;;
    esac
    if [[ -z "${unsupported+x}" ]]; then
        echo "Detected $device_name ($deviceid)."
    else
        die "$deviceid is unsupported; connect a supported device and try again."
    fi
    
}

irecovery_retry() {
    local description="$1"
    shift
    local attempt status
    for attempt in 1 2 3; do
        echo "[RUN] $description (attempt $attempt/3)"
        "$project_root/bin/Darwin/irecovery" "$@"
        status=$?
        if [[ $status -eq 0 ]]; then
            echo "[OK] $description"
            return 0
        fi
        echo "[WARN] $description failed with exit status $status."
        sleep 2
    done
    die "$description failed after 3 attempts."
}

send_ramdisk() {
    echo "Booting ramdisk..."
    cd "ramdisks/bruteforce-$deviceid-$ios_version" ||
        die "Unable to enter the ramdisk cache directory."
    local boot_asset
    for boot_asset in iBSS iBEC devicetree ramdisk.dmg kernelcache; do
        require_file "$boot_asset"
    done

    sleep 3
    irecovery_retry "Upload iBSS" -f iBSS

    sleep 1
    irecovery_retry "Upload iBEC" -f iBEC

    sleep 3
    irecovery_retry "Set diagnostic screen color" -c "bgcolor 0 255 255"

    sleep 1
    irecovery_retry "Upload device tree" -f devicetree
    irecovery_retry "Activate device tree" -c devicetree

    sleep 1
    irecovery_retry "Upload ramdisk" -f ramdisk.dmg
    irecovery_retry "Activate ramdisk" -c ramdisk

    sleep 1
    irecovery_retry "Upload kernelcache" -f kernelcache
    irecovery_retry "Boot device" -c bootx
    echo ""
    echo "Device should show text on screen now."
    echo "After passcode is found please reboot using home + power button."
}

version_check() {
    if [[ $no_version_check == 1 ]]; then
        echo "No version check flag detected, update check is disabled and no support will be provided."
        return
    fi
    pushd .. >/dev/null
    version_update_check
    if [[ -z $version_latest ]]; then
        echo "Failed to check for updates. GitHub may be down or blocked by your network."
    elif [[ $git_hash_latest != "$git_hash" ]]; then
        if [[ -z $version_current ]]; then
            echo "* Latest version:  $version_latest ($git_hash_latest)"
            echo "* Please download/pull the latest version before proceeding."
            version_update
        elif (( $(echo $version_current | cut -c 2- | sed -e 's/\.//g') >= $(echo $version_latest | cut -c 2- | sed -e 's/\.//g') )); then
            echo "Current version is newer/different than remote: $version_latest ($git_hash_latest)"
        else
            echo "* A newer version of iwannabrute is available."
            echo "* Current version: $version_current ($git_hash)"
            echo "* Latest version:  $version_latest ($git_hash_latest)"
            echo "* Please download/pull the latest version before proceeding."
            version_update
        fi
    fi
    popd >/dev/null
}

version_update_check() {
    pushd "$(dirname "$0")/tmp$$" >/dev/null
    if [[ $platform == "macos" && ! -e ./resources/firstrun ]]; then
        xattr -cr ./bin/Darwin/Darwin
    fi
    echo "Checking for updates..."
    github_api=$(curl https://api.github.com/repos/platinumstufff/iwannabrute/latest 2>/dev/null)
    version_latest=$(echo "$github_api" | $jq -r '.assets[] | select(.name|test("complete")) | .name' | cut -c 25- | cut -c -9)
    git_hash_latest=$(echo "$github_api" | $jq -r '.assets[] | select(.name|test("git-hash")) | .name' | cut -c 21- | cut -c -7)
    popd >/dev/null
}

version_update() {
    local url
    local req
    select_yesno "Do you want to update now?" 1
    if [[ $? != 1 ]]; then
        log "User selected N, cannot continue. Exiting."
        exit
    fi
    if [[ -d .git ]]; then
        log "Running git pull..."
        print "* If this fails for some reason, run: git reset --hard"
        print "* To clean more files if needed, run: git clean -df"
        git pull
        pushd "$(dirname "$0")/tmp$$" >/dev/null
        log "Done! Please run the script again"
        exit
    elif (( $(ls bin | wc -l) > 1 )); then
        req=".assets[] | select (.name|test(\"complete\")) | .browser_download_url"
    elif [[ $platform == "linux" ]]; then
        req=".assets[] | select (.name|test(\"${platform}_$platform_arch\")) | .browser_download_url"
    else
        req=".assets[] | select (.name|test(\"${platform}\")) | .browser_download_url"
    fi
    pushd "$(dirname "$0")/tmp$$" >/dev/null
    url="$(echo "$github_api" | $jq -r "$req")"
    log "Downloading: $url"
    curl -L $url -o latest.zip
    if [[ ! -s latest.zip ]]; then
        error "Download failed. Please run the script again"
    fi
    popd >/dev/null
    log "Updating..."
    cp resources/firstrun tmp$$ 2>/dev/null
    rm -r bin/ LICENSE README.md restore.sh
    if [[ $device_sudoloop == 1 ]]; then
        sudo rm -rf resources/
    fi
    rm -r resources/ saved/ipwndfu/ 2>/dev/null
    unzip -q tmp$$/latest.zip -d .
    cp tmp$$/firstrun resources 2>/dev/null
    pushd "$(dirname "$0")/tmp$$" >/dev/null
    log "Done! Please run the script again"
    exit
}

select_yesno() {
    local msg="Do you want to continue?"
    if [[ -n $1 ]]; then
        msg="$1"
    fi
    if [[ $2 == 1 ]]; then
        msg+=" (Y/n): "
    else
        msg+=" (y/N): "
    fi
        local opt
        while true; do
            read -p "$(echo "$msg")" opt
            case $opt in
                [NnYy] ) break;;
                "" )
                    # select default if no y/n given
                    if [[ $2 == 1 ]]; then
                        opt='y'
                    else
                        opt='n'
                    fi
                    break
                ;;
            esac
        done
        if [[ $2 == 1 ]]; then # default is "yes" if $2 is set to 1
            [[ $opt == [Nn] ]] && return 0 || return 1
        else                   # default is "no" otherwise
            [[ $opt == [Yy] ]] && return 1 || return 0
        fi
}

main() {
clear

echo "  *****  iWannaBrute  *****  "
echo " - Script by platinumstuff - "
echo ""
echo "* Version: $script_version   "
echo ""
echo ""


if [[ $EUID == 0 && $run_as_root != 1 ]]; then
    die "Running the script as root is not allowed."
fi

if [[ ! -d "./resources" ]]; then
    die "The resources folder cannot be found. Replace it and try again. If it is present, remove spaces from the project path."
fi

set_tool_paths

if [[ $no_internet_check != 1 ]]; then
    echo "Checking Internet connection..."
    local try=("google.com" "www.apple.com" "208.67.222.222")
    local check
    for i in "${try[@]}"; do
        ping -c1 $i >/dev/null
           check=$?
        if [[ $check == 0 ]]; then
            break
        fi
    done
    if [[ $check != 0 ]]; then
        die "Please check your Internet connection before proceeding."
    fi
fi


local checks=(curl git patch unzip xxd zip)
local check_fail
for check in "${checks[@]}"; do
    if [[ $debug_mode == 1 ]]; then
        echo "Checking for $check in PATH"
    fi
    if [[ ! $(command -v $check) ]]; then
        echo "$check not found in PATH"
        check_fail=1
    fi
done

if [[ ! -e "./resources/firstrun" || $(cat "./resources/firstrun") != "$platform_ver" || $check_fail == 1 ]]; then
    install_depends
fi
get_device_info "$@"
echo ""
echo "Enter ramdisk version ($default_version is default)"
echo ""
read -p "Version:" ios_version
major="${ios_version%%.*}"
if [ "$major" = "10" ]; then
    echo "For iOS 10.x devices use 9.0.2 ramdisk."
    exit
fi
ios_version="${ios_version:-$default_version}"

if [[ "$is_a4" == "true" ]]; then
    preflight_a4
fi

echo ""
echo "Checking is Ramdisk exists."
echo ""

check_ramdisk_cache

if [[ "$build_only" == "true" ]]; then
    echo "[OK] Build-only validation completed for $deviceid $ios_version."
    return
fi

#mk_bruteforce_ramdisk $deviceid $ios_version

echo ""
echo ""

echo "Pwning and sending a ramdisk..."

pwn_device

send_ramdisk

}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    othertmp=$(ls "$(dirname "$0")" | grep -c tmp)
    pushd "$(dirname "${BASH_SOURCE[0]}")" > /dev/null
    project_root="$(pwd)"
    trap cleanup_build_mount EXIT
    init_diagnostic_log
    main "$@"
fi
