# FreePascalOS architecture

## Layers

The kernel follows the layering of Windows NT, using plain descriptive names
instead of NT's terminology.

```
+-----------------------------------------------------------+
|  User mode: sh, coreutils -> libcoreutils, libsystem       |
+=================== system calls (syscall) ================+
|  Processes (processes, threads, address spaces, handles,   |
|             image loader, system calls)                    |
|  I/O       (block devices, file systems, pipes, console)   |
|  Objects   (object manager, reference counting, names)     |
|  Memory    (page frames, page tables, heap, stacks)        |   "executive"
+-----------------------------------------------------------+
|  Kernel core                                               |
|  priority levels, spin locks, interrupt dispatch,          |
|  scheduler, clock, events, panic                           |
|  core/<arch>: descriptor tables, stubs, context switch     |
+-----------------------------------------------------------+
|  HAL (hal/<arch>): interrupt controller, timers, serial    |
+-----------------------------------------------------------+
|  Hardware                                                  |
+-----------------------------------------------------------+
```

Unit names carry their layer as a prefix: `Hal.*`, `Kernel.*`, `Memory.*`,
`Objects.*`, `Processes.*`, `Runtime.*` and `Debug.*`. Architecture specific
units have `Arch` in their name (`Kernel.Arch.*`, `Memory.Arch.*`) or live in
`hal/<arch>`.

## Architecture independence

Every architecture provides units with the **same names and interfaces** in
its own directory (`kernel/core/amd64`, `kernel/memory/amd64`, `hal/amd64`,
`shared/amd64`, `boot/uefi/amd64`, and so on). The Makefile puts only the
selected architecture's directories on the unit search path, so the rest of
the kernel never contains `{$ifdef CPU...}` blocks.

An AArch64 port would add, among others:

| Unit                          | x86-64 implementation           | AArch64 equivalent            |
|-------------------------------|---------------------------------|-------------------------------|
| `Kernel.Arch.Cpu`             | cli/sti, CR registers, MSRs     | DAIF, system registers        |
| `Kernel.Arch.PriorityLevel`   | CR8 task priority register      | GIC priority mask register    |
| `Kernel.Arch.ContextSwitch`   | saves RBX, RBP, R12-R15, RFLAGS | saves X19-X30, SP             |
| `Kernel.Arch.TrapFrame` etc.  | IDT, interrupt stubs, TSS       | exception vector table        |
| `Memory.Arch.PageTables`      | 4-level x86-64 paging           | 4-level AArch64 translation   |
| `Hal.Platform`                | local APIC, PIT                 | GIC, generic timer            |
| `Hal.SerialPort`              | 16550 UART                      | PL011 UART                    |

Building an AArch64 UEFI loader also needs a toolchain that can produce
AArch64 PE images (Free Pascal 3.2.2 cannot; the trunk compiler or binutils
`objcopy` conversion can).

## Toolchain approach

Free Pascal has no target for "UEFI application" or "freestanding kernel" in
release 3.2.2, so two ordinary targets are borrowed:

- The **loader** is compiled for `win64`. That target produces PE32+ images
  and uses the Microsoft x64 calling convention, which is exactly what UEFI
  requires. `objcopy --subsystem efi-app` then marks the image as an EFI
  application.
- The **kernel** is compiled for `linux` (System V calling convention, ELF
  objects) and linked by GNU `ld` with `kernel/link/amd64.ld`.

Both are built against `rtl/system.pas`, a minimal System unit with only what
the compiler insists on. Nothing in the kernel uses the stock runtime library.
Unit initialization sections are never used; every subsystem has an explicit
`Initialize...` routine called in a defined order from `Kernel.Startup`.

The kernel does not save floating point or SIMD registers, so `make` fails if
the compiler ever emits SSE instructions in kernel code (`check-kernel`).

## Boot sequence

1. **Firmware** loads `\EFI\BOOT\BOOTX64.EFI` (the loader).
2. **Loader** (`boot/uefi/OsLoader.pas`):
   - records the GOP framebuffer and the ACPI RSDP,
   - reads `\FreePascalOS\kernel.elf` and copies its segments into one
     physically contiguous block,
   - allocates the boot information record and a 64 KiB boot stack,
   - builds page tables: the physical memory window, an identity mapping of
     the same range, and the kernel image (4 KiB pages, per-segment
     permissions),
   - captures the memory map into the boot information record and exits
     boot services,
   - loads CR3, switches to the boot stack and jumps to the kernel.
3. **Kernel phase 0** (`KernelEntryPoint`, interrupts disabled): debug
   output, processor tables, memory management, object and process managers,
   HAL, scheduler. The boot code becomes the idle thread.
4. **Kernel phase 1** (a system thread): runs the self tests, then exits.

The loader tags its own allocations with OS-reserved UEFI memory types
(`0x80000001`-`0x80000003`), so the memory map tells the kernel exactly which
pages hold the kernel image, boot data and page tables.

## Virtual address space (x86-64)

