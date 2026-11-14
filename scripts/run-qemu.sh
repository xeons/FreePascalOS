#!/usr/bin/env bash
#
# Boots an EFI system partition directory in QEMU with OVMF firmware.
#
#   run-qemu.sh <arch> <esp-directory> [--debug]
#
# Serial output (the kernel debug log) appears on this terminal.
# With --debug QEMU waits for GDB on localhost:1234.

set -euo pipefail

architecture="$1"
esp_directory="$2"
debug_mode="${3:-}"

find_first_existing_file() {
    for candidate in "$@"; do
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

case "$architecture" in
    amd64)
        qemu_binary=qemu-system-x86_64
        firmware_code=$(find_first_existing_file \
            /usr/share/edk2/x64/OVMF_CODE.4m.fd \
            /usr/share/OVMF/x64/OVMF_CODE.4m.fd \
            /usr/share/OVMF/OVMF_CODE.fd \
            /usr/share/ovmf/OVMF.fd) || { echo "OVMF firmware not found"; exit 1; }
        firmware_variables_template=$(find_first_existing_file \
            /usr/share/edk2/x64/OVMF_VARS.4m.fd \
            /usr/share/OVMF/x64/OVMF_VARS.4m.fd \
            /usr/share/OVMF/OVMF_VARS.fd) || { echo "OVMF variable store not found"; exit 1; }
        machine_arguments=(-machine q35 -cpu max)
        ;;
    *)
        echo "Unsupported architecture: $architecture"
        exit 1
        ;;
esac

build_directory=$(dirname "$esp_directory")
firmware_variables="$build_directory/OVMF_VARS.fd"
if [[ ! -f "$firmware_variables" ]]; then
    cp "$firmware_variables_template" "$firmware_variables"
fi

extra_arguments=()
if [[ "$debug_mode" == "--debug" ]]; then
    extra_arguments+=(-s -S)
    echo "Waiting for GDB: gdb $build_directory/kernel.elf -ex 'target remote :1234'"
fi

exec "$qemu_binary" \
    "${machine_arguments[@]}" \
    -m 512M \
    -smp 1 \
    -drive if=pflash,format=raw,readonly=on,file="$firmware_code" \
    -drive if=pflash,format=raw,file="$firmware_variables" \
    -drive format=raw,file=fat:rw:"$esp_directory" \
    -serial stdio \
    -no-reboot \
    "${extra_arguments[@]}"
