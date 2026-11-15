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

Both are built against `rtl/freestanding/system.pas`, a minimal System unit
with only what the compiler insists on. Nothing in the kernel uses the stock
runtime library. User programs are compiled for `linux` too (with `UNIX` and
`LINUX` undefined) and get the full Free Pascal runtime library, ported to
this kernel (see "The runtime library").
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

- 32 priorities. Every processor has a run queue per priority
  (`Kernel.ReadyQueues`); the idle thread (priority 0) runs only when
  nothing else is ready and is never queued.
- A thread that becomes ready goes to the processor it last ran on if that
  one is idle (its data may still be cached there), else to an idle
  processor, else to the one running the least important thread if that
  is less important, else back to its last processor; that processor is
  sent its dispatch interrupt if the thread should run there now. A
  processor choosing its next thread takes from another processor's
  queues a more important thread than its own best, or, with its own
  queues empty, any thread - so no processor idles or runs something
  less important while a thread it may run waits elsewhere.
- **Affinity.** A thread's `AffinityMask` (bit N: processor N) limits
  where it is queued and run; `SetThreadAffinity` moves a thread that is
  queued or running where it may no longer be. A process has a mask in
  its credentials, inherited by the processes it starts and applied to
  all its threads (`CallGetAffinity`, `CallSetAffinity`; `taskset`, and
  `nproc` counts only the processors it may use).
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
  Only the dispatcher lock is still shared by all processors.
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
- **Scheduling.** Each processor has its own run queues (see Scheduling);
  the dispatcher lock is shared. Each
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
- **Devices** interrupt the processors in turn: each interrupt connection
  (an I/O APIC route or an MSI address) goes to the next processor other
  than the boot processor, which keeps time. For that the processors are
  started in phase 1 right after the ACPI tables and interrupt routing
  (`InitializePlatformTables`), before any driver connects.

## I/O and storage

Started from phase 1 by `Io.Startup`, in dependency order:

1. **ACPI** (`Firmware.Acpi`) finds the system description tables through
   the RSDP the loader passed on.
2. **PCI** (`Io.Pci`) scans every bus in the MCFG table's ECAM windows.
   Buses with devices stay mapped (uncached, via `Memory.DeviceMapping`).
   Then the **ACPI namespace** is loaded (see below), which needs PCI
   configuration space and gives the routing of PCI interrupt lines.
3. **Storage drivers** (`Drivers.Ahci`) register whole-disk block devices
   named `disk0`, `disk1`, ... Each disk has a device object of the `ahci`
   driver, without a name; the block device sends it read and write
   requests. The AHCI driver uses every command slot of a port: on disks
   with native command queuing, reads and writes are queued commands
   (READ/WRITE FPDMA QUEUED, up to the disk's queue depth at once);
   flushes, and everything on disks without NCQ, run alone. Data moves
   straight to and from the request's pages (one PRDT entry per page,
   translated with `TranslateVirtualAddress`); only buffers that cannot
   be translated use the port's 64 KiB bounce buffer. Requests complete
   from its MSI interrupt (polling while disks are identified, or without
   MSI). Commands have a 5 second deadline (`Kernel.Timers`); a command
   that fails or times out fails every request running on the port with
   `ErrorIo`, and the port is reset as the AHCI specification describes
   (stop, clear errors, COMRESET if the device is still busy, start).
   ATAPI devices (optical drives, signature EB140101h) are read-only disks
   of their medium's block size: IDENTIFY PACKET DEVICE gives the model,
   SCSI READ CAPACITY(10) the size, and reads are READ(10) commands in
   ATAPI packets, never queued. A drive without a readable medium is left
   alone. The tests put a 64-block medium in a drive on the fifth port.
   The block cache writes dirty lines back in batches
   (`WriteBlocksTogether` sends all requests before waiting), which is
   what keeps several commands in flight; the disk statistics filter
   reports the most requests in flight at once. The tests attach a disk through QEMU's
   blkdebug that fails reads of one sector.

   Virtio block devices (`Drivers.VirtioBlock`, on the virtio 1.0 PCI
   transport in `Drivers.VirtioPci`) are disks too, of the `virtio-blk`
   driver. A request is a descriptor chain on a split virtqueue: header,
   data pages from the driver's bounce pages (128 KiB a command) and a
   status byte. Requests complete by MSI-X interrupt (or are polled).
   Flushes are sent when the device has a volatile write cache. The tests
   attach a virtio disk holding a copy of the ext4 test partition.

   NVMe controllers (`Drivers.Nvme`, queue pairs in `Drivers.NvmeQueues`)
   are disabled, given an admin queue pair, enabled and identified; one
   I/O queue pair is created, and every active namespace becomes a disk
   of the `nvme` driver with its logical block size. Admin commands are
   polled. I/O commands complete by MSI-X or MSI. Data goes through the
   controller's bounce pages, up to 128 KiB (or the controller's largest
   transfer) a command, described by PRP entries or a PRP list. The tests
   attach an NVMe disk holding a copy of the FAT32 test partition.

   USB: xHCI controllers (`Drivers.Xhci`, rings in `Drivers.XhciRings`)
   are taken over from the firmware, reset and given a device context
   array (with scratchpad pages), a command ring and an event ring. Events
   come by MSI-X or MSI (or are polled); a deferred call takes them off
   the ring and wakes whoever waits for the command or transfer. At start
   every connected port is reset and its device enumerated: a slot is
   enabled, the device addressed, its descriptors read and its first
   configuration set. The device is then offered to the class drivers
   (`RegisterUsbClassDriver`). Hot plugging is not handled yet. Transfers
   move through each device's DMA pages (64 KiB), and only events for the
   TRBs being waited for count. USB mass storage (`Drivers.UsbStorage`,
   Bulk-Only Transport) sends SCSI commands in command block wrappers:
   INQUIRY, TEST UNIT READY with REQUEST SENSE, READ CAPACITY(10),
   READ/WRITE(10) and SYNCHRONIZE CACHE(10). Each device becomes a disk of
   the `usb-storage` driver, whose requests run in the caller's thread.
   The tests attach a USB stick holding a copy of the exFAT test
   partition.
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
- Devices can be **layered**: `AttachDevice` puts a filter device on top
  of a device's stack, and requests sent to any device of the stack start
  at its top. A filter passes a request down with `ForwardRequest`,
  optionally with a completion routine of its own (at most four layers);
  a filter without a routine for some request kind passes it on
  unchanged. On completion the layers' routines run innermost first, then
  the sender's completion - also for requests completed later from an
  interrupt.
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
completion routines, cancelling the request of an alerted thread, and a
filter on top of the test device.

The drivers so far:

| Driver | Devices |
|---|---|
| `memory` (`Drivers.MemoryDevices`) | `null`, `zero`, `full`, `random`, `urandom` (RDRAND, or a TSC-seeded xorshift without it), all `rw-rw-rw-` |
| `console` (`Drivers.ConsoleDevice`) | `console` and `tty`: reads and writes go to `Io.Console`; control requests get and set the modes, the size and the foreground group and take a pending Ctrl-C |
| `disk` (`Drivers.DiskDevices`) | one block device per disk and partition, `rw-------` for root; any offset and length (through a one-block buffer, around the block cache: reads write the cache back first, writes drop what it holds of the disk); writing to a device that holds a mounted volume, or to a disk with a mounted partition, is refused |
| `ps2keyboard` (`Drivers.Ps2Keyboard`) | `keyboard`, exclusive, `rw-------`: the characters typed (`Io.InputDevice`) |
| `serial` (`Drivers.SerialDevice`) | `serial0`, exclusive, `rw-------`: the characters received on COM1 |
| `events` (`Io.InputEvents`) | `events`, one opener at a time, `rw-------`: every keyboard's and pointing device's input events (`TAbiInputEvent`); while open, the keyboards stop typing into the console |
| `ahci` (`Drivers.AhciRequests`) | one unnamed device per SATA disk, asynchronous |
| `diskstats` (`Drivers.DiskStatistics`) | a filter on each disk's storage device counting completed reads and writes, their bytes, and failures; written to the kernel log after the self tests and at the end |

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
chosen processor's local APIC) and data (the vector), and turns its legacy
interrupt line off. `ConnectPciExtendedMessageInterrupt` does the same
through entry 0 of an MSI-X table (in device memory, found through the
capability's BAR and offset), with every other entry masked;
`ConnectPciInterrupt` prefers MSI-X and falls back to MSI.

Devices without either use their PCI interrupt line (INTA to INTD):
`ConnectPciLineInterrupt` (Io.PciLineInterrupts) reads the device's pin
and looks it up in the routing tables built from the ACPI namespace.
Behind a bridge without a table of its own, the line is swizzled to the
bridge's slot ((pin + device) mod 4), and so on up. It connects the
global system interrupt the line arrives on, level triggered with the
table's polarity (`ConnectGlobalInterrupt`; an ISA IRQ goes through the
MADT's overrides first), and clears the device's interrupt disable bit.
Lines can be shared: a line's vector calls every handler on it, and each
handler checks and quiets its own device.

### The ACPI namespace and its AML

The DSDT and SSDTs hold the ACPI namespace as AML bytecode: devices,
their methods and the operation regions those methods use. The kernel
interprets it (`Firmware.Aml*`) to learn what only the namespace says,
for now the routing of PCI interrupt lines.
- **The interpreter is plain Pascal.** It reaches the machine only
  through `AmlHost` (allocation, system memory, port I/O, PCI
  configuration space, sleeping, the time and a log), so it builds for
  the host too. `make aml-test` (run first by `make test`) loads DSDTs
  captured from QEMU's q35 and i440fx machines (`tools/AmlTest`), with a
  fake configuration space, and compares the namespace size, the routing
  and the PIC-mode link interrupts with the expected output.
- **Values** (`Firmware.AmlValues`) are integers (32-bit for revision 1
  tables), strings, buffers and packages in counted shared storage,
  references (to a node, or to a package element or buffer byte) and
  name paths kept for later lookup.
- **The namespace** (`Firmware.AmlNamespace`) is a tree of four character
  names, looked up with AML's rules (the root, parent prefixes, multi
  name paths, the upward search for single names).
- **Running** (`Firmware.AmlInterpreter`): a table body runs like a
  method at the root, its named object opcodes building the namespace.
  Methods run from the table bytes in a frame of their own (locals,
  arguments, return value), covering:
  - control flow (`If`, `Else`, `While`, `Break`, `Continue`, `Return`);
  - arithmetic, logic and comparisons;
  - strings, buffers, packages, `Index`, `RefOf`, `DerefOf`, `CondRefOf`;
  - conversions, `Concatenate`, `Mid`, `Match`;
  - buffer fields;
  - `Notify`, `Sleep`, `Stall`, mutexes and events (always acquired);
  - `\_OSI` answers for the Windows versions firmware asks about.

  Stores follow ACPI's implicit conversions; a store into a named buffer
  keeps its length and storage, so buffer fields over it stay valid.
  Errors end the evaluation cleanly. So do loops that run too long and
  calls nested too deep.
- **Fields** (`Firmware.AmlFields`) read and write bits a unit at a time
  (the access width), following the update rule for the bits around
  them. Plain fields go to their region; bank fields set the bank
  first; index fields go through their index and data fields; buffer
  fields go into a buffer. A PCI configuration region finds its device
  from the `_ADR` above it and its bus from `_BBN`.
- **Loading** (`Io.AcpiNamespace`) gives the interpreter the kernel as
  its host and loads the DSDT (through the FADT) and every SSDT. It then
  runs the devices' `_STA` and `_INI` and builds the routing. The
  interpreter recurses as the AML nests, so it runs on a thread with a
  256 KiB stack (`CreateSystemThread` takes a stack size; a kernel
  thread's exit event is signalled when its routine returns, so it can
  be waited for).
- **Routing** (`Firmware.AcpiPciRouting`): `\_PIC(1)` (I/O APIC mode),
  then the `_PRT` of every PCI root bridge (`PNP0A03`/`PNP0A08`) and of
  the bridges below it that have one (their bus read from their
  configuration space). Each entry names a global system interrupt or a
  link device, whose `_CRS` (`Firmware.AcpiResources`: IRQ and extended
  interrupt descriptors) gives the interrupt, trigger and polarity. A
  link not yet connected gets the first interrupt its `_PRS` offers,
  through `_SRS`.

### ACPI events, sleep states and shutting down

- **Fixed hardware** (`Io.AcpiHardware`). The FADT names the PM1 event
  and control blocks, the GPE blocks, the SCI, the SMI command port and
  the reset register. Registers come from their generic address where
  given, else from the older I/O port fields. Entering ACPI mode writes
  ACPI_ENABLE to the SMI command port and waits for SCI_EN.
- **Events** (`Io.AcpiEvents`). The SCI (its ISA IRQ through the MADT's
  overrides, else level triggered and active low; shareable) is handled
  in two halves.
  - The interrupt handler clears and notes the power and sleep button
    statuses, and disables each GPE that fired (it may be level
    triggered).
  - A deferred call then wakes the event thread, which runs AML on a
    256 KiB stack. A GPE runs `\_GPE._Lnn` (then its status is cleared)
    or `_Enn` (cleared first), and is enabled again.

  Only GPEs with a method are ever enabled. The AML's `Notify` reaches
  the kernel through `AmlHost.Notify`. 0x80 to a power or sleep button
  device (`PNP0C0C`, `PNP0C0E`: buttons with control methods) is a
  press; other notifications are logged. Button presses go to the power
  policy `Kernel.Startup` gives: the power button powers off. The
  interpreter is not reentrant, so all AML after loading runs under one
  lock (`LockAmlInterpreter`).
- **Sleep states** (`Io.AcpiSleep`). A state's SLP_TYP values come from
  `\_Sx`. Entering one evaluates `\_PTS`, clears the status and writes
  the types, then SLP_EN, into the PM1 control registers. S5 (soft off)
  and S3 (suspend to RAM, below) are entered; S1, S2 and S4 are not.
  Resetting uses the FADT's reset register, then `HalResetMachine` (the
  keyboard controller, then port 0CF9h).
- **Shutting down** (`Processes.Shutdown`). The power button,
  `CallShutdown` (root only: `poweroff`, `reboot`, `halt`) and the
  kernel debug shell (`poweroff`, `reboot`) can start it; the first
  request wins. A thread of its own:
  1. asks every user process to end (status 143) and waits up to five
     seconds;
  2. syncs the volumes;
  3. writes the closing summaries;
  4. enters S5, resets or halts.

  The phase 1 thread, seeing init end during a shutdown, leaves the rest
  to it.