```
0000_0000_0000_0000 - 0000_7FFF_FFFF_FFFF   user space (one per process)
FFFF_8000_0000_0000 - FFFF_BFFF_FFFF_FFFF   physical memory window
FFFF_C000_0000_0000 - FFFF_C0FF_FFFF_FFFF   kernel dynamic region (heap, stacks)
FFFF_FFFF_8000_0000 - FFFF_FFFF_FFFF_FFFF   kernel image
```

The physical memory window maps all RAM (and at least the first 4 GiB, for
devices) at a fixed offset with 2 MiB pages. Page tables, page frames and
device registers are reached through it with `PhysicalToVirtual`.

## Interrupt priority levels

| Level | Name                  | Meaning                                      |
|-------|-----------------------|----------------------------------------------|
| 0     | `PassiveLevel`        | normal thread execution; may block           |
| 2     | `DispatchLevel`       | scheduler; no thread switches; may not block |
| 3-12  | `DeviceLevel*`        | device interrupts                            |
| 13    | `ClockLevel`          | periodic clock                               |
| 14    | `InterProcessorLevel` | inter-processor interrupts                   |
| 15    | `HighLevel`           | everything masked (panic, debug output)      |

On x86-64 the level is the value of CR8, and each interrupt's vector is
chosen so its APIC priority class (vector div 16) equals its level (see
`Hal.InterruptVectors`). Interrupt handlers run with interrupts enabled at
their own level, so higher-priority interrupts nest naturally.

Rules that follow from this:

- Mutexes may only be used at `PassiveLevel`; they put the thread to
  sleep instead of spinning.
- Spin locks are acquired at `DispatchLevel` or above. A lock that an
  interrupt handler takes must be acquired at that handler's level.
- Raising to a lower level, or acquiring a dispatch-level lock while at a
  higher level, is a fatal error (`RaisePriorityLevel` checks).
- Code holding the debug output lock (`DebugBeginMessage`) runs at
  `HighLevel` and must not take other locks.

## Scheduling

- 32 priorities, one run queue each; the idle thread (priority 0) runs only
  when nothing else is ready and is never queued.
- Time slices of `QuantumTicks` clock ticks (100 Hz clock) rotate threads of
  equal priority.
- The clock interrupt never switches threads itself. It requests the dispatch
  software interrupt (a self-IPI on the dispatch vector), which the APIC
  delivers as soon as the processor drops below `DispatchLevel`. The same
  mechanism handles a thread becoming ready at a higher priority.
- The dispatcher lock protects all scheduler state and wait queues. It is
  held across a context switch and released by the thread that runs next.
- Exited threads are put on a list and cleaned up by the idle thread
  (stack freed, object dereferenced).
- Each clock tick is charged to the running thread (`RunTicks`), which is
  where a process's CPU time comes from.
- Every 5 seconds the clock tick samples the number of threads running or
  ready and folds it into three exponentially decayed averages (1, 5 and
  15 minutes, fixed point with 11 fraction bits, as in Unix load
  averages). The run queues keep a count of their threads for this.
- User threads run at priority 8 for nice 0; every 4 nice steps move one
  priority (nice -20 is 13, nice 19 is 4). `SetThreadPriority` moves a
  ready thread to the run queue of its new priority.
- Floating point and SSE registers belong to threads: the switch saves the
  old thread's (FXSAVE) and loads the new one's (FXRSTOR). The kernel
  itself uses no such registers (the build checks), so interrupts and
  system calls need not save them.

## Several processors

- **Finding and starting them.** The MADT lists every processor by local
  APIC id. In phase 1 the boot processor gives each one a block
  (`Kernel.Processors`), an idle thread with a kernel stack, and stacks for
  double faults, NMIs and machine checks, then wakes it with INIT and two
  STARTUP interrupts (`Kernel.SecondaryProcessors`). It starts in real mode
  in a page below 1 MiB (the physical allocator keeps track of which low
  pages were free RAM and hands them out with `ClaimLowPhysicalPages`),
  running `ProcessorTrampoline.s`: protected mode, the boot processor's
  CR4, a small page table that maps that page at its own address next to
  the kernel half, EFER and CR0 (paging on), long mode, and a jump to
  `SecondaryProcessorEntry` on the idle stack. There it loads the kernel's
  page table, its own GDT and TSS, its block, the shared IDT, the boot
  processor's PAT, its system call registers and its local APIC and clock,
  and becomes its idle thread. `processors=N` limits how many start.
- **Per-processor data.** Each block holds the running thread, the idle
  thread, the scheduler's per-processor state, the loaded address space,
  the descriptor tables and the kernel stack for system calls. Kernel code
  reaches its own block through the GS base; user code may change GS, so
  every entry from user mode and every return to it does SWAPGS (the
  interrupt entry checks the saved code selector; the system call entry
  always swaps). The running thread is read with one GS-relative load, so
  `CurrentThread` cannot be torn by a move to another processor; anything
  else in a block is only used at DispatchLevel or above.
