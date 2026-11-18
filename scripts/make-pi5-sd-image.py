#!/usr/bin/env python3
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

"""Builds the Raspberry Pi 5 boot files and an SD card image (native boot).

    make-pi5-sd-image.py [--kernel build/arm64/native/fpos.img]
                         [--system-image build/arm64/system-disk.img.xz]
                         [--firmware-files ~/Downloads/pi5/boot]
                         [--boot-directory build/arm64/pi5-boot]
                         [--output build/arm64/pi5-sd.img]
                         [--server ADDRESS] [--netlog HOST] [--options "..."]
                         [--boot-files-only]

The Pi 5's EEPROM bootloader carries its own firmware (no start*.elf), so
the boot volume holds only
    config.txt          arm_64bit=1, kernel=fpos.img,
                        initramfs system.img followkernel, os_check=0 and
                        the HDMI framebuffer settings,
    cmdline.txt         the kernel options: netlog=SERVER and --options,
    bcm2712-rpi-5-b.dtb, bcm2712d0-rpi-5-b.dtb
                        the device trees (the firmware picks the one for
                        the board's stepping, edits it and passes it on),
    overlays/           whatever the firmware files directory has there
                        (vc4-kms-v3d-pi5.dtbo, see below),
    fpos.img            the native kernel (Linux arm64 Image format),
    system.img          the system image, loaded after the kernel as the
                        RAM disk: compressed (xz by default; the kernel
                        unpacks xz and gzip images), since the firmware
                        passes it on as it is and, over the network,
                        fetches it at a few hundred KiB/s and gives up
                        on a file after 60 s. The plain image works
                        too (make SYSTEM_IMAGE_COMPRESSION=none).

The boot directory (default build/arm64/pi5-boot) gets these files, the
kernel and system image as symbolic links to the build, so
netboot-serve.py --pi5 serves every rebuild as it is. The SD card image
(MBR, one FAT32 partition of 256 MiB) is made from it, with a compressed
copy next to it (.xz, or .gz without xz).

The device trees are the user's download (github.com/raspberrypi/firmware,
boot/); the directory defaults to ~/Downloads/pi5/boot. If it has
overlays/vc4-kms-v3d-pi5.dtbo, config.txt loads it: with it the firmware
leaves a simple-framebuffer node for the HDMI screen in the device tree.
"""

import argparse
import os
import shutil
import sys

import pi_boot_media

FIRMWARE_BOOT_URL = "https://github.com/raspberrypi/firmware/raw/master/boot"
DEVICE_TREES = ("bcm2712-rpi-5-b.dtb", "bcm2712d0-rpi-5-b.dtb")
FRAMEBUFFER_OVERLAY = "vc4-kms-v3d-pi5"
KERNEL_NAME = "fpos.img"
SYSTEM_IMAGE_NAME = "system.img"


def fail(message):
    sys.exit(f"make-pi5-sd-image: {message}")


def check_firmware_files(directory):
    missing = [name for name in DEVICE_TREES if not os.path.isfile(os.path.join(directory, name))]
    if missing:
        urls = "\n".join(f"    {FIRMWARE_BOOT_URL}/{name}" for name in missing)
        fail(f"the Raspberry Pi 5 device tree is missing from {directory}: {', '.join(missing)}.\n"
             f"Download into that directory (or pass PI5_FIRMWARE=<directory>):\n{urls}")


def framebuffer_overlay_present(directory):
    return os.path.isfile(os.path.join(directory, "overlays", FRAMEBUFFER_OVERLAY + ".dtbo"))


def config_text(with_framebuffer_overlay):
    lines = [
        "# FreePascalOS on the Raspberry Pi 5: native boot, no UEFI.",
        "# The EEPROM bootloader reads this, loads the kernel, the RAM disk",
        "# and the device tree, and starts the kernel at EL2 with the device",
        "# tree's address in x0.",
        "arm_64bit=1",
        f"kernel={KERNEL_NAME}",
        f"initramfs {SYSTEM_IMAGE_NAME} followkernel",
        "# Not a Linux kernel: skip the firmware's kernel compatibility check.",
        "os_check=0",
        "",
        "# The HDMI screen: the firmware sets the mode and hands the kernel a",
        "# framebuffer, described by a simple-framebuffer node in the device",
        "# tree (address, size, stride, format).",
    ]
    if with_framebuffer_overlay:
        lines += [
            "# With the KMS overlay the firmware disables the bcm2708-fb node and",
            "# adds simple-framebuffer nodes instead (FreePascalOS has no vc4",
            "# driver, so the firmware's framebuffer stays).",
            f"dtoverlay={FRAMEBUFFER_OVERLAY}",
        ]
    else:
        lines += [
            f"# overlays/{FRAMEBUFFER_OVERLAY}.dtbo was not there when this was made;",
            "# without it the firmware may leave only the bcm2708-fb node.",
            f"#dtoverlay={FRAMEBUFFER_OVERLAY}",
        ]
    lines += [
        "hdmi_force_hotplug=1",
        "disable_overscan=1",
        "disable_fw_kms_setup=1",
        "framebuffer_depth=32",
        "framebuffer_ignore_alpha=1",
        "",
        "# RP1's UART0 (GPIO 14/15, header pins 8 and 10) set up at 115200 and",
        "# RP1 not reset before the kernel starts, for a serial adapter.",
        "enable_rp1_uart=1",
        "",
        "# Keep the PCIe x4 link to RP1 (USB, Ethernet) that the bootloader",
        "# trained instead of resetting it before the kernel starts, so the",
        "# kernel inherits a working link.",
        "pciex4_reset=0",
        "",
    ]
    return "\n".join(lines)


