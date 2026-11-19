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
# Under TCG the user mode tests alone take minutes (wgettest adds up to
# one more), so TCG gets twice as long; TEST_TIMEOUT overrides both.
if [[ "${ACCEL:-}" == kvm ]]; then
    timeout_seconds=${TEST_TIMEOUT:-240}
else
    timeout_seconds=${TEST_TIMEOUT:-480}
fi
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
# process; its exit code decides the result. heapchecks: the kernel heap
# and every program check their heap (fill patterns, guards, quarantine).
# netlog: the kernel log goes to scripts/netlog.py on the host as well
# (QEMU's user networking hands 10.0.2.2 to the host's loopback); the
# address comes from the network service networktest starts, not from the
# kernel's own DHCP (netdhcp=0), which would get in its way.
netlog_port=$((40000 + $$ % 20000))
netlog_received="$build_directory/test-netlog.log"
if [[ -n "${system_disk_image:-}" ]]; then
    # hangdump: if the tests stop making progress, the log shows why.
    echo "test-exit fstest heapchecks init=/bin/coretest hangdump=20 netlog=10.0.2.2:$netlog_port netdhcp=0" \
        > "$test_esp_directory/FreePascalOS/options.txt"
else
    echo "test-exit fstest heapchecks" > "$test_esp_directory/FreePascalOS/options.txt"
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
# The virtio disk make-test-disk.sh writes next to the test disk.
run_virtio_disk_image="$build_directory/test-disk-virtio-run.img"
if [[ -n "$test_disk_image" && -f "${test_disk_image%.img}-virtio.img" ]]; then
    cp -f "${test_disk_image%.img}-virtio.img" "$run_virtio_disk_image"
    disk_arguments+=(-drive if=none,id=virtio0,format=raw,cache=unsafe,file="$run_virtio_disk_image"
        -device virtio-blk-pci,drive=virtio0)
else
    run_virtio_disk_image=""
fi
run_nvme_disk_image="$build_directory/test-disk-nvme-run.img"
if [[ -n "$test_disk_image" && -f "${test_disk_image%.img}-nvme.img" ]]; then
    cp -f "${test_disk_image%.img}-nvme.img" "$run_nvme_disk_image"
    disk_arguments+=(-drive if=none,id=nvme0,format=raw,cache=unsafe,file="$run_nvme_disk_image"
        -device nvme,serial=fpostest,drive=nvme0)
else
    run_nvme_disk_image=""
fi
run_usb_disk_image="$build_directory/test-disk-usb-run.img"
if [[ -n "$test_disk_image" && -f "${test_disk_image%.img}-usb.img" ]]; then
    cp -f "${test_disk_image%.img}-usb.img" "$run_usb_disk_image"
    disk_arguments+=(-device qemu-xhci,id=xhci
        -drive if=none,id=usbdisk0,format=raw,cache=unsafe,file="$run_usb_disk_image"
        -device usb-storage,bus=xhci.0,drive=usbdisk0)
else
    run_usb_disk_image=""
fi
# An SD card on an SD host controller (SDHCI 3.00) for the SDHCI driver:
# 4 GiB (SDHC) holding a copy of the FAT16 partition. Its controller
# goes on the command line after every other PCI device, so theirs keep
# their places, and the card is the last disk.
run_sd_card_image="$build_directory/test-disk-sdhc-run.img"
sd_card_arguments=()
if [[ -n "$test_disk_image" && -f "${test_disk_image%.img}-sdhc.img" ]]; then
    cp -f --sparse=always "${test_disk_image%.img}-sdhc.img" "$run_sd_card_image"
    sd_card_arguments+=(-device sdhci-pci,sd-spec-version=3
        -drive if=none,id=sdcard0,format=raw,cache=unsafe,file="$run_sd_card_image"
        -device sd-card,drive=sdcard0)
else
    run_sd_card_image=""
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

# An optical drive on the fifth AHCI port (disk4), for the ATAPI driver.
if [[ -n "$test_disk_image" && -f "${test_disk_image%.img}-cdrom.img" ]]; then
    disk_arguments+=(-drive if=none,id=cdrom0,format=raw,media=cdrom,readonly=on,file="${test_disk_image%.img}-cdrom.img"
        -device ide-cd,drive=cdrom0,bus=ide.4)