- **Scheduling.** The run queues and the dispatcher lock are shared. Each
  processor has its own clock interrupt for its time slices (only the boot
  processor's advances the tick count). When a thread becomes ready, an
  idle processor (or the one running the least important thread, if that
  is less important) is sent its dispatch interrupt as an IPI. The handoff
  of the dispatcher lock across a switch also guarantees that a thread
  which just switched away is not picked up elsewhere before its registers
  are saved, and that a terminated thread's stack is not freed too early.
- **TLB shootdown.** After removing a mapping, the page table code
  invalidates it locally and, outside its lock, calls
  `InvalidateRemoteTranslations` (`Kernel.InterProcessor`): every other
  processor for a kernel address, only those with that address space
  loaded for a user address. Each processor publishes the address space
  it loads before switching CR3, so a processor either receives the
  request or only ever sees the changed table. The sender waits at
  DispatchLevel with interrupts on for all acknowledgements; page faults
  are therefore resolved with interrupts on, so a processor spinning on a
  lock in the fault path can still answer. Ranges are unmapped in runs of
  up to 32 pages with one request per run; the physical pages are freed
  only after the run's request was answered.
- **Panic.** The panicking processor stops the others with an NMI before
  printing; the debug output lock records its owner's processor number,
  so nested messages on one processor and messages from different
  processors are told apart.
- **Devices** still interrupt only the boot processor.

## I/O and storage

Started from phase 1 by `Io.Startup`, in dependency order:

1. **ACPI** (`Firmware.Acpi`) finds the system description tables through
   the RSDP the loader passed on.
2. **PCI** (`Io.Pci`) scans every bus in the MCFG table's ECAM windows.
   Buses with devices stay mapped (uncached, via `Memory.DeviceMapping`).
3. **Storage drivers** (`Drivers.Ahci`) register whole-disk block devices
   named `disk0`, `disk1`, ... Each disk has a device object of the `ahci`
   driver, without a name; the block device sends it read and write
   requests. The AHCI driver uses one command slot per port, moves data
   through a 64 KiB bounce buffer and completes requests from its MSI
   interrupt (polling while disks are identified, or without MSI). Every
   command has a 5 second timer (`Kernel.Timers`); a command that fails or
   times out fails its request with `ErrorIo`, and the port is reset as
   the AHCI specification describes (stop, clear errors, COMRESET if the
   device is still busy, start). The tests attach a disk through QEMU's
   blkdebug that fails reads of one sector.
4. **Partitions** (`Io.Partitions`) are read from GPT (with CRC checks) or
   MBR (including logical partitions) and registered as `disk1p2` etc. A
   partition device forwards requests to its disk with an offset.
5. **Device objects** for every disk and partition (`Drivers.DiskDevices`,
   see below).
6. **File systems** are mounted on every partition (and on disks without a
   partition table) by the first driver whose probe accepts it.

Block devices are objects of type `BlockDevice`. All file system metadata
and data reads go through `Io.BlockCache`, which caches 4 KiB lines per
device, evicts least recently used first, and lets callers read any byte
range regardless of the device's block size.

## The I/O manager: drivers, devices, requests

`Io.Manager` keeps driver objects and device objects:

- A **driver** has a name and a dispatch table, one routine per request
  kind: open, close, read, write, control. A missing open or close means
  nothing to do; any other missing routine makes that request
  unsupported.
- A **device** belongs to a driver and has a name, a kind (character or
  block), an owner, a group and permission bits like a file, a size (block
  devices), and an extension: memory for the driver's state of that device.
  It also says what programs are told a handle to it is (`HandleKindConsole`
  for the console, `HandleKindNullDevice` for `null`, otherwise
  `HandleKindDevice`).
- Opening a device makes a **device file** object: the device, the position
  (block devices) and a context pointer for the driver's state of that
  open. Closing its last handle sends the driver a close request.
- A device created without a name is not listed under `/dev`; only the
  kernel reaches it (the AHCI disks below the block devices). A device
  can be **exclusive**: one open at a time (the input devices, which the
  console holds open).
- Every operation is a **request** (`TIoRequest`: the kind, the device and
  device file, a kernel buffer, length and offset, or a control code and
  argument), handed to the driver by `CallDriver`. The driver either
  finishes it and returns its status (an Abi error code, with the bytes
  moved or the control result in `Information`), or returns
  `StatusPending`, keeps it, and calls `CompleteRequest` later - usually
  from a deferred call after its device interrupted. Every request
  completes exactly once: completing runs the request's completion
  routine, if it has one, or signals its completion event.
  `CallDriverAndWait` sends a request and waits for it.
- A driver holding requests until something happens keeps them in a
  **request queue** (`QueueRequest`, `TakeQueuedRequest`). Programs wait
  for their requests alertably (`Io.DeviceFiles`); when the thread is
  alerted (ended, or stopped by job control), `CancelRequest` takes its
  request out of the queue and completes it with `ErrorInterrupted`,
  and the call is restarted after a stop. Drivers that wait themselves
  (the console) wait alertably too. Buffers are always kernel memory
  (system calls copy through their transfer buffer), and devices are
  never removed.

`Kernel.IoSelfTest` checks the asynchronous paths on every boot with a
test driver that holds its reads: completion from a deferred call,
completion routines, and cancelling the request of an alerted thread.

The drivers so far:

| Driver | Devices |
|---|---|
| `memory` (`Drivers.MemoryDevices`) | `null`, `zero`, `full`, `random`, `urandom` (RDRAND, or a TSC-seeded xorshift without it), all `rw-rw-rw-` |
| `console` (`Drivers.ConsoleDevice`) | `console` and `tty`: reads and writes go to `Io.Console`; control requests get and set the modes, the size and the foreground group and take a pending Ctrl-C |
| `disk` (`Drivers.DiskDevices`) | one block device per disk and partition, `rw-------` for root; any offset and length (through a one-block buffer, past the write-through cache); writing to a device that holds a mounted volume, or to a disk with a mounted partition, is refused |
| `ps2keyboard` (`Drivers.Ps2Keyboard`) | `keyboard`, exclusive, `rw-------`: the characters typed (`Io.InputDevice`) |
| `serial` (`Drivers.SerialDevice`) | `serial0`, exclusive, `rw-------`: the characters received on COM1 |
| `ahci` (`Drivers.AhciRequests`) | one unnamed device per SATA disk, asynchronous |

Programs reach every device as `/dev/<name>`, whatever their root
directory: `Processes.FileCalls` recognizes those paths (and `/dev`
itself, which lists the devices), checks the permission bits on open and
sends reads, writes, seeks (block devices) and control requests to the
device. The first program's standard handles are opened on `console`.

## Device interrupts

The legacy 8259 PICs are masked; device interrupts go through the I/O
APICs listed in the ACPI MADT (Firmware.Madt, Hal.IoApic). A driver asks
`ConnectIsaInterrupt` (Io.InterruptRouting) for its IRQ: the MADT's
interrupt source overrides give the real input, polarity and trigger
mode, and the driver gets one of the device vectors 0x30-0x3F. Its handler
runs at device level, where the dispatcher lock cannot be taken, so a
handler that needs to wake a thread queues a deferred call
(Kernel.DeferredCalls); queued calls run at dispatch level from the
dispatch interrupt, before the scheduler picks the next thread.

A **timer** (Kernel.Timers) queues a deferred call once a delay has
passed; the boot processor's clock interrupt expires timers. Drivers use
them to notice what does not happen in time (a disk command that never
completes). Cancelling cannot take back a call that is already queued,
so the routine checks whether its reason still holds.

PCI devices with the MSI capability skip the I/O APIC:
`ConnectPciMessageInterrupt` (Io.PciMessageInterrupts) takes a vector
(`ConnectMessageInterrupt`), programs the device's message address (the
boot processor's local APIC) and data (the vector), and turns its legacy
interrupt line off. The legacy PCI lines could only be routed with the
ACPI namespace, which the kernel does not interpret.

### Ctrl-C

Processes belong to process groups (inherited, or a new group led by the
new process). The console has a foreground group. When the console's
interrupt key mode is on (the default; `stty -isig` turns it off), Ctrl-C
does not reach the input buffer: a deferred call wakes the
`console-interrupt` system thread, which ends every process of the
foreground group with exit status 130, except processes that asked to
ignore it. If it ended none (an interactive shell waiting at its prompt
is the foreground), Ctrl-C is passed to the reader as a character, and
the shell's line editor clears the line. The interactive shell runs each
foreground pipeline in a new group and makes it the foreground group
while it waits. While the shell itself is busy (a loop made only of
builtins) nobody reads the character; the console also remembers that an
interrupt is pending, and the shell asks for it between commands with
the console control request `ControlTakePendingInterrupt`, which answers
once per key press and removes the Ctrl-C from the input.

### Job control

Ctrl-Z goes the same way as Ctrl-C and stops the foreground group
(sparing the same processes). Stopping works like ending a program
(Processes.Stopping): `StopProcesses` marks the process and alerts its
threads, and each user thread waits on the process's continue event at
its next safe point (the same points as for termination). A stopped
thread clears its alert first (`ClearCurrentThreadAlert`), so its wait
blocks; a request to end the process sets its flag before alerting, so
it still gets through. When the last active thread has stopped the
process counts as stopped and `WaitForProcessChange` reports it once
(`WaitStatusStopped`); `ContinueProcesses` signals the continue event.
Targets are a process id, a process group (negated) or the caller's own
group.

A system call cut short by the stop's alert returns ErrorInterrupted;
the dispatcher then waits at the safe point and runs the call again once
the process is continued, so programs never see the stop (a timed wait
starts its timeout again). Console and pipe transfers therefore report an
alert as "interrupted", not as end of file or a broken pipe. A process
outside the console's foreground group that reads the console stops its
own group instead (like SIGTTIN); the restarted read succeeds once a
shell has made it the foreground.

The shell keeps a job table (`Shell.Jobs`): every background pipeline,
and every foreground pipeline stopped by Ctrl-Z, with the process handles
of its programs. `jobs`, `fg`, `bg`, `wait` and `kill` with `%N` are in
`Shell.JobBuiltins`; `fg` hands the console's foreground group to the job
while it waits. Finished jobs are reported before the next prompt, and
stopped jobs are ended (status 129) when an interactive shell exits.
`ps` shows stopped processes as `T`.

The keyboard (Drivers.Ps2Keyboard, IRQ 1) and the serial port
(Drivers.SerialDevice, IRQ 4) are input devices (Io.InputDevice): their
interrupt handlers put characters in a ring, and a deferred call hands
them to waiting read requests. The console opens both devices and always
keeps one read outstanding on each (Io.ConsoleInput); the completion
routine passes the characters to the console's input ring
(DeliverConsoleInput) and a deferred call sends the next read. Without an
I/O APIC there is no serial device and the console polls the serial
port. The keyboard's characters come from a layout
(Drivers.KeyboardLayouts: us, uk, de or fr, chosen with the kernel option
`keymap=`), written as the keys that differ from US, with a third level
on AltGr; characters beyond ASCII are sent in UTF-8 (the framebuffer font
only has ASCII). The driver sets the Caps, Num and Scroll Lock lights
(keyboard command 0xED, answered by interrupts); with Num Lock off the
keypad sends cursor and editing keys.

## File systems

The VFS (`kernel/filesystems`) has three parts:

- `FileSystem.Types` defines the driver contract: a `TFileSystemDriver`
  record of routines (probe, mount, lookup, read directory, read file, read
  symbolic link, release node) and the node, volume and status types.
- `FileSystem.Volumes` keeps the driver list and the mounted volumes.
- `FileSystem.Files` resolves paths and implements open files (objects of
  type `File`).

Nodes are shared: every node a driver hands out goes through a node cache
(keyed by a per-volume node number), so all opens of one file see the same
size and each other's writes, and a file that is open cannot be removed.
Every driver call holds the volume's lock.

The namespace is a single tree. The root lists the mounted volumes, each a
directory named after its block device: `/disk1p7/docs/readme.txt`. Paths
are absolute; `.` and `..` are resolved textually first. Symbolic links are
followed up to 8 deep, and an absolute link target is resolved from the
root of the link's own volume.

Drivers (each split into Structures / Volume / Write units plus a main
unit; ext also has Blocks and Directories):

| Driver           | Formats               | Notes                                                  |
|------------------|-----------------------|--------------------------------------------------------|
| `FileSystem.Fat`   | FAT12, FAT16, FAT32 | VFAT long names with generated `~N` short names, NT lower-case flags, all FAT copies kept in sync, FSInfo free count |
| `FileSystem.ExFat` | exFAT               | contiguous ("no FAT chain") and chained files, allocation bitmap, entry set checksums and name hashes, up-case table lookup, volume dirty flag |
| `FileSystem.Ext`   | ext2, ext3, ext4    | block maps and extent trees (writing up to depth 1), 64-bit, flex_bg, META_BG, all metadata checksums, fast and slow symlinks, holes |

Writes are write-through (the block cache writes every change to disk
immediately). ext volumes are written without the journal; they are only
mounted read-write when the journal is clean, and are mounted read-only if
they use features the driver cannot keep consistent (bigalloc, quota,
encryption, case folding, multiple-mount protection). htree indexed
directories are read but not modified.

`make test` builds a GPT test disk (`scripts/make-test-disk.sh`) with one
partition per format and the same files on each. The kernel reads every one
of them (`Kernel.FileSystemTest`), then writes to each one
(`Kernel.FileSystemWriteTest`). Afterwards `scripts/verify-test-disk.sh`
checks every partition on the host with the format's own consistency
checker and reads the written files back through independent
implementations.

## Objects

Every object has a header (signature, reference count, type, optional name)
followed by its body; callers only ever see body pointers. An object is
deleted, through its type's delete routine, when its last reference is
dropped. Named objects live in a flat namespace (`LookupObjectByName`).
Thread objects embed the scheduler's thread control block.

## User mode

### Processes and address spaces

Each user process has its own top level page table. The kernel half is
copied from the kernel's table when the process is created, so kernel
addresses stay valid in every process; the scheduler loads a thread's
`AddressSpaceRoot` into CR3 when it switches between processes.

User memory is described by a sorted list of regions (`Processes.AddressSpace`):
the program image (from 0x400000), shared libraries (from 0x7F00_0000_0000),
heap allocations and an 8 MiB stack below 0x7FFF_FFFF_F000. Pages are only
mapped when first touched: the page fault handler asks the address space
whether the address belongs to a region and, if so, maps a zeroed page. A
fault anywhere else in user mode ends just that process (exit status 139,
as a segmentation fault on Unix). The threads of a process share its
address space; region changes, page commits and the copies the kernel
makes in and out of it are serialized by a spin lock in the address space.

### Threads

A user process has one or more threads (`Processes.UserThread`). Each has
its own kernel stack (system calls and interrupts run on it; the scheduler
points the TSS and the system call entry at it on every switch), its own
user stack (a region with an unmapped guard page below it) and its own
thread data region (`Processes.ThreadStorage`) with the thread control
block and static thread-local storage. The thread pointer, the FS base
(MSR 0xC0000100), is part of each thread's state and is loaded by the
scheduler whenever it switches to a thread with a different one.

`CreateThread` (40) starts a thread at an entry point with one argument
and returns a thread handle; `WaitForThread` (42) waits for its exit
code; `ExitThread` (41) ends the calling thread. The process counts its
active threads, and the thread that brings the count to zero ends the
process: it closes the handles, releases the modules, frees the address
space and wakes the waiters. Exit (or a crash) in any thread instead marks
the process for termination, just as `TerminateProcess` does, so the other
threads end at their next safe point (see "Ending other programs"). Every
exiting thread first switches to the kernel's address space, so the last
one can free the process's while the others are still on their way out.

User-mode locks (`Sys.Locks`) take and release a free lock with one atomic
instruction. Only a contended lock enters the kernel: `WaitOnAddress` (45)
sleeps while a 32-bit word still holds a given value, comparing it under
the same lock that `WakeAddress` (46) takes, so no wake-up is lost
(`Processes.AddressWait`). The waits are alertable, so a process asked to
end is never stuck in a lock.

### Thread-local storage and initialization

The loader lays out thread-local storage with the static model of x86-64
variant II: the TLS block of the program and of each library loaded with
it sits at a fixed offset below the thread pointer, and the thread pointer
points at a control block whose first word points to itself (`%fs:0`),
followed by a word for the user runtime and the thread id
(`ThreadBlock*` in `Abi.SystemCalls`). Every new thread gets fresh copies
of the TLS images. The loader handles the TLS relocations DTPMOD64,
DTPOFF64, TPOFF64 and TPOFF32; a module's "id" is its offset from the
thread pointer, so `__tls_get_addr` in the System unit is one addition.
Libraries opened with `LoadLibrary` after startup may not have a TLS
segment or initializers (`ErrorUnsupported`): the layout is fixed by then.

Free Pascal 3.2.2 does not use ELF TLS for threadvars: every access calls
`FPC_THREADVAR_RELOCATE` with an offset stored in the variable. The System
unit hands out the offsets at startup from the program's
`FPC_THREADVARTABLES` (which covers every unit the program uses, those in
libraries included) and gives each thread a zeroed threadvar block on its
first access, kept in the runtime word of its control block.

Initialization code runs in user mode. The kernel collects the
initializers (DT_INIT, then DT_INIT_ARRAY) of the program and its
libraries, dependencies first, and the finalizers (DT_FINI_ARRAY in
reverse, then DT_FINI) in the opposite order, and passes both lists in the
auxiliary vector (`AuxiliaryInitializers` and friends). The System unit
runs the initializers, then the unit initialization sections listed in
the program's `INITFINAL` table (the compiler orders it by unit
dependencies, across libraries), then the main block; at exit it runs the
unit finalization sections in reverse, the output flush hook and the
finalizers. Symbols stay bound eagerly when the program is loaded; there
is no lazy PLT binding.

