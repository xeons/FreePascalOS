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
# Running out of memory, and discarding freed space, in a small guest.
#
#   test-memory-pressure.sh <arch> <esp-directory> <system-disk-image>
#
# Boots amd64 with 256 MiB of RAM and /bin/memorytest as the first
# program (its "suite": the out-of-memory policy, then discards), with
# two more disks whose images are sparse files QEMU punches holes into
# when the guest discards (discard=unmap):
#
#   * an NVMe disk holding an ext4 volume labelled TRIMNVME: a 24 MiB
#     file is written, synced and removed; the batched discards go out
#     with the next sync;
#   * a virtio disk holding a FAT16 volume labelled TRIMVIRT: the same,
#     then fstrim.
#
# Passes if memorytest passed (a hog ended with 137, the bystander and
# the system alive, the process with the OOM score adjustment 1000
# ended first; the disks told to discard), the kernel logged the
# endings, and each image holds no more than 4 MiB beyond what it held
# after it was made (the 24 MiB written went again). The serial log is
# kept in the build directory (test-memory-serial.log).

set -uo pipefail

architecture="$1"
esp_directory="$2"
system_disk_image="$3"
build_directory=$(dirname "$esp_directory")
test_esp_directory="$build_directory/test-esp-memory"
serial_log="$build_directory/test-memory-serial.log"
timeout_seconds=${TEST_TIMEOUT:-600}
slack_kib=4096

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
# The default commit policy overcommits: the hogs touch every page they
# commit and run out of pages long before the commit ceiling (four times
# the RAM processes may use), so the out-of-memory policy (not the
# commit limit) is what stops them here, as it is for any program that
# touches more than there is; scripts/test-responsiveness.sh checks the
# commit limits themselves.
echo "test-exit init=/bin/memorytest" > "$test_esp_directory/FreePascalOS/options.txt"
firmware_variables="$build_directory/test-memory-OVMF_VARS.fd"
cp -f "$firmware_variables_template" "$firmware_variables"

run_system_disk="$build_directory/test-memory-system.img"
nvme_image="$build_directory/test-memory-nvme.img"
virtio_image="$build_directory/test-memory-virtio.img"
cp -f "$system_disk_image" "$run_system_disk"
rm -f "$nvme_image" "$virtio_image"
truncate -s 64M "$nvme_image" "$virtio_image"
mke2fs -q -F -t ext4 -L TRIMNVME -E lazy_itable_init=0,lazy_journal_init=0,nodiscard "$nvme_image"
mkfs.fat -F 16 -n TRIMVIRT "$virtio_image" > /dev/null

allocated_kib() {
    echo $(( $(stat -c %b "$1") * $(stat -c %B "$1") / 1024 ))
}
nvme_base=$(allocated_kib "$nvme_image")
virtio_base=$(allocated_kib "$virtio_image")

if [[ "${ACCEL:-}" == kvm ]]; then
    cpu_arguments=(-accel kvm -cpu host)
else
    cpu_arguments=(-cpu max)
fi

timeout "$timeout_seconds" qemu-system-x86_64 \
    -machine q35 "${cpu_arguments[@]}" -m 256M -smp 2 \
    -drive if=pflash,format=raw,readonly=on,file="$firmware_code" \
    -drive if=pflash,format=raw,file="$firmware_variables" \
    -drive format=raw,file=fat:rw:"$test_esp_directory" \
    -drive format=raw,cache=unsafe,file="$run_system_disk" \
    -drive if=none,id=nvme0,format=raw,cache=unsafe,discard=unmap,file="$nvme_image" \
    -device nvme,serial=fpostrim,drive=nvme0 \
    -drive if=none,id=virtio0,format=raw,cache=unsafe,discard=unmap,file="$virtio_image" \
    -device virtio-blk-pci,drive=virtio0,discard=on \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    -serial file:"$serial_log" \
    -display none -no-reboot \
    < /dev/null > /dev/null 2>&1
qemu_status=$?

sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' -e 's/\r//g' "$serial_log" | grep -E 'memorytest|\[memory\]|\[cache\]|trimmed|PANIC|panic' | head -80

nvme_final=$(allocated_kib "$nvme_image")
virtio_final=$(allocated_kib "$virtio_image")
echo "NVMe image: ${nvme_base} KiB allocated after mkfs, ${nvme_final} KiB after the run"
echo "virtio image: ${virtio_base} KiB allocated after mkfs, ${virtio_final} KiB after the run"

failed=0
if [[ "$qemu_status" != 1 ]]; then
    echo "TEST FAILED: QEMU ended with status $qemu_status (1 is success, 5 a failed memorytest, 3 a panic)"
    failed=1
fi
if ! grep -q 'memorytest: .* checks passed' "$serial_log" || grep -q 'memorytest: FAIL' "$serial_log"; then
    echo "TEST FAILED: memorytest did not pass"
    failed=1
fi
if ! grep -q '\[memory\] Out of memory: ended memorytest' "$serial_log"; then
    echo "TEST FAILED: the kernel did not log ending a process for memory"
    failed=1
fi
if (( nvme_final > nvme_base + slack_kib )); then
    echo "TEST FAILED: the NVMe image did not shrink back (discards not sent or not taken)"
    failed=1
fi
if (( virtio_final > virtio_base + slack_kib )); then
    echo "TEST FAILED: the virtio image did not shrink back (fstrim did not reach it)"
    failed=1
fi
rm -f "$run_system_disk"
if (( failed )); then
    exit 1
fi
echo "TEST PASSED"
