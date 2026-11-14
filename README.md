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
- An object manager with reference counting and named objects, plus process
  and thread objects.
- Debug output to the serial port and to a text console drawn on the
  framebuffer.
- Kernel self tests that run on every boot.

## Requirements

- Free Pascal 3.2.2 (`fpc`, x86-64 compiler)
- GNU binutils (`ld`, `objcopy`, `objdump`)
- QEMU (`qemu-system-x86_64`) and OVMF UEFI firmware, for running it
- `sfdisk` and mtools, only for `make image`

On Arch based systems: `pacman -S fpc qemu-system-x86 edk2-ovmf mtools`.

## Building and running

```
make            # build build/amd64/esp (loader + kernel)
make run        # boot in QEMU; the kernel log appears on the terminal
make debug      # boot in QEMU and wait for GDB on localhost:1234
make image      # build build/amd64/FreePascalOS.img (GPT, one EFI partition)
make clean
```

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
  core/             Priority levels, spin locks, interrupts, scheduler,
                    clock, events, panic
  core/amd64/       Descriptor tables, interrupt stubs, context switch, CPU
  memory/           Physical pages, virtual ranges, heap, stacks
  memory/amd64/     Page tables
  objects/          Object manager
  processes/        Process and thread objects
  runtime/          Linked lists, atomics
  debug/            Debug log and framebuffer console (+ font)
  link/             Kernel linker scripts
tools/PsfToPascal/  Converts a PSF console font into a Pascal include file
scripts/            QEMU launcher and disk image builder
docs/               Architecture notes
```

## Licenses of included material

The console font in `kernel/debug/Debug.ConsoleFont.inc` is generated from
Terminus (ter-116n), distributed under the SIL Open Font License 1.1; the
license is in `kernel/debug/Debug.ConsoleFont.LICENSE`.