### System calls

Programs enter the kernel with the `syscall` instruction. The number is in
RAX and the arguments in RDI, RSI, RDX, R10, R8 and R9, as on Linux; the
result comes back in RAX, with errors as negative values (`-ErrorNotFound`,
...). The numbers, error codes and the records passed to the kernel are in
`shared/Abi.SystemCalls.pas`, which the kernel and `libsystem` both compile.

The entry code switches to the thread's kernel stack, builds a trap frame
and calls `DispatchSystemCall` with interrupts enabled; it returns with
`iretq`. Every user pointer is checked against the user half and the
process's regions before the kernel touches it (`Processes.UserAccess`).

Another thread of the process may free the memory between that check and
the copy, so the kernel touches user memory only through two small leaf
routines (`Kernel.Arch.UserCopy`: a byte copy and a string copy). While a
thread is inside one it is marked (`UserCopyActive`); a page fault on a
user address that the fault resolver cannot satisfy then does not panic:
the exception handler makes the routine return -1 by setting RAX and
popping its return address, and the call fails with `ErrorBadAddress`.
Drivers and file systems never see user pointers: reads and writes go
through a kernel transfer buffer of up to 16 KiB at a time. With that in
place SMAP is switched on when the processor has it, and the copy routines
allow user accesses only for their own duration (STAC/CLAC), so a stray
direct access anywhere else in the kernel faults at once. A kernel self
test copies to an unmapped user address.

