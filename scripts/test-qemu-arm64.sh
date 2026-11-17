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
#   test-qemu-arm64.sh <esp-directory>
#
# It boots twice: with the firmware at EL1 and two processors, and with
# the firmware at EL2 (virtualization=on, as the Raspberry Pi 4's UEFI
# firmware runs) and four processors, so the loader's drop from EL2 and
# PSCI over SMC are covered too. The kernel ends QEMU through
# semihosting: exit status 1 is success, 3 a panic, 5 a failed test;
# anything else (the timeout) is a failure as well. The serial logs are
# kept in the build directory (test-arm64-el1.log, test-arm64-el2.log).
#
# Not part of make test yet (it needs qemu-system-aarch64 and the edk2
# AArch64 firmware); run it with make arm64-test.

set -uo pipefail

esp_directory="$1"
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
    local serial_log="$build_directory/test-arm64-$name.log"

    rm -f "$build_directory/QEMU_VARS.fd"
    VIRTUALIZATION="$virtualization" PROCESSORS="$processors" SEMIHOSTING=1 \
        timeout "$timeout_seconds" "$script_directory/run-qemu-arm64.sh" "$test_esp_directory" --headless \
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
    elif ! grep -q "\[smp\] $processors processors running" "$serial_log"; then
        result="failed (not all $processors processors started)"
    fi

    echo "ARM64 BOOT TEST ($name, $processors processors): $result ($serial_log)"
    [[ "$result" == passed ]]
}

overall=0
run_one el1 0 2 || overall=1
run_one el2 1 4 || overall=1
exit $overall
