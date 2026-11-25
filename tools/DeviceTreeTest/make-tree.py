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

#
# Writes the flattened device tree the device tree test
# (DeviceTreeTest.pas) reads, encoded here without dtc: laid out like the
# Raspberry Pi 5's (bcm2712-rpi-5-b as its firmware passes it: /soc with
# 32-bit addresses moved to 10_7C00_0000 by its ranges, the GIC-400 and
# the PL011 debug UART there, /axi with the PCIe root complex of RP1 and
# the SD controller, a simple-framebuffer of r5g6b5 in /chosen without
# ranges, the firmware's bootargs, an initrd, an alias as stdout-path, a
# memory reservation), plus a generic ECAM PCI host bridge with an
# interrupt-map as QEMU's virt machine has, a node using
# interrupts-extended and a disabled node with a child.
#
# Below the RP1 root complex (pcie2, as bcm2712-rpi-5-b.dtb has it): its
# three inbound windows (RP1's own BAR, all RAM at 10_0000_0000, the
# MIP's doorbell at FF_FFFF_F000), msi-parent naming the MIP
# (brcm,bcm2712-mip, with its msi-ranges of 64 SPIs from 128), and the
# "rp1" node: its peripheral window C0_4000_0000 at PCI address 0, its
# dma-ranges, the Ethernet controller with its PHY, a USB controller, a
# UART, a disabled display controller and the shared memory with a
# child of its own.
#
#   make-tree.py <output.dtb>

import struct
import sys

GIC = 1
INTC2 = 2
RP1 = 3
MIP = 4
PHY = 5
BROKEN_PARENT = 6
HOSTILE_NEXUS = 7


def cells(*values):
    return b''.join(struct.pack('>I', value & 0xFFFFFFFF) for value in values)


def text(value):
    return value.encode() + b'\0'


def strings(*values):
    return b''.join(text(value) for value in values)


def node(name, properties, children=()):
    return (name, properties, list(children))