### Suspend to RAM

S3 turns every processor and device off; only memory keeps its
contents. Waking, the firmware starts the boot processor at the FACS's
waking vector, and every device starts from its reset state: the kernel
brings everything back from what memory still holds. `Processes.Suspend`
runs it on a thread pinned to the boot processor:
1. `\_PTS(3)` and the S3 types; the volumes are synced.
2. Every power handler suspends (`Io.PowerManagement`, by stage, last
   first).
   - **Services:** the block I/O gate in `Io.BlockDevice` stops new
     requests and waits for those in flight; the audio framework stops
     its outputs and inputs and pauses its threads.
   - **Devices:** drivers quiet their hardware (AHCI stops its ports,
     NVMe is told to shut down).
   - **Platform:** PCI configuration space is saved.
3. Processors (`Kernel.ProcessorPower`).
   - Every other processor freezes in its dispatch interrupt, where it
     holds no spin lock: it saves its state (`Kernel.Arch.Suspend`:
     callee-saved registers, stack, flags, FS and swapped GS bases, FPU
     state, like `setjmp`) and halts.
   - The boot processor saves the I/O APIC entries and its own state,
     points the waking vector at the start-up page (the trampoline that
     starts secondary processors) and writes the sleep registers.
4. Waking, the trampoline takes the boot processor to 64-bit mode and
   `WakeEntry`.
   - It reloads its page tables, descriptor tables (kept in memory; the
     TSS made available again), processor block, interrupt table, PAT
     and system call registers.
   - Its interrupt hardware comes back: the legacy PICs masked, the
     local APIC and clock, the I/O APIC entries.
   - It resumes its saved state, then starts each frozen processor
     again (INIT, STARTUP), which resumes inside its dispatch interrupt.
5. The wall clock is read again (the uptime leaves the sleep out), and
   every power handler resumes, first stage first:
   - **Platform:** PCI configuration (BARs, bridges, capabilities, then
     the command register) and the MSI-X tables, which live in device
     memory.
   - **Firmware:** ACPI mode, `\_WAK(3)`, the button and GPE enables.
   - **Buses:** xHCI's rings are emptied in their pages and the
     controller runs again. Each device is set up again on its port: a
     slot, its address, its configuration, every endpoint it had open
     (recorded when opened), then the class driver's part (boot
     protocol, the streaming setting, clearing a disk's "unit
     attention"), then the interrupt reads.
   - **Devices:** AHCI ports pointed at their command lists again; NVMe
     queues emptied and recreated; virtio reset, its features and queue
     given again; HD Audio's controller reset and codec paths set up;
     AC'97's codec and list; the serial port; the PS/2 controller; the
     Bochs display's mode registers (the firmware set the mode at boot)
     and the console redrawn from its copy.
   - **Services:** block I/O open again; audio volumes set again and
     capturing restarted.

`suspend` (root only, `CallSuspend`) and the kernel debug shell's
`suspend` start it. The input test suspends a machine with AHCI,
virtio, NVMe and USB disks and HD Audio, AC'97 and USB audio, wakes it
(`system_wakeup`), then reads every disk raw, writes and reads back
files on three volumes, plays a tone on each sound output (recorded and
checked) and checks the display.

`make aml-test` also checks the sleep states (S3, S4, S5 on both QEMU
machines) and the GPE methods the tables have. The input test plugs a
processor in, which raises GPE 2: the `_E02` method notifies the new
processor's device, which the kernel logs. It then presses the power
button (`system_powerdown`) and expects the programs to end, S5, and
QEMU exiting by itself with status 0. coretest checks that `poweroff`,
`reboot` and `halt` refuse anyone but root.

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
port.

