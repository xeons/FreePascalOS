#!/usr/bin/env bash
# FreePascalOS
# Copyright (C) 2026 Brandon Scott
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

#
# User mode test of the AArch64 build in QEMU's virt machine (GICv2,
# Cortex-A72, edk2 firmware at EL2, as on the Raspberry Pi 4):
#
#   test-qemu-arm64-user.sh <esp-directory> <test-disk-image> <system-disk-image>
#
# 1. coretest: boots with init=/bin/coretest and "test-exit", as the
#    x86-64 test does (scripts/test-qemu.sh), with the disks on an AHCI
#    controller in the same order (disk0 the boot volume, disk1 the test
#    disk, disk2 the system disk, disk3 a disk that fails to read sector
#    100, disk4 an optical drive), a virtio network card with the wget
#    test's web servers, HD Audio and AC'97, and a second network card.
#    Reports coretest's pass and fail counts; exit status 5 from the
#    kernel means some check failed.
# 2. The shell: boots the system normally (the service manager in text
#    mode, kernel option "boot=text") and logs in on the serial console,
#    runs a few commands and checks what they print.
#
# The serial logs stay in the build directory (test-arm64-coretest.log,
# test-arm64-shell.log). Not part of make test (it needs
# qemu-system-aarch64 and the edk2 AArch64 firmware); run it with
# make arm64-test.

set -uo pipefail

esp_directory="$1"
test_disk_image="$2"
system_disk_image="$3"
build_directory=$(dirname "$esp_directory")
script_directory=$(cd "$(dirname "$0")" && pwd)
test_esp_directory="$build_directory/test-esp-user"
coretest_timeout=${CORETEST_TIMEOUT:-1500}
shell_timeout=${SHELL_TIMEOUT:-300}

overall=0

prepare_esp() {
    rm -rf "$test_esp_directory"
    cp -r "$esp_directory" "$test_esp_directory"
    echo "$1" > "$test_esp_directory/FreePascalOS/options.txt"
}

# --- coretest ---------------------------------------------------------------

