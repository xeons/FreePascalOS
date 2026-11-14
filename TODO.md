# TODO

Roughly in the order they unblock each other. See `docs/Architecture.md` for
how the existing pieces fit together.

## Hardware discovery

- [ ] Parse ACPI tables (RSDP from the loader → XSDT → MADT, HPET, FADT)
- [ ] I/O APIC driver; route legacy IRQs onto the device vectors (0x30-0x3F)
- [ ] Map MMIO with proper caching attributes instead of relying on the
      physical memory window's write-back mapping
- [ ] PCI / PCI Express configuration space enumeration (ECAM from MCFG)

## Multiprocessor support

- [ ] Per-processor data block (current thread, priority level, scheduler state)
- [ ] Start application processors (INIT/SIPI trampoline below 1 MiB)
- [ ] Per-processor GDT, TSS and interrupt stacks
- [ ] Per-processor run queues and load balancing
- [ ] Inter-processor interrupts: TLB shootdown, reschedule, panic halt
- [ ] Record the owning processor in the debug output lock

## Kernel core

- [ ] Timeouts on waits (`WaitForEvent` with a deadline)
- [ ] Mutexes (owner tracking, recursion) and semaphores
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
- [ ] Interactive kernel debug console (simple command shell)
- [ ] Shadow buffer for the framebuffer console so scrolling never reads
      video memory
- [ ] Storage: AHCI and/or NVMe driver
- [ ] FAT32 file system (read the EFI partition)

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

- [ ] `make test`: boot headless in QEMU, fail on panic or missing self-test results
- [ ] Continuous integration running `make test`
- [ ] GDB helper script (load symbols, break on panic)