fi

# Sound: an HD Audio controller with an output codec (/dev/audio) and a
# microphone codec (/dev/audioin, fed silence by the "none" backend), an
# AC'97 controller (/dev/audio1) and a USB audio device on the xHCI
# controller (/dev/audio2); each output is recorded into a WAV file that
# the host checks afterwards.
audio_recording="$build_directory/test-audio.wav"
ac97_recording="$build_directory/test-audio-ac97.wav"
usb_audio_recording="$build_directory/test-audio-usb.wav"
rm -f "$audio_recording" "$ac97_recording" "$usb_audio_recording"
if [[ -n "$system_disk_image" ]]; then
    disk_arguments+=(-audiodev wav,id=sound0,path="$audio_recording"
        -device intel-hda -device hda-output,audiodev=sound0
        -audiodev none,id=microphone0 -device hda-micro,audiodev=microphone0
        -audiodev wav,id=sound1,path="$ac97_recording"
        -device AC97,audiodev=sound1)
    if [[ -n "$run_usb_disk_image" ]]; then
        disk_arguments+=(-audiodev wav,id=sound2,path="$usb_audio_recording"
            -device usb-audio,bus=xhci.0,audiodev=sound2)
    fi
fi

# The web servers of the wget test (wgettest): scripts/test-web-server.py
# runs for each connection the guest makes to one of their addresses,
# over HTTP or HTTPS with the test certificates of tools/TlsTest; behind
# 10.0.2.103 is OpenSSL's s_server -www (reached through the same
# script as a relay). They need Python 3 with its ssl module and openssl
# on the host.
if ! python3 -c 'import ssl' 2> /dev/null; then
    echo "TEST FAILED: the wget test needs Python 3 with its ssl module on the host"
    exit 1
fi
if ! command -v openssl > /dev/null; then
    echo "TEST FAILED: the wget test needs openssl on the host (for openssl s_server)"
    exit 1
fi
web_server="python3 $(cd "$(dirname "$0")" && pwd)/test-web-server.py"
certificate_directory="$(cd "$(dirname "$0")/.." && pwd)/tools/TlsTest/certificates"
s_server_port=$((20000 + $$ % 20000))
openssl s_server -quiet -www -tls1_3 -accept "$s_server_port" -cert "$certificate_directory/server-rsa.pem" \
    -key "$certificate_directory/server-rsa.key" < /dev/null > /dev/null 2>&1 &
s_server_process=$!
rm -f "$netlog_received"
python3 -I "$(dirname "$0")/netlog.py" --bind 127.0.0.1 --port "$netlog_port" --output "$netlog_received" \
    --no-color > /dev/null 2>&1 &
netlog_process=$!
trap 'kill "$s_server_process" "$netlog_process" 2> /dev/null' EXIT
web_forwards="guestfwd=tcp:10.0.2.101:443-cmd:$web_server https server-chain.pem server.key"
web_forwards+=",guestfwd=tcp:10.0.2.102:80-cmd:$web_server http"
web_forwards+=",guestfwd=tcp:10.0.2.103:443-cmd:$web_server relay $s_server_port"
web_forwards+=",guestfwd=tcp:10.0.2.104:443-cmd:$web_server https wrong-name-chain.pem wrong-name.key"
web_forwards+=",guestfwd=tcp:10.0.2.105:443-cmd:$web_server https other-server.pem other-server.key"
web_forwards+=",guestfwd=tcp:10.0.2.106:443-cmd:$web_server https expired-chain.pem expired.key"

