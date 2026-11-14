#!/usr/bin/env bash
#
# Checks a test disk after the kernel has written to it.
#
#   verify-test-disk.sh <disk-image>
#
# Every partition is extracted and checked with its file system's own
# tools: the consistency checker (fsck.fat, fsck.exfat, e2fsck) must find
# no errors, and the files the kernel's write test leaves behind (see
# kernel/Kernel.FileSystemWriteTest.pas) must read back with the expected
# contents through an independent implementation (mtools, debugfs, or the
# exFAT helper).

set -uo pipefail

disk_image="$1"
script_directory=$(cd "$(dirname "$0")" && pwd)
work_directory=$(dirname "$disk_image")/verify-work
rm -rf "$work_directory"
mkdir -p "$work_directory"

big_file_size=$((200 * 1024 + 123))
many_file_count=40
failures=0

report_failure() {
    echo "  FAILED: $1"
    failures=$((failures + 1))
}

# Prints the contents of a file stored on a partition image.
read_file() {
    local type="$1" image="$2" path="$3"
    case "$type" in
        fat*)  mtype -i "$image" "::/$path" 2>/dev/null ;;
        exfat) python3 -I "$script_directory/exfat-tool.py" cat "$image" "$path" 2>/dev/null ;;
        ext*)  debugfs -R "cat \"/$path\"" "$image" 2>/dev/null ;;
    esac
}

check_consistency() {
    local type="$1" image="$2" output
    case "$type" in
        fat*)  output=$(fsck.fat -n "$image" 2>&1) ;;
        exfat) output=$(fsck.exfat -n "$image" 2>&1) ;;
        ext*)  output=$(e2fsck -fn "$image" 2>&1) ;;
    esac
    local status=$?
    if (( status != 0 )); then
        report_failure "$type consistency check reported problems (exit $status)"
        echo "$output" | sed 's/^/    /' | head -30
    fi
}

check_contents() {
    local type="$1" image="$2" path="$3" expected="$4" actual
    actual=$(read_file "$type" "$image" "$path"; printf x)
    actual=${actual%x}
    if [[ "$actual" != "$expected" ]]; then
        report_failure "$type: $path does not contain the expected text"
    fi
}

check_big_file() {
    local type="$1" image="$2"
    read_file "$type" "$image" "written/big-written.bin" > "$work_directory/big.bin"
    if ! python3 -I - "$work_directory/big.bin" "$big_file_size" <<'EOF'
import sys
data = open(sys.argv[1], "rb").read()
expected_size = int(sys.argv[2])
if len(data) != expected_size:
    sys.exit(f"size {len(data)}, expected {expected_size}")
for position, value in enumerate(data):
    if value != (position * 7) % 253:
        sys.exit(f"wrong byte at {position}")
EOF
    then
        report_failure "$type: written/big-written.bin is wrong"
    fi
}

check_sparse_file() {
    local type="$1" image="$2"
    read_file "$type" "$image" "written/sparse-written.bin" > "$work_directory/sparse.bin"
    if ! python3 -I - "$work_directory/sparse.bin" <<'EOF'
import sys
data = open(sys.argv[1], "rb").read()
stride, region, final_size = 20000, 1000, 150000
if len(data) != final_size:
    sys.exit(f"size {len(data)}, expected {final_size}")
for position, value in enumerate(data):
    expected = ord("S") if position % stride < region else 0
    if value != expected:
        sys.exit(f"wrong byte at {position}")
EOF
    then
        report_failure "$type: written/sparse-written.bin is wrong"
    fi
}

check_partition() {
    local type="$1" image="$2"
    echo "Checking $type"
    check_consistency "$type" "$image"
    check_contents "$type" "$image" "written/final.txt" $'Final contents.\n'
    check_contents "$type" "$image" "written/append.txt" "one two"
    check_contents "$type" "$image" "written/Mixed Case Long Name.txt" $'mixed\n'
    check_contents "$type" "$image" "written/lower.txt" $'lower\n'
    check_contents "$type" "$image" "written/moved/inner.txt" $'inner\n'
    check_big_file "$type" "$image"
    check_sparse_file "$type" "$image"
    case "$type" in
        ext*)
            if ! debugfs -R "stat /written/short-link" "$image" 2>/dev/null |
                grep -q 'Fast link dest: "final.txt"'; then
                report_failure "$type: written/short-link does not point at final.txt"
            fi
            ;;
    esac
    local index name
    for (( index = 0; index < many_file_count; index++ )); do
        printf -v name '%02d' "$index"
        check_contents "$type" "$image" "written/many/file-$name.txt" "file $name"$'\n'
    done
    # The original files must be untouched.
    check_contents "$type" "$image" "hello.txt" $'Hello from FreePascalOS!\n'
}

# Extract each GPT partition, named after its file system type.
while read -r start size name; do
    image="$work_directory/$name.img"
    dd if="$disk_image" of="$image" bs=512 skip="$start" count="$size" status=none
    check_partition "$name" "$image"
done < <(sfdisk --json "$disk_image" | python3 -I -c '
import json, sys
for partition in json.load(sys.stdin)["partitiontable"]["partitions"]:
    print(partition["start"], partition["size"], partition["name"])
')

if (( failures > 0 )); then
    echo "Host side verification: $failures problem(s)"
    exit 1
fi
echo "Host side verification: all partitions consistent"
