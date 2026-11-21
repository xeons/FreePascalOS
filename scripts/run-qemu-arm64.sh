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
# Boots the AArch64 build (an EFI system partition directory) in QEMU's
# virt machine with the edk2 AArch64 UEFI firmware (AAVMF / QEMU_EFI).
#
#   run-qemu-arm64.sh <esp-directory> [--debug] [--headless] [disk-image]...
#                     [-- qemu-argument...]
#
# The machine is chosen to match a Raspberry Pi 4 as far as QEMU can:
# Cortex-A72 processors, a GICv2 interrupt controller (the Pi's GIC-400),
# the ARM generic timer, a PL011 UART, UEFI with ACPI tables. The
# framebuffer is QEMU's ramfb (a plain UEFI GOP framebuffer in memory,
# like the Pi firmware's), the boot volume a virtio disk on PCIe, the
# keyboard and the pointer (a tablet) USB devices on an xHCI controller,
# as on the Pi (whose VL805 is an xHCI controller).
#
# Environment:
#   PROCESSORS     number of processors (default 2)
#   MEMORY         memory size (default 1G)
#   VIRTUALIZATION=1  start the firmware at EL2, as the Pi's firmware
#                  does, so the loader's drop to EL1 is exercised
#   CPU            the processor model (default cortex-a72; "max" has
#                  PAN, ARMv8.1+, like the Raspberry Pi 5's Cortex-A76)
#   SEMIHOSTING=1  let the kernel end QEMU with an exit status (tests)
#   SD_CARD=image  an SD card holding the image, on an SD host controller
#                  (sdhci-pci; the image's size must be a power of two)
#   SERIAL         where the serial port goes (default stdio, e.g.
#                  file:log.txt)
#
# Arguments after "--" go to QEMU as they are (devices, a network of
# its own instead of the default virtio network card).
#
# Serial output (the kernel debug log) appears on this terminal. With
# --debug QEMU waits for GDB on localhost:1234.

set -euo pipefail

esp_directory="$1"
debug_mode=""
headless=""
disk_images=()
qemu_arguments=()
taking_qemu_arguments=""
for argument in "${@:2}"; do
    if [[ -n "$taking_qemu_arguments" ]]; then
        qemu_arguments+=("$argument")
        continue
    fi
    case "$argument" in
        --debug) debug_mode=yes ;;
        --headless) headless=yes ;;
        --) taking_qemu_arguments=yes ;;
        *) disk_images+=("$argument") ;;
    esac
done

find_first_existing_file() {
    for candidate in "$@"; do
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

firmware_code=$(find_first_existing_file \
    /usr/share/edk2/aarch64/QEMU_EFI.fd \
    /usr/share/AAVMF/AAVMF_CODE.fd \
    /usr/share/qemu-efi-aarch64/QEMU_EFI.fd) || { echo "AArch64 UEFI firmware (edk2-aarch64) not found"; exit 1; }
firmware_variables_template=$(find_first_existing_file \
    /usr/share/edk2/aarch64/QEMU_VARS.fd \
    /usr/share/AAVMF/AAVMF_VARS.fd) || { echo "AArch64 UEFI variable store not found"; exit 1; }

build_directory=$(dirname "$esp_directory")
firmware_variables="$build_directory/QEMU_VARS.fd"
if [[ ! -f "$firmware_variables" ]]; then
    cp "$firmware_variables_template" "$firmware_variables"
fi

machine="virt,gic-version=2"
if [[ "${VIRTUALIZATION:-}" == 1 ]]; then
    machine="$machine,virtualization=on"
fi

extra_arguments=()
disk_number=0
for disk_image in "${disk_images[@]}"; do
    extra_arguments+=(-drive if=none,format=raw,file="$disk_image",id=disk$disk_number)
    extra_arguments+=(-device virtio-blk-pci,drive=disk$disk_number)
    disk_number=$((disk_number + 1))
done
if [[ -n "${SD_CARD:-}" ]]; then
    extra_arguments+=(-device sdhci-pci,sd-spec-version=3
        -drive if=none,format=raw,cache=unsafe,file="$SD_CARD",id=sdcard0
        -device sd-card,drive=sdcard0)
fi
if [[ -n "$headless" ]]; then
    extra_arguments+=(-display none)
fi
if [[ "${SEMIHOSTING:-}" == 1 ]]; then
    extra_arguments+=(-semihosting-config enable=on,target=native)
fi
if [[ -n "$debug_mode" ]]; then
    extra_arguments+=(-s -S)
    echo "Waiting for GDB: gdb-multiarch $build_directory/kernel.elf -ex 'target remote :1234'"
fi
qemu_binary=qemu-system-aarch64

# Sound: an HD Audio controller with an output and a microphone, played
# through PipeWire or PulseAudio when this QEMU has that backend
# (packages qemu-audio-pipewire / qemu-audio-pa), otherwise recorded to
# a WAV file in the build folder (AUDIO=none leaves sound out).
audio_arguments=()
if [[ "${AUDIO:-}" != none ]]; then
    audio_backends=$("$qemu_binary" -audiodev help 2>/dev/null)
    if grep -qx pipewire <<< "$audio_backends"; then
        audio_arguments=(-audiodev pipewire,id=sound0 -audiodev pipewire,id=microphone0)
    elif grep -qx pa <<< "$audio_backends"; then
        audio_arguments=(-audiodev pa,id=sound0 -audiodev pa,id=microphone0)
    else
        echo "QEMU has no PipeWire or PulseAudio backend: sound goes to $build_directory/run-audio.wav"
        audio_arguments=(-audiodev wav,id=sound0,path="$build_directory/run-audio.wav"
            -audiodev none,id=microphone0)
    fi
    audio_arguments+=(-device intel-hda -device hda-output,audiodev=sound0
        -device hda-micro,audiodev=microphone0)
fi

exec "$qemu_binary" \
    -machine "$machine" \
    -cpu "${CPU:-cortex-a72}" \
    -m "${MEMORY:-1G}" \
    -smp "${PROCESSORS:-2}" \
    -drive if=pflash,format=raw,readonly=on,file="$firmware_code" \
    -drive if=pflash,format=raw,file="$firmware_variables" \
    -drive if=none,format=raw,file=fat:rw:"$esp_directory",id=esp \
    -device virtio-blk-pci,drive=esp \
    -device ramfb \
    -device qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0 -device usb-tablet,bus=xhci.0 \
    -serial "${SERIAL:-stdio}" \
    -no-reboot \
    "${audio_arguments[@]}" \
    "${extra_arguments[@]}" \
    "${qemu_arguments[@]}"