| Area | Calls |
|---|---|
| Files | Open, Close, Read, Write, Seek, SetFileSize, GetHandleInformation, GetHandleKind, ControlHandle (console modes) |
| Paths | GetPathInformation, ReadDirectory, CreateDirectory, Remove, Rename, CreateSymbolicLink, ReadSymbolicLink, CreateHardLink, SetPathAttributes, Get/SetCurrentDirectory, SetRootDirectory |
| Processes | CreateProcess, WaitForProcess (with a timeout), TerminateProcess, Exit, GetProcessId, CreatePipe, DuplicateHandle, Sleep |
| Threads | CreateThread, ExitThread, WaitForThread, GetThreadId, SetThreadPointer, WaitOnAddress, WakeAddress |
| Users and processes (50-69) | ListProcesses, GetCredentials, SetUserIds, SetGroupIds, SetGroups, SetUmask, GetPriority, SetPriority, CreateFifo |
| Job control | StopProcesses, ContinueProcesses, WaitForProcessChange |
| Memory | AllocateMemory, FreeMemory |
| Libraries | LoadLibrary, FindSymbol |
| System | GetTime, GetSystemInformation, ListVolumes, Sync |

There is no fork: `CreateProcess` starts a program directly, with an
argument list, an environment, a working directory and the three handles
that become the new program's standard input, output and error.

