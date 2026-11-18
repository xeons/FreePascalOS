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
# Network boot test of the AArch64 build in QEMU's virt machine (the
# firmware at EL2, as on the Raspberry Pi 4), with QEMU's user mode
# network:
#
#   test-arm64-netboot.sh <esp-directory> <system-disk-image>
#
#   1. HTTP, the SD card setup: the boot volume holds only
#      EFI/BOOT/BOOTAA64.EFI and FreePascalOS/options.txt with
#      netboot=http://10.0.2.2:PORT/; scripts/netboot-serve.py on this
#      machine serves the kernel, the options and the system image.
#   2. TFTP: the same with netboot=tftp://10.0.2.2/, QEMU's own TFTP
#      server serving the files (through the firmware's PXE client).
#
# The firmware's own PXE or HTTP boot of the loader (no loader on the
# boot volume) is not tested: this edk2 build offers no network boot
# option on the virt machine.
#
# Each boot must load the kernel and the system image over the network,
# run from the RAM disk (the system volume /ramdisk0p1) and start user
# mode: the served options are "test-exit init=/bin/true", so the kernel
# ends QEMU (semihosting) once /bin/true exits. The serial logs stay in
# the build directory (test-arm64-netboot-http.log, -tftp.log).
# Not part of make test; run it with make arm64-netboot-test.

set -uo pipefail

esp_directory="$1"
system_disk_image="$2"
build_directory=$(dirname "$esp_directory")
script_directory=$(cd "$(dirname "$0")" && pwd)
work_directory="$build_directory/test-netboot"
timeout_seconds=${TIMEOUT:-600}
served_options="test-exit init=/bin/true"
failures=0

rm -rf "$work_directory"
mkdir -p "$work_directory"
echo "$served_options" > "$work_directory/options.txt"

# Checks a boot's serial log; $1 the case's name, $2 the log, $3 QEMU's
# exit status, $4 what the loader must have loaded from.
check_boot() {
    local name="$1" log="$2" status="$3" source="$4"
    local missing=()
    grep -aq "Loading ${source}FreePascalOS/kernel.elf" "$log" || missing+=("kernel loaded from $source")
    grep -aq "RAM disk: " "$log" || missing+=("system image loaded by the loader")
    grep -aq "\[ramdisk\] ramdisk0: " "$log" || missing+=("RAM disk device")
    grep -aq "System volume: /ramdisk0" "$log" || missing+=("system volume on the RAM disk")
    grep -aq "Kernel options: netboot=${source} ${served_options}" "$log" || missing+=("served options")
    grep -aq "/bin/true exited with code 0" "$log" || missing+=("user mode ran /bin/true")
    if [[ "$status" != 1 ]]; then
        missing+=("QEMU exit status 1 (was $status)")
    fi
    if (( ${#missing[@]} == 0 )); then
        echo "ARM64 NETBOOT ($name): passed ($log)"
    else
        echo "ARM64 NETBOOT ($name): failed ($log), missing:"
        printf '    %s\n' "${missing[@]}"
        failures=$((failures + 1))
    fi
}

# The firmware's network stack needs a random number generator (its
# drivers wait for EFI_RNG_PROTOCOL, since edk2 2024), which the virt
# machine has only with a virtio RNG device; the Raspberry Pi has its
# own. Its PXE client is off unless fw_cfg turns it on; only IPv4, so
# the firmware tries nothing else first.
network_switches=(-device virtio-rng-pci
    -fw_cfg name=opt/org.tianocore/IPv4PXESupport,string=yes
    -fw_cfg name=opt/org.tianocore/IPv6Support,string=no)

run_qemu() {
    local boot_volume="$1" log="$2"
    shift 2
    rm -f "$(dirname "$boot_volume")/QEMU_VARS.fd"
    VIRTUALIZATION=1 PROCESSORS=2 MEMORY=1G SEMIHOSTING=1 SERIAL=file:"$log" \
        timeout "$timeout_seconds" "$script_directory/run-qemu-arm64.sh" "$boot_volume" --headless \
        -- -nic none "${network_switches[@]}" "$@" < /dev/null > /dev/null 2>&1
}

# --- 1. HTTP, from netboot= on the boot volume --------------------------------

if [[ "${CASES:-http tftp}" == *http* ]]; then

port=$((20000 + $$ % 20000))
card_directory="$work_directory/card"
mkdir -p "$card_directory/EFI/BOOT" "$card_directory/FreePascalOS"
cp "$esp_directory/EFI/BOOT/BOOTAA64.EFI" "$card_directory/EFI/BOOT/"
echo "netboot=http://10.0.2.2:$port/" > "$card_directory/FreePascalOS/options.txt"

python3 "$script_directory/netboot-serve.py" --esp "$esp_directory" --system-image "$system_disk_image" \
    --options-file "$work_directory/options.txt" --bind 127.0.0.1 --port "$port" \
    > "$build_directory/test-arm64-netboot-server.log" 2>&1 &
server_process=$!
trap 'kill "$server_process" 2> /dev/null' EXIT
for _ in $(seq 50); do
    if python3 -c "import socket,sys; socket.create_connection(('127.0.0.1', $port), 1)" 2> /dev/null; then
        break
    fi
    sleep 0.1
done

http_log="$build_directory/test-arm64-netboot-http.log"
run_qemu "$card_directory" "$http_log" -netdev user,id=net0 -device virtio-net-pci,netdev=net0
check_boot "HTTP" "$http_log" "$?" "http://10.0.2.2:$port/"
grep -q "system.img: " "$build_directory/test-arm64-netboot-server.log" ||
    echo "    (the server log shows no system image transfer)"

fi

# --- 2. TFTP, from netboot=tftp:// on the boot volume ---------------------------

if [[ "${CASES:-http tftp}" == *tftp* ]]; then
tftp_root="$work_directory/tftp"
tftp_card="$work_directory/tftp-card"
mkdir -p "$tftp_root/FreePascalOS" "$tftp_card/EFI/BOOT" "$tftp_card/FreePascalOS"
cp "$esp_directory/EFI/BOOT/BOOTAA64.EFI" "$tftp_card/EFI/BOOT/"
echo "netboot=tftp://10.0.2.2/" > "$tftp_card/FreePascalOS/options.txt"
cp "$esp_directory/FreePascalOS/kernel.elf" "$tftp_root/FreePascalOS/"
cp "$system_disk_image" "$tftp_root/FreePascalOS/system.img"
cp "$work_directory/options.txt" "$tftp_root/FreePascalOS/options.txt"

tftp_log="$build_directory/test-arm64-netboot-tftp.log"
run_qemu "$tftp_card" "$tftp_log" -netdev "user,id=net0,tftp=$tftp_root" -device virtio-net-pci,netdev=net0
check_boot "TFTP" "$tftp_log" "$?" "tftp://10.0.2.2/"
fi

(( failures == 0 ))