TREE = node('', [
    ('#address-cells', cells(2)), ('#size-cells', cells(2)),
    ('model', text('Raspberry Pi 5 Model B Rev 1.1')),
    ('compatible', strings('raspberrypi,5-model-b', 'brcm,bcm2712')),
    ('interrupt-parent', cells(GIC)),
], [
    node('aliases', [('serial10', text('/soc@107c000000/serial@7d001000'))]),
    node('chosen', [
        ('#address-cells', cells(2)), ('#size-cells', cells(2)),
        ('bootargs', text('reboot=w coherent_pool=1M 8250.nr_uarts=1 netlog=192.168.1.2')),
        ('stdout-path', text('serial10:115200n8')),
        ('linux,initrd-start', cells(0x02000000)),
        ('linux,initrd-end', cells(0x06000000)),
    ], [
        node('framebuffer@3f800000', [
            ('compatible', text('simple-framebuffer')),
            ('reg', cells(0, 0x3f800000, 0, 0x007e9000)),
            ('width', cells(1920)), ('height', cells(1080)), ('stride', cells(3840)),
            ('format', text('r5g6b5')),
        ]),
    ]),
    node('memory@0', [
        ('device_type', text('memory')),
        ('reg', cells(0, 0, 0, 0x3f800000, 0, 0x40000000, 1, 0xc0000000)),
    ]),
    node('reserved-memory', [
        ('#address-cells', cells(2)), ('#size-cells', cells(2)), ('ranges', b''),
    ], [
        node('atf@0', [('reg', cells(0, 0, 0, 0x80000)), ('no-map', b'')]),
        node('linux,cma', [('size', cells(0, 0x4000000)), ('reusable', b'')]),
    ]),
    node('cpus', [('#address-cells', cells(1)), ('#size-cells', cells(0))], [
        node('cpu@%d' % index, [
            ('device_type', text('cpu')), ('compatible', text('arm,cortex-a76')),
            ('reg', cells(index * 0x100)), ('enable-method', text('psci')),
        ]) for index in range(4)
    ] + [
        # Not in the Pi 5's tree (it has none): a standby state and a
        # power-down state whose timer stops, for the idle state reading.
        node('idle-states', [('entry-method', text('psci'))], [
            node('cpu-standby', [
                ('compatible', text('arm,idle-state')), ('arm,psci-suspend-param', cells(0x1)),
                ('entry-latency-us', cells(20)), ('exit-latency-us', cells(40)),
                ('min-residency-us', cells(100)),
            ]),
            node('cpu-off', [
                ('compatible', text('arm,idle-state')), ('arm,psci-suspend-param', cells(0x10000)),
                ('entry-latency-us', cells(200)), ('exit-latency-us', cells(400)),
                ('min-residency-us', cells(2000)), ('local-timer-stop', b''),
            ]),
        ]),
    ]),
    node('psci', [('compatible', strings('arm,psci-1.0', 'arm,psci-0.2')), ('method', text('smc'))]),
    node('timer', [
        ('compatible', text('arm,armv8-timer')),
        ('interrupts', cells(1, 13, 0xf08, 1, 14, 0xf08, 1, 11, 0xf08, 1, 10, 0xf08)),
    ]),
    node('soc@107c000000', [
        ('compatible', text('simple-bus')),
        ('#address-cells', cells(1)), ('#size-cells', cells(1)),
        ('ranges', cells(0x7c000000, 0x10, 0x7c000000, 0x04000000)),
    ], [
        node('serial@7d001000', [
            ('compatible', strings('arm,pl011', 'arm,primecell')),
            ('reg', cells(0x7d001000, 0x200)),
            ('interrupts', cells(0, 121, 4)),
        ]),
        node('interrupt-controller@7fff9000', [
            ('compatible', text('arm,gic-400')),
            ('reg', cells(0x7fff9000, 0x1000, 0x7fffa000, 0x2000, 0x7fffc000, 0x2000, 0x7fffe000, 0x2000)),
            ('interrupt-controller', b''), ('#interrupt-cells', cells(3)),
            ('phandle', cells(GIC)),
        ]),
        node('intc@7d508380', [
            ('compatible', text('brcm,l2-intc')),
            ('reg', cells(0x7d508380, 0x10)),
            ('interrupt-controller', b''), ('#interrupt-cells', cells(1)),
            ('interrupts', cells(0, 242, 4)),
            ('phandle', cells(INTC2)),
        ]),
        node('gpio@7d517c00', [
            ('compatible', text('brcm,bcm2712-gpio')),
            ('reg', cells(0x7d517c00, 0x40)),
            ('interrupts-extended', cells(INTC2, 7, GIC, 0, 244, 1)),
        ]),
        node('watchdog@7d200000', [
            ('compatible', text('brcm,bcm2712-pm')),
            ('reg', cells(0x7d200000, 0x604)),
            ('status', text('disabled')),
        ], [
            node('child', [('compatible', text('test,hidden-child'))]),
        ]),
    ]),
    node('axi', [
        ('compatible', text('simple-bus')),
        ('#address-cells', cells(2)), ('#size-cells', cells(2)),
        ('ranges', cells(0x10, 0, 0x10, 0, 0x1, 0) + cells(0x1f, 0, 0x1f, 0, 0x1, 0) +
         cells(0x1c, 0, 0x1c, 0, 0x3, 0)),
        ('dma-ranges', cells(0, 0, 0, 0, 0x10, 0) + cells(0x10, 0, 0x10, 0, 0x1, 0) +
         cells(0x14, 0, 0x14, 0, 0x4, 0) + cells(0x18, 0, 0x18, 0, 0x4, 0) + cells(0x1c, 0, 0x1c, 0, 0x4, 0)),
    ], [
        node('pcie@1000120000', [
            ('compatible', text('brcm,bcm2712-pcie')),
            ('reg', cells(0x10, 0x00120000, 0, 0x9310)),
            ('device_type', text('pci')),
            ('linux,pci-domain', cells(2)),
            ('max-link-speed', cells(2)),
            ('#address-cells', cells(3)), ('#size-cells', cells(2)),
            ('#interrupt-cells', cells(1)),
            ('interrupts', cells(0, 233, 4, 0, 234, 4)),
            ('interrupt-names', strings('pcie', 'msi')),
            ('interrupt-map-mask', cells(0, 0, 0, 7)),
            ('interrupt-map', cells(0, 0, 0, 1, GIC, 0, 229, 4) + cells(0, 0, 0, 2, GIC, 0, 230, 4)),
            ('resets', cells(6, 7, 44)),
            ('reset-names', strings('rescal', 'bridge')),
            ('msi-controller', b''),
            ('msi-parent', cells(MIP)),
            ('ranges', cells(0x02000000, 0, 0, 0x1f, 0, 0, 0xfffffffc) +
             cells(0x43000000, 0x4, 0, 0x1c, 0, 0x3, 0)),
            ('dma-ranges', cells(0x02000000, 0, 0, 0x1f, 0, 0, 0x400000) +
             cells(0x43000000, 0x10, 0, 0, 0, 0x10, 0) +
             cells(0x03000000, 0xff, 0xfffff000, 0x10, 0x130000, 0, 0x1000)),
            ('aspm-no-l0s', b''),
        ], [
            node('rp1', [
                ('compatible', text('simple-bus')),
                ('#address-cells', cells(2)), ('#size-cells', cells(2)),
                ('#interrupt-cells', cells(2)), ('interrupt-controller', b''),
                ('interrupt-parent', cells(RP1)),
                ('ranges', cells(0xc0, 0x40000000, 0x02000000, 0, 0, 0, 0x410000)),
                ('dma-ranges', cells(0x10, 0, 0x43000000, 0x10, 0, 0x10, 0) +
                 cells(0xc0, 0x40000000, 0x02000000, 0, 0, 0, 0x410000) +
                 cells(0, 0, 0x02000000, 0x10, 0, 0x10, 0)),
                ('phandle', cells(RP1)),
            ], [
                node('serial@30000', [
                    ('compatible', text('arm,pl011-axi')),
                    ('reg', cells(0xc0, 0x40030000, 0, 0x100)),
                    ('interrupts', cells(25, 4)),
                ]),
                node('ethernet@100000', [
                    ('reg', cells(0xc0, 0x40100000, 0, 0x4000)),
                    ('compatible', strings('raspberrypi,rp1-gem', 'cdns,macb')),
                    ('#address-cells', cells(1)), ('#size-cells', cells(0)),
                    ('interrupts', cells(6, 4)),
                    ('phy-mode', text('rgmii-id')),
                    ('cdns,aw2w-max-pipe', bytes([8])),
                    ('cdns,ar2r-max-pipe', bytes([8])),
                    ('cdns,use-aw2b-fill', b''),
                    ('local-mac-address', bytes([0x2c, 0xcf, 0x67, 0x12, 0x34, 0x56])),
                    ('phy-handle', cells(PHY)),
                    ('phy-reset-gpios', cells(0x2e, 32, 1)),
                    ('phy-reset-duration', cells(5)),
                ], [
                    node('ethernet-phy@1', [
                        ('reg', cells(1)), ('brcm,powerdown-enable', b''), ('phandle', cells(PHY)),
                    ]),
                ]),
                node('usb@200000', [
                    ('reg', cells(0xc0, 0x40200000, 0, 0x100000)),
                    ('compatible', text('snps,dwc3')),
                    ('dr_mode', text('host')),
                    ('snps,axi-pipe-limit', bytes([8])),
                    ('snps,dis_rxdet_inp3_quirk', b''),
                    ('snps,parkmode-disable-ss-quirk', b''),
                    ('snps,tx-max-burst', bytes([8])),
                    ('snps,tx-thr-num-pkt', bytes([2])),
                    ('interrupts', cells(31, 1)),
                ]),
                node('dsi@110000', [
                    ('compatible', text('raspberrypi,rp1dsi')),
                    ('status', text('disabled')),
                    ('reg', cells(0xc0, 0x40118000, 0, 0x1000)),
                    ('interrupts', cells(47, 4)),
                ]),
                node('sram@400000', [
                    ('compatible', text('mmio-sram')),
                    ('reg', cells(0xc0, 0x40400000, 0, 0x10000)),
                    ('#address-cells', cells(1)), ('#size-cells', cells(1)),
                    ('ranges', cells(0, 0xc0, 0x40400000, 0x10000)),
                ], [
                    node('shmem@ff00', [
                        ('compatible', text('raspberrypi,rp1-shmem')),
                        ('reg', cells(0xff00, 0x100)),
                    ]),
                ]),
            ]),
        ]),
        node('msi-controller@1000130000', [
            ('compatible', text('brcm,bcm2712-mip')),
            ('reg', cells(0x10, 0x130000, 0, 0xc0, 0xff, 0xfffff000, 0, 0x1000)),
            ('msi-controller', b''),
            ('msi-ranges', cells(GIC, 0, 0x80, 1, 0x40)),
            ('brcm,msi-offset', cells(0)),
            ('phandle', cells(MIP)),
        ]),
        node('mmc@1000fff000', [
            ('compatible', text('brcm,bcm2712-sdhci')),
            ('reg', cells(0x10, 0x00fff000, 0, 0x260, 0x10, 0x00fff400, 0, 0x200)),
            ('interrupts', cells(0, 273, 4)),
        ]),
    ]),
    node('pcie@10000000', [
        ('compatible', text('pci-host-ecam-generic')),
        ('device_type', text('pci')),
        ('reg', cells(0x40, 0x10000000, 0, 0x10000000)),
        ('bus-range', cells(0, 0xff)),
        ('linux,pci-domain', cells(0)),
        ('#address-cells', cells(3)), ('#size-cells', cells(2)),
        ('#interrupt-cells', cells(1)),
        ('interrupt-map-mask', cells(0x1800, 0, 0, 7)),
        ('interrupt-map', cells(0x0000, 0, 0, 1, GIC, 0, 3, 4) + cells(0x0800, 0, 0, 1, GIC, 0, 4, 4) +
         cells(0x0800, 0, 0, 2, GIC, 0, 5, 4)),
        ('ranges', cells(0x01000000, 0, 0, 0, 0x3eff0000, 0, 0x10000) +
         cells(0x02000000, 0, 0x10000000, 0, 0x10000000, 0, 0x2eff0000) +
         cells(0x03000000, 0x80, 0, 0x80, 0, 0x80, 0)),
        ('dma-coherent', b''),
    ]),
    # A nexus whose interrupt-map names a parent with absurd #address-cells
    # and #interrupt-cells (their sum wraps 32 bits back to the entry's
    # start): resolving through it must fail, not loop forever.
    node('broken-parent', [
        ('#address-cells', cells(0xFFFFFFFF)),
        ('#interrupt-cells', cells(0xFFFFFFFF)),
        ('phandle', cells(BROKEN_PARENT)),
    ]),
    node('hostile-nexus', [
        ('#address-cells', cells(0)),
        ('#interrupt-cells', cells(1)),
        ('interrupt-map', cells(2, BROKEN_PARENT, 7, 8, 9, 10)),
        ('phandle', cells(HOSTILE_NEXUS)),
    ]),
    node('hostile-device', [
        ('interrupt-parent', cells(HOSTILE_NEXUS)),
        ('interrupts', cells(1)),
    ]),
])


def build(tree):
    structure = bytearray()
    names = bytearray()
    offsets = {}

    def name_offset(name):
        if name not in offsets:
            offsets[name] = len(names)
            names.extend(text(name))
        return offsets[name]

    def emit(entry):
        name, properties, children = entry
        structure.extend(cells(1))
        structure.extend(text(name))
        while len(structure) % 4:
            structure.append(0)
        for property_name, value in properties:
            structure.extend(cells(3, len(value), name_offset(property_name)))
            structure.extend(value)
            while len(structure) % 4:
                structure.append(0)
        for child in children:
            emit(child)
        structure.extend(cells(2))

    emit(tree)
    structure.extend(cells(9))
    reservations = struct.pack('>QQ', 0, 0x80000) + struct.pack('>QQ', 0, 0)
    header_size = 40
    reservation_offset = header_size
    structure_offset = reservation_offset + len(reservations)
    strings_offset = structure_offset + len(structure)
    total = strings_offset + len(names)
    header = struct.pack('>10I', 0xd00dfeed, total, structure_offset, strings_offset, reservation_offset,
                         17, 16, 0, len(names), len(structure))
    return header + reservations + bytes(structure) + bytes(names)


with open(sys.argv[1], 'wb') as output:
    output.write(build(TREE))