### Ending other programs

A program cannot be stopped at an arbitrary point in the kernel, where it
may hold locks. `TerminateProcess` (Processes.Termination) only marks the
process and alerts its threads; the process ends itself at the next safe
point:

- before a system call returns to it,
- when an interrupt (the clock at the latest) returns to it, through a hook
  in the interrupt dispatcher, which also catches programs that make no
  calls at all,
- when an alertable wait is cut short. Waits in the kernel core take a
  timeout and an "alertable" flag; whichever of the signal, the timeout or
  the alert comes first removes the thread from both the event's queue and
  the sleep queue (`WakeWaitingThreadLocked`). Pipe and console reads,
  pipe writes, sleeping and waiting for a process are alertable.

Stopping a program uses the same safe points (see "Job control").

The exit code is chosen by the caller: 128 plus a signal number, as a Unix
shell reports a program killed by that signal. Running processes are kept
in a registry so they can be found by id.

### File attributes

Drivers may implement `SetAttributes` (mode, owner, group, modification and
access time), `CreateHardLink` and `GetFreeSpace`. ext2/3/4 supports all of
them. FAT and exFAT map the mode onto the read-only attribute, store times
in their own resolution and refuse owners other than 0 and hard links.
A per-process root directory implements `chroot`: paths are taken relative
to it and ".." never leads above it.

