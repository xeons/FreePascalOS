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

# Checks the kernel panic's back trace: boots the system headless in QEMU
# with the testpanic kernel option (Kernel.PanicTest), once for a page
# fault and once for a failed assertion, each three calls deep, and
# checks that the panic's "Back trace:" in the serial log names the
# routines of the call chain, innermost first.
#   test-panic-trace.sh <arch> <esp-directory>
# (make panic-trace-test, or make ARCH=arm64 panic-trace-test.) The
# serial logs stay in the build directory as test-panic-<kind>.log.

set -uo pipefail

architecture="$1"
esp_directory="$2"
timeout_seconds=${TEST_TIMEOUT:-120}
build_directory=$(dirname "$esp_directory")
test_esp_directory="$build_directory/panic-test-esp"
script_directory=$(dirname "$0")

find_first_existing_file() {
    for candidate in "$@"; do
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

# Boots with the given testpanic value; the serial log goes to $2.
# Returns QEMU's exit status (3: the kernel panicked).
boot_with_panic() {
    local kind="$1"
    local serial_log="$2"
    rm -rf "$test_esp_directory"
    cp -r "$esp_directory" "$test_esp_directory"
    echo "test-exit testpanic=$kind" > "$test_esp_directory/FreePascalOS/options.txt"
    rm -f "$serial_log"
    case "$architecture" in
        amd64)
            local firmware_code firmware_variables_template
            firmware_code=$(find_first_existing_file \
                /usr/share/edk2/x64/OVMF_CODE.4m.fd \
                /usr/share/OVMF/x64/OVMF_CODE.4m.fd \
                /usr/share/OVMF/OVMF_CODE.fd) || { echo "OVMF firmware not found"; return 100; }
            firmware_variables_template=$(find_first_existing_file \
                /usr/share/edk2/x64/OVMF_VARS.4m.fd \
                /usr/share/OVMF/x64/OVMF_VARS.4m.fd \
                /usr/share/OVMF/OVMF_VARS.fd) || { echo "OVMF variable store not found"; return 100; }
            cp -f "$firmware_variables_template" "$build_directory/panic-test-OVMF_VARS.fd"
            timeout "$timeout_seconds" qemu-system-x86_64 \
                -machine q35 -cpu max -m 512M -smp 2 \
                -drive if=pflash,format=raw,readonly=on,file="$firmware_code" \
                -drive if=pflash,format=raw,file="$build_directory/panic-test-OVMF_VARS.fd" \
                -drive format=raw,file=fat:rw:"$test_esp_directory" \
                -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
                -serial file:"$serial_log" \
                -display none -no-reboot \
                < /dev/null > /dev/null 2>&1
            ;;
        arm64)
            rm -f "$build_directory/QEMU_VARS.fd"
            SEMIHOSTING=1 PROCESSORS=2 AUDIO=none \
                timeout "$timeout_seconds" "$script_directory/run-qemu-arm64.sh" "$test_esp_directory" --headless \
                < /dev/null > "$serial_log" 2>&1
            ;;
        *)
            echo "Unsupported architecture: $architecture"
            return 100
            ;;
    esac
}

# Whether the lines after "Back trace:" in the log name the routines
# given, in that order (other frames may come between them).
trace_names_in_order() {
    python3 - "$@" <<'CHECK'
import re
import sys

log_path, wanted = sys.argv[1], sys.argv[2:]
with open(log_path, 'rb') as log:
    text = log.read().decode('ascii', 'replace')
text = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', text).replace('\r', '')
if 'Back trace:' not in text:
    print('  no "Back trace:" in the log')
    sys.exit(1)
trace = text.split('Back trace:', 1)[1]
frames = []
for line in trace.splitlines()[1:]:
    match = re.match(r'\s+#(\d+) 0x[0-9A-Fa-f]+ (\S+)', line)
    if not match:
        break
    frames.append(match.group(2).split('+')[0])
print('  trace: ' + ' <- '.join(frames))
position = 0
for name in wanted:
    while position < len(frames) and frames[position] != name:
        position += 1
    if position == len(frames):
        print('  missing (in order): ' + name)
        sys.exit(1)
    position += 1
CHECK
}

chain=(Kernel.PanicTest.PanicTestInnermost Kernel.PanicTest.PanicTestMiddle
       Kernel.PanicTest.PanicTestOutermost Kernel.PanicTest.RunPanicTestIfAsked)

overall=0
for kind in fault assert; do
    serial_log="$build_directory/test-panic-$kind.log"
    boot_with_panic "$kind" "$serial_log"
    status=$?
    expected=("${chain[@]}")
    if [[ "$kind" == assert ]]; then
        expected=(Kernel.Panic.KernelAssert "${chain[@]}")
    fi
    result=passed
    if [[ $status -ne 3 ]]; then
        result="failed (QEMU exit status $status, expected 3: a panic)"
    elif ! trace_names_in_order "$serial_log" "${expected[@]}"; then
        result="failed (the back trace does not name the call chain)"
    fi
    echo "PANIC TRACE TEST ($architecture, $kind): $result ($serial_log)"
    [[ "$result" == passed ]] || overall=1
done
exit $overall
