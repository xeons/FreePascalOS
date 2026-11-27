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
# The system stays usable whatever one program does.
#
#   test-responsiveness.sh <arch> <esp-directory> <system-disk-image>
#
# Boots amd64 with 512 MiB of RAM and four processors, /bin/responsivetest
# as the first program: priority classes, the lateness of a 10 ms sleep
# loop beside a program spinning 16 threads (Normal and Interactive class)
# and beside a program taking memory without end, the commit policy's
# limits (by default overcommitment: a commitment larger than the RAM is
# refused at once), that program refused or ended by the out-of-memory
# policy, the system usable afterwards, and a job's commit limit (strict
# under every policy). Passes if responsivetest passed and the kernel did not
# panic. The serial log is kept in the build directory
# (test-responsiveness-serial.log).

set -uo pipefail

architecture="$1"
esp_directory="$2"
system_disk_image="$3"
build_directory=$(dirname "$esp_directory")
test_esp_directory="$build_directory/test-esp-responsiveness"
serial_log="$build_directory/test-responsiveness-serial.log"
timeout_seconds=${TEST_TIMEOUT:-600}

if [[ "$architecture" != "amd64" ]]; then
    echo "Unsupported architecture: $architecture"
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
echo "test-exit init=/bin/responsivetest" > "$test_esp_directory/FreePascalOS/options.txt"
firmware_variables="$build_directory/test-responsiveness-OVMF_VARS.fd"
cp -f "$firmware_variables_template" "$firmware_variables"

run_system_disk="$build_directory/test-responsiveness-system.img"
cp -f "$system_disk_image" "$run_system_disk"

if [[ "${ACCEL:-}" == kvm ]]; then
    cpu_arguments=(-accel kvm -cpu host)
else
    cpu_arguments=(-cpu max)
fi

timeout "$timeout_seconds" qemu-system-x86_64 \
    -machine q35 "${cpu_arguments[@]}" -m 512M -smp 4 \
    -drive if=pflash,format=raw,readonly=on,file="$firmware_code" \
    -drive if=pflash,format=raw,file="$firmware_variables" \
    -drive format=raw,file=fat:rw:"$test_esp_directory" \
    -drive format=raw,cache=unsafe,file="$run_system_disk" \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    -serial file:"$serial_log" \
    -display none -no-reboot \
    < /dev/null > /dev/null 2>&1
qemu_status=$?

sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' -e 's/\r//g' "$serial_log" | grep -E 'responsivetest|memorytest|burn|\[memory\]|PANIC|panic' | head -80

failed=0
if [[ "$qemu_status" != 1 ]]; then
    echo "TEST FAILED: QEMU ended with status $qemu_status (1 is success, 5 a failed responsivetest, 3 a panic)"
    failed=1
fi
if ! grep -q 'responsivetest: .* checks passed' "$serial_log" || grep -q 'responsivetest: FAIL' "$serial_log"; then
    echo "TEST FAILED: responsivetest did not pass"
    failed=1
fi
rm -f "$run_system_disk"
rm -rf "$test_esp_directory"
if (( failed )); then
    exit 1
fi
echo "TEST PASSED"