# A virtio network card on QEMU's user networking (the guest is
# 10.0.2.15, the gateway 10.0.2.2 answers pings); a TCP connection to
# 10.0.2.100 port 7 reaches "cat", an echo service for networktest, and
# 10.0.2.101 to 10.0.2.106 the web servers above. IPv6 too, as user
# networking has it by default: QEMU's router (fe80::2) advertises
# fec0::/64 (the guest makes a stable-privacy and a temporary address in it,
# not the EUI-64 one), fec0::2 answers pings and fec0::3 is the DNS server it
# advertises. (Naming ipv6-net, ipv6-host or ipv6-dns explicitly stops
# QEMU 11's DHCP server from answering, so the defaults are relied on.)
network_arguments=(-netdev "user,id=net0,guestfwd=tcp:10.0.2.100:7-cmd:cat,$web_forwards"
    -device virtio-net-pci,netdev=net0)

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
    "${network_arguments[@]}" \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    -netdev user,id=net1 -device e1000e,netdev=net1 \
    -netdev user,id=net2 -device e1000,netdev=net2 \
    -netdev user,id=net3 -device rtl8139,netdev=net3 \
    "${sd_card_arguments[@]}" \
    -device i6300esb \
    -serial file:"$serial_log" \
    -display none -no-reboot \
    < /dev/null > /dev/null 2>&1
qemu_status=$?
# The last datagrams may still be on their way.
sleep 1
kill "$netlog_process" 2> /dev/null

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

# A heap check that failed in a program (the report goes to the console)
# fails the test, unless it was one of the mistakes heaptest makes on
# purpose.
unexpected_heap_reports=$(grep 'heap check in ' "$serial_log" | grep -v 'heap check in [^ ]*heaptest ')

