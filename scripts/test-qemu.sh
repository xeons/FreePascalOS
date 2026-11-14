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
    # hangdump: if the tests stop making progress, the log shows why.
    echo "test-exit init=/bin/coretest hangdump=20" > "$test_esp_directory/FreePascalOS/options.txt"
else
    echo "test-exit" > "$test_esp_directory/FreePascalOS/options.txt"
fi

firmware_variables="$build_directory/test-OVMF_VARS.fd"
cp -f "$firmware_variables_template" "$firmware_variables"

# The run disks are copies thrown away afterwards: QEMU need not make
# the guest's flushes durable on the host (cache=unsafe), which would
# only slow the journal's commits down. The guest still sends them.
disk_arguments=(-drive format=raw,file=fat:rw:"$test_esp_directory")
run_disk_image="$build_directory/test-disk-run.img"
if [[ -n "$test_disk_image" ]]; then
    cp -f "$test_disk_image" "$run_disk_image"
    disk_arguments+=(-drive format=raw,cache=unsafe,file="$run_disk_image")
fi
run_system_disk_image="$build_directory/system-disk-run.img"
if [[ -n "$system_disk_image" ]]; then
    cp -f "$system_disk_image" "$run_system_disk_image"
    disk_arguments+=(-drive format=raw,cache=unsafe,file="$run_system_disk_image")
fi

# A blank disk whose sector 100 always fails to read (QEMU's blkdebug),
# so the tests see the AHCI driver fail a request and reset the port.
# It comes after the other disks, so it is the last diskN.
if [[ -n "$system_disk_image" ]]; then
    fault_disk_image="$build_directory/test-fault-disk.img"
    fault_rules="$build_directory/test-fault-disk.conf"
    rm -f "$fault_disk_image"
    truncate -s 1M "$fault_disk_image"
    cat > "$fault_rules" <<'RULES'
[inject-error]
event = "read_aio"
errno = "5"
sector = "100"
RULES
    disk_arguments+=(-drive format=raw,file=blkdebug:"$fault_rules":"$fault_disk_image")
fi

# ACCEL=kvm runs on the real processor (faster, and with the processor's
# own behaviour, such as SIMD floating point exceptions, which QEMU's
# emulator does not raise).
if [[ "${ACCEL:-}" == kvm ]]; then
    cpu_arguments=(-accel kvm -cpu host)
else
    cpu_arguments=(-cpu max)
fi

# Checks the first partition of a disk image with e2fsck.
check_system_disk() {
    local image="$1" partition="$build_directory/system-partition-check.img" start size output
    read -r start size < <(sfdisk --json "$image" | python3 -I -c '
import json, sys
partition = json.load(sys.stdin)["partitiontable"]["partitions"][0]
print(partition["start"], partition["size"])')
    dd if="$image" of="$partition" bs=512 skip="$start" count="$size" status=none
    if ! output=$(e2fsck -fn "$partition" 2>&1); then
        echo "$output" | sed 's/^/    /' | head -30
        rm -f "$partition"
        return 1
    fi
    rm -f "$partition"
}

timeout "$timeout_seconds" qemu-system-x86_64 \
    -machine q35 "${cpu_arguments[@]}" -m 512M -smp ${PROCESSORS:-4} \
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
        # The system disk was written by the user mode tests (through its
        # journal); it must be consistent and its journal empty.
        if [[ -n "$system_disk_image" ]] && ! check_system_disk "$run_system_disk_image"; then
            echo "TEST FAILED: the system disk did not pass e2fsck"
            exit 1
        fi
        # The disk statistics filter saw the journal's flushes.
        if [[ -n "$system_disk_image" ]] &&
           ! grep -q '\[diskstats\] disk2: .* [1-9][0-9]* flushes' "$serial_log"; then
            echo "TEST FAILED: no flushes reached the system disk"
            exit 1
        fi
        # The statistics filter on every disk saw the test disk's reads,
        # and the failed reads of the fault disk.
        if [[ -n "$test_disk_image" ]] &&
           ! grep -q '\[diskstats\] disk1: [1-9][0-9]* reads' "$serial_log"; then
            echo "TEST FAILED: the disk statistics filter counted no reads"
            exit 1
        fi
        if [[ -n "$system_disk_image" ]] &&
           ! grep -q '\[diskstats\] disk3: .* [1-9][0-9]* failed' "$serial_log"; then
            echo "TEST FAILED: the disk statistics filter counted no failed reads"
            exit 1
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
