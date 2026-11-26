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
# Boot smoke test of the AArch64 build: boots the EFI system partition
# headless in QEMU's virt machine (GICv2, Cortex-A72, edk2 firmware) with
# the "test-exit" kernel option and checks that the kernel reaches the
# end of its start-up with every self test passed.
#
#   test-qemu-arm64.sh <esp-directory> [sd-card-image]
#
# It boots twice: with the firmware at EL1 and two processors, and with
# the firmware at EL2 (virtualization=on, as the Raspberry Pi 4's UEFI
# firmware runs) and four processors, so the loader's drop from EL2 and
# PSCI over SMC are covered too; a third boot uses QEMU's "max"
# processor (ARMv8.1+ with PAN, as the Raspberry Pi 5's Cortex-A76 has),
# so the kernel runs with PAN on; a fourth boots a GICv3 (redistributors,
# the system register interface, LPIs through the ITS) at EL2 on "max"
# with only 16 address space identifiers (asidbits=4: their generations
# roll over). The first and the fourth also suspend to RAM during
# start-up (suspendtest; QEMU's PSCI refuses SYSTEM_SUSPEND, so
# psci-suspend=force tries it anyway and every other processor comes
# back through CPU_OFF and CPU_ON). The kernel ends QEMU through
# semihosting: exit status 1 is success, 3 a panic, 5 a failed test;
# anything else (the timeout) is a failure as well. The serial logs are
# kept in the build directory (test-arm64-el1.log, test-arm64-el2.log, test-arm64-max.log,
# test-arm64-gic3.log).
#
# With an SD card image (make-test-disk.sh's test-disk-sdsc.img: an SDSC
# card holding a copy of the ext4 test partition, with its dirty journal
# and orphan), each boot also gets a copy of it on an SD host controller
# and runs the file system tests (fstest) on it; the copy is checked on the host afterwards
# (verify-test-disk.sh). The EL2 boot treats every device as not cache
# coherent (noncoherentdma), as on the Raspberry Pi 4, so the SD card's
# DMA goes through the cache maintenance and the xHCI and mailbox
# buffers through uncached mappings.
#
# Run by make arm64-test, and by make test when qemu-system-aarch64, the
# edk2 AArch64 firmware and the AArch64 build are there.

set -uo pipefail

esp_directory="$1"
sd_card_image="${2:-}"
timeout_seconds=${TIMEOUT:-180}
build_directory=$(dirname "$esp_directory")
test_esp_directory="$build_directory/test-esp"
script_directory=$(dirname "$0")

rm -rf "$test_esp_directory"
cp -r "$esp_directory" "$test_esp_directory"
echo "test-exit heapchecks" > "$test_esp_directory/FreePascalOS/options.txt"

# The kernel's own words for a failure.
failure_pattern='PANIC|panic|: FAILED|failed:|unhandled processor exception'

run_one() {
    local name="$1"
    local virtualization="$2"
    local processors="$3"
    local extra_options="$4"
    local processor="${5:-cortex-a72}"
    local gic_version="${6:-2}"
    local serial_log="$build_directory/test-arm64-$name.log"
    local sd_card_copy=""

    echo "test-exit heapchecks $extra_options" > "$test_esp_directory/FreePascalOS/options.txt"
    if [[ -n "$sd_card_image" ]]; then
        sd_card_copy="$build_directory/test-arm64-$name-sdcard.img"
        cp -f "$sd_card_image" "$sd_card_copy"
        echo "test-exit heapchecks fstest $extra_options" > "$test_esp_directory/FreePascalOS/options.txt"
    fi
    rm -f "$build_directory/QEMU_VARS.fd"
    # The EL2 boot runs QEMU's four processors on one host thread: with a
    # thread each (MTTCG) and the GICv2, QEMU now and then sleeps through
    # a generic timer the kernel set correctly (QEMU's own arm_gt trace
    # shows it armed for the right tick; its main loop polls on for up
    # to ~0.75 s while every processor waits for an interrupt), so a
    # sleep ends that much late. Seen most with four processors; the
    # others keep a thread per processor (with one thread, the two
    # processor boots starve the scheduler stress test's meddler: QEMU
    # runs one processor at a time for long stretches).
    local accelerator=()
    if [[ "$name" == el2 ]]; then
        accelerator=(-- -accel tcg,thread=single)
    fi
    GIC="$gic_version" CPU="$processor" VIRTUALIZATION="$virtualization" PROCESSORS="$processors" SEMIHOSTING=1 SD_CARD="$sd_card_copy" \
        timeout "$timeout_seconds" "$script_directory/run-qemu-arm64.sh" "$test_esp_directory" --headless "${accelerator[@]}" \
        < /dev/null > "$serial_log" 2>&1
    local status=$?

    local result=passed
    if [[ $status -ne 1 ]]; then
        result="failed (QEMU exit status $status)"
    elif ! grep -q "\[init\] System ready" "$serial_log"; then
        result="failed (start-up did not finish)"
    elif grep -qE "$failure_pattern" "$serial_log"; then
        result="failed (see the log)"
    elif [[ $(grep -c "\[selftest\].*: passed" "$serial_log") -lt 10 ]]; then
        result="failed (self tests missing)"
    elif ! grep -q "\[hal\] GICv$gic_version," "$serial_log"; then
        result="failed (not driven as a GICv$gic_version)"
    elif ! grep -q "\[selftest\] AArch64 platform (GIC, ASIDs, PL031): passed" "$serial_log"; then
        result="failed (the platform self test with the PL031 did not pass)"
    elif [[ "$extra_options" == *suspendtest* ]] && ! grep -q "\[selftest\] suspend to RAM .*: passed" "$serial_log"; then
        result="failed (the suspend to RAM self test did not pass)"
    elif ! grep -q "\[smp\] $processors processors running" "$serial_log"; then
        result="failed (not all $processors processors started)"
    elif [[ -n "$sd_card_copy" ]] && ! grep -q '\[sdhci\] disk[0-9]*: SDSC card .*ADMA2.* interrupts' "$serial_log"; then
        result="failed (the SD card was not started with ADMA2 and interrupts)"
    elif [[ -n "$sd_card_copy" ]] && ! grep -q 'filesystem writes ext4 on .*passed' "$serial_log"; then
        result="failed (the file system tests did not pass on the SD card)"
    elif [[ -n "$sd_card_copy" ]] && ! "$script_directory/verify-test-disk.sh" "$sd_card_copy" > /dev/null; then
        result="failed (the SD card's volume did not pass the host side checks)"
    fi

    echo "ARM64 BOOT TEST ($name, $processors processors): $result ($serial_log)"
    [[ "$result" == passed ]]
}

overall=0
run_one el1 0 2 "suspendtest psci-suspend=force" || overall=1
run_one el2 1 4 noncoherentdma || overall=1
run_one max 0 2 "" max || overall=1
run_one gic3 1 4 "suspendtest psci-suspend=force asidbits=4" max 3 || overall=1
exit $overall
