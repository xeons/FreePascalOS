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

"""Builds a Raspberry Pi 5 bootloader recovery SD card that sets the
EEPROM up for network boot from this PC (flashed once).

    make-pi5-eeprom-image.py [--eeprom-files ~/Downloads/pi5/eeprom]
                             [--server ADDRESS] [--output build/arm64/pi5-eeprom.img]
                             [--client-ip A.B.C.D --subnet MASK [--gateway A.B.C.D]]
                             [--sd-first] [--print-config]

Takes the newest pieeprom-*.bin and recovery.bin from the user's download
of github.com/raspberrypi/rpi-eeprom (firmware-2712/default/), replaces
the bootloader configuration in the image (see pi5_eeprom_image.py) with

    BOOT_ORDER=0xf12        network first, then the SD card, then again
    TFTP_IP=SERVER          the TFTP server, whatever the DHCP server says
    DHCP_TIMEOUT=15000      give up on the network after 15 s (no server,
                            no cable) and boot the SD card
    TFTP_FILE_TIMEOUT=60000 room for the 64 MiB system image
    NET_INSTALL_AT_POWER_ON=0  no network install screen at power on
    BOOT_UART=1             the bootloader's log on the UART too

(--client-ip and --subnet give a fixed address instead of DHCP;
--sd-first makes it 0xf21: the card first, the network only without one),
and writes an SD card image (MBR, one FAT32 partition) holding
recovery.bin, pieeprom.bin and pieeprom.sig. The Pi's boot ROM runs
recovery.bin from the card, which writes the EEPROM: the green LED then
blinks rapidly without end and an HDMI screen turns green (red and an
error pattern on failure).
"""

import argparse
import glob
import ipaddress
import os
import re
import sys
import tempfile

import pi_boot_media
import pi5_eeprom_image

EEPROM_FIRMWARE_URL = "https://github.com/raspberrypi/rpi-eeprom/raw/master/firmware-2712/default"
EEPROM_DIRECTORY_URL = "https://github.com/raspberrypi/rpi-eeprom/tree/master/firmware-2712/default"


def fail(message):
    sys.exit(f"make-pi5-eeprom-image: {message}")


def find_eeprom_files(directory):
    images = glob.glob(os.path.join(directory, "pieeprom-*.bin"))
    recovery = os.path.join(directory, "recovery.bin")
    if not images or not os.path.isfile(recovery):
        missing = []
        if not images:
            missing.append("pieeprom-YYYY-MM-DD.bin (the newest)")
        if not os.path.isfile(recovery):
            missing.append("recovery.bin")
        fail(f"the Raspberry Pi 5 bootloader files are missing from {directory}: {', '.join(missing)}.\n"
             f"Download them from {EEPROM_DIRECTORY_URL}\n"
             f"(for example {EEPROM_FIRMWARE_URL}/recovery.bin) into that directory, "
             "or pass PI5_EEPROM=<directory>.")
    newest = max(images, key=lambda path: [int(number) for number in re.findall(r"\d+", os.path.basename(path))])
    return newest, recovery


def checked_address(text, what):
    try:
        return str(ipaddress.IPv4Address(text))
    except ValueError:
        fail(f"{what} must be an IPv4 address, not {text!r}")


def bootloader_config(arguments, server):
    lines = [
        "[all]",
        "BOOT_UART=1",
        f"BOOT_ORDER={'0xf21' if arguments.sd_first else '0xf12'}",
        f"TFTP_IP={server}",
        "DHCP_TIMEOUT=15000",
        "TFTP_FILE_TIMEOUT=60000",
        "NET_INSTALL_AT_POWER_ON=0",
    ]
    if arguments.client_ip:
        if not arguments.subnet:
            fail("--client-ip needs --subnet too")
        lines.append(f"CLIENT_IP={checked_address(arguments.client_ip, 'CLIENT_IP')}")
        lines.append(f"SUBNET={checked_address(arguments.subnet, 'SUBNET')}")
        if arguments.gateway:
            lines.append(f"GATEWAY={checked_address(arguments.gateway, 'GATEWAY')}")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description="Build a Raspberry Pi 5 EEPROM recovery card for network boot.")
    parser.add_argument("--eeprom-files", default="~/Downloads/pi5/eeprom",
                        help="the directory with pieeprom-*.bin and recovery.bin")
    parser.add_argument("--server", help="the PC serving the boot files (default: this machine)")
    parser.add_argument("--output", default="build/arm64/pi5-eeprom.img", help="the SD card image to write")
    parser.add_argument("--client-ip", help="a fixed address for the Pi's bootloader instead of DHCP")
    parser.add_argument("--subnet", help="the subnet mask with --client-ip")
    parser.add_argument("--gateway", help="the gateway with --client-ip, if the server is on another network")
    parser.add_argument("--sd-first", action="store_true", help="boot the SD card first, the network after it")
    parser.add_argument("--print-config", action="store_true", help="print the configuration only")
    arguments = parser.parse_args()

    try:
        server = checked_address(arguments.server or pi_boot_media.default_server_address(), "SERVER")
        config = bootloader_config(arguments, server)
        if arguments.print_config:
            sys.stdout.write(config)
            return
        pi_boot_media.check_tools()
        image_path, recovery_path = find_eeprom_files(os.path.expanduser(arguments.eeprom_files))
        with open(image_path, "rb") as source:
            image = pi5_eeprom_image.EepromImage(source.read())
        previous_config = image.read_file(pi5_eeprom_image.CONFIG_FILE_NAME).decode(errors="replace")
        image.replace_file(pi5_eeprom_image.CONFIG_FILE_NAME, config.encode())
        if image.read_file(pi5_eeprom_image.CONFIG_FILE_NAME) != config.encode():
            fail("the configuration did not read back from the new image")
        image_bytes = bytes(image.data)

        output_directory = os.path.dirname(os.path.abspath(arguments.output))
        os.makedirs(output_directory, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="pi5-eeprom-", dir=output_directory) as staging:
            with open(recovery_path, "rb") as source, open(os.path.join(staging, "recovery.bin"), "wb") as output:
                output.write(source.read())
            with open(os.path.join(staging, "pieeprom.bin"), "wb") as output:
                output.write(image_bytes)
            with open(os.path.join(staging, "pieeprom.sig"), "w") as output:
                output.write(pi5_eeprom_image.signature_text(image_bytes))
            size = pi_boot_media.build_fat_card_image(arguments.output, staging, "PI5EEPROM")
        compressed = pi_boot_media.compress(arguments.output)
    except (pi_boot_media.BootMediaError, pi5_eeprom_image.EepromImageError) as error:
        fail(str(error))

    print(f"Bootloader: {image_path} with {recovery_path}")
    print("Configuration before:\n    " + previous_config.strip().replace("\n", "\n    "))
    print("Configuration now:\n    " + config.strip().replace("\n", "\n    "))
    print(f"Image:      {arguments.output} ({size // (1024 * 1024)} MiB), compressed {compressed} "
          f"({os.path.getsize(compressed) // 1024} KiB)")
    print(pi_boot_media.flash_instructions(compressed))
    print("Put the card in the Pi 5 and power it on: when the green LED blinks rapidly without end "
          "(and an HDMI screen is green), the EEPROM is written. Power off, then flash the card with "
          "make pi5-sd-image (the fallback when the PC does not answer).")


if __name__ == "__main__":
    main()
