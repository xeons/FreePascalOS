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
# The deliberate protection violations (Kernel.ProtectionFaultTest): one
# boot per kind with "selftest=KIND", each of which must stop the system
# with the right fault report.
#
#   test-protection-faults.sh <arch> <esp-directory> [kind...]
#
# amd64 boots QEMU's "max" processor (NX, SMEP, SMAP, UMIP; ACCEL=kvm:
# the host's); arm64 boots "max" too (PXN, PAN; CPU overrides it, e.g.
# CPU=cortex-a72, which has no PAN, so "useraccess" is then expected to
# report the missing protection instead). The serial logs are kept in
# the build directory (test-fault-KIND.log).

set -uo pipefail

architecture="$1"
esp_directory="$2"
shift 2
kinds=("$@")
if (( ${#kinds[@]} == 0 )); then
    kinds=(nx textwrite userexec useraccess pagepoison)
fi
build_directory=$(dirname "$esp_directory")
script_directory=$(cd "$(dirname "$0")" && pwd)
test_esp_directory="$build_directory/test-esp-faults"
timeout_seconds=${TIMEOUT:-240}

# What each violation must be reported as.
expected_report() {
    case "$1" in
        nx|userexec) echo 'Instruction fetch from .* \(protection violation' ;;
        textwrite) echo 'Write to .* \(protection violation' ;;
        useraccess)
            if [[ "$architecture" == arm64 && "${CPU:-max}" == cortex-a72 ]]; then
                echo 'selftest=useraccess: the processor has no SMAP/PAN'
            else
                echo 'Read from .* \(protection violation'
            fi ;;
        pagepoison) echo 'physical page written after it was freed' ;;
    esac
}

find_first_existing_file() {
    for candidate in "$@"; do
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

boot_amd64() {
    local serial_log="$1"
    local firmware_code firmware_variables_template cpu_arguments
    firmware_code=$(find_first_existing_file /usr/share/edk2/x64/OVMF_CODE.4m.fd \
        /usr/share/OVMF/x64/OVMF_CODE.4m.fd /usr/share/OVMF/OVMF_CODE.fd) || return 99
    firmware_variables_template=$(find_first_existing_file /usr/share/edk2/x64/OVMF_VARS.4m.fd \
        /usr/share/OVMF/x64/OVMF_VARS.4m.fd /usr/share/OVMF/OVMF_VARS.fd) || return 99
    cp -f "$firmware_variables_template" "$build_directory/test-faults-OVMF_VARS.fd"
    if [[ "${ACCEL:-}" == kvm ]]; then
        cpu_arguments=(-accel kvm -cpu host)
    else
        cpu_arguments=(-cpu max)
    fi
    timeout "$timeout_seconds" qemu-system-x86_64 \
        -machine q35 "${cpu_arguments[@]}" -m 512M -smp 2 \
        -drive if=pflash,format=raw,readonly=on,file="$firmware_code" \
        -drive if=pflash,format=raw,file="$build_directory/test-faults-OVMF_VARS.fd" \
        -drive format=raw,file=fat:rw:"$test_esp_directory" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
        -serial file:"$serial_log" -display none -no-reboot -net none \
        < /dev/null > /dev/null 2>&1
}

boot_arm64() {
    local serial_log="$1"
    rm -f "$build_directory/QEMU_VARS.fd"
    CPU="${CPU:-max}" SEMIHOSTING=1 AUDIO=none timeout "$timeout_seconds" \
        "$script_directory/run-qemu-arm64.sh" "$test_esp_directory" --headless \
        < /dev/null > "$serial_log" 2>&1
}

overall=0
for kind in "${kinds[@]}"; do
    serial_log="$build_directory/test-fault-$kind.log"
    rm -rf "$test_esp_directory"
    cp -r "$esp_directory" "$test_esp_directory"
    echo "test-exit heapchecks selftest=$kind" > "$test_esp_directory/FreePascalOS/options.txt"
    case "$architecture" in
        amd64) boot_amd64 "$serial_log" ;;
        arm64) boot_arm64 "$serial_log" ;;
        *) echo "Unsupported architecture: $architecture"; exit 1 ;;
    esac
    status=$?
    pattern=$(expected_report "$kind")
    result=passed
    # Exit status 3: the kernel panicked, as it must.
    if [[ $status -ne 3 ]]; then
        result="failed (QEMU exit status $status, not a panic)"
    elif ! grep -q "Deliberate protection violation \"$kind\"" "$serial_log"; then
        result="failed (the panic came before the test)"
    elif ! grep -qE "$pattern" "$serial_log"; then
        result="failed (no report matching: $pattern)"
    fi
    echo "PROTECTION FAULT TEST ($architecture, $kind): $result ($serial_log)"
    [[ "$result" == passed ]] || overall=1
done
exit $overall