run_coretest() {
    local serial_log="$build_directory/test-arm64-coretest.log"
    local run_test_disk="$build_directory/test-arm64-disk-run.img"
    local run_system_disk="$build_directory/test-arm64-system-run.img"
    local fault_disk="$build_directory/test-arm64-fault-disk.img"
    local fault_rules="$build_directory/test-arm64-fault-disk.conf"


    prepare_esp "test-exit fstest heapchecks init=/bin/coretest hangdump=20"
    cp -f "$test_disk_image" "$run_test_disk"
    cp -f "$system_disk_image" "$run_system_disk"
    rm -f "$fault_disk"
    truncate -s 1M "$fault_disk"
    printf '[inject-error]\nevent = "read_aio"\nerrno = "5"\nsector = "100"\n' > "$fault_rules"

    # Virtio disks after the boot volume's, in slot order (the AHCI
    # controller finds no drives on this machine yet).
    local devices=()
    devices+=(-drive if=none,id=testdisk,format=raw,cache=unsafe,file="$run_test_disk"
        -device virtio-blk-pci,drive=testdisk)
    devices+=(-drive if=none,id=systemdisk,format=raw,cache=unsafe,file="$run_system_disk"
        -device virtio-blk-pci,drive=systemdisk)
    devices+=(-drive if=none,id=faultdisk,format=raw,file=blkdebug:"$fault_rules":"$fault_disk"
        -device virtio-blk-pci,drive=faultdisk)
    # Sound outputs recorded into WAV files (as on x86-64), a USB keyboard
    # (/dev/keyboard: the machine has no PS/2 one).
    devices+=(-audiodev wav,id=sound0,path="$build_directory/test-arm64-audio.wav" -device intel-hda -device hda-output,audiodev=sound0
        -audiodev none,id=microphone0 -device hda-micro,audiodev=microphone0
        -audiodev wav,id=sound1,path="$build_directory/test-arm64-audio-ac97.wav" -device AC97,audiodev=sound1
        -device qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0)

    # The web servers of the wget test, as in scripts/test-qemu.sh.
    local web_server="python3 $script_directory/test-web-server.py"
    local certificate_directory="$script_directory/../tools/TlsTest/certificates"
    local s_server_port=$((20000 + $$ % 20000))
    openssl s_server -quiet -www -tls1_3 -accept "$s_server_port" -cert "$certificate_directory/server-rsa.pem" \
        -key "$certificate_directory/server-rsa.key" < /dev/null > /dev/null 2>&1 &
    local s_server_process=$!
    local forwards="guestfwd=tcp:10.0.2.100:7-cmd:cat"
    forwards+=",guestfwd=tcp:10.0.2.101:443-cmd:$web_server https server-chain.pem server.key"
    forwards+=",guestfwd=tcp:10.0.2.102:80-cmd:$web_server http"
    forwards+=",guestfwd=tcp:10.0.2.103:443-cmd:$web_server relay $s_server_port"
    forwards+=",guestfwd=tcp:10.0.2.104:443-cmd:$web_server https wrong-name-chain.pem wrong-name.key"
    forwards+=",guestfwd=tcp:10.0.2.105:443-cmd:$web_server https other-server.pem other-server.key"
    forwards+=",guestfwd=tcp:10.0.2.106:443-cmd:$web_server https expired-chain.pem expired.key"
    devices+=(-nic none -netdev "user,id=net0,$forwards" -device virtio-net-pci,netdev=net0
        -netdev user,id=net1 -device e1000e,netdev=net1)

    rm -f "$build_directory/QEMU_VARS.fd"
    VIRTUALIZATION=1 PROCESSORS=4 MEMORY=1G SEMIHOSTING=1 SERIAL=file:"$serial_log" \
        timeout "$coretest_timeout" "$script_directory/run-qemu-arm64.sh" "$test_esp_directory" --headless \
        -- "${devices[@]}" < /dev/null > /dev/null 2>&1
    local status=$?
    kill "$s_server_process" 2> /dev/null

    local counts
    counts=$(sed -n 's/.*\[coretest\] \([0-9]* passed, [0-9]* failed\).*/\1/p' "$serial_log" | tail -n 1)
    local result
    case "$status" in
        1) result="passed" ;;
        3) result="failed (kernel panic)" ;;
        5) result="failed (coretest reported failures)" ;;
        124) result="failed (timed out after $coretest_timeout seconds)" ;;
        *) result="failed (QEMU exit status $status)" ;;
    esac
    echo "ARM64 CORETEST: $result, ${counts:-no result} ($serial_log)"
    grep -a '\[coretest\] FAIL' "$serial_log" | head -n 40
    [[ "$result" == passed ]]
}

# --- the shell on the serial console ---------------------------------------

run_shell() {
    local serial_log="$build_directory/test-arm64-shell.log"
    local run_system_disk="$build_directory/test-arm64-shell-system-run.img"
    local input_pipe="$build_directory/test-arm64-shell.in"

    prepare_esp "boot=text"
    cp -f "$system_disk_image" "$run_system_disk"
    rm -f "$serial_log" "$input_pipe"
    mkfifo "$input_pipe"

    rm -f "$build_directory/QEMU_VARS.fd"
    VIRTUALIZATION=1 PROCESSORS=2 SERIAL=file:"$serial_log" \
        timeout "$shell_timeout" "$script_directory/run-qemu-arm64.sh" "$test_esp_directory" --headless \
        "$run_system_disk" -- -serial none -chardev pipe,id=console,path="$input_pipe" \
        < /dev/null > /dev/null 2>&1 &
    local qemu_process=$!

    local result="failed (no login prompt)"
    local waited=0
    while (( waited < shell_timeout - 30 )); do
        if grep -aq 'fpos login:' "$serial_log" 2> /dev/null; then
            result=""
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    kill "$qemu_process" 2> /dev/null
    wait "$qemu_process" 2> /dev/null
    rm -f "$input_pipe"
    if [[ -z "$result" ]]; then
        result=passed
    fi
    echo "ARM64 SHELL TEST: $result ($serial_log)"
    [[ "$result" == passed ]]
}

# ONLY=coretest or ONLY=shell runs one of them.
if [[ "${ONLY:-coretest}" == coretest ]]; then
    run_coretest || overall=1
fi
if [[ "${ONLY:-shell}" == shell ]]; then
    run_shell || overall=1
fi
exit $overall
