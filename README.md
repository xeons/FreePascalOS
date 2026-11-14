# FreePascalOS

A small, modern operating system written in Free Pascal (with inline assembly
where the hardware requires it), for 64-bit UEFI machines. The kernel is
layered in the style of Windows NT: a hardware abstraction layer at the
bottom, a kernel core for scheduling and synchronization, and executive-style
subsystems (memory, objects, processes) on top.

The first target is x86-64. The code is arranged so that a 64-bit ARM
(AArch64) port only has to supply its own versions of the architecture
specific units; see [docs/Architecture.md](docs/Architecture.md).

## What works today

- A UEFI loader that finds the framebuffer and ACPI tables, loads the kernel
  ELF image, builds the initial page tables, exits boot services and jumps to
  the kernel.
- A higher-half kernel with its own GDT, TSS (with separate stacks for double
  faults, NMIs and machine checks) and IDT, plus a register dump on any fatal
  exception.
- Interrupt priority levels (passive, dispatch, device, clock, high) mapped
  onto the local APIC task priority register, and spin locks built on them.
- A local APIC HAL with a calibrated periodic clock and self interrupts for
  deferred scheduling.
- Memory management: a page frame database, four level page tables, a kernel
  virtual range allocator, a size class heap, and guard-paged kernel stacks.
- A preemptive, priority based scheduler with time slices, sleeping, events
  and thread exit and cleanup.
- Mutexes (sleeping, recursive locks) alongside spin locks and events.
- An object manager with reference counting and named objects, plus process
  and thread objects.
- Device discovery through ACPI tables and PCI Express (ECAM) enumeration.
- An AHCI SATA driver, block devices, GPT and MBR (including logical)
  partitions, and a block cache.
- A virtual file system with path lookup, symbolic links, a shared node
  cache, open files, directory listings, and create / write / truncate /
  remove / rename, with read-write drivers for **FAT12, FAT16, FAT32 (with
  long file names), exFAT, ext2, ext3 and ext4** (extents, 64-bit, flex_bg,
  metadata checksums, htree directories for reading, sparse files, fast and
  slow symbolic links).
- A real-time clock driver, so files get correct timestamps.
- Debug output to the serial port and to a text console drawn on the
  framebuffer.
- Kernel self tests that run on every boot, including file system read and
  write tests against a disk image with one partition of every supported
  format. After a test run, `make test` checks every written partition with
  the format's own tools (fsck.fat, fsck.exfat, e2fsck, mtools, debugfs).

## Requirements

- Free Pascal 3.2.2 (`fpc`, x86-64 compiler)
- GNU binutils (`ld`, `objcopy`, `objdump`)
- QEMU (`qemu-system-x86_64`) and OVMF UEFI firmware, for running it
- `sfdisk` and mtools, for `make image`
- dosfstools, exfatprogs, e2fsprogs and Python 3, for the test disk used by
  `make run` and `make test`

On Arch based systems:
`pacman -S fpc qemu-system-x86 edk2-ovmf mtools dosfstools exfatprogs e2fsprogs python`.

## Building and running

```
make            # build build/amd64/esp (loader + kernel)
make run        # boot in QEMU with the test disk; the kernel log appears on the terminal
make debug      # same, but wait for GDB on localhost:1234
make test       # boot headless, run every self test, print TEST PASSED or TEST FAILED
make image      # build build/amd64/FreePascalOS.img (GPT, one EFI partition)
make clean
```

Mounted volumes appear under the root as `/disk1p1`, `/disk1p2`, ...

Kernel options can be put in `\FreePascalOS\options.txt` on the boot volume
(see `kernel/core/Kernel.Options.pas`).

The disk image can be written to a USB stick to boot real hardware, with
Secure Boot disabled. Writing it erases the stick:

```
sudo dd if=build/amd64/FreePascalOS.img of=/dev/sdX bs=1M conv=fsync
```

## Source layout

```
boot/uefi/          UEFI loader (built as a PE32+ EFI application)
  amd64/            Page table setup and kernel hand-off for x86-64
shared/             Code and definitions used by both loader and kernel
  amd64/            Virtual address layout for x86-64
rtl/                Minimal freestanding System unit for the compiler
hal/amd64/          Hardware abstraction layer: APIC, PIT, PIC, serial, ports
kernel/
  Kernel.Startup    Entry point and phase 0 / phase 1 initialization
  Kernel.SelfTest   Boot-time self tests
  Kernel.FileSystemTest  File system self test
  core/             Priority levels, spin locks, mutexes, interrupts,
                    scheduler, clock, events, options, panic
  core/amd64/       Descriptor tables, interrupt stubs, context switch, CPU
  memory/           Physical pages, virtual ranges, heap, stacks
  memory/amd64/     Page tables
  objects/          Object manager
  processes/        Process and thread objects
  firmware/         ACPI tables
  io/               I/O startup, PCI, block devices, partitions, block cache
  drivers/storage/  AHCI SATA driver
  filesystems/      VFS (types, volumes, open files) and the FAT, exFAT and
                    ext2/3/4 drivers
  runtime/          Linked lists, atomics, checksums, Unicode, time
  debug/            Debug log and framebuffer console (+ font)
  link/             Kernel linker scripts
tools/PsfToPascal/  Converts a PSF console font into a Pascal include file
scripts/            QEMU launcher, test runner, disk image builders
docs/               Architecture notes
```

## Licenses of included material

The console font in `kernel/debug/Debug.ConsoleFont.inc` is generated from
Terminus (ter-116n), distributed under the SIL Open Font License 1.1; the
license is in `kernel/debug/Debug.ConsoleFont.LICENSE`.
