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
# Boots the system headless with the C test suite (/usr/bin/ctest, built
# by make c-runtime) as the first program and reports whether every C
# and C++ check passed (make c-test).
#
#   test-c-runtime.sh <arch> <esp-directory> <system-disk-image>
#
# The kernel leaves QEMU through the isa-debug-exit device (test-exit):
# status 1 means the first program ended with 0. The serial log is kept
# as c-test-serial.log in the build directory. ACCEL=kvm uses the host's
# processor.

set -uo pipefail

architecture="$1"
esp_directory="$2"
system_disk_image="$3"
timeout_seconds=${TEST_TIMEOUT:-300}

build_directory=$(dirname "$esp_directory")
test_esp_directory="$build_directory/c-test-esp"
serial_log="$build_directory/c-test-serial.log"
run_system_disk_image="$build_directory/c-test-system-disk.img"

if [[ "$architecture" != "amd64" ]]; then
    echo "test-c-runtime.sh: only amd64 boots here; arm64 runs ctest through its coretest line"
    exit 1
fi
if [[ ! -f "$build_directory/user/usr/bin/ctest" ]]; then
    echo "test-c-runtime.sh: no C runtime in the build (make c-toolchain, then make c-runtime)"
    exit 1
fi

firmware_code=/usr/share/edk2/x64/OVMF_CODE.4m.fd
firmware_variables_template=/usr/share/edk2/x64/OVMF_VARS.4m.fd
for candidate in /usr/share/OVMF/x64/OVMF_CODE.4m.fd /usr/share/OVMF/OVMF_CODE.fd; do
    [[ -f "$firmware_code" ]] || firmware_code="$candidate"
done
for candidate in /usr/share/OVMF/x64/OVMF_VARS.4m.fd /usr/share/OVMF/OVMF_VARS.fd; do
    [[ -f "$firmware_variables_template" ]] || firmware_variables_template="$candidate"
done

rm -rf "$test_esp_directory"
cp -r "$esp_directory" "$test_esp_directory"
echo "test-exit init=/usr/bin/ctest" > "$test_esp_directory/FreePascalOS/options.txt"
firmware_variables="$build_directory/c-test-OVMF_VARS.fd"
cp -f "$firmware_variables_template" "$firmware_variables"
cp -f "$system_disk_image" "$run_system_disk_image"

if [[ "${ACCEL:-}" == kvm ]]; then
    cpu_arguments=(-accel kvm -cpu host)
else
    cpu_arguments=(-cpu max)
fi

timeout "$timeout_seconds" qemu-system-x86_64 \
    -machine q35 "${cpu_arguments[@]}" -m 512M -smp ${PROCESSORS:-4} \
    -drive if=pflash,format=raw,readonly=on,file="$firmware_code" \
    -drive if=pflash,format=raw,file="$firmware_variables" \
    -drive format=raw,file=fat:rw:"$test_esp_directory" \
    -drive format=raw,cache=unsafe,file="$run_system_disk_image" \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    -serial file:"$serial_log" \
    -display none -no-reboot \
    < /dev/null > /dev/null 2>&1
qemu_status=$?

sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' -e 's/\r//g' "$serial_log" | grep -E "ctest|cxxtest|hello|process |mlibc|ld.so" | head -200

if [[ "$qemu_status" == 1 ]] && grep -q "ctest: all .* checks passed" "$serial_log"; then
    echo "C TEST PASSED"
    exit 0
fi
echo "C TEST FAILED (QEMU status $qemu_status; log in $serial_log)"
exit 1