File information includes `AllocatedBytes`, the space a node takes on its
volume: for ext the inode's block count (512-byte units, or file system
blocks with the huge file flag), for FAT and exFAT the size rounded up to
whole clusters.

### Users and permissions

Every process has real, effective and saved user and group ids, up to 32
supplementary groups, a umask and a nice value (`TProcessCredentials`),
copied to its children. The first program runs as root (0:0, umask 022).
`SetUserIds` and `SetGroupIds` work like `setresuid`: root may set any id,
others only switch among their three current ones. `SetGroups` is for
root only. A program whose file has the set-user-ID (or set-group-ID) bit
runs with its owner (group) as effective and saved id; `su` and `passwd`
are installed that way and check passwords against salted SHA-256 hashes
in `/etc/shadow` (`Util.Passwords`).

The VFS does not know about processes. `FileSystem.Security` holds two
hooks, installed by `Processes.Security` when the first program starts:
"may the caller have this access to a node with this owner, group and
mode" and "which owner, group and umask do nodes the caller creates get".
Kernel threads act as root and keep the driver defaults. The checks:

| Operation | Needs |
|---|---|
| each directory on a path | search (x) |
| open | read and/or write on the node (not if the open just created it) |
| create, remove, rename, link | write and search on the directory (both, for rename) |
| chmod | being the owner |
| chown | root; the owner may change the group to one of its own groups |
| set times | being the owner, or write permission when setting them to now |
| run a program | execute; root needs at least one x bit |

Root passes every check except the last. New nodes get the effective user
and group and mode 0666 (files) or 0777 (directories) less the umask; on
FAT and exFAT, which have no owners, only the mode is applied. Refusals
from the mode bits are `ErrorAccessDenied` (13, "Permission denied");
refusals of chmod, chown, set-id calls and priorities are
`ErrorNotPermitted`.

### Named pipes

ext volumes can hold FIFO nodes (`NodeKindFifo`, inode type `S_IFIFO`,
directory entry type 5, no data blocks). Opening one does not give a file
handle: `Io.Pipes` keeps a registry of named pipes keyed by volume and node
number, so everyone who opens the node while an end is open shares one
pipe object, and the handle is a pipe read or write end. Opening one end
waits (alertably) until the other end is opened too, so a reader does not
see end of file before the first writer arrives.

### Handles

A process has a table of 64 handles, each naming a referenced object and
its kind: file, console, pipe read end, pipe write end, process, thread
or the null device. Handles 0-2 are standard input, output and error.
`DuplicateHandle` copies one onto another number, which is how the shell
redirects its own output for builtins. A pipe counts its open ends
separately from object references, so a reader sees end of file once the
last write end is closed, and a writer gets a broken pipe error once no
reader is left.

### Paths

