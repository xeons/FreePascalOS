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
# boot volume (a virtio disk: the firmware cannot boot from AHCI here,
# and the kernel numbers virtio disks first on AArch64), then on ports
# 1-4 of an AHCI controller disk1 the test disk, disk2 the system disk,
# disk3 a disk that fails to read sector 100 (the AHCI driver's error
# path) and disk4 the optical drive; a virtio network card with the wget
# test's web servers, a second network card (e1000e), HD Audio recorded
# into a WAV file, AC'97 on a PCI interrupt line (its I/O ports through
# the root bridge's window) and USB audio, each recorded too, and
# run-qemu-arm64.sh's USB keyboard. Reports coretest's pass and fail
# counts and the failed checks; the kernel's exit status 5 means some
# check failed.
#
# GIC=3 runs it on a GICv3 (redistributors, LPIs through the ITS for
# the message interrupts) instead of the Pi 4's GICv2.
#
# The serial log stays in the build directory (test-arm64-coretest.log,
# test-arm64-coretest-gic3.log with GIC=3). Run by make arm64-test, and
# by make test when qemu-system-aarch64, the edk2 AArch64 firmware and
# the AArch64 build are there.

set -uo pipefail

esp_directory="$1"
test_disk_image="$2"
system_disk_image="$3"
build_directory=$(dirname "$esp_directory")
script_directory=$(cd "$(dirname "$0")" && pwd)
test_esp_directory="$build_directory/test-esp-user"
timeout_seconds=${TIMEOUT:-1800}

gic_version=${GIC:-2}
log_suffix=""
if [[ "$gic_version" != 2 ]]; then
    log_suffix="-gic$gic_version"
fi
serial_log="$build_directory/test-arm64-coretest$log_suffix.log"
run_test_disk="$build_directory/test-arm64-disk-run.img"
run_system_disk="$build_directory/test-arm64-system-run.img"
fault_disk="$build_directory/test-arm64-fault-disk.img"
fault_rules="$build_directory/test-arm64-fault-disk.conf"

rm -rf "$test_esp_directory"
cp -r "$esp_directory" "$test_esp_directory"
# The GICv3 run also uses only 32 address space identifiers, so their
# generations roll over many times while coretest starts its programs.
extra_options=""
if [[ "${GIC:-2}" != 2 ]]; then
    extra_options="asidbits=5"
fi
echo "test-exit fstest heapchecks init=/bin/coretest hangdump=20 $extra_options" > "$test_esp_directory/FreePascalOS/options.txt"
cp -f "$test_disk_image" "$run_test_disk"
cp -f "$system_disk_image" "$run_system_disk"
rm -f "$fault_disk"
truncate -s 1M "$fault_disk"
printf '[inject-error]\nevent = "read_aio"\nerrno = "5"\nsector = "100"\n' > "$fault_rules"

devices=(-device ich9-ahci,id=ahci)
devices+=(-drive if=none,id=testdisk,format=raw,cache=unsafe,file="$run_test_disk"
    -device ide-hd,drive=testdisk,bus=ahci.1)
devices+=(-drive if=none,id=systemdisk,format=raw,cache=unsafe,file="$run_system_disk"
    -device ide-hd,drive=systemdisk,bus=ahci.2)
devices+=(-drive if=none,id=faultdisk,format=raw,file=blkdebug:"$fault_rules":"$fault_disk"
    -device ide-hd,drive=faultdisk,bus=ahci.3)
cdrom_image="${test_disk_image%.img}-cdrom.img"
if [[ -f "$cdrom_image" ]]; then
    devices+=(-drive if=none,id=cdrom0,format=raw,media=cdrom,readonly=on,file="$cdrom_image"
        -device ide-cd,drive=cdrom0,bus=ahci.4)
fi
audio_recording="$build_directory/test-arm64-audio$log_suffix.wav"
ac97_recording="$build_directory/test-arm64-audio-ac97$log_suffix.wav"
usb_audio_recording="$build_directory/test-arm64-audio-usb$log_suffix.wav"
rm -f "$audio_recording" "$ac97_recording" "$usb_audio_recording"
devices+=(-audiodev wav,id=sound0,path="$audio_recording"
    -device intel-hda -device hda-output,audiodev=sound0
    -audiodev none,id=microphone0 -device hda-micro,audiodev=microphone0
    -audiodev wav,id=sound1,path="$ac97_recording" -device AC97,audiodev=sound1
    -audiodev wav,id=sound2,path="$usb_audio_recording" -device usb-audio,bus=xhci.0,audiodev=sound2
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
forwards+=",guestfwd=tcp:10.0.2.107:443-cmd:$web_server https-h2 server-chain.pem server.key"
devices+=(-nic none -netdev "user,id=net0,$forwards" -device virtio-net-pci,netdev=net0
    -netdev user,id=net1 -device e1000e,netdev=net1)

rm -f "$build_directory/QEMU_VARS.fd"
AUDIO=none GIC="$gic_version" VIRTUALIZATION=1 PROCESSORS=4 MEMORY=1G SEMIHOSTING=1 \
    SERIAL=file:"$serial_log" \
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
# What the sound devices played (check-audio.py: coretest's tones on
# HD Audio, AC'97 at 700 Hz, USB audio at 500 Hz, as on x86-64).
if [[ "$result" == passed ]]; then
    if ! python3 -I "$script_directory/check-audio.py" "$audio_recording" > /dev/null; then
        result="failed (the HD Audio recording does not hold coretest's tones)"
    elif ! python3 -I "$script_directory/check-audio.py" "$ac97_recording" 700:0.5 > /dev/null; then
        result="failed (the AC'97 recording does not hold the 700 Hz tone)"
    elif ! python3 -I "$script_directory/check-audio.py" "$usb_audio_recording" 500:0.5 > /dev/null; then
        result="failed (the USB audio recording does not hold the 500 Hz tone)"
    fi
fi
echo "ARM64 CORETEST (GICv$gic_version): $result, ${counts:-no result} ($serial_log)"
grep -a '\[coretest\] FAIL' "$serial_log" | head -n 40
[[ "$result" == passed ]]