case "$qemu_status" in
    1)
        if [[ -n "$unexpected_heap_reports" ]]; then
            echo "TEST FAILED: heap checks failed in user mode:"
            echo "$unexpected_heap_reports"
            exit 1
        fi
        if ! grep -q 'kernel heap checks: .*passed' "$serial_log"; then
            echo "TEST FAILED: the kernel heap check self test did not run"
            exit 1
        fi
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
        if [[ -n "$run_nvme_disk_image" ]]; then
            if ! grep -q '\[nvme\] .*: 1 namespaces, .* interrupts' "$serial_log"; then
                echo "TEST FAILED: the NVMe disk was not started with interrupts"
                exit 1
            fi
            if ! "$(dirname "$0")/verify-test-disk.sh" "$run_nvme_disk_image"; then
                echo "TEST FAILED: the volume on the NVMe disk did not pass the host side checks"
                exit 1
            fi
        fi
        if [[ -n "$run_usb_disk_image" ]]; then
            if ! grep -q '\[xhci\] Controller .* interrupts' "$serial_log" ||
               ! grep -q '\[usb\] Port [0-9]*: device' "$serial_log"; then
                echo "TEST FAILED: the USB stick was not found through xHCI with interrupts"
                exit 1
            fi
            if ! "$(dirname "$0")/verify-test-disk.sh" "$run_usb_disk_image"; then
                echo "TEST FAILED: the volume on the USB stick did not pass the host side checks"
                exit 1
            fi
        fi
        if [[ -n "$run_sd_card_image" ]]; then
            if ! grep -q '\[sdhci\] disk[0-9]*: SDHC card .*ADMA2.* interrupts' "$serial_log"; then
                echo "TEST FAILED: the SD card was not started (SDHC, ADMA2, interrupts)"
                exit 1
            fi
            if ! "$(dirname "$0")/verify-test-disk.sh" "$run_sd_card_image"; then
                echo "TEST FAILED: the volume on the SD card did not pass the host side checks"
                exit 1
            fi
        fi
        # The tones coretest played (check-audio.py lists them) on the HD
        # Audio output, 700 Hz for half a second on the AC'97 one and 500 Hz
        # on the USB one.
        if [[ -n "$system_disk_image" ]]; then
            if ! grep -q '\[audio\] HD Audio .*interrupts by MSI' "$serial_log" ||
               ! python3 -I "$(dirname "$0")/check-audio.py" "$audio_recording"; then
                echo "TEST FAILED: the sound played was not right"
                exit 1
            fi
            if ! grep -q "\[audio\] AC'97 .*interrupts by line" "$serial_log" ||
               ! python3 -I "$(dirname "$0")/check-audio.py" "$ac97_recording" 700:0.5; then
                echo "TEST FAILED: the sound played on the AC'97 output was not right"
                exit 1
            fi
            if [[ -n "$run_usb_disk_image" ]] && { ! grep -q '\[audio\] USB audio' "$serial_log" ||
               ! python3 -I "$(dirname "$0")/check-audio.py" "$usb_audio_recording" 500:0.5; }; then
                echo "TEST FAILED: the sound played on the USB audio output was not right"
                exit 1
            fi
        fi
        # The network card: found and driven by interrupts.
        if ! grep -q '\[virtio\] eth[0-9]*: network card, interrupts by MSI-X' "$serial_log"; then
            echo "TEST FAILED: the virtio network card was not started with MSI-X interrupts"
            exit 1
        fi
        # The virtio disk: found, driven by interrupts, and its volume
        # (tested like the others) consistent afterwards.
        if [[ -n "$run_virtio_disk_image" ]]; then
            if ! grep -q '\[virtio\] disk[0-9]*: interrupts by MSI-X' "$serial_log"; then
                echo "TEST FAILED: the virtio disk was not started with MSI-X interrupts"
                exit 1
            fi
            if ! "$(dirname "$0")/verify-test-disk.sh" "$run_virtio_disk_image"; then
                echo "TEST FAILED: the volume on the virtio disk did not pass the host side checks"
                exit 1
            fi
        fi
        # The orphans the ext3 and ext4 test partitions came with were freed.
        if [[ -n "$test_disk_image" ]] &&
           [[ $(grep -c 'disk1p[67]: 1 orphaned inodes freed' "$serial_log") != 2 ]]; then
            echo "TEST FAILED: the orphans of the ext test partitions were not freed"
            exit 1
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
        # The network cards: each registered as an adapter with its address
        # and interrupts (MSI on the PCI Express e1000e, the PCI line on
        # the others), and its link came up.
        for network_card in "Intel 82574L:MSI" "Intel 82540EM:line" "Realtek RTL8139:line"; do
            card_name="${network_card%%:*}"
            card_interrupts="${network_card##*:}"
            # (Up already when it registered, or later.)
            if ! grep -q "\[net\] eth[0-9]*: $card_name, address [0-9A-F:]*, .*interrupts by $card_interrupts" "$serial_log" ||
               { ! grep -q "\[net\] eth[0-9]*: $card_name, address [0-9A-F:]*, link up" "$serial_log" &&
                 ! grep -q "\[net\] eth[0-9]* ($card_name): link up" "$serial_log"; }; then
                echo "TEST FAILED: the $card_name network card was not started, or its link did not come up"
                exit 1
            fi
        done
        # The hardware watchdog (QEMU's i6300esb, after every other PCI
        # device): found, and kept from resetting the machine by the
        # kernel timer during the self test (a reset would have ended
        # QEMU, which runs with -no-reboot).
        if ! grep -q '\[watchdog\] Intel 6300ESB watchdog at' "$serial_log" ||
           ! grep -q '\[selftest\] watchdog: passed' "$serial_log"; then
            echo "TEST FAILED: the i6300esb watchdog was not found or its self test did not pass"
            exit 1
        fi
        # The network log: the replay from the first line once eth0 had
        # an address, then lines as they were written, all from one boot.
        if [[ -n "$system_disk_image" ]] &&
           ! python3 -I - "$netlog_received" <<'CHECK'
import re, sys
lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
entries = []
for line in lines:
    match = re.match(r"(\S+) (\d+)\+? [0-9.]+ (.*)$", line)
    if match and not line.startswith("#"):
        entries.append((int(match.group(2)), match.group(3)))
problems = []
if any(line.startswith("#") and "REBOOT" in line for line in lines):
    problems.append("the sequence numbers started again")
if not any(sequence <= 5 and "kernel starting" in text for sequence, text in entries):
    problems.append("no replay of the first lines")
announced = [sequence for sequence, text in entries if "[netlog] sending the kernel log to 10.0.2.2" in text]
if not announced:
    problems.append("no line saying where the log goes")
elif not any(sequence > announced[0] + 20 for sequence, text in entries):
    problems.append("no lines written after streaming began")
if problems:
    print("netlog: " + "; ".join(problems) + " (%d lines received)" % len(entries))
    sys.exit(1)
CHECK
        then
            echo "TEST FAILED: the network log (netlog) did not arrive as it should"
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