Every keyboard turns keys into characters the same way
(Drivers.KeyboardTranslation, one TKeyboardState per keyboard): keys are
numbered as PS/2 scan codes (set 1, with E0 for the extended keys), and
the characters come from a layout (Drivers.KeyboardLayouts: us, uk, de
or fr, chosen with the kernel option `keymap=`), written as the keys that
differ from US, with a third level on AltGr. The accent keys of de
(´ ` ^) and fr (^ ¨) are dead keys: their accent goes on the next letter
(é, è, ê, ë, upper case too); space, or the dead key again, gives the
accent alone, and any other key gives the accent followed by it.
Characters beyond ASCII are sent in UTF-8; with Num Lock off the keypad
sends cursor and editing keys. The PS/2 driver sets the Caps, Num and
Scroll Lock lights (keyboard command 0xED, answered by interrupts).

USB keyboards (Drivers.UsbKeyboard, on the xHCI driver) use the HID boot
protocol. Their interrupt IN endpoint is read over and over (a report
handler called from the xHCI event processing, which queues the next
read). Each 8-byte report is compared with the one before: modifier bits
and the usage codes of up to six held keys give the keys pressed and
released, which are mapped onto the PS/2 scan codes. Each keyboard is an
input device `usbkeyboardN` that the console reads. Keys do not repeat
while held, and the lights stay off. The input test types on a QEMU USB
keyboard, then unplugs it and types on the PS/2 keyboard; the kernel
logs how many keys each kind delivered, and the test checks both.

Input events (Io.InputEvents) are the input for a graphical program:
every keyboard and pointing device as one stream of `TAbiInputEvent`
records (shared/Abi.SystemCalls.inc) read from `/dev/events`. An event
has a time (milliseconds of uptime), a kind, the device it came from (a
source number each driver takes with NewInputSource) and its values:

| Kind | Values |
|---|---|
| key | Code: the set 1 scan code (plus KeyCodeExtended for E0 keys); Value 1 pressed, 0 released; Character: the character typed (0 for none or an escape sequence); Modifiers: Shift, Control, Alt, AltGr and the locks |
| motion | X, Y: relative motion, right and down positive |
| position | X, Y: an absolute position, 0 to 65535 across the screen whatever its resolution (InputPositionMaximum), so it scales to any display and DPI |
| button | Code: 1 left, 2 right, 3 middle, 4 and 5 the side buttons; Value 1 pressed, 0 released |
| wheel | Value: steps, positive away from the user |

Drivers call AddInputEvent from any level (the ring of 256 events is
under a spinlock with interrupts off; a deferred call completes waiting
reads with whole events). One program opens the device at a time;
events are only kept while it is open, and while it is, the keyboards'
characters do not go to their input devices (the console): keyboards
report key events from Drivers.KeyboardTranslation, which also tracks
the left Alt key for the modifiers. The serial port still feeds the
console.

The PS/2 controller's code shared by the keyboard and the mouse is in
Drivers.Ps2Controller. The PS/2 mouse (Drivers.Ps2Mouse, IRQ 12) is set
up by polling with its interrupt off: the second port enabled, the mouse
reset and given its defaults, then the IntelliMouse sample rate knock
(200, 100, 80): id 3 means a wheel and four-byte packets. The first
byte of every packet has bit 3 set, which keeps the packets in step.
Waking from S3 sets it up again.

USB pointing devices (Drivers.UsbPointer) are any HID interface the
keyboard driver did not take whose report descriptor has X and Y. The
descriptor (GET_DESCRIPTOR 22h on the interface) is parsed by
Drivers.HidReports: global items (usage page, logical range, report
size, count and id, push and pop), local items (usages and usage
ranges, reset by each main item), and Input main items laying out their
fields bit by bit. The report holding X and Y gives where X, Y, the
wheel and buttons 1-5 are. Relative X and Y (a mouse) give motion
events; absolute ones (a tablet, like QEMU's usb-tablet) give position
events scaled from the logical range to 0-65535. Boot devices are put
in report protocol, the format the descriptor describes, again after
waking.

`events [-n COUNT]` prints the events as text. The input test runs it
and moves QEMU's PS/2 mouse (HMP mouse_move and mouse_button, a wheel
step), places the USB tablet (QMP input-send-event: HMP's moves are
relative) and presses a key, checking each event and that the key did
not reach the shell; after waking from S3 it checks the mouse and the
tablet again. The test's xHCI controller has eight ports of each kind:
with four, QEMU would put the USB devices behind a hub, which the
kernel does not drive yet.

The framebuffer console (Debug.FramebufferConsole) decodes UTF-8 and
draws from a font with ASCII, Latin-1, Œ œ Ÿ and € (generated from
Terminus by `tools/PsfToPascal`; other characters show as `?`). It
carries out the escape sequences programs use (cursor movement and
positioning, erasing in a line or the screen, colours). Once the kernel
heap is up it keeps a copy of the screen in memory: every pixel goes to
both, and scrolling moves the copy and writes the framebuffer, never
reading video memory. The input test checks UTF-8 text and a colour,
pixel by pixel against the font, in a screen dump taken after
scrolling.

### The display device

`/dev/display` (Drivers.DisplayDevice) is the screen for a graphical
program: the framebuffer the firmware set up, which the loader passes
on. One program opens it at a time. Opening it takes the screen from
the text console, which goes on drawing into its copy of the screen
only (SuspendConsoleDrawing); closing it, however the program ends,
gives the screen back and the console draws itself again from the copy.
A kernel panic takes it back too.

Control requests give the size, the pitch (bytes per line), the pixel
format (blue-green-red or red-green-blue in a LongWord), the physical
size in millimetres, the DPI and the scale. The framebuffer is mapped
into the program with `CallMapHandle` (offset 0), its writes combined.
`Sys.Display` in libsystem wraps all of it (OpenDisplay, CloseDisplay,
DisplayPixel).

The DPI comes from the kernel option `dpi=N` if given; else from the
display's EDID: the one the firmware has (the loader copies the base
block from the EDID active or discovered protocol into the boot
information), else the one QEMU's Bochs display keeps at the start of
its register BAR; else 96. Drivers.Edid takes the physical size from
the first detailed timing descriptor (in millimetres) or, without one,
from bytes 21 and 22 (centimetres); the DPI is the framebuffer's width
in pixels against that. The scale is the DPI against 96, to the nearest
quarter, at least 100%: 96 DPI is 100%, 144 is 150%. Programs size what
they draw in points and logical units with them.

`display` prints what the display is like; `display -f RRGGBB` fills
the screen with a colour and a frame a quarter inch in. The input test
checks the DPI QEMU's EDID gives (325x203 mm at 1280 pixels: 100 DPI),
the colour and the frame in a screen dump while it runs, and the
console's screen after it ends.

## Sound

The audio framework (`Io.AudioOutput`, `Io.AudioStreams`) is the part of
sound that does not depend on the hardware:
- **Outputs.** A sound driver registers each output with routines to
  start and stop playing, report where the hardware is in the ring, and
  set the volume. The output gets a ring of 16 page-sized periods, played
  as 16-bit stereo at 48 kHz, and a device file: the first output is
  `/dev/audio`.
- **Streams.** Every open of the device is a stream of its own, so any
  number of programs play at once. A stream's format is 8, 16, 24 or
  32-bit integer or 32-bit float samples, 1 to 8 channels (WAVE order)
  and 8 to 192 kHz (`ControlAudioSetFormat`). Its samples wait in a 64 KiB
  queue; a write waits while the queue is full.
- **Mixing.** The mixer thread (`RunAudioMixer`) keeps four periods ahead
  of the hardware. For each it takes every stream's next frames: it
  folds other channel counts into stereo (centre and surround at 1/√2,
  LFE left out), converts the rate by linear interpolation, applies the
  stream's volume, sums the streams and clips to 16 bits. All of it is
  integer arithmetic; float samples are decoded from their bits. The
  hardware starts when a stream has data and stops after half a second of
  silence; each period it finishes (the driver calls
  `AudioPeriodsElapsed`) wakes the mixer.
- **Draining and controls.** Draining (on request, and on close) waits
  until the stream's last sound has been played. A stream has its own
  volume; the master volume (the hardware's) applies to all. The queue's
  fill and the frames mixed so far can be asked for.

Recording (`Io.AudioInput`, `Io.CaptureStreams`) mirrors playing:
- **Inputs.** A driver registers each input with routines to start and
  stop capturing, report where the hardware is in its ring and set the
  gain. The input gets a ring like an output's and a device file: the
  first input is `/dev/audioin`.
- **Capture streams.** Every open is a capture stream with its own
  format, any of those streams take, and its own volume. The hardware
  captures while any stream is open. As periods fill, the capture thread
  (`RunAudioCapture`) hands each one to every stream. The stream converts
  the rate, spreads stereo over its channels (mono gets the average) and
  queues the result. Its samples wait in a 64 KiB queue until read; what
  doesn't fit is dropped and counted (`ControlAudioGetDropped`). A read
  waits for at least one frame.
- **Monitors.** Each output also has a monitor input
  (`/dev/audiomonitor` for `/dev/audio`). It has no hardware: the mixer
  feeds it every period it mixes, so what plays can be recorded. Like
  loopback capture elsewhere, it only delivers while the output plays.

The Intel HD Audio driver resets the controller and talks to its codecs
through the immediate command interface (`Drivers.HdAudio.Codecs`). In
each codec's audio function group it looks for an output path (an output
converter feeding an output pin) and an input path (an input pin feeding
an input converter). Either may run directly or through one mixer or
selector, and each may be on a different codec. The driver powers the
path up, enables the pin and unmutes it.
`Drivers.HdAudio.Streams` programs the first output stream and the first
input stream: a buffer descriptor list with an entry per period, each
interrupting when done (by MSI; otherwise a timer polls the positions).
The output's volume and the input's gain are their converters'
amplifiers (`Drivers.HdAudio`).

The AC'97 driver (`Drivers.Ac97`) drives Intel ICH-style controllers:
the codec's mixer and the bus master are I/O ports, and the PCM out box
plays a list of 32 buffer descriptors that describes the ring twice
over. The box stops at its last valid entry, so the driver keeps moving
that entry to just before the current one. Descriptors take 32-bit
addresses, so the ring comes from `AllocateZeroedPhysicalPageBelow`.
It signals on its PCI interrupt line as each buffer completes; the
handler clears the box's status (the line is level triggered and may be
shared). Without routing tables, a 10 ms timer follows the box instead.

The USB audio driver (`Drivers.UsbAudio`, audio class 1.0) looks
through a device's configuration for an audio streaming setting that
takes 16-bit stereo at 48 kHz over an isochronous OUT endpoint. It also
looks for the control interface's feature unit, whose mute and volume
controls give the output volume. It selects the setting, sets the
endpoint's rate and registers an output. Isochronous transfers are a
stream in the xHCI driver (`Drivers.XhciIsochronous`): the class driver
supplies packets and hears when each has gone. The stream keeps 24 on the
endpoint's ring, each a transfer descriptor of an isochronous TRB
started as soon as possible, plus a chained normal TRB when the packet
crosses a page. Packets come straight from the output's ring, 48 frames
a millisecond, and the bytes completed are the output's position.
Built-in sound starts before the USB controllers, so it keeps the first
device names.

In user space, `libaudio` holds `Audio.Device` (format, volume, writing,
draining), `Audio.Wave` (PCM WAV files) and `Audio.Synthesis` (sine tones
from a quarter-sine table and a fixed point phase).

### The voice engine

`Audio.Engine` mixes voices in a graph, in 32-bit float, the way XAudio2
does:
- **Voices.** A source voice plays the buffers queued on it, in any
  sample kind and rate. Submix voices take what others send them and pass
  it on, in the order of their processing stage. The one mastering voice
  ends the graph. Sound only flows down: to the mastering voice or to a
  submix voice of a later stage.
- **Buffers** (`Audio.Voices`). A buffer plays from its play start to
  its play end, jumping back round its loop region as often as it says
  (or until `ExitLoop`). Callbacks tell when buffers start and end, loops
  come round, the stream ends (the buffer flagged as its end) and passes
  start and end. The rate, times the voice's frequency ratio (its pitch),
  is converted by cubic Hermite interpolation.
- **Shaping.** Every voice has a volume, a volume per channel, a filter
  (`Audio.Filters`: state variable low, band and high-pass and notch, and
  one-pole low and high-pass) and a chain of effects. Each send to a
  destination has an output matrix (how the channels go into the
  destination's) and a filter of its own.
- **Effects** (`Audio.EffectChain`). An effect is a record of routines
  (process in place, parameters, reset, release, the length of its tail)
  and a state, so programs can write their own. A voice stopped with
  `StopPlayTails` keeps processing until its effects' tails have played.
- **Operation sets.** A change made with an operation set waits for
  `CommitChanges` with that set, so several changes land in the same
  pass; set 0 changes at once.
- **Running.** Passes of 10 ms run on the engine's own thread, which
  writes the mastering voice's float samples to `/dev/audio`; the kernel
  mixes them with other programs. Writing waits while the device's queue
  is full, and that paces the engine. Callbacks run on the engine's
  thread and may call back into the engine. An offline engine has no
  device or thread: `RenderAudio` processes passes for its caller, as the
  tests do. `GetPerformanceData` counts voices, passes and frames, and
  the frames queued in the device.

### Effects and 3D audio

The built-in effects implement the effect interface, so they go in any
voice's chain like a program's own:
- **Reverb** (`Audio.Effects.Reverb`): Freeverb's eight comb filters
  (damped feedback: the room's echoes) and four all-pass filters (the
  wash) for each channel, the right a little longer than the left. Room
  size, damping, wet and dry levels and width; its tail lasts until the
  longest comb falls to -60 dB.
- **Echo** (`Audio.Effects.Echo`): a delay line of up to two seconds with
  feedback and a wet/dry mix.
- **Equalizer** (`Audio.Effects.Equalizer`): four peaking bands
  (Bristow-Johnson biquads), each a centre, a gain and a width in
  octaves.
- **Volume meter and limiter** (`Audio.Effects.Dynamics`): the meter
  reports each pass's peak and RMS level per channel; the limiter holds
  the peak under a threshold, its gain dropping at once and recovering
  over the release time, shared by the channels.

`Audio.Spatial` works out what X3DAudio does for an emitter and a
listener (left-handed space: X right, Y up, Z forward):
- **Panning.** Each emitter channel is panned by its direction from the
  listener, with equal power between the two speakers on either side of
  it, over mono, stereo, quad, 5.1 or 7.1 (the LFE gets nothing). The
  channels of a multi-channel emitter sit at their azimuths round it;
  inside its inner radius the sound spreads over every speaker.
- **Distance and cones.** The volume follows a curve of distance (by
  default 1 / distance past the curve's scale), and a cone fades from
  its inner to its outer volume between its angles. Curves also give a
  low-pass coefficient and a reverb send level by distance.
- **Doppler.** The factor comes from the speeds of emitter and listener
  along the line between them, against the speed of sound.
- `ApplySpatial` puts the result on a voice: the output matrix, the
  frequency ratio and the filter.

### Programs and tests

The programs are `tone` (plays a tone, or writes it as a WAV file, in
any format), `play` (WAV files: integer, float and extensible, any of the
formats streams take), `record` (records an input into a WAV file),
`soundinfo` (a WAV file's format, length, peak and frequency), `mixer`
(the master volume), `voicetest` (the engine's tests) and `effecttest`
(the effects' and 3D audio's). The tests record what QEMU's HD Audio device plays (its
`wav` audio backend). coretest plays a 1000 Hz tone, a 440 Hz WAV file,
600 and 1500 Hz from two programs at once, then 800, 2000 and 300 Hz at
22.05, 96 and 11.025 kHz as u8, float mono and s24 six-channel samples,
then `voicetest play`: one cycle of 600 Hz at 24 kHz looped 600 times at
twice its pitch, 1200 Hz for half a second. Then two programs record the monitor
(16 kHz mono s16 and 96 kHz six-channel float) while 900 Hz plays, and
`soundinfo` checks both recordings in the guest. Last, 700 Hz on the
AC'97 output (`/dev/audio1`) and 500 Hz on a USB audio device
(`/dev/audio2`), each recorded into a file of its own. Another test
records half a second from `/dev/audioin`: QEMU's microphone codec
(`hda-micro` on the `none` backend) gives silence, at the right rate and
length. `scripts/check-audio.py`
measures each 50 ms of the recording at the expected frequencies
(Goertzel's algorithm) and checks the order, the tones together and the
lengths. `voicetest` on its own renders graphs offline and checks them:
resampling, pitch, volumes, matrices, every filter, the callbacks' order
and the frames played, loops, flushing, 8-bit samples, submix stages and
several sends, send filters, operation sets, a custom effect with its
parameters and tail, and the performance data. `effecttest` measures
each built-in effect (the meter's readings, the limiter's ceiling, the
echo's delays and levels from an impulse, the equalizer's gain in and
out of its band, the reverb's answer, decay and width), tails after
stopping, and the 3D calculations: panning in stereo, 5.1 and 7.1,
distance, curves, cones, emitter channels, the inner radius, Doppler,
and a voice placed and moving to one side.

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

Removing a file that is still open removes only its name: the open file
goes on reading and writing, and its storage is freed when it is closed
for the last time (the driver routines `RemoveOpenNode` and
`FinishRemoval`; the node leaves the node cache at once, so a new file
with the same node number is not confused with it). On ext3/ext4 such a
file goes on the orphan list in the superblock in the same transaction,
and mounting frees orphans a crash left behind (`FileSystem.Ext.Orphans`).
Renaming onto an existing name replaces it as on Unix (a file replaces a
file, a directory an empty directory); on ext3/ext4 the removal and the
rename are one transaction (`BeginAtomicChange` / `EndAtomicChange`). In a
directory with the sticky bit (`/tmp`), only the owner of a name, of the
directory or root may remove or replace it.

The block cache (`Io.BlockCache`, 1024 lines of 4 KiB) writes back:

- **Writes** only dirty a line. Dirty lines reach the disk when
  `FlushCachedDevice` is called (which then also sends the disk a flush),
  when the background writer (the `CacheWriter` thread) finds them dirty
  for more than a second, or before their line is reused. Everything
  that needs data durable or ordered flushes: the ext journal around its
  commit blocks, exFAT after marking the volume dirty, syncing (including
  before `test-exit`), and raw disk access.
- **Locking.** The cache lock only covers the hash table, the recency list
  and which part of a device each line holds, and is never held across
  I/O. Each line has its own mutex for its data and I/O, so different
  disks (and different lines) are read and written in parallel. A line's
  mutex is only taken while the line is pinned, so choosing a line to
  reuse never waits.
- **Reading ahead.** Read misses on consecutive lines of a device read up
  to 16 more lines in the same request.

ext volumes are mounted read-only if they use features the
driver cannot keep consistent (bigalloc, quota, encryption, case folding,
multiple-mount protection). htree indexed directories are read but not
modified.

### The ext3/ext4 journal

ext3 and ext4 volumes are written through their journal (JBD2, the file of
inode 8), in "ordered" mode:

- **Transactions.** Every driver call that changes the volume is one
  transaction (`FileSystem.Ext` wraps the write entry points). All of the
  driver's disk accesses go through `ExtRead`, `ExtWriteMetadata` and
  `ExtWriteData`. While a call runs, metadata blocks (inodes, bitmaps,
  group descriptors, the superblock and its free counters, directory,
  extent and block pointer blocks, symbolic link targets) are not written
  in place: each changed block is copied into the transaction, and reads
  see the copy. File data is written in place right away.
- **Commit.** When the call ends (`FileSystem.Ext.Transactions`) the
  blocks go to the log after a descriptor block, followed by a revoke
  block if needed. Then the disk is flushed, the commit block written and
  flushed again; from then on the change survives a crash. Then the blocks
  are written in place. Because data was written before the flush, a
  committed file never points at stale data.
- **The log** holds transactions one after another and is reset to its
  start when the next one does not fit. Recovery replays everything since
  the reset, so freeing a block that is in the log adds a revoke record:
  the old metadata copy must not overwrite whatever the block holds now.
  While the log holds anything, the superblock carries the needs-recovery
  feature and the journal superblock names the log's start. Syncing or
  unmounting empties the journal and clears the mark; the kernel syncs
  every volume before `test-exit` leaves the emulator.
- **Recovery** (`FileSystem.Ext.JournalRecovery`) runs when a writable
  volume that needs it is mounted. It makes three passes: scan for the
  last valid commit, collect revoke records, replay the logged blocks.
  The volume is then mounted afresh. A volume mounted read-only is not
  replayed.
- **Formats** (`FileSystem.Ext.JournalFormat`): plain journals and
  journals with v3 checksums (CRC32C on every descriptor, revoke and
  commit block and on every logged block), 32 or 64-bit block numbers, and
  escaped blocks that start with the journal's magic number.
  `FileSystem.Ext.Journal` switches on the revoke feature, and 64-bit
  block numbers on 64-bit volumes, as Linux does. Version 1 superblocks,
  v1 and v2 checksums, fast commits and external journals are replayed
  where possible, but the volume stays read-only.
- **Limits.** A call that changes more blocks than a transaction holds (a
  quarter of the log, at most 2048 blocks) commits part way, so a crash in
  between can leave it half done (as Linux does for long truncates).

The flush is a new I/O request, `IoFunctionFlush`. AHCI sends it as FLUSH
CACHE EXT, and `FlushBlockDevice` sends it to the disk holding a
partition. The disk statistics filter counts flushes.

`make test` builds a GPT test disk (`scripts/make-test-disk.sh`) with one
partition per format and the same files on each. The kernel reads every one
of them (`Kernel.FileSystemTest`), then writes to each one
(`Kernel.FileSystemWriteTest`). The writing only happens with the kernel
option `fstest`, which the main test passes; other boots leave test
volumes alone, since the write test changes them and leaves journaled
ones read-only until the next boot (the simulated crash below).
Afterwards `scripts/verify-test-disk.sh`
checks every partition on the host with the format's own consistency
checker and reads the written files back through independent
implementations.

The ext3 and ext4 partitions are built needing journal recovery: debugfs
leaves committed transactions in their journals (plain on ext3; v3
checksums and 64-bit block numbers on ext4). These hold a replayed block,
a block logged and then revoked, and an escaped block, which the kernel's
read test checks after the replay at mount. Each write test ends with a
simulated crash (`SimulateCrashAfterNextCommit`): its last rename is
committed but never written in place. The host checks that the rename is
only in the journal, replays it with `e2fsck`, and requires the result to
be clean. That checks the kernel's journal format, revoke records
included, against e2fsprogs. The system disk, written by the user mode
tests, must pass `e2fsck` too.

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

Device memory is mapped into a process with `CallMapHandle(Handle,
Offset, Length)`: the handle's driver says which physical memory that is
and whether writes may be combined (the I/O function IoFunctionMap), and
the pages go into a region of their own, mapped at once, writable if the
handle was opened for writing. The program unmaps it with
`CallFreeMemory`. The page table entries of device pages carry a
software bit (MappingDevice), so neither unmapping nor destroying the
address space hands them to the page allocator, and the kernel never
reaches them through its physical memory window. Write-combining is the
page attribute table's entry 4, which the kernel sets at start (and
every processor takes on as it starts or wakes).

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
`FPC_THREADVAR_RELOCATE` with an offset stored in the variable. Until the
first thread starts they are plain globals; then the runtime's thread
manager (`rtl/fpc/systhrd.inc`) hands out the offsets from the program's
`FPC_THREADVARTABLES` (which covers every unit the program uses, those in
libraries included) and gives each thread a zeroed threadvar block, kept
in the runtime word of its control block.

Initialization code runs in user mode. The kernel collects the
initializers (DT_INIT, then DT_INIT_ARRAY) of the program and its
libraries, dependencies first, and the finalizers (DT_FINI_ARRAY in
reverse, then DT_FINI) in the opposite order, and passes both lists in the
auxiliary vector (`AuxiliaryInitializers` and friends). The System unit
runs the initializers, then the unit initialization sections listed in
the program's `INITFINAL` table (the compiler orders it by unit
dependencies, across libraries), then the main block; at exit it runs the
exit procedures, the unit finalization sections in reverse (`Sys.Streams`
flushes its buffers in its own) and the finalizers. Symbols stay bound eagerly when the program is loaded; there
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

### Controlling threads

A thread can suspend, resume and end other threads of its process and
set their priorities (`Processes.ThreadControl`; `CallSuspendThread`,
`CallResumeThread`, `CallTerminateThread`, `CallSetThreadPriority`,
`CallGetThreadPriority`). As with stopping or ending a process, a request
only marks the thread and alerts it; the thread acts at its next safe
point - a system call or interrupt returning to user mode: a suspended
thread waits until it is resumed as often as it was suspended (a system
call it was waiting in runs again), a thread asked to end exits as if it
had called `CallExitThread`. A busy loop is caught by the clock interrupt.
A thread's priority is its process's (from the nice value) plus an offset
of -15 .. 15, kept when the nice value changes; only root may raise a
thread above its process. The runtime's `SuspendThread`, `ResumeThread`,
`KillThread`, `ThreadSetPriority` and `ThreadGetPriority` use these calls.

### Processor exceptions

A processor exception in user mode that the kernel does not resolve
itself (demand paging and copy on write are resolved) is passed to the
program, as Windows does with its user mode exception dispatcher. The
runtime registers a dispatcher at startup (`CallSetExceptionDispatcher`).
The kernel (`Processes.UserExceptions`) writes a `TAbiExceptionRecord` -
the exception code (access violation, integer divide, invalid
instruction, x87 or SIMD floating point, alignment, ...), the faulting
instruction and address, the access kind, and every register - onto the
thread's stack below the red zone, and lets the thread continue in the
dispatcher with RDI pointing at the record, as if the faulting
instruction had called it. System's `SysDispatchException` reports with
`CallExceptionDispatched`, maps the exception to Free Pascal's runtime
error (216 access violation, 200 integer division, 208 float division,
205/206/207 float overflow, underflow and invalid operation, ...), resets
the floating point unit for floating point exceptions, and raises the
runtime error: with SysUtils an exception try/except can catch
(`EAccessViolation`, `EDivByZero`, `EZeroDivide`, ...), without it the
program ends with "Runtime error 216" and that status. TThread catches an
exception escaping a thread (`FatalException`).

A **stack overflow** is caught the same way. The bottom of every stack
(64 KiB, a quarter of small stacks) is a reserve the page fault resolver
does not provide on demand. Touching it opens the reserve (the region's
`ReserveInUse`) and passes `ExceptionStackOverflow`, runtime error 202,
`EStackOverflow`: the record and the runtime's handling fit in the
reserve, and try/except blocks further up catch it. When the kernel is
the first to touch the reserve - copying a system call's data into a
buffer on the stack - it opens the reserve, lets the call complete and
raises the overflow as the call returns, with the call's result in the
record's context. Only the thread's own stack reserve is opened this
way. A frame larger than the reserve (Free Pascal emits no stack probes)
can jump past it, so its first touch lands below the stack region; a
fault there - in the stack's guard (or in no region), at or above the
stack pointer less the red zone - is taken for a stack overflow
too. The reserve is opened and the record goes at its top, as the stack
pointer is outside the stack; a system call writing into such a frame
fails (there is no memory) and raises the overflow as it returns. So
that such a frame never reaches other memory, every stack - the main
thread's and each thread's - has a 256 MiB guard below it: address
space recorded as a region of kind `RegionKindStackGuard`, so nothing is
ever placed there, but never mapped, never valid for the kernel's
accesses to user memory and free of cost. A thread's guard goes with its
stack. Once the thread's
stack pointer is 64 KiB above the reserve again - checked at every system
call, interrupt return and exception - its pages are given back and it is
armed for the next overflow.

**Continuing**: `CallContinue` (like NtContinue) loads a complete
register context - validated to lead back into user memory; of RFLAGS
only the arithmetic and direction flags are taken - and returns to user
mode there, through the system call's `iretq`. The runtime offers an
exception filter (`ExceptionFilter`, typed in `Sys.Exceptions`): it sees
every exception record before it becomes a runtime error, and if it
returns True the thread continues at the record's context, which the
filter may have changed (skip the instruction, fix a register).

The kernel ends the process instead (status 139, logged) when no
dispatcher is registered, when the record does not fit on the stack (an
overflow while the reserve is still open, which the log names) or when a
thread raises an exception again before its dispatcher reported - the
dispatcher itself failed. CR0.NE and CR4.OSXMMEXCPT are set, so unmasked x87 and SSE
exceptions arrive as #MF and #XM; Free Pascal leaves invalid operation,
division by zero and overflow unmasked. (QEMU's emulator does not raise
SIMD floating point exceptions; under KVM they arrive.)

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

### Objects for programs that work together

What a display server and its clients need from the kernel, as objects
behind handles (closed with `CallClose`, inherited, passed in messages):

- **Events** (`Objects.Events`): kernel events a program creates
  (`CallCreateEvent`, manual or automatic reset), sets and resets.
- **Timers** (`Objects.Timers`): an event signaled when a time comes,
  once or periodically (`CallSetTimer`), on the clock's 10 ms ticks.
  Deleting or re-arming one stops it safely: it is marked first, so its
  call does not arm it again, taken off the timer queue, and its
  deferred call taken off its queue or waited for if a processor is
  running it (`CancelDeferredCall`), twice.
- **Sections** (`Objects.Sections`): zeroed pages to share, mapped with
  `CallMapHandle` into each process that holds a handle (each mapping
  takes a reference to every page, so the pages outlive the section's
  last handle while mapped).
- **Ports and channels** (`Processes.Channels`): a channel is a pair of
  connected ends; a message (up to 16 KiB and 8 handles) sent on one is
  queued at the other, at most 64 (then sending fails with
  `ErrorWouldBlock`: a server never waits for a slow client). The
  handles travel as references of their own (`TakeHandleReference`,
  which also counts a pipe end as open) and become handles of the
  receiver; a message never received gives them back. A server creates
  a named port (`CallCreatePort`); `CallConnectPort` makes a channel and
  leaves the other end waiting at the port for `CallAcceptConnection`.
  Receiving never waits: programs wait on the channel's handle.

`CallWaitForHandles` waits for the first of up to 64 handles to be ready,
with a timeout: an event or timer signaled, a process or thread ended, a
pipe's read end or a channel readable (data, or the other end gone), a
port with a connection waiting, a device with input (a driver may keep a
`ReadyEvent`: `/dev/events` does). Each stands for a notification event
kept in step with the object (pipes gained a `Readable` event for this,
apart from the synchronization event their readers wait on). The wait is
alertable, so ending or stopping the process ends it.

Underneath is waiting on several kernel events (`WaitForAnyEvent`): a
waiting thread is linked into each event's waiters by a wait block (on
its stack), and the first event to release it takes all its blocks off
and records which one it was; timeouts and alerts take them off the same
way. A single wait is the same with one block.

`Sys.Objects` in libsystem wraps all of it, with `CallChannel` for a
request and its reply. `ipctest` (run by coretest) checks every object,
the waits and timeouts, and a section shared with a second process: it
starts itself as a child that connects to its port, receives the section
and an event in a message, changes the section and signals the event.

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
Libraries are linked with `-Bsymbolic`, so references to their own
symbols are bound when they are linked and need no lookup (libsystem has
only RELATIVE relocations). Relocations are applied page by page.

Images are read once and kept as **image sections**
(`Processes.ImageSections`, up to 32, least recently used dropped first):
the file's bytes for the loader, and its memory image in physical pages.
A process maps a section's pages instead of copies: read-only pages are
shared, writable ones are copy on write. Physical pages carry reference
counts (`ReferencePhysicalPage`; freeing drops one); a copy on write page
is mapped read-only with a software bit in its page table entry, and the
first write - by the program, or by the kernel writing into the process
(relocations, system call results) - gives the process its own copy, or
simply makes the page writable if nobody else holds it. A section enters
the cache only once its pages are filled. The file system reports every
write to or resize of a file (`SetFileChangedHook`), which drops that
file's sections (one still in use by a load is marked stale and goes when
the load is done); the volume, node number, size and modification time are
also compared on every use.
`LoadLibrary` uses the same machinery for libraries opened at run time,
and `FindSymbol` looks a name up in a library and the libraries it needs.

The initial stack holds the argument count, the arguments, the
environment and an auxiliary vector (program headers, page size, entry
point, and the initializer and finalizer lists), as on Linux.

### The userland

Everything in user mode is Free Pascal, compiled with `-Cg` (position
independent) against the Free Pascal runtime library:

- **The runtime library** (in libsystem.so) – System, ObjPas, SysUtils,
  Classes, Math, TypInfo, Types, StrUtils, DateUtils, Variants, fgl,
  Contnrs, SyncObjs and the rest of the generic RTL, from the compiler's
  sources, with the operating system parts in `rtl/fpc` (see "The runtime
  library" below).
- **si_prc** – the `_start` entry point linked into each program; it
  passes the program's unit tables and the initial stack to System.
- **libcryptography.so** – digests (`Crypto.Md5`, `Crypto.Sha1`,
  `Crypto.Sha256`, `Crypto.Sha512`, `Crypto.Blake2b` behind
  `Crypto.Digests`), `Crypto.Hmac`, `Crypto.Checksums`, `Crypto.Aes`,
  `Crypto.ChaCha20` and `Crypto.Random`. Every algorithm is checked
  against its published test vectors.
- **libsystem.so** – `Sys.Kernel` (one wrapper per system call),
  `Sys.Memory` (the runtime's heap: one heap per process), `Sys.Streams`
  (buffered standard input, output and error), `Sys.Format` (printf style),
  `Sys.Text`, `Sys.Files`, `Sys.Processes` (PATH search, start, wait),
  `Sys.Environment`, `Sys.Time`, `Sys.Libraries`, `Sys.Information`,
  `Sys.Display` (the display device: its framebuffer mapped, its size,
  format and DPI),
  `Sys.Locks` (user-mode locks and atomic operations) and `Sys.Threads`
  (creating, waiting for and ending threads, through the runtime's thread
  manager). The heap is thread safe; buffered output is not synchronized.
- **libdrawing.so** – drawing in memory: `Drawing.Colors` ($AARRGGBB,
  blending in exact integer arithmetic), `Drawing.Rectangles`,
  `Drawing.Regions` (areas of rectangles that do not overlap: adding,
  subtracting and intersecting, for clipping and for what needs
  drawing again), `Drawing.Surfaces` (pixels of one's own or someone
  else's, such as a framebuffer), `Drawing.Canvas` (a surface, a clip
  region and an origin; fills, outlines, copies and blends of surfaces,
  gradients), `Drawing.Shapes` (Bresenham lines with both ends, ellipses
  and polygons filling the pixels whose centres are inside) and
  `Drawing.Bevels` (raised and sunken edges, the focus frame). Every
  shape is drawn as horizontal spans through one routine (`FillSpan`),
  which clips them and blends translucent colours. It needs only the
  runtime library.
- **libfont.so** – text: `Font.Psf` (PSF1 and PSF2 bitmap fonts with
  their Unicode tables), `Font.Utf8` (decoding, one U+FFFD for every bad
  sequence), `Font.Text` (font sets; a face picked by point size and DPI,
  the tallest not taller than asked; measuring and drawing) and
  `Font.Files` (reading the system's fonts, Terminus in heights 12 to 32,
  regular and bold, from `/lib/fonts/terminus` with its licence). Sizes
  are in points, so text is the same size on any display.

  Both build on the host too, without `Font.Files`: `make drawing-test`
  (part of `make test`) runs `tools/DrawingTest`, which checks colour
  arithmetic, regions, clipped fills, the exact pixels of lines,
  ellipses and polygons, copies, gradients, bevels, malformed UTF-8, a
  PSF1 font built by the test, and Terminus glyphs drawn pixel for pixel
  against their bitmaps, and writes a sample picture
  (`build/tools/drawing-sample.ppm`). On the system, `drawtest` draws a
  window on the display, everything sized by the display's scale and
  DPI; the input test checks it in a screen dump.
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

### The runtime library

User programs get the real Free Pascal runtime library: reference
counted strings, dynamic arrays, exceptions, classes and interfaces,
variants, generics, text and typed files, threads, SysUtils, Classes and
the rest. The generic code comes from the compiler's source tree
(`FPC_SOURCE`, `/usr/lib/fpc/src` by default: `rtl/inc`, `rtl/x86_64`,
`rtl/objpas`, `packages/rtl-objpas`, `packages/rtl-unicode` and
`packages/fcl-base`); `rtl/fpc` holds what depends on this kernel:

- `system.pp` and its include files: `sysos.inc` (the system call and the
  mapping of Abi errors to `InOutRes`), `sysheap.inc` (memory for the heap
  manager), `sysfile.inc` and `sysdir.inc` (files and directories, for
  `Assign`/`Reset`/`Rewrite`, `BlockRead`, `MkDir` and so on),
  `systhrd.inc` (the thread manager: kernel threads, threadvars,
  recursive critical sections and events on the wait-on-address call) and
  `sysdl.inc` (`LoadLibrary`/`GetProcAddress` on the kernel's loader).
- `si_prc.pas` – program startup.
- `sysutils.pp` – files, directories, `FindFirst`, file dates, disks,
  time, environment, `ExecuteProcess` and error messages on the system
  calls; the Unicode string manager (`fpwidestring` with the root
  collation) is installed with it, so `AnsiUpperCase`, `AnsiCompareText`
  and friends handle every character.
- `classes.pp` and `tthread.inc` – Classes with the portable TThread.

System lives in libsystem.so, shared by the program and all its
libraries, but the compiler puts the unit tables (`INITFINAL`, the
threadvar and resource string tables) into the program. As for Free
Pascal's Windows DLLs, System is built with
`FPC_HAS_INDIRECT_ENTRY_INFORMATION`: `si_prc` collects the tables and the
initial stack into a `TEntryInformation` and calls `SysEntry`. Text is
UTF-8 everywhere (`DefaultSystemCodePage`, file names, the console).
Times are UTC. The runtime is checked by `rtltest` (strings, arrays,
exceptions, classes, generics, files, searching, threads, processes).

## Diagnosing hangs

With the kernel option `hangdump=SECONDS`, a system thread
(`Processes.HangWatch`) notes when processes start and end. If neither
happens for that long while user processes exist, it writes every user
thread to the kernel log - process, state, whether it waits on a list or
with a timeout, alertable, suspended, priority, last processor, run time,
where in the program it last entered the kernel (from the register frame
at the top of its kernel stack) and the system call it is in - and what
each processor runs. The tests set `hangdump=20`, so a hung
test run leaves its explanation in the log.

## The kernel debug shell

With the kernel option `kshell`, `Kernel.DebugShell` runs on the console
once the system is up, before the first program: `help`, `echo`, `ls`,
`cat`, `volumes`, `disks`, `ps`, `mem`, `cache`, `uptime`, and `exit` to go
on with the boot. It reads lines through the console like a program
(with line editing) and writes through the kernel debug output, so it
works on the serial port and the screen. The input test starts with a
few of its commands.

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
