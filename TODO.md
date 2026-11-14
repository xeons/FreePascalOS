# TODO

Roughly in the order they unblock each other. See `docs/Architecture.md` for
how the existing pieces fit together.

## Hardware discovery

- [x] Parse ACPI tables (RSDP from the loader → XSDT/RSDT → table lookup)
- [ ] Use the MADT (processor and I/O APIC list), HPET and FADT
- [ ] I/O APIC driver; route legacy IRQs onto the device vectors (0x30-0x3F)
- [x] Map MMIO with proper caching attributes (`Memory.DeviceMapping`)
- [x] PCI / PCI Express configuration space enumeration (ECAM from MCFG)
- [ ] Legacy configuration access (ports 0xCF8/0xCFC) for machines without MCFG
- [ ] MSI / MSI-X interrupts for PCI devices

## Multiprocessor support

- [ ] Per-processor data block (current thread, priority level, scheduler state)
- [ ] Start application processors (INIT/SIPI trampoline below 1 MiB)
- [ ] Per-processor GDT, TSS and interrupt stacks
- [ ] Per-processor run queues and load balancing
- [ ] Inter-processor interrupts: TLB shootdown, reschedule, panic halt
- [ ] Record the owning processor in the debug output lock

## Kernel core

- [ ] Timeouts on waits (`WaitForEvent` with a deadline)
- [x] Mutexes (owner tracking, recursion)
- [ ] Semaphores and reader/writer locks
- [ ] Wait on multiple objects
- [ ] Deferred work queue that runs at dispatch level (for device drivers)
- [ ] Priority boosting for threads woken from waits
- [ ] Stack back trace in the panic screen

## Memory management

- [ ] Reclaim the loader's boot data pages once the kernel no longer needs them
- [ ] Unmap the kernel image's padding and map .text/.rodata with no-execute
      where appropriate (verify W^X across the whole kernel)
- [ ] Contiguous physical allocations (for DMA buffers)
- [ ] Per-process address spaces (copy the kernel half of the top level table)
- [ ] Page fault handling for demand-zero and later demand-paged memory

## Objects and processes

- [ ] Hierarchical object namespace (directories, e.g. `\Device\Keyboard`)
- [ ] Per-process handle tables
- [ ] Process creation and teardown
- [ ] Waiting on thread and process objects (exit notification)

## I/O

- [ ] I/O manager: driver objects, device objects, request packets
- [ ] PS/2 keyboard driver (first interrupt-driven device)
- [ ] Interactive kernel debug console (simple command shell: ls, cat, ...)
- [ ] Shadow buffer for the framebuffer console so scrolling never reads
      video memory

## Storage

- [x] Block device layer and partition devices
- [x] GPT and MBR partition tables (with logical partitions)
- [x] AHCI SATA driver (polled, one command slot)
- [ ] AHCI: interrupts, all 32 command slots, NCQ, direct DMA without bounce buffer
- [ ] ATAPI (optical drives) on AHCI
- [ ] NVMe driver
- [ ] virtio-blk driver (fast QEMU disks)
- [ ] USB mass storage (needs an xHCI driver first)
- [x] Block cache (read)
- [ ] Block cache: write-back, per-device locks, read-ahead

## File systems

- [x] VFS: volumes, path resolution, symbolic links, open files, directory listing
- [x] FAT12 / FAT16 / FAT32 with long file names (read)
- [x] exFAT (read)
- [x] ext2 / ext3 / ext4 (read): block maps, extents, 64-bit, flex_bg, META_BG, htree
- [ ] Write support: FAT family
- [ ] Write support: exFAT
- [ ] Write support: ext2, then ext3/ext4 with journaling
- [ ] ext3/ext4 journal replay on mount
- [ ] ext4: inline data larger than the inode, encrypted and case-folded directories,
      metadata checksum verification
- [ ] exFAT / FAT: verify and use the backup boot sector when the main one is damaged
- [ ] Hierarchical mount points (mount a volume at any directory) and a boot volume alias
- [ ] File timestamps beyond modification time; ext4 nanosecond timestamps

## User mode

- [ ] Ring 3 transition and system call entry (`syscall`/`sysret`)
- [ ] System call table and argument validation
- [ ] Executable loader for user programs (ELF)
- [ ] First user mode program

## ARM64 port

- [ ] Toolchain: AArch64 Free Pascal cross compiler (and a way to produce
      AArch64 PE images for the loader: FPC trunk or binutils `objcopy`)
- [ ] `boot/uefi/arm64`: page tables and hand-off
- [ ] `kernel/core/arm64`: exception vectors, context switch, priority levels
      (GIC priority mask)
- [ ] `kernel/memory/arm64`: translation tables
- [ ] `hal/arm64`: GIC, generic timer, PL011 UART
- [ ] Run under `qemu-system-aarch64 -machine virt` with AAVMF firmware

## Tooling

- [x] `make test`: boot headless in QEMU, fail on panic or missing self-test results
- [x] Test disk with one partition per supported file system
- [ ] Continuous integration running `make test`
- [ ] GDB helper script (load symbols, break on panic)
