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
- [x] Per-process address spaces (copy the kernel half of the top level table)
- [x] Page fault handling for demand-zero memory
- [ ] Demand paging from files (map executables instead of copying them in)
- [ ] Copy-on-write sharing of library pages between processes

## Objects and processes

- [ ] Hierarchical object namespace (directories, e.g. `\Device\Keyboard`)
- [x] Per-process handle tables
- [x] Process creation and teardown
- [x] Waiting on process objects (exit notification)
- [ ] Multiple threads per user process (thread creation call, thread local storage)
- [ ] Signals or another way to interrupt a running program (Ctrl-C)
- [ ] Users, groups and permission checks

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
- [x] Block cache (read, write-through)
- [ ] Block cache: write-back with flush, per-device locks, read-ahead

## File systems

- [x] VFS: volumes, path resolution, symbolic links, open files, directory listing
- [x] FAT12 / FAT16 / FAT32 with long file names (read)
- [x] exFAT (read)
- [x] ext2 / ext3 / ext4 (read): block maps, extents, 64-bit, flex_bg, META_BG, htree
- [x] Write support: FAT family (create, write, truncate, remove, rename, mkdir)
- [x] Write support: exFAT
- [x] Write support: ext2/ext3/ext4 with metadata checksums (unjournaled, journal kept clean)
- [x] Shared node cache, per-volume locking, open flags (create, exclusive, truncate, append)
- [x] Host side verification of written volumes in `make test`
- [ ] ext3/ext4: write through the journal (crash safety), and journal replay on mount
- [ ] ext4: modify htree indexed directories (currently read-only)
- [ ] ext4: extent trees deeper than one index level when writing
- [ ] ext4: allocate from block groups still marked uninitialized
- [ ] ext4: bigalloc, quota, encryption and case folding (currently force read-only)
- [ ] Hard links (ext) and replacing an existing file on rename
- [ ] Delete-on-last-close for files removed while open (currently refused)
- [ ] ext4: inline data larger than the inode, encrypted and case-folded directories,
      metadata checksum verification
- [ ] exFAT / FAT: verify and use the backup boot sector when the main one is damaged
- [ ] Hierarchical mount points (mount a volume at any directory) and a boot volume alias
- [ ] File timestamps beyond modification time; ext4 nanosecond timestamps
- [ ] Time zones (the real-time clock is assumed to hold UTC)

## User mode

- [x] Ring 3 transition and system call entry (`syscall`, return with `iretq`)
- [x] System call table and argument validation
- [x] ELF loader for position independent programs and shared libraries
      (DT_NEEDED, eager binding, run time LoadLibrary / FindSymbol)
- [x] First user mode program (`init=`, default `/bin/sh`)
- [x] Pipes, console, /dev/null, handle duplication
- [x] User System unit and startup code; libsystem.so; libcoreutils.so
- [x] Shell: pipes, redirections, && ||, if/while/until/for, variables,
      $( ), $(( )), globbing, quoting, scripts, builtins
- [x] Core utilities: basename cat cp cut date df dirname echo env expr false
      fold head ln ls mkdir mv nl paste printf pwd readlink rm rmdir seq sleep
      sort stat sync tac tail tee test [ touch tr true truncate uname uniq wc yes
- [x] `coretest`: user mode tests run by `make test`
- [ ] Lazy binding (PLT resolution on first call) and symbol versioning
- [ ] Thread local storage (PT_TLS) so FPC threadvars work in user mode
- [ ] Unit initialization sections in libraries (DT_INIT / DT_INIT_ARRAY)
- [ ] Shell: case, functions, here documents, job control, history and line editing
- [ ] More utilities: grep, find, xargs, od, md5sum/sha256sum, du, chmod, id, comm, split
- [ ] touch: a system call to set file times; df: free space per volume
- [ ] Hard links in ln (the ext driver supports them internally)
- [ ] Interrupt driven console input (keyboard and serial) instead of polling

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
- [x] System disk (ext4, FPOSROOT) built from the userland without root rights
- [ ] Continuous integration running `make test`
- [ ] GDB helper script (load symbols, break on panic)