def replace_with_link(link, target):
    if os.path.lexists(link):
        os.remove(link)
    os.symlink(os.path.relpath(os.path.abspath(target), os.path.dirname(os.path.abspath(link))), link)


def write_boot_directory(arguments, options):
    directory = arguments.boot_directory
    if os.path.isdir(directory):
        shutil.rmtree(directory)
    os.makedirs(directory)
    with_overlay = framebuffer_overlay_present(arguments.firmware_files)
    with open(os.path.join(directory, "config.txt"), "w") as config:
        config.write(config_text(with_overlay))
    with open(os.path.join(directory, "cmdline.txt"), "w") as cmdline:
        cmdline.write(" ".join(options) + "\n")
    for name in DEVICE_TREES:
        shutil.copyfile(os.path.join(arguments.firmware_files, name), os.path.join(directory, name))
    overlays = os.path.join(arguments.firmware_files, "overlays")
    if os.path.isdir(overlays):
        shutil.copytree(overlays, os.path.join(directory, "overlays"))
    replace_with_link(os.path.join(directory, KERNEL_NAME), arguments.kernel)
    replace_with_link(os.path.join(directory, SYSTEM_IMAGE_NAME), arguments.system_image)
    return with_overlay


def main():
    parser = argparse.ArgumentParser(description="Build the Raspberry Pi 5 boot files and SD card image.")
    parser.add_argument("--kernel", default="build/arm64/native/fpos.img", help="the native kernel")
    parser.add_argument("--system-image", default="build/arm64/system-disk.img.xz",
                        help="the system image, compressed or not (served as system.img)")
    parser.add_argument("--firmware-files", default="~/Downloads/pi5/boot",
                        help="the downloaded device trees (and overlays/)")
    parser.add_argument("--boot-directory", default="build/arm64/pi5-boot",
                        help="where the boot files are put (served by netboot-serve.py --pi5)")
    parser.add_argument("--output", default="build/arm64/pi5-sd.img", help="the SD card image to write")
    parser.add_argument("--server", help="the PC's address for netlog= (default: this machine)")
    parser.add_argument("--netlog", help="the host the kernel sends its log to (default: the server)")
    parser.add_argument("--options", default="", help="more kernel options for cmdline.txt")
    parser.add_argument("--boot-files-only", action="store_true", help="write the boot directory only")
    arguments = parser.parse_args()
    arguments.firmware_files = os.path.expanduser(arguments.firmware_files)

    try:
        if not arguments.boot_files_only:
            pi_boot_media.check_tools()
        if not os.path.isfile(arguments.kernel):
            fail(f"no native kernel {arguments.kernel}: the native (device tree) kernel is not built yet")
        if not os.path.isfile(arguments.system_image):
            fail(f"no system image {arguments.system_image}: make ARCH=arm64 served-system-image")
        check_firmware_files(arguments.firmware_files)
        server = arguments.server or pi_boot_media.default_server_address()
        options = [f"netlog={arguments.netlog or server}"]
        if arguments.options:
            options.append(arguments.options)

        with_overlay = write_boot_directory(arguments, options)
        print(f"Boot files: {arguments.boot_directory} (from {arguments.firmware_files})")
        print(f"cmdline:    {' '.join(options)}")
        if not with_overlay:
            print(f"Warning: no overlays/{FRAMEBUFFER_OVERLAY}.dtbo in {arguments.firmware_files}; without it "
                  "the firmware may give the kernel no simple-framebuffer (no HDMI log). Download\n"
                  f"    {FIRMWARE_BOOT_URL}/overlays/{FRAMEBUFFER_OVERLAY}.dtbo\n"
                  f"into {os.path.join(arguments.firmware_files, 'overlays')}/ and run this again.")
        if arguments.boot_files_only:
            return
        size = pi_boot_media.build_fat_card_image(arguments.output, arguments.boot_directory, "FPOSPI5")
        compressed = pi_boot_media.compress(arguments.output)
    except pi_boot_media.BootMediaError as error:
        fail(str(error))
    print(f"Image:      {arguments.output} ({size // (1024 * 1024)} MiB), compressed {compressed} "
          f"({os.path.getsize(compressed) // 1024} KiB)")
    print(pi_boot_media.flash_instructions(compressed))


if __name__ == "__main__":
    main()
