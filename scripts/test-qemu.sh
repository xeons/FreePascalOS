#!/usr/bin/env bash
#
# Boots the system headless in QEMU with the "test-exit" kernel option and
# reports whether startup (including the kernel self tests) succeeded.
#
#   test-qemu.sh <arch> <esp-directory> [test-disk-image] [system-disk-image]
#
# The kernel leaves QEMU through the isa-debug-exit device: exit status 1
# means success, 3 means a panic, 5 that the user mode tests failed. Anything else (for example the timeout)
# is a failure too. The serial log is printed and kept in the build
# directory as test-serial.log.
#
# When a test disk is given (see make-test-disk.sh), the file system self
# tests must also have passed for every file system type on it. The test
# runs on a copy of the disk (test-disk-run.img), since the write tests
# change it, and the copy is checked afterwards with each file system's
# own tools by verify-test-disk.sh.

set -uo pipefail

architecture="$1"
esp_directory="$2"
test_disk_image="${3:-}"
system_disk_image="${4:-}"
timeout_seconds=120
expected_file_systems=(fat12 fat16 fat32 exfat ext2 ext3 ext4)

build_directory=$(dirname "$esp_directory")
test_esp_directory="$build_directory/test-esp"
serial_log="$build_directory/test-serial.log"

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

# A private copy of the ESP with the test option added.
rm -rf "$test_esp_directory"
cp -r "$esp_directory" "$test_esp_directory"
# With a system disk the user mode test program runs as the first
# process; its exit code decides the result.
if [[ -n "${system_disk_image:-}" ]]; then
    echo "test-exit init=/bin/coretest" > "$test_esp_directory/FreePascalOS/options.txt"
else
    echo "test-exit" > "$test_esp_directory/FreePascalOS/options.txt"
fi

firmware_variables="$build_directory/test-OVMF_VARS.fd"
cp -f "$firmware_variables_template" "$firmware_variables"

disk_arguments=(-drive format=raw,file=fat:rw:"$test_esp_directory")
run_disk_image="$build_directory/test-disk-run.img"
if [[ -n "$test_disk_image" ]]; then
    cp -f "$test_disk_image" "$run_disk_image"
    disk_arguments+=(-drive format=raw,file="$run_disk_image")
fi
run_system_disk_image="$build_directory/system-disk-run.img"
if [[ -n "$system_disk_image" ]]; then
    cp -f "$system_disk_image" "$run_system_disk_image"
    disk_arguments+=(-drive format=raw,file="$run_system_disk_image")
fi

timeout "$timeout_seconds" qemu-system-x86_64 \
    -machine q35 -cpu max -m 512M -smp ${PROCESSORS:-4} \
    -drive if=pflash,format=raw,readonly=on,file="$firmware_code" \
    -drive if=pflash,format=raw,file="$firmware_variables" \
    "${disk_arguments[@]}" \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    -serial file:"$serial_log" \
    -display none -no-reboot \
    < /dev/null > /dev/null 2>&1
qemu_status=$?

# Strip the firmware's terminal control sequences for readability.
sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' -e 's/\r//g' "$serial_log" | sed -n '/kernel starting/,$p'

missing_file_systems=()
if [[ -n "$test_disk_image" ]]; then
    for file_system in "${expected_file_systems[@]}"; do
        if ! grep -q "filesystem $file_system on .*passed" "$serial_log"; then
            missing_file_systems+=("$file_system")
        fi
        if ! grep -q "filesystem writes $file_system on .*passed" "$serial_log"; then
            missing_file_systems+=("$file_system (writes)")
        fi
    done
fi

case "$qemu_status" in
    1)
        if (( ${#missing_file_systems[@]} > 0 )); then
            echo "TEST FAILED: no passing file system test for: ${missing_file_systems[*]}"
            exit 1
        fi
        if [[ -n "$test_disk_image" ]]; then
            if ! "$(dirname "$0")/verify-test-disk.sh" "$run_disk_image"; then
                echo "TEST FAILED: the written volumes did not pass the host side checks"
                exit 1
            fi
        fi
        echo "TEST PASSED"
        exit 0
        ;;
    3)
        echo "TEST FAILED: kernel panic"
        ;;
    5)
        echo "TEST FAILED: the user mode tests (coretest) reported failures"
        ;;
    124)
        echo "TEST FAILED: timed out after ${timeout_seconds} seconds"
        ;;
    *)
        echo "TEST FAILED: QEMU exited with status $qemu_status"
        ;;
esac
exit 1