Programs see a Unix style tree: `/` is the root of the system volume (the
one labelled `FPOSROOT`, or named by `root=`), and `/volumes/<name>`
leads to every mounted volume. `/dev` holds the devices (see "The I/O
manager").
`Processes.Paths` normalizes a path against the current directory and
translates it to the kernel's namespace.

### Executables and shared libraries

Programs and libraries are position independent ELF files (`ld -pie` and
`ld -shared`), linked with `--hash-style=sysv`. The kernel's loader
(`Processes.ImageLoader`) does the work of a dynamic linker: it maps each
segment, loads every `DT_NEEDED` library from `/lib` (once per process),
and applies the relocations (RELATIVE, 64, GLOB_DAT, JUMP_SLOT and COPY),
binding every symbol at load time by searching the modules in load order.
`LoadLibrary` uses the same machinery for libraries opened at run time,
and `FindSymbol` looks a name up in a library and the libraries it needs.

The initial stack holds the argument count, the arguments, the
environment and an auxiliary vector (program headers, page size, entry
point, and the initializer and finalizer lists), as on Linux.

### The userland

Everything in user mode is Free Pascal, compiled with `-Cg` (position
independent) against `rtl/user/system.pas`:

- **System unit** – the `syscall` instruction, program start (reads the
  initial stack, runs library initializers, unit initialization and the
  main block), exit (unit finalization, a hook so buffered output is
  flushed, library finalizers), threadvars and `__tls_get_addr`.
- **si_prc** – the `_start` entry point linked into each program; it
  passes the program's `INITFINAL` and threadvar tables to the System unit.
- **libcryptography.so** – digests (`Crypto.Md5`, `Crypto.Sha1`,
  `Crypto.Sha256`, `Crypto.Sha512`, `Crypto.Blake2b` behind
  `Crypto.Digests`), `Crypto.Hmac`, `Crypto.Checksums`, `Crypto.Aes`,
  `Crypto.ChaCha20` and `Crypto.Random`. Every algorithm is checked
  against its published test vectors.
- **libsystem.so** – `Sys.Kernel` (one wrapper per system call),
  `Sys.Memory` (size class heap on top of AllocateMemory), `Sys.Streams`
  (buffered standard input, output and error), `Sys.Format` (printf style),
  `Sys.Text`, `Sys.Files`, `Sys.Processes` (PATH search, start, wait),
  `Sys.Environment`, `Sys.Time`, `Sys.Libraries`, `Sys.Information`,
  `Sys.Locks` (user-mode locks and atomic operations) and `Sys.Threads`
  (creating, waiting for and ending threads). The heap is thread safe;
  buffered output is not synchronized.
- **libtlstest.so** – a small library in assembly with TLS and
  initializer arrays, which Free Pascal does not emit; `threadtest` uses
  it to test the loader and the runtime.
- **libcoreutils.so** – `Util.Options` (GNU style options: grouped short
  options, long options with abbreviations, `--help` and `--version`),
  `Util.Messages` ("program: message: error" diagnostics), `Util.Input`,
  `Util.Paths`, `Util.Sorting` (stable merge sort), `Util.Sizes`,
  `Util.Directories`, `Util.FileTree` (copying, removing and walking
  trees), `Util.RegularExpressions` (POSIX BRE and ERE with groups),
  `Util.Modes` (chmod modes), `Util.Dates`, `Util.BaseEncoding`,
  `Util.DigestTool`, `Util.Accounts` (/etc/passwd and /etc/group) and
  `Util.Commands` (running a command, signal names).
- **sh** – lexer, parser to a syntax tree, word expansion and execution;
  on the console it reads lines through `Util.LineEditor` (cursor keys,
  history in `$HOME/.sh_history`, Tab completion; a line longer than the
  screen scrolls sideways, so redrawing needs only carriage return,
  backspace and spaces and works on serial terminals too).
  Pipelines start their external programs first and then run builtins and
  compound commands inside the shell, so no stage waits for one that has
  not started. The language has `case`, functions (`Shell.Functions`: a
  copy of the body and its source text, so command substitutions, which
  run as a new `sh`, are given the functions and variables first) with
  per-call positional parameters, `local` and `return`, here-documents
  (collected by the lexer; fed through a pipe, or a file in `/tmp` when
  larger than a pipe holds) and redirections on compound commands. The
  builtins about running commands (`eval`, `exec`, `command`, `type`,
  `return`, `local`) are in `Shell.CommandBuiltins`; job control (see
  "Job control") in `Shell.Jobs` and `Shell.JobBuiltins`.
- **coreutils** – one program per file in `userland/bin`.

Units may have initialization and finalization sections and threadvars
(see "Thread-local storage and initialization"); the libraries themselves
have no initialization code of their own.

## Coding conventions

- Descriptive names for everything; no abbreviations or clever one-liners.
- One responsibility per unit; small files.
- Interfaces are documented at the top of each unit.
- Loops over unsigned counts use `while` (or `for I := 1 to Count`), never
  `for I := 0 to Count - 1`, which wraps around when `Count` is zero.
- A routine that takes the address of a record parameter declares it
  `constref` or `var`, never `const`, which may pass a copy.
- Assembly is Intel syntax (`{$asmmode intel}`) and limited to small,
  commented routines in architecture specific units.
