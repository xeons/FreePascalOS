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
# User mode test of the AArch64 build: coretest, in QEMU's virt machine
# (GICv2, Cortex-A72, edk2 firmware at EL2, as on the Raspberry Pi 4).
#
#   test-qemu-arm64-user.sh <esp-directory> <test-disk-image> <system-disk-image>
#
# Boots with init=/bin/coretest and "test-exit", as the x86-64 test does
# (scripts/test-qemu.sh), with the disks in the same order: disk0 the
# boot volume, disk1 the test disk, disk2 the system disk, disk3 a disk
# that fails to read sector 100 - all virtio disks (the AHCI controller
# finds no drives on this machine yet, so there is no disk4, the optical
# drive) - a virtio network card with the wget test's web servers, a
# second network card (e1000e), HD Audio recorded into a WAV file (no
# AC'97: PCI devices on interrupt lines get no interrupts here yet, so its
# checks fail rather than wait forever)
# and run-qemu-arm64.sh's USB keyboard. Reports coretest's pass
# and fail counts and the failed checks; the kernel's exit status 5
# means some check failed.
#
# The serial log stays in the build directory (test-arm64-coretest.log).
# Not part of make test (it needs qemu-system-aarch64 and the edk2
# AArch64 firmware); run it with make arm64-test.

set -uo pipefail

esp_directory="$1"
test_disk_image="$2"
system_disk_image="$3"
build_directory=$(dirname "$esp_directory")
script_directory=$(cd "$(dirname "$0")" && pwd)
test_esp_directory="$build_directory/test-esp-user"
timeout_seconds=${TIMEOUT:-1800}

serial_log="$build_directory/test-arm64-coretest.log"
run_test_disk="$build_directory/test-arm64-disk-run.img"
run_system_disk="$build_directory/test-arm64-system-run.img"
fault_disk="$build_directory/test-arm64-fault-disk.img"
fault_rules="$build_directory/test-arm64-fault-disk.conf"

rm -rf "$test_esp_directory"
cp -r "$esp_directory" "$test_esp_directory"
echo "test-exit fstest heapchecks init=/bin/coretest hangdump=20" > "$test_esp_directory/FreePascalOS/options.txt"
cp -f "$test_disk_image" "$run_test_disk"
cp -f "$system_disk_image" "$run_system_disk"
rm -f "$fault_disk"
truncate -s 1M "$fault_disk"
printf '[inject-error]\nevent = "read_aio"\nerrno = "5"\nsector = "100"\n' > "$fault_rules"

devices=()
devices+=(-drive if=none,id=testdisk,format=raw,cache=unsafe,file="$run_test_disk"
    -device virtio-blk-pci,drive=testdisk)
devices+=(-drive if=none,id=systemdisk,format=raw,cache=unsafe,file="$run_system_disk"
    -device virtio-blk-pci,drive=systemdisk)
devices+=(-drive if=none,id=faultdisk,format=raw,file=blkdebug:"$fault_rules":"$fault_disk"
    -device virtio-blk-pci,drive=faultdisk)
devices+=(-audiodev wav,id=sound0,path="$build_directory/test-arm64-audio.wav"
    -device intel-hda -device hda-output,audiodev=sound0
    -audiodev none,id=microphone0 -device hda-micro,audiodev=microphone0
    )

# The web servers of the wget test, as in scripts/test-qemu.sh.
web_server="python3 $script_directory/test-web-server.py"
certificate_directory="$script_directory/../tools/TlsTest/certificates"
s_server_port=$((20000 + $$ % 20000))
openssl s_server -quiet -www -tls1_3 -accept "$s_server_port" -cert "$certificate_directory/server-rsa.pem" \
    -key "$certificate_directory/server-rsa.key" < /dev/null > /dev/null 2>&1 &
s_server_process=$!
trap 'kill "$s_server_process" 2> /dev/null' EXIT
forwards="guestfwd=tcp:10.0.2.100:7-cmd:cat"
forwards+=",guestfwd=tcp:10.0.2.101:443-cmd:$web_server https server-chain.pem server.key"
forwards+=",guestfwd=tcp:10.0.2.102:80-cmd:$web_server http"
forwards+=",guestfwd=tcp:10.0.2.103:443-cmd:$web_server relay $s_server_port"
forwards+=",guestfwd=tcp:10.0.2.104:443-cmd:$web_server https wrong-name-chain.pem wrong-name.key"
forwards+=",guestfwd=tcp:10.0.2.105:443-cmd:$web_server https other-server.pem other-server.key"
forwards+=",guestfwd=tcp:10.0.2.106:443-cmd:$web_server https expired-chain.pem expired.key"
devices+=(-nic none -netdev "user,id=net0,$forwards" -device virtio-net-pci,netdev=net0
    -netdev user,id=net1 -device e1000e,netdev=net1)

rm -f "$build_directory/QEMU_VARS.fd"
AUDIO=none VIRTUALIZATION=1 PROCESSORS=4 MEMORY=1G SEMIHOSTING=1 SERIAL=file:"$serial_log" \
    timeout "$timeout_seconds" "$script_directory/run-qemu-arm64.sh" "$test_esp_directory" --headless \
    -- "${devices[@]}" < /dev/null > /dev/null 2>&1
status=$?

counts=$(sed -n 's/.*\[coretest\] \([0-9]* passed, [0-9]* failed\).*/\1/p' "$serial_log" | tail -n 1)
case "$status" in
    1) result="passed" ;;
    3) result="failed (kernel panic)" ;;
    5) result="failed (coretest reported failures)" ;;
    124) result="failed (timed out after $timeout_seconds seconds)" ;;
    *) result="failed (QEMU exit status $status)" ;;
esac
echo "ARM64 CORETEST: $result, ${counts:-no result} ($serial_log)"
grep -a '\[coretest\] FAIL' "$serial_log" | head -n 40
[[ "$result" == passed ]]
