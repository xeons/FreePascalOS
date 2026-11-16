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
`Objects.*`, `Processes.*`, `Io.*`, `Network.*`, `Drivers.*`, `Runtime.*`
and `Debug.*`. Architecture specific
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
4. **Kernel phase 1** (a system thread): starts the drivers and the
   system threads, runs the self tests (and the debug shell with
   `kshell`), then starts the first user program and waits for it.
5. **The first program** is the service manager (`/bin/servicemanager`),
   unless `init=` names another (the tests' `init=/bin/coretest`; a
   system volume without the manager gets `/bin/sh`). It starts the
   services of the boot mode: in graphical mode (the default) the
   display server, then the session (the login window, then the user's
   desktop) and a login on the serial console; in text mode
   (`mode=text`) a login on the console. See "Startup, services and
   sessions".

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
| 13    | `ClockLevel`          | clock (one-shot, per processor)              |
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
- Time slices of `QuantumTicks` clock ticks (100 Hz) rotate threads of
  equal priority. Timeouts and sleeps end when due, to well under a
  millisecond (see The clock and timers).
- The clock interrupt never switches threads itself. It requests the dispatch
  software interrupt (a self-IPI on the dispatch vector), which the APIC
  delivers as soon as the processor drops below `DispatchLevel`. The same
  mechanism handles a thread becoming ready at a higher priority.
- The dispatcher lock protects all scheduler state and wait queues. It is
  held across a context switch and released by the thread that runs next.
- Exited threads are put on a list and cleaned up by the idle thread
  (stack freed, object dereferenced).
- Processor time is taken at every switch (`Kernel.ProcessorTime`): each
  processor remembers since when its running thread runs, and the switch
  charges the time since then (in clock nanoseconds) to the thread it
  leaves and to the processor's busy time, or its idle time when it
  leaves its idle thread. So a thread's time is exact to the clock, not
  counted in ticks; reading it adds the run going on now. Where the
  clock tick finds the thread (user mode or the kernel) is counted per
  tick, and the exact time is split between the two in that proportion,
  rather than timing every system call and interrupt (see "Processor
  time and memory").
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

## The clock and timers

- **Time.** The kernel measures time with a fine clock from the HAL
  (`HalClockNanoseconds`): on x86-64 the time stamp counter, read on any
  processor without a lock (`Hal.TimeStampClock`). Its rate is measured
  at start against the interval timer, over 50 ms and together with the
  local APIC timer, so the two agree closely. Uptime, timers, timeouts
  and the tick count (`ClockTickCount`, in 10 ms ticks, which drivers
  still use for coarse deadlines) all come from it, in nanoseconds
  (`ClockNanoseconds`).
- **One-shot clock interrupts.** Each processor's local APIC timer runs
  in one-shot mode (`Kernel.Clock`). Every time it interrupts, it is set
  again for the first of three things on that processor: its next 10 ms
  tick, its first timer, and the first wake-up of the threads that began
  a timed wait there. Whoever adds an earlier due time on a processor
  asks for an earlier interrupt (`RequestClockInterruptBy`, interrupts
  disabled). A late interrupt counts every tick it missed, and the ticks
  keep to their schedule (each is due 10 ms after the last was due).
- **Why the tick stays.** A fully tickless clock would also have to
  stop the tick on idle processors and account time slices from
  timestamps at every switch (processor time already is). The tick is
  kept for those - time slices (`QuantumTicks`), the split of processor
  time between user mode and the kernel, the load averages - while
  everything that waits for a
  time is taken off the tick: it costs one extra interrupt per due time,
  is simple to get right, and gives timers and sleeps the precision of
  the APIC timer.
- **Timers** (`Kernel.Timers`) go on the queue of the processor that
  sets them; each queue has a lock its clock interrupt takes, and
  setting or cancelling also takes one shared lock, so that two
  processors changing the same timer cannot put it on two queues. The
  clock interrupt queues the expired timers' deferred calls.
- **Timeouts.** A thread waiting with a timeout goes on the sleep queue
  of the processor it began the wait on (under the dispatcher lock).
  That processor's clock interrupt requests the dispatch interrupt when
  the first is due, which wakes the threads due and asks for the next
  wake-up's interrupt. A wake-up already due is left out when the
  interrupt is set again, so a processor kept above dispatch level for a
  while is not interrupted over and over.
- **Never early.** A timer or timeout due at T ends at T or later by the
  counter: the APIC timer is set a little long (rounded up, plus 1/1024),
  and an interrupt that still comes early only sets itself again.
- **Suspend to RAM** turns the counter off and may restart it from zero:
  the HAL pauses the clock before sleeping (`HalPrepareForSleep`) and
  continues it from the same time after waking, before any other
  processor runs, so the uptime leaves out the time asleep and every due
  time still holds. Each processor starts its clock interrupt again as
  it wakes (`StartClockOnThisProcessor` in `WakeEntry`).
- The counters of all processors are taken to run together, as they do
  on machines with an invariant counter and in virtual machines; under
  emulation (TCG) both the counter and the APIC timer follow the host's
  real time.

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
  processor has its own one-shot clock interrupt for its time slices, its
  timers and its threads' timeouts (see The clock and timers). When a
  thread becomes ready, an
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
  only after the run's request was answered. Calling it with interrupts
  disabled or above DispatchLevel is a panic, since such a sender could
  never answer a shootdown that started first. A request must also never
  get lost: in xAPIC mode an IPI is sent by writing the destination
  register and then the command register, and an interrupt in between
  that sends an IPI of its own (the clock asking for a dispatch
  interrupt) would redirect it, so `Hal.LocalApic` sends with interrupts
  disabled.
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
   (`RegisterUsbClassDriver`). Devices come and go while the system
   runs: a port whose connection changes raises a port status change
   event, which wakes the `UsbPorts` thread (`RunUsbPortWatcher`; it also
   looks at every port once a second, for polled controllers). A port
   that lost its connection has its device taken away: marked gone (its
   transfers fail, the one being waited for at once), its slot disabled
   and its class driver told (`UsbSetRemovalHandler`). A port that gained
   one is enumerated as at startup once the connection has settled
   (100 ms). The record of a device taken away is kept, since its class
   driver may still hold it. Transfers
   move through each device's DMA pages (64 KiB), and only events for the
   TRBs being waited for count. USB mass storage (`Drivers.UsbStorage`,
   Bulk-Only Transport) sends SCSI commands in command block wrappers:
   INQUIRY, TEST UNIT READY with REQUEST SENSE, READ CAPACITY(10),
   READ/WRITE(10) and SYNCHRONIZE CACHE(10). Each device becomes a disk of
   the `usb-storage` driver, whose requests run in the caller's thread,
   marked removable. Unplugged, its requests fail and its removal is
   announced (below). The tests attach a USB stick holding a copy of the
   exFAT test partition, and the input test plugs a second one in and
   out while the system runs.
4. **Partitions** (`Io.Partitions`) are read from GPT (with CRC checks) or
   MBR (including logical partitions) and registered as `disk1p2` etc. A
   partition device forwards requests to its disk with an offset.
5. **Device objects** for every disk and partition (`Drivers.DiskDevices`,
   see below).
6. **File systems** are mounted on every partition (and on disks without a
   partition table) by the first driver whose probe accepts it.

From then on a disk that arrives (a USB disk plugged in) goes through
steps 4 to 6 on its own (`Io.DiskArrival.AnnounceDiskArrival`): its
partitions are read, it and they appear in `/dev`, and their volumes are
mounted, as `/volumes/<name>` for programs. A disk that goes
(`AnnounceDiskRemoval`) is marked removed, so every read, write and
flush of it and its partitions fails at once; its volumes are taken away
(see "Volumes going away"), the block cache forgets it (dirty lines of
a removed disk are dropped, not written), and it and its partitions
leave `/dev` (`UnlistDevice`) and the list of block devices. The
objects stay, since the cache and the file systems may still hold their
addresses.

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
  (system calls copy through their transfer buffer). A device whose
  hardware went away (an unplugged disk) leaves `/dev` with
  `UnlistDevice`; the object stays, as handles and stacks may name it.

`Kernel.IoSelfTest` checks the asynchronous paths on every boot with a
test driver that holds its reads: completion from a deferred call,
completion routines, cancelling the request of an alerted thread, and a
filter on top of the test device.

The drivers so far:

| Driver | Devices |
|---|---|
| `memory` (`Drivers.MemoryDevices`) | `null`, `zero`, `full`, `random`, `urandom` (RDRAND, or a TSC-seeded xorshift without it), all `rw-rw-rw-` |
| `console` (`Drivers.ConsoleDevice`) | `console` and `tty` (which opens the program's controlling terminal, see "Pseudo-terminals"): reads and control requests go through the console's line discipline, writes to `Io.Console`; control requests get and set the modes, the size and the foreground group and take a pending Ctrl-C |
| `pts` and `ptmaster` (`Drivers.PseudoTerminalDevices`) | `ptsN`, `rw-rw-rw-`, made as pseudo-terminals are first needed: a terminal like the console; and an unnamed master device for each, opened only by `CallCreatePseudoTerminal` |
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
passed; the clock interrupt of the processor that set it expires it, as
soon as it is due (see The clock and timers). Drivers use
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
  0. if a process watches for shutdowns (`CallWatchShutdown`: the
     service manager), signals its event and waits up to 30 seconds for
     it to end, so the services stop in the reverse of their start
     order (see "Startup, services and sessions");
  1. asks every user process to end (reason shutdown, see
     "Notifications and requests to end": those that do not take it end
     at once with status 143), waits up to five seconds, then ends what
     is left and waits five more;
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
     callee-saved registers, stack, flags, FS and swapped GS bases, the
     priority level, FPU state, like `setjmp`) and halts.
   - The boot processor saves the I/O APIC entries, pauses the clock and
     saves its own state,
     points the waking vector at the start-up page (the trampoline that
     starts secondary processors) and writes the sleep registers.
4. Waking, the trampoline takes the boot processor to 64-bit mode and
   `WakeEntry`.
   - It reloads its page tables, descriptor tables (kept in memory; the
     TSS made available again), processor block, interrupt table, PAT
     and system call registers.
   - Its interrupt hardware comes back: the legacy PICs masked, the
     local APIC, the I/O APIC entries; the clock continues from where it
     paused and its clock interrupt starts again (each other processor
     starts its own as it wakes).
   - It resumes its saved state, then starts each frozen processor
     again (INIT, STARTUP), which resumes inside its dispatch interrupt.
     The priority level (CR8, which a woken processor has at 0) comes
     back with the rest: a processor resumed in its dispatch interrupt
     goes on at dispatch level, holding the dispatcher lock and perhaps
     switching threads. At level 0 a clock interrupt there would start
     the dispatch interrupt again on top of itself, waiting forever for
     the lock its own processor holds, and every other processor after
     it.
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
     AC'97's codec and list; the serial port; the PS/2 controller; each
     Bochs display's mode registers (the mode it had, the firmware's or
     one a program set) and the console redrawn from its copy.
   - **Services:** block I/O open again; audio volumes set again and
     capturing restarted.

`suspend` (root only, `CallSuspend`) and the kernel debug shell's
`suspend` start it. The input test suspends a machine with AHCI,
virtio, NVMe and USB disks and HD Audio, AC'97 and USB audio, wakes it
(`system_wakeup`), then reads every disk raw, writes and reads back
files on three volumes, plays a tone on each sound output (recorded and
checked) and checks the display. `make suspend-stress`
(scripts/stress-suspend.py, not part of `make test`) suspends and wakes
the same machine over and over (ROUNDS, 30 by default), waking it at
once, after a moment or after two seconds, and with POINTERS=1 checks
the PS/2 mouse and USB tablet after each wake; a wake that does not
come back is reported with each processor's registers, local APIC and
stack.

`make aml-test` also checks the sleep states (S3, S4, S5 on both QEMU
machines) and the GPE methods the tables have. The input test plugs a
processor in, which raises GPE 2: the `_E02` method notifies the new
processor's device, which the kernel logs. It then presses the power
button (`system_powerdown`) and expects the programs to end, S5, and
QEMU exiting by itself with status 0. coretest checks that `poweroff`,
`reboot` and `halt` refuse anyone but root.

### Ctrl-C

Processes belong to process groups (inherited, or a new group led by the
new process). Every terminal - the console and each pseudo-terminal -
has a foreground group. When a terminal's interrupt key mode is on (the
default; `stty -isig` turns it off), Ctrl-C does not reach the input
buffer: the terminal notes it (`Io.LineDiscipline`) and a deferred call
wakes the `terminal-signals` system thread (`Io.TerminalSignals`,
`Processes.TerminalSignals`), which asks every process of that
terminal's foreground group to end with the reason "interrupt", except
processes that asked to ignore it: a process that takes that request
(see "Notifications and requests to end") is told and decides itself,
any other ends with exit status 130. If it asked none (an interactive shell waiting at its prompt
is the foreground), Ctrl-C is passed to the reader as a character, and
the shell's line editor clears the line. The interactive shell runs each
foreground pipeline in a new group and makes it the foreground group
while it waits. While the shell itself is busy (a loop made only of
builtins) nobody reads the character; the terminal also remembers that an
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
starts its timeout again). Terminal and pipe transfers therefore report an
alert as "interrupted", not as end of file or a broken pipe. A process
outside the foreground group of its controlling terminal that reads that
terminal stops its own group instead (like SIGTTIN); the restarted read
succeeds once a shell has made it the foreground. The interactive shell
starts each foreground pipeline with `GroupNewInForeground`, so the new
group is the terminal's foreground group before its first program runs
(handing it over afterwards would let a quick reader stop itself).

The shell keeps a job table (`Shell.Jobs`): every background pipeline,
and every foreground pipeline stopped by Ctrl-Z, with the process handles
of its programs. `jobs`, `fg`, `bg`, `wait` and `kill` with `%N` are in
`Shell.JobBuiltins`; `fg` hands the terminal's foreground group to the job
while it waits. Finished jobs are reported before the next prompt, and
stopped jobs are ended (status 129) when an interactive shell exits.
`ps` shows stopped processes as `T`.

### Pseudo-terminals

A pseudo-terminal is a terminal that a program shows (a terminal window)
instead of the screen. What makes a device a terminal is its **line
discipline** (`Io.LineDiscipline`), shared by the console and every
pseudo-terminal: the input ring (filled from any level, dropping what
does not fit, or from a thread that waits while there is no room), line
editing with echo (Backspace takes back a whole UTF-8 character),
character-at-a-time reading, Ctrl-D as end of file, the interrupt key
mode (Ctrl-C and Ctrl-Z noted for the signal thread, see "Ctrl-C"), the
pending interrupt, the modes, the window size and the foreground group,
readiness events for waiting (`Readable`: a read would not wait;
`InputRoom`: typing would not wait) and the hang-up. Echo goes to the
terminal's output routine: the kernel log's outputs for the console
(`Io.Console`), the master's output buffer for a pseudo-terminal.
`Io.TerminalRequests` handles reads and the console control requests
for any terminal device (`ControlGetConsoleMode` to
`ControlSetConsoleSize`, and `ControlGetTerminalNumber`); every terminal
device points at its line discipline (`TDeviceObject.Terminal`).

`CallCreatePseudoTerminal(TerminalAddress, Size)` takes a pair from the
pool (`Io.PseudoTerminals`: up to 16, made as first needed, reused once
both sides are closed; devices are never removed) and fills a
`TAbiPseudoTerminal`:

- `OutputHandle` and `InputHandle`: the master side (an unnamed device
  of the `ptmaster` driver) opened for reading and for writing, so each
  can be waited on for what it is for. Reading gives what programs
  wrote to the terminal, echo included, as written (a line feed stays a
  line feed: the program showing it goes to the start of the next line,
  as the console does); it waits for some, and gives end of file once
  every handle to the terminal side is closed. Writing types into the
  terminal through its line discipline, so Ctrl-C written there
  interrupts its foreground group; a write waits only while nothing
  fits, then stops where the ring is full, so a writer that waits for
  the handle to be ready never blocks. (A device handle opened only for
  writing is ready when its device's `WritableEvent` is signaled.)
- `TerminalHandle`: the terminal side, `/dev/ptsN` (rw-rw-rw-), told to
  programs as a console (`HandleKindConsole`), so the shell, its line
  editor, `stty`, `less` and the rest treat it exactly like the console.
  Programs' writes wait while the master's 16 KiB buffer is full (a
  window that stops reading holds its programs up, as a slow screen
  would); echo that does not fit is dropped.
- `Number`: N.

`Size` is the window size (rows shl 16 or columns; 0 for 25 by 80). The
program showing the terminal sets the size with `ControlSetConsoleSize`
on either side when its window changes; programs ask with
`ControlGetConsoleSize` (`stty size`), and a change is told to the
processes of the terminal's foreground group that selected
`NotifyTerminalResized` (through the signal thread). The shell's line
editor simply asks before every line.

Closing the last master handle hangs the terminal up: readers of the
terminal get end of file, writers `ErrorIo`, it cannot be opened again,
and the signal thread asks every process whose controlling terminal it
is to end with the reason "hang-up": those that do not take it
(interactive shells included) end with status 129 (128 + SIGHUP).

**Controlling terminals.** A process has one (`TProcess.ControllingTerminal`,
a terminal device), inherited from its parent; the first program's is
the console. `CreateProcess` with `GroupNewInForeground` starts the
child in a new group that is the foreground group of its controlling
terminal from the start: if the child's standard input is a terminal,
that terminal becomes its controlling terminal (and its children's).
That is how a terminal window starts its shell (`StartOnTerminal` in
`Sys.PseudoTerminals`), and how the interactive shell starts its
foreground pipelines. The controlling terminal is what `/dev/tty`
opens, whose foreground group decides whether reading it stops a
process (reading another terminal never does), and whose hang-up ends
the process. Userland never assumed the console: the shell and job
control use the terminal on standard input; `tty` prints `/dev/ptsN`
there (`ControlGetTerminalNumber`), and `stty rows N cols N` sets the
size.

`ptytest` (run by coretest) checks the two sides (a console and not,
the number, the size set on the master and seen on the terminal,
readiness for reading and for typing, a program writing through
`/dev/ptsN`, an edited line read in line editing mode with its echo),
then an interactive shell on the terminal typed into through the
master: the echo and output of a command, `tty` and `stty size`,
`/dev/tty`, `cat` in line editing mode ended by Ctrl-D, Ctrl-C ending a
`sleep` (status 130), the hang-up ending the shell (129), and a second
pseudo-terminal reusing the first whose master reads end of file once
its program is gone.

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

**Keyboard layouts and the key repeat.** These tables are the system's
only ones: the console and the display server's input both type through
them, so a layout is chosen in one place, the kernel. The boot's comes
from `keymap=`; while the system runs, `CallSetKeyboardSettings` (root
only; `CallGetKeyboardSettings` and `CallDescribeKeyboardLayout` for
anyone, `Sys.Keyboard` in libsystem) chooses another and the key
repeat. A new layout is built in a spare table and then made the active
one, so a key typed meanwhile sees one whole layout or the other. The
repeat (`Drivers.KeyboardRepeat`: a delay of 250 to 1000 ms and 2 to
30 repeats a second) is the PS/2 keyboard's own typematic setting
(command 0xF3, the nearest it can do), sent with the lights through
one little command machine: one command of two bytes at a time, each
byte answered by an interrupt, a change that comes meanwhile waiting for
it (`Ps2RunInTurnWithInterrupts` starts a command from a system call in
turn with the interrupt). USB keyboards send no repeats yet. On the
screen the layout is the user's: the display server (root) changes it
for any program (`RequestSetKeyboardSettings`, see below), as it does
the mouse's settings; `keyboardsettings [-r] [-d DELAY] [-s RATE]
[LAYOUT]` (`-l` lists the layouts) goes through the server when one
runs, and otherwise to the kernel, as root only.

The PS/2 keyboard and mouse share the controller's one output byte:
whichever interrupt comes takes every waiting byte and hands each to its
device by the status bit (Ps2ServiceController, under a lock), as an
interrupt that finds the other device's byte first cannot count on the
other interrupt coming (the line may stay raised, and both can run on
two processors at once). While a driver sets the controller or the
mouse up by polling (Ps2BeginPolling .. Ps2EndPolling: the keyboard's
controller configuration, the mouse's setup, at start-up and after
waking), the interrupts leave every byte for the poller: the
controller's own answers come marked as the keyboard's and raise its
interrupt, which, on another processor, could take the answer first and
make the setup fail. Ending, the bytes that came meanwhile are handed
on, as their interrupt has come and gone.

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
program: the display the firmware showed the boot on. Other displays
are `/dev/display1`, `/dev/display2` and so on. One program opens a
display at a time. Opening the first takes the screen from the text
console, which goes on drawing into its copy of the screen only
(SuspendConsoleDrawing); closing it, however the program ends, gives
the screen back and the console draws itself again from the copy.
A kernel panic takes it back too.

Control requests give the size, the pitch (bytes per line), the pixel
format (blue-green-red or red-green-blue in a LongWord), the physical
size in millimetres, the DPI and the scale; they list the display's
modes (`ControlDisplayGetModeCount`, `ControlDisplayGetMode`, each a
width and height at 4 bytes a pixel, smallest first) and set one
(`ControlDisplaySetMode`). The framebuffer is mapped into the program
with `CallMapHandle` (offset 0), its writes combined; after a new mode
it is mapped again. `Sys.Display` in libsystem wraps all of it
(OpenDisplay with a display's number, CloseDisplay, DisplayModeCount,
DisplayModeAt, SetDisplayMode, DisplayPixel).

A display driver describes each display it has (a `TDisplayAdapter`:
the framebuffer and its memory, the mode it has, its EDID, the largest
mode and a routine to set one) and `RegisterDisplay` makes a device of
it. Drivers.Displays finds them at start: the first is the firmware's
framebuffer, driven natively if a driver knows its adapter, else used
as it is in the one mode the firmware set; then every other adapter a
native driver finds.

The native driver is Drivers.BochsDisplay: QEMU's standard VGA,
secondary-vga and bochs-display (PCI 1234:1111). Each device is a
display of its own: its framebuffer is BAR 0 (the video memory), and
BAR 2 has its EDID at the start and its "DISPI" mode registers from
0x500 (reached there rather than through the old I/O ports, which
bochs-display lacks and two devices could not share). A mode is set
with the display off: 32 bits a pixel, the size, a virtual width the
same (so the pitch is the width times 4), no offsets, then on with the
linear framebuffer. The largest mode is read with the "capabilities"
bit set. The device holding the firmware's framebuffer keeps the
firmware's mode; another starts in the mode its EDID prefers (else
1024x768).

The mode list (Drivers.DisplayModes) is the EDID's modes (detailed
timing descriptors, standard timings and established timings,
Drivers.Edid), the common sizes from 640x480 to 2560x1440 and the mode
the display has, each only if the adapter can make it (within its
largest width and height and its video memory). A display without a
driver lists only its mode.

A program may set any mode of the list while it has the display;
closing the display gives back the mode it had when opened. So the
console, which draws at the boot mode's size, finds that mode again
whenever it gets the screen back: resuming the console's drawing first
asks the display driver to set the boot mode if it was changed (a
routine Drivers.DisplayDevice gives Debug.FramebufferConsole), which
covers a panic too. The console never has to cope with another size.

The DPI follows the mode: the display's physical width from its EDID
(the device's own, else the one the firmware has: the loader copies the
base block from the EDID active or discovered protocol into the boot
information) against the mode's width in pixels; else 96. Drivers.Edid
takes the physical size from the first detailed timing descriptor (in
millimetres) or, without one, from bytes 21 and 22 (centimetres). The
kernel option `dpi=N` gives the first display's DPI at its boot mode
instead (other modes have it in proportion to their width). The scale
is the DPI against 96, to the nearest quarter, at least 100%: 96 DPI is
100%, 144 is 150%. Programs size what they draw in points and logical
units with them.

`display` prints what a display is like (`-d` picks one); `-l` lists
its modes; `-m WIDTHxHEIGHT` sets one while it runs; `-f RRGGBB` fills
the screen with a colour and a frame a quarter inch in. The input test
checks the DPI QEMU's EDID gives (325x203 mm at 1280 pixels: 100 DPI),
the colour and the frame in a screen dump while it runs, and the
console's screen after it ends; the mode list, a program setting
1024x768 (the screen dump is that size, the frame 20 pixels in at 80
DPI), the boot mode and the console back after it; and a second display
(QEMU's bochs-display, which has no firmware picture) driven natively
in the mode its EDID prefers.

### The display server

`displayserver` is an ordinary program that owns the display and the
input devices (the text console gives them up while it runs) and draws
the windows of the programs that connect to it. Its units are in
`userland/displayserver`; the protocol is `Windowing.Protocol` in
libwindowing.

A program connects to the port `display` and says hello; the server
answers with the screen's size, DPI and scale. Every message either way
is one fixed record (`TWindowMessage`). A window's client area is the
program's: a section of pixels it draws into, whose handle goes with
the request that creates the window (or, after a resize, gives it a new
surface); after drawing, the program names the rectangle it changed.
Positions on the screen travel in logical units, surfaces in pixels.

The server keeps the windows in stacking order, in three layers:
desktop windows (`WindowDesktop`, the shell's) at the bottom, then
ordinary windows, then topmost ones (the taskbar, pop-ups); raising a
window brings it to the top of its layer only. It draws their frames itself (a raised
bevel, a title bar with a gradient, the title in a bold face of the
theme's text family picked by point size and DPI, minimize, maximize
and close buttons; all sizes from the theme's metrics in logical units,
`Server.Theme`), and composes in a
back buffer: what needs drawing again is collected as a region (a window
moved, a program drew, the pointer moved), and only that is drawn, the
desktop, the windows from the bottom up and the pointer, clipped to it,
then copied to the framebuffer (`Server.Composer`, `Server.Screen`).

Input (`Server.Input`): the pointer moves the arrow (drawn at the
display's scale rounded to a whole number) and goes to the window under
it, in its surface's pixels, or to the window that captured it.
Pressing a button activates a window; on its frame it starts a drag:
the title bar moves the window live, a border or corner shows an outline
of the new size and asks the program for it when let go (it answers
with a new surface), the title buttons act when let go over them (close
asks the program, maximize fills the display's work area below the
title bar and back, minimize minimizes: see the shell below). A window dropped on another display takes its
scale. The title button under the pointer is drawn hot (a lighter
face), and pressed (sunken, its glyph pushed a pixel in) while the
button is held over it; moving off it lets it up, and letting go there
does nothing (`Server.TitleButtons`). A double click on a title bar
maximizes the window or restores it: two presses on the same title bar
within 500 ms by the input events' own times, a few logical units apart
at the window's scale (`Server.DoubleClicks`). Keys go to the active
window; Alt+F4 asks it to close. Events for a program are sent without
waiting, so one that stops reading cannot hold up the others; a program
that ends loses its
windows. Everything waits in one place: the input device, the port and
every client's channel in one `CallWaitForHandles`.

The mouse's settings (`Server.MouseSettings`): a speed (1 to 20; 10
moves the pointer as far as the mouse says) multiplies a mouse's
relative motion, and an acceleration (0 to 10) makes a fast movement go
further still (beyond 4 device units in one report every further unit
adds to the gain, up to four times the speed); what is left below a
pixel is carried to the next movement, so a slow speed still moves
smoothly. Left-handed swaps the left and right buttons of every pointing
device. A tablet's absolute positions are never changed. Any program
may read and change them (`RequestGetMouseSettings`,
`RequestSetMouseSettings`, answered with `EventMouseSettings`), as it
may the scale: they belong to whoever sits at the screen. They are a
user's settings (see "Settings" below): the server starts with the
system's, the session manager gives it a user's own when they log in and
the system's again when the session ends. `mousesettings [-r] [-s SPEED]
[-a ACCELERATION] [-l on|off]` changes them and prints them; `-r`
(`--remember`) also keeps them in the user's settings.

The keyboards' settings (`Server.KeyboardSettings`): the layout and the
key repeat are the kernel's (keys become characters there, for the
console too), and only root may change them; the server runs as root
and changes them for any program (`RequestGetKeyboardSettings`,
`RequestSetKeyboardSettings`, answered with `EventKeyboardSettings`:
the layout's name in Text, the delay and the rate), as it does the
mouse's: they belong to whoever sits at the screen. A layout the kernel
does not have leaves the layout as it was. They are a user's settings
too (`Keyboard/Layout`, `Keyboard/RepeatDelay`, `Keyboard/RepeatRate`,
`Windowing.KeyboardSettings`): the server starts with the system's
(over the machine's own: the layout `keymap=` chose, else US), the
session manager gives it a user's at login and the system's after the
session.

Remembered display settings (`Server.RememberedSettings`): a request to
change a display's scale or mode with the flag `DisplayRemember`
(`displayscale -r`, `displaymode -r`) has the server keep it in the
system's settings (`Display/N/Scale`, `Display/N/Mode`; a display's mode
and scale belong to the machine, whoever logs in). At start the server
sets each display's remembered mode, then its scale (a new mode brings
the display's own scale back, so keeping a mode forgets the scale kept
for that display), printing a line for each. Without the flag a change
lasts until the server ends, so the tests' many changes leave nothing
behind.

Pointer shapes: the arrow, the four resize arrows (left-right, up-down
and the two diagonals), a text beam and a busy hourglass
(`Pointer*` in the protocol). Each is a small pattern of black, white
and clear pixels with a hotspot (`Server.PointerShapes`), scaled by a
whole number like the arrow always was: the scale of the display the
pointer is on, rounded. They are read at start from
`/lib/pointers/NAME.pointer` (`Server.PointerFiles`): text files, so a
shape can be changed without building anything:

    ; comments start with a semicolon
    hotspot 8 4
        #       #
       ##       ##
      #.#########.#
     #.............#

Every line after the hotspot is a row: `#` black, `.` white, a space or
`-` clear. A missing or malformed file leaves that shape built in (the
built-in patterns are the same as the files `make-system-disk.sh`
installs from `userland/pointers`); the server says how many it read.
Which shape shows (`Server.PointerAreas`): over a frame the server's
choice, a resize arrow on the borders and corners of a resizable window
(and while one is dragged), the arrow elsewhere; over a client area the
program's (`RequestSetPointerShape`): a shape for the whole client area
(area 0) and up to 15 rectangles with their own (a higher area wins
where they overlap). The shape is worked out again before every
compose, so it follows windows that move under a still pointer.

Moving a window (`Server.WindowMoves`) copies what stays visible instead
of drawing it again: the old place's pixels that are up to date (not in
the damage waiting to be drawn, not covered by a window above) and land
where the window shows at the new place are copied within the back
buffer (a line at a time, in the order that never reads a pixel already
written: bottom up when moving down, from the right when moving right),
and only the rest of the old and new places is damaged. Each display
has its own back buffer, so this is done display by display, and only
for pixels that stay on the same display: what crosses from one display
to the other is drawn again. The pointer and a resize outline are drawn
over everything, so their places are damaged first and never copied.
The copied pixels go to the screen with the next compose
(`AddPresentOnly`). `displayserver --check-moves` draws every display
again after every compose that followed a move and compares it with
what the copy left, printing any difference and, after each title bar
drag, how many moves it compared.

Owned windows: a window can be created with an owner, another window of
the same program (the request's `Code`), and given another one later
(`RequestSetOwner`; never one it owns): if that leaves it below its new
owner, or in the wrong layer, it is raised. An owned window is always
above its owner: raising a window raises the windows it owns above it,
in the order they had (`RaiseWindow`), and one owned by a topmost window
counts as topmost. Hiding a window hides the windows it owns and showing
it shows them again; destroying it leaves them without an owner. A
program hears whenever one of its windows is shown or hidden
(`EventVisibilityChanged`), whoever did it: along with its owner, or
minimized by its title button. A window
can be disabled (`RequestEnableWindow`): the server never activates it
and sends it no input, the pointer over it being over no window; a press
on it, frame included, brings it forward and activates its topmost
enabled owned window instead (the dialog), and no drag starts. Disabling
the active window gives the keyboard to that window too, or to none.

Several displays (`Server.Screen`): the server opens every display
device (`/dev/display`, then `/dev/display1`...) and lays them out side
by side, left to right in their order, tops in line (other layouts can
come later). Each is composed in its own back buffer: the canvas's
origin puts desktop pixels where they fall in it, and each display gets
the part of the damage on it, so a window across the edge is drawn on
both.

The coordinate model (`Server.Desktop`): inside the server everything
(windows, the pointer, the damage) is in desktop pixels, where each
display has its rectangle. Programs give and are told places in logical
units of one desktop, where each display has its pixel size at its own
scale, laid out the same way: display 0 at 0,0, display 1 at display
0's logical width, and so on. A point is turned from one space to the
other by the display it is on (or the nearest, for a point off every
display): its offset from that display's top left is scaled by that
display's scale. So a place means the same spot on the same display
whatever the other displays do, and on one display it is the plain
conversion. A window is on the display that holds the middle of its
frame: its frame and title font are at that display's scale and DPI,
and so is the surface its program draws, even while part of it shows on
another display. Absolute pointing devices span the whole desktop (the
rectangle around every display); the pointer stays on the displays,
going from one to the next across their shared edge, and its shape is
at the scale of the display it is on.

The scale (`Server.Scale`): each display's starts as its own. A program
can ask for another, 100% to 400%, for any display (`RequestSetScale`
with the display's number; any program may, as a display's settings
would; `displayscale [-d NUMBER] PERCENT`): as if the display were that
much denser, the DPI goes with it (the display's DPI times the new
scale over its own). The server picks that display's title font again,
ends a drag, and lays the displays out again: every window keeps its
place on its own display, its offset from the display's top left in
that display's logical units (on the changed display its pixels move;
on displays to its right it moves with its display). The whole desktop
is damaged before the windows are placed again, so none of those moves
copies pixels drawn at the old scale. Each window on the changed
display is told its new scale (`EventScaleChanged` for that window,
with the display's size, the DPI and the scale) and its program gives
it a surface of the same logical size; a maximized window is maximized
again; every program hears where its windows are (`EventMoved`), and
when display 0 changed, every program hears that too
(`EventScaleChanged` for window 0: what new windows start at). A window
dragged onto another display, or moved there by its program, takes that
display's scale: its frame at once, and its program is told the same
way.

Modes (`Server.Modes`): a program can ask for one of a display's modes
(`RequestSetDisplayMode`; `displaymode [-d NUMBER] WIDTHxHEIGHT`; the
list with `RequestDescribeDisplayMode`, `displaymode -l`). The device
sets it, the display gets a back buffer of the new size and takes the
display's own scale and DPI at it (the DPI follows the mode), and
everything is laid out again as for a new scale; windows that would
hang off the display are moved onto it as far as they fit. The device
gives back the boot mode when the server ends. `RequestDescribeDisplay`
tells a display's size, scale, DPI and place on the desktop
(`EventDisplayDescribed`, which also answers the two requests that
change a display); `displaymode` alone prints every display.
`Windowing.Displays` in libwindowing wraps these requests.

The shell (`Server.Shell`): one program may register as the shell
(`RequestRegisterShell`, answered by `EventShellRegistered`; a second is
refused while the first lives). It hears about every top-level window
of the other programs (framed, owned by no window, not a desktop):
`EventShellWindowChanged` with its title, display, state (shown,
minimized, active, which counts its dialog having the keyboard,
maximized, resizable) and the process its program runs as (asked of
the kernel, `CallGetChannelPeer`, when the program connected),
`EventShellWindowGone` when it goes or is given an owner. Rather than every place that changes a window telling the
shell, the server compares each window with what the shell last heard
of it (kept in the window) once per turn of its loop and sends what
differs. `RequestManageWindow` activates, minimizes, restores,
maximizes or asks to close a window (`Manage*`): the shell's for any
window, any program's for its own (`TWindow.Minimize`, `Maximize`,
`Restore`) and for the top-level windows of the programs of its user
(root: of every program), which is how a task manager switches to one
(`Server.WindowList`). Minimizing is a state (`Server.WindowStates`): the window
is hidden with the windows it owns, its program hears it
(`EventVisibilityChanged`), and it stays in the shell's list as
minimized until shown again, by its program or the shell (activating a
minimized window restores it); a program hiding its window itself is
not minimizing. The shell hears `EventDisplaysChanged` when the
displays are laid out again.

Work areas (`Server.WorkAreas`): the shell keeps strips of a display
for itself (`RequestSetWorkArea` with the display's number and the
rectangle left, in logical units of the desktop). Each display keeps
them as the widths of the strips at its four edges, in logical units at
its scale, so they stay the same logical size when the scale or the
mode changes, as a taskbar does. Maximized windows fill the work area
(and are maximized again when it changes), a new framed window is moved
into it as far as it fits (only on a display with strips kept), and any
program can ask for it (`RequestDescribeWorkArea`, answered by
`EventWorkArea`; `DescribeWorkArea` in `Windowing.Displays`). Without a
shell, or when it ends, every display is whole.

Other programs' windows (`Server.WindowList`): any program may list the
top-level windows of the other programs of its user (root: of all;
another user's titles may say what that user is doing) with
`RequestListWindows`, answered by an `EventWindowListed` per window
(its title, state, display and process) and one for window 0 that ends
the list (`ListOtherWindows` in `Windowing.WindowList`).

Keys for the whole desktop (`Server.Hotkeys`): the shell may take a key
with the modifiers that must be held with it (`RequestRegisterHotkey`;
`RegisterHotkey` in `Windowing.Shell`). Pressed with exactly those
(Shift, Ctrl, Alt and AltGr compared, the locks not), it goes to the
shell as `EventHotkey` whatever window is active, and neither it nor
its release reaches a window, so no program sees half a key. The keys
go when the shell does. The desktop takes Ctrl+Shift+Escape for the
task manager.

Notification icons (`Server.Notifications`): any program may show a
small icon with a tooltip in the shell's notification area
(`RequestSetNotificationIcon`: its own number for the icon, shown or
taken away, a picture and the tooltip; `Windowing.Notifications`). The
picture is one the shell draws (`NotificationPicture*`: information, a
warning, the volume, the volume muted, the network), so no pixels
travel. The server
keeps the icons, numbered its own way since programs' numbers may
clash, passes them to the shell (`EventNotificationIconChanged`, all of
them when a shell registers) and drops a program's icons when it ends.

The protocol's numbers: requests 1 to 26 (hello to the window requests
up to `RequestSetScale` = 12; the display requests 13 to 15; then
`RequestSetOwner` = 16, `RequestSetPointerShape` = 17,
`RequestGetMouseSettings` = 18, `RequestSetMouseSettings` = 19,
`RequestRegisterShell` = 20, `RequestSetWorkArea` = 21,
`RequestDescribeWorkArea` = 22, `RequestManageWindow` = 23,
`RequestSetNotificationIcon` = 24, `RequestListWindows` = 25,
`RequestRegisterHotkey` = 26, `RequestGetKeyboardSettings` = 27,
`RequestSetKeyboardSettings` = 28), events 101 to 125 (up to
`EventScaleChanged` = 112; `EventDisplayDescribed` = 113,
`EventDisplayMode` = 114, `EventVisibilityChanged` = 115,
`EventMouseSettings` = 116, `EventShellRegistered` = 117,
`EventShellWindowChanged` = 118, `EventShellWindowGone` = 119,
`EventWorkArea` = 120, `EventDisplaysChanged` = 121,
`EventNotificationIconChanged` = 122, `EventWindowListed` = 123,
`EventHotkey` = 124, `EventKeyboardSettings` = 125).

`wintest` shows a window and prints what happens to it (its place, a
new scale, being shown or hidden; `-b` sets a text beam over its left
half, a pointer area; `-n` puts an icon in the notification area).
The input test starts the server (with `--check-moves`) and two of
them, and with the USB tablet (exact positions) checks the stacking and
the active title bar, the text beam over the pointer area, a drag by
the title bar, a resize by the corner, maximizing, the close button, a
key going to the window left active; then on that window the hot and
pressed title button (and that letting go off it does nothing), the
resize arrow over a border, a double click maximizing and another
restoring, drags partly off the screen and back with every move's
picture the same as a full redraw, left-handed buttons (a right click
arriving as button 1) and the speed doubling a PS/2 mouse's motion; and
the console getting the screen back when the server ends. QEMU there
has a second display (bochs-display, 1024x768) to the right of the
first, and the tablet spans both: the test sets the second to 150%,
drags a window across the edge (still checking every move against a
full redraw) and checks it in a screen dump of that display (HMP
`screendump FILE video1`, the device's id) at 1.5 times its pixels, and
that the program printed its new scale; then it sets the first display
to 1024x768 with a window near its right edge (the screen dump is that
size, the window moved onto it and told the new DPI, the other
display's window still there) and back to 1280x800. `ownertest` shows
three windows (one owned) and takes a step at each key: the input test
checks that a window hidden with its owner is no longer `Visible` in
its program and is shown again with it, and that a window given an
owner later stays above it when the owner is activated, and not once it
has none again.

### Windows and controls for programs

**libwindowing** is what a program uses to have windows. One connection
per program (`Windowing.Connection`: hello, the screen's size, DPI and
scale; `Scaled` and `Unscaled` between logical units and pixels;
replies waited for while other events are kept in order). A `TWindow`
(`Windowing.Windows`) is a class whose handlers a program overrides:
`Paint` (on its surface, clipped to what is invalid), keys, the pointer,
the wheel, `Resized`, `ScaleChanged`, `ActiveChanged`, `CloseRequested`,
`TimerFired`, `Moved` (the server moved it, or told its place after the
displays changed).
Positions given to it are logical units; what it is told is pixels.
`Invalidate` marks what needs painting; the message loop
(`RunMessageLoop`) paints before it waits and tells the server what
changed; a new size gets a new surface painted whole before the server
sees it. The loop waits on the server's channel, the posted message
event, the window timers (timer objects) and the program's own handles
(`Windowing.HandleWatches`: a pipe, a pseudo-terminal's master side, a
process; `WatchHandle` calls a handler whenever one is ready, after the
server's events are served) at once, and on the program's notifications:
once its loop runs, a program with windows takes requests to end
(asked, service stop, shutdown, log off) and handles one as if its user
had closed every window no other window owns (`Windowing.EndRequests`,
`AskWindowsToClose`: each gets `CloseRequested`, so Notepad asks to save
and the last window gone ends the loop). `OnEndRequested` replaces that
(the desktop simply ends; the session manager logs the user off first),
and `TakeEndRequests := False` leaves the requests to the system. A
request that comes while one is handled (a question on the screen) is
dropped.

A window can be given an owner when it is made, or later (`Owner`),
which it then stays above, and can be disabled (`Enabled`). A program
can change its window's size itself (`SetClientSize`: a new surface,
`Resized`, painted whole before the server shows it) and minimize,
maximize or restore it (`Minimize`, `Maximize`, `Restore`). `Visible`
follows what the server says (`VisibilityChanged`), so a window hidden
along with its owner, or minimized, is not `Visible`. `SetPointerShape`
and `SetPointerShapeInArea` choose the pointer's shape over the client
area (in its surface's pixels); a control has a `PointerShape` (the
edit boxes the text beam), which `TControlWindow` asks the server for
as the pointer moves over controls. Each window is at the scale and DPI
of the display it is on (`Scale`, `Dpi`); the scale used for converting
(`DisplayScale`, `DisplayDpi`, `Scaled`, `Unscaled`) is the one of the
window being served: libwindowing selects it before a window's handlers
run, before it paints, and before a queued message reaches it or one of
its controls (`TMessageReceiver.PrepareToReceive`, which a control
passes to its window). A new window starts at display 0's
(`DefaultScale`). When a window's scale changes (it moved to another
display, or its display's scale or mode changed) it gets a surface of
the logical size it had at the new scale: `ScaleChanged`, then
`Resized`, then painted whole before the server sees it. A control
window lays its controls out again
from their logical bounds in `Resized`, and fonts are picked by point
size at the DPI each time they are used, so nothing else needs doing;
a window that keeps something in pixels picks it again in
`ScaleChanged`.

`Windowing.Messages`: every window and control is a `TMessageReceiver`.
`DeliverMessage` calls its `ReceiveMessage` at once; `PostMessage`
queues the message for the loop from any thread (an event wakes it).
Codes below `MessageUser` are the libraries' (`MessageNotify`: a control
telling its parent something); programs number theirs from there. A
receiver that is freed takes its queued messages with it.

`Windowing.Theme` holds the colours and metrics (logical units), shared
by the display server's frames and the controls, and the font families:
the interface's text (`TextFamily`, DejaVu Sans, proportional) and a
monospaced one (`FixedFamily`, Terminus). `Windowing.Fonts` lists each
family once and picks faces from them at the display's DPI: the theme's
text face (`TextFace`, `BoldTextFace`, `FontFace`) and the monospaced one
(`FixedTextFace`, `FixedFontFace`), or either family by name
(`TFontFamily`: `FamilyFontFace`, `FamilyFaceSize`, `FamilyCaption`; a
system without the monospaced fonts gets the text family's). The
display server picks its title face from the theme's text family too. Text is drawn anti-aliased;
the multi-line edit box uses the monospaced face unless told otherwise,
so columns of text line up, and the console stays Terminus. The controls use anti-aliased
shapes where curves and slants show (the radio button's circle, a
checked menu item's dot, the message box signs, the list view's stock
icons, whose straight edges still fall on whole pixels) and scale a
program's own icons smoothly.

**libcontrols** builds windows out of controls. `TControl`
(`Controls.Base`) has a parent, children, bounds in logical units within
the parent (or a side to dock to, in the order they were made; one
docked to the client area fills what the others leave, whenever it was
made), and virtual handlers (paint on a
canvas whose origin is its own top left, clipped to it; pointer, wheel,
keys, focus, size); the `On...` events let code hook any control without
making a new class, and a control tells its parent what happened through
a `MessageNotify` message (also `OnNotify`). New controls are made the
same way as the library's. `TControlWindow` (`Controls.Window`) hosts a
tree of them: it paints them, sends the pointer to the control under it
(and to the one pressed until the button is let go: the server captures
the pointer for the window meanwhile), keys to the focused one (and up
to its parents until one uses them), moves the focus with Tab and
Shift+Tab, and presses the default and cancel buttons on Enter and
Escape. So far: label, panel, group box, button, check box, radio button
(one checked among its siblings), edit box (one line, UTF-8 by
characters, caret, selection, scrolling), progress bar, scroll bar,
slider (`Controls.Slider`: a value on a groove with tick marks, the
thumb put where the groove is pressed and dragged, the arrow keys,
Page Up and Down, Home and End; `OnRelease` once a drag ends, for what
is slow to apply) and status bar (`Controls.Text` draws text fitted
with "..."), list box,
multi-line edit box (`Controls.TextEdit`: positions are a line and a
character), combo box (its text always the chosen item's, also when the
items change under it), menu bar and pop-up menus (`Controls.Menus`),
toolbar, tab control, tree view (dotted lines joining nodes to their
parents and siblings, drawn a row at a time, as thick as the display's
scale makes a logical unit; a small stock icon before a node's text if
it has one; nodes taken away again with `DeleteNode`, the choice going
to the parent; `NodeAt` and `DropTarget` for context menus and drops),
splitter (`Controls.Splitter`: dragged to give the pane docked before
it another width) and list view. Controls that own children
place them in their `Layout` with `AssignBounds` (which, unlike
`SetBounds`, does not ask the parent to lay out again) and keep their
own children's notifications (a scroll bar's) out of `OnNotify` by
overriding `ReceiveMessage`.

**Context menus and dragging** belong to every control
(`Controls.Base`, `Controls.Window`). A right click, when the button is
let go over the control it was pressed on, and Shift+F10 or the menu key
for the focused control, call `ContextMenu` (`OnContextMenu`, with the
point in the control's pixels: the pointer's, or `KeyboardContextPoint`,
which a list view puts on its focused item). A control starts a drag of
some data while a button is held (`BeginDrag` with a `TDragData`:
`Controls.DragData`, text with a format naming it, "text" or
"file-list", and the control it came from); the window then owns the
data, and as the pointer moves asks the control under it, then its
parents until one answers, what a drop there would do (`DragOver`,
`OnDragOver`: nothing, copy or move, given the modifiers; asked again
when Ctrl or Shift change), tells the one that answered when the pointer
leaves it (`DragLeave`), and on the button's release hands it the data
(`DragDrop`, `OnDragDrop`) once the drag is over (so a drop may ask in a
dialog). Escape, or the window losing the keyboard, ends a drag without
a drop.

The list view shows its items (`Controls.ListItems`: texts by column,
an icon with a mark over it for a symbolic link, selected or not, a
pointer for the program) in four views:
details (columns under a header that can be clicked and resized), list
(names in columns flowing down, then across), small and large icons.
Every view is a grid of equal cells (`Controls.ListViewLayout`): one
per line in details; filled across, then down, for icons; down, then
across, in the list, which scrolls sideways. A "line" is a row of cells
or a column of them, so scrolling, the arrow keys and hit testing are
the same code in every view; `Controls.ListViewPainting` draws the
header and an item in each view (details rows with the small icons too
if `IconsInDetails`; under a large icon a name that does not fit takes
two lines, broken after a space, dot, dash or underscore where one is
in reach). Icons (`Controls.Icons`) are the program's own surface,
stretched to the size the view and the display scale need, or a stock
icon drawn as shapes at that size: a text document, a folder, and in
`Controls.FileIcons` a plain file, a program, a fixed and a removable
disk, the home folder, the computer, and the arrow over a link's icon,
drawn on the design grid `Controls.PictureGrid` (the desktop's
pictures use it too).
With `MultiSelect` several items are selected (Ctrl+click toggles one,
Shift+click and Shift with the moving keys select from the anchor,
Ctrl+A all; `Selected[Row]`, `SelectedCount`); `ItemIndex` is the item
with the focus. `SortByColumn` sorts by a column's texts, as numbers
(the number a text starts with) or by `OnCompare`, and puts an arrow on
that column's header; `SortWith` takes any comparison. The sort is a
stable merge sort (`Controls.ListSorting`), so ties keep their order.
A right click asks for a context menu (`OnContextMenu`, when the button
is let go, so the release does not choose from the menu at once): on
an item not selected it first selects that item alone, so the menu is
about what was clicked; Shift+F10 asks for one at the focused item.
With `SortOnHeaderClick` a header click sorts (again: the other way).
Typing a name's first letters goes to it (`Controls.TypeAhead`: letters
typed within a second make a prefix, the same letter again steps
through the names starting with it). `EditItem` renames an item in
place: an edit box over its name (`Controls.ListEditing`, the name
without its extension selected), Enter or a click elsewhere takes the
new name (`OnEdited` may refuse it), Escape keeps the old one. A right
press selects the item under the pointer unless it is selected already
(the context menu is then for the selection). With `DragEnabled`, moving
the pointer four units with the button held on an item starts a drag
(`OnStartDrag` gives the data); a press on one of several selected items
keeps them all selected until the button is let go without a drag, so
they can be dragged together; `DropTarget` shows the item a drop would
go to.

A click with Ctrl or Shift is told by the modifiers: the display server
puts the keyboard's modifiers (from the newest key event) in every
pointer event, and libwindowing keeps those of the newest event
(`HeldModifiers`).

The edit boxes share the edit commands (`Controls.EditCommands`): Ctrl+X
or Shift+Delete cuts, Ctrl+C or Ctrl+Insert copies, Ctrl+V or
Shift+Insert pastes, Ctrl+A selects all, and a right click shows the
same in a context menu (when the button is let go, so the release does
not choose an item), greyed when they cannot be done. They go through
`Controls.Clipboard`: text in a store behind `ClipboardText` and
`SetClipboardText`. Files cut or copied are a file list on it
(`Controls.FileLists`), a text any program can read:

    file-list copy
    file:///home/user/notes.txt
    file:///home/user/My%20Pictures

The first line says what pasting does ("copy", or "cut": move the
files); each line after it is a file URI (RFC 8089: "file://", the
absolute path with every byte but letters, digits, "-", ".", "_", "~"
and "/" written as "%" and two hexadecimal digits). Reading also takes
plain absolute paths and skips empty lines; text without the header is
not a file list. Dragged files carry the same text (format
"file-list"). For now the store keeps the text in the program;
the system clipboard (step 8) will be a store that asks the display
server, set with `SetClipboardStore`, and the controls stay as they are.
A one line box pastes up to the first line break; the multi-line box
splits what it pastes into lines.

The multi-line edit box is three layers. `Controls.TextView` shows the
lines: in rows, one per line or, with `WordWrap`, as many as a line
breaks into at the box's width (soft breaks after the last space that
fits, a word wider than the box broken where it stops fitting:
`Controls.TextWrap`), scrolled by rows (the scroll bar, the wheel,
moving up and down keeping to one X; Home and End go to the ends of
the row), sideways without word wrap; in the face `SetFont` picks (a
family, a size in points, bold or not; the monospaced one at the
theme's size by default). `Controls.TextLayout` lays a line out as
libfont measures it, with tabs to stops every eight spaces' widths, and
draws a range of it; the view remembers how many rows each line takes
(laid out again only when the line, the width or the face changes) and
the line laid out last, and draws only what shows of a long line, so a
text of hundreds of kilobytes scrolls, finds and wraps at once.
`Controls.TextEdit` edits: every change goes through one place, which
records it (`Controls.TextUndo`: the text removed at a position and the
text put there) and sets `Modified`; `Undo` (Ctrl+Z) and `Redo`
(Ctrl+Y) go by groups: characters typed one after another (a word at a
time), Backspaces in a row, Deletes in a row, and anything else (a
paste, a line break, a replacement, every replacement of a "replace
all") alone; moving the caret starts a new group. `FindText` selects
the next match after the selection or the one before it, with or
without matching case (`Controls.TextSearch`; within a line, A to Z
matched to their small letters), `ReplaceNext` replaces the selected
match and finds the next, `ReplaceAll` replaces every one as one change
to undo, `GoToLine` moves there, `ReplaceSelection` inserts at the
caret, and `OnCaretMoved` tells where the caret went. Ctrl+Home and
Ctrl+End go to the ends, Ctrl with the arrows by words. Positions,
undo, wrapping and search are plain logic: `make text-test` (part of
`make test`) builds them on the host (`tools/TextTest`) and checks
UTF-8 positions, how changes group, where lines break and what is found.

Pop-ups (`Controls.Popups`: menus, a combo box's list) are windows
without a frame, topmost and never activated: the owner keeps the
keyboard and hands its keys to the open pop-up (`TControlWindow.Popup`);
the pop-up captures the pointer, so a press anywhere else dismisses it;
a pop-up is freed through a posted message, once its own events are
over. They are placed in screen units: the server tells a program where
its window is whenever it moves (`EventMoved`, `ScreenLeft` and
`ScreenTop`). In a chain of menus only the newest pop-up holds the
pointer and passes what happens over its parents and the menu bar to
them.

Pop-ups are owned by the window they open from. Opening one ends the
press that opened it in the owner (`TControlWindow.Popup`): the pop-up
holds the pointer, so that press never sees its release, and the
owner's moves after the pop-up closes go to the control under the
pointer again. `MeasurePopupMenu` and `PopupMenuItemTop` tell how big a
pop-up menu will be and where its items are, so it can be opened where
it fits (above a taskbar). Tooltips (`Controls.Tooltips`): a line of
text in a small box (`Theme.Tooltip`) without a frame, owned by the
window it describes and placed above the point it is about, kept on the
display; when to show and hide it is the caller's.

Dialogs (`Controls.Dialogs`): a dialog takes an owner, the window it asks
for: it is centred on it (on the screen without one) and stays above it.
`ShowModal` serves the program's windows in a nested loop (`RunModal` in
libwindowing) until the dialog ends, with it modal: the program's other
windows are disabled meanwhile (and enabled again after, before the
dialog is hidden, so the keyboard goes back to the owner), so the
server sends them nothing and a click on one brings the dialog forward,
while pop-ups (a combo box in the dialog) still work. Buttons made with `AddButton` end it with their
result; Enter and Escape press the default and cancel buttons.
Accelerators (`AddAccelerator`, Ctrl+M say) run before the focused
control sees the key. `ShowMessageBox` lays a message box out for its
text with a sign (information, warning, error, question: shapes drawn
at any size) and OK, OK/Cancel, Yes/No or Yes/No/Cancel, with an
optional owner. `ShowChoiceBox` is the same with buttons of the
caller's own (each as wide as its caption) and an optional check box
under the text ("do this for every file"), and tells the caller just
before it appears (`OnShowing`).

The common dialogs are built from the same controls, on a
`TCommonDialog` (`Controls.CommonDialogs`: OK and Cancel at the bottom
right, `Execute`, and `OnShowing` just before it appears; OK ends it only
if the dialog's `Accept` agrees). `Controls.FileDialog` has the open and
save dialogs (`ChooseFileToOpen`, `ChooseFileToSave`): the folder shown
(type another one and press Enter to go there), a list view of it
(`Controls.FolderListing`: "..", folders first, then the files that fit
the filter, with size and kind; a link shows as what it points to), the
file name box and a filter box ("*.txt;*.md", and "*"). A double click
or Enter on a row opens a folder or takes the file; OK takes what the
name box says: a folder is opened, a pattern becomes the filter, and
anything else is the file, relative to the folder or absolute
(`Controls.FileNames` cleans the path up as text). Open wants a file
that exists; save wants the folder to exist and asks in a message box
before replacing a file, and can start with a name in its box, selected
so typing replaces it. `Controls.FindDialog` has the find dialog (what
to find, match case, up or down) and the replace dialog (what to put
instead, Replace and Replace All): it stays open while the user finds
one match after another, its buttons telling the program (`OnFindNext`,
`OnReplace`, `OnReplaceAll`), which searches its own text and can say
it found nothing in a message box owned by the dialog. `Controls.ColorDialog` (`ChooseColor`) has a
grid of basic colours, a scroll bar and a number box for each of red,
green and blue kept in step, and a swatch of the colour.
`Controls.FontDialog` (`ChooseFont`; `ChooseFontOfFamily` also lets
the user pick the family, the proportional DejaVu Sans or the
monospaced Terminus) lists the sizes the family comes in at this
display's DPI (the faces have some pixel sizes
only; each is listed as the smallest whole, or else half, point size
that picks it, so no two entries look the same, found without reading
any face), bold or regular, and a sample drawn with the face a program
asking for that size gets (`Windowing.Fonts` lists the faces for it).

Mnemonics: an ampersand in a caption marks the next character as the
control's mnemonic ("&File", "&OK"; "&&" is an ampersand itself).
`Controls.Text` draws such captions without the marks and the mnemonic
underlined (right under the letter's feet at every size: the bitmap
faces carry no baseline, so libfont's `FaceBaseline` finds it under the
face's own H), measures them without the marks, and gives the caption as
shown (`TextWithoutMnemonic`) and its mnemonic in lower case
(`MnemonicOf`); buttons, check boxes, radio buttons, labels, group
boxes, tabs, tool buttons, menu headings and menu items draw with it
(a label of plain text, such as a message box's, turns it off with
`ShowsMnemonic`). Alt and a character (not with Ctrl or AltGr, which
type characters on some layouts), after the accelerators have had their
chance, picks the first visible, enabled control in tree order whose
`MatchesMnemonic` says yes; its `ActivateMnemonic` acts: a button
clicks, a check box or radio button is focused and toggled or checked,
a label or group box focuses the next control after it that takes the
focus (`FocusControlAfter`: a label "&Name:" made just before its edit
box), a tab control shows the page, and the menu bar opens that
heading's menu with its first item highlighted. In an open menu an
item's letter, with or without Alt, chooses it (or opens its submenu),
and Alt with a heading's letter moves to that menu. A window's menu bar
registers itself (`TControlWindow.MenuBar`, through `TWindowMenuBar`, so
the window need not know menus); F10, or Alt pressed and let go with no
key or click between (Alt+F4 does not count: the display server keeps
the F4 press, but its release still reaches the window), puts the bar in keyboard mode: the first heading is picked
and the bar takes the window's keys: Left and Right pick another
heading, Down, Up and Enter open its menu, a heading's letter opens
that one, Escape, F10, Alt again, a click or the window going inactive
leave. Escape in a menu opened from the bar closes it back to its
heading; Left and Right in a menu open the next heading's menu with its
first item highlighted. A menu's `OnOpening` runs just before it opens,
for the program to enable and check its items as things are now;
`AddItemAccelerator` makes a window accelerator that chooses an item
(after its menu's `OnOpening`, and only if the item is enabled then).

`controlsdemo` has one of each, and a swatch made in the program (a
`TControl` subclass that posts a message of the program's own when
clicked). The input test types into it, tabs, clicks a radio button,
the scroll bar and the swatch with the USB tablet, toggles the check box
with Alt+R and goes back to the edit box with the label's Alt+N, presses
Enter, and checks what it printed and the swatch's colour; it changes
the scale to 150% and back with `displayscale` and checks that the
window's client area became 1.5 times as many pixels (`controlsdemo`
prints its size in `ScaleChanged`) and the swatch is where its logical
place is at each scale. `controlstour` has the
rest (a menu bar, a toolbar, a tab control with a list box and combo
box, a multi-line edit box and edit boxes to copy and paste between, a
tree view and a list view with buttons for its views, message boxes);
it prints where its controls are on the screen, and the input test
clicks them there and checks what it printed: text copied with Ctrl+C
and pasted with Ctrl+V and from the context menu, the list view sorted
by a header click (as numbers), a Ctrl+click and a Shift+click
selection, and large icons (the stock document's lines on the screen;
a Ctrl+click needs a key held, so the test holds it through QMP).
`dialogtour` opens each common dialog from a button and prints the
choice, and where the dialog's controls are when it appears (and the
file dialogs' rows for each folder shown); the input test opens /etc
and takes passwd in the open dialog, types a name in the save dialog,
refuses to replace an existing file there, and picks a basic colour, a
size and bold.
It also chooses Help > About from the keyboard four ways (Alt+H and
Enter, Alt+H and the item's letter, F10 then Right and Down, Alt alone
then Right and Down).
Its message boxes are owned by its window: the test clicks the window's
title bar while one is open and checks that nothing in the window's
client area changed (the box is still above it), that its title bar
stayed inactive, and that Enter still went to the box.

`notepad` is the plain text editor (its units in `userland/notepad`): a
`TTextEdit` filling the window, titled with the file's name
("Untitled" for a new one), a menu bar (File: New, Open, Save, Save As,
Exit; Edit: Undo, Redo, Cut, Copy, Paste, Delete, Find, Find Next,
Replace, Go To, Select All, Time/Date; Format: Word Wrap, Font; View:
Status Bar; Help: About) with accelerators for the usual keys, and a
status bar with the caret's line and column. New, Open, Exit and the
close button ask first whether to save changes (Yes, No, Cancel). Files
are UTF-8 with lines ending in line feeds; a file whose first line ends
with a carriage return and a line feed is read with every such pair a
line feed and written back with them, so saving keeps its style (a byte
order mark is kept the same way); a file named on the command line that
does not exist yet is made when saved. It prints what happens (the
title, the file opened and its first line, saves, the caret's place,
undo and redo, matches, word wrap's rows, the answer to saving), and
the input test drives it from the keyboard: it opens /etc/passwd from
the command line, types at its end, undoes the last word and redoes it,
saves as /tmp/note.txt through the save dialog (reading the file back
over the serial shell), finds a word and finds it again with F3, wraps
a long line of a new document into rows (Home going to the start of
the caret's row), and on Exit cancels the question to save, then
answers No. Word wrap, the status bar and the font are kept in the
user's settings (`Notepad.Settings`, group `Notepad`) as soon as they
are chosen, and Notepad starts with them (it prints `settings word-wrap
on|off, status-bar on|off, font ...`); the input test turns word wrap on,
ends Notepad and checks that the next one starts with it on.

### The file manager

`files [FOLDER]` (`userland/bin/files.pas`, units in `userland/files`)
shows a folder (relative to the current one; the user's home without
one) in one window that goes from folder to folder:

- **The window** (`FileManager.BrowserWindow`): the menu bar, a
  toolbar (Back, Forward, Up; Icons, List, Details), an address box
  (type a folder and Enter; Ctrl+L or Alt+D), the places at the left
  beside the folder's items with a splitter between them, and a status
  bar (how many items; how many selected and their size). Going to a
  folder adds it to the history (`FileManager.History`). The title is
  the folder's name.
- **The places** (`FileManager.PlacesPane`, a tree view): home, the file
  system, and Volumes with each volume (label and name; a removable
  disk's icon for one that can be unplugged). It watches `/volumes`
  (`Sys.Volumes`): a disk plugged in appears at once, one unplugged
  goes, and a window showing a folder on it moves to the nearest folder
  above that is still there (or home), forgetting it from the history.
- **The items** (`FileManager.FolderView`, a list view): large icons
  with names (two lines for a long one), a list, or details (name, size,
  type, modified, permissions, owner), sorted by any column either way
  round, folders first (`FileManager.ItemOrder`), hidden files (names
  starting with a dot) on request. Items are read by
  `FileManager.FolderReading` (a link described by what it points to,
  with its arrow; a broken one as itself); their type and icon come
  from `FileManager.FileTypes` (folders, programs: an execute bit, text
  documents by extension, pipes, devices, other files by extension).
  The folder shown is watched: any program changing it has it read
  again (once for changes that come together, never under a rename in
  place), keeping the selection, the focus and the scrolling by name.
- **Opening** (`FileManager.Associations`, the one place that decides):
  a folder is shown; a text document (by its extension) opens in
  Notepad; a file with an execute bit that is an ELF program or starts
  with `#!` runs; any other file whose first 4 KiB are UTF-8 without a
  zero byte opens in Notepad; anything else says there is no program
  for it. `FileManager.Launching` starts the program in a process group
  of its own; "Open with Notepad" opens any file as text.
- **Commands** (`FileManager.CommandWindow`, from the menus, the keys,
  the context menus or the mouse): New folder ("New folder", "New
  folder (2)": `FileManager.ConflictNames`, put up for renaming at
  once), Rename in place (F2; a name with a slash, ".", ".." or one
  taken is refused with the reason), Delete (asked first, saying it is
  permanent: there is no recycle bin), Cut, Copy and Paste (file lists
  on the clipboard; after a paste of cut files the clipboard is
  emptied), Select All, Properties, Refresh (F5), and drag and drop:
  files dropped on a folder item, on the folder shown, or on a place
  move within a volume and are copied onto another, Ctrl copying and
  Shift moving (`FileManager.DropRules`; volumes are told apart by the
  file information's volume number). The keys that edit text act on
  files only while the items have the focus, so the address box keeps
  them.
- **Copy, move and delete** run one after another on a thread of their
  own (`FileManager.OperationRunner`, `FileManager.OperationWorker`),
  so the window stays usable. The worker counts what there is to do,
  then copies folders recursively and files in 64 KiB pieces
  (`Sys.FileCopies`), keeping permissions and times (and owners, for
  root) where the file system holds them, links as links, a folder's
  own permissions and times set after its contents; moves within a
  volume by renaming, onto another by copying and then removing what
  was copied whole; deletes everything below a folder, then the folder.
  A name already taken is a question (`FileManager.OperationQuestions`:
  the worker posts a message and sleeps on an event until the window's
  thread answers): Replace, Skip, Rename ("name (2).txt"), Stop, and
  "do this for every conflict"; a folder onto a folder merges, a copy
  into its own folder gets a numbered name without asking. An error
  (`FileManager.ErrorTexts`: no permission, the disk full, the volume
  unplugged...) asks Skip or Stop ("skip every error"). The progress
  window (`FileManager.ProgressWindow`, `FileManager.OperationProgress`
  shared under a lock) shows the file being done, a bar, files and
  bytes, and Cancel, which stops at the next piece (a file stopped half
  way is removed); it appears only once an operation has run for
  `Files/ProgressDelay` milliseconds. Closing the window, or a request
  to end, while one runs asks whether to stop it; Yes stops it and the
  window closes once it has stopped cleanly.
- **Properties** (`FileManager.PropertiesDialog`): name, type, location,
  size (a folder's added up by `FileManager.FolderSizeCounter` on a
  thread, the count running), link target, the three times, owner and
  group, and permissions as check boxes (read, write, execute for the
  owner, the group and others) that change the mode at once for the
  owner or root and are greyed for others. A volume's
  (`FileManager.VolumeProperties`, from its place's context menu):
  label, file system, where it is, removable, read only, size, free
  space with a bar.
- **Settings** (`FileManager.Settings`, group `Files`): the view, the
  order and hidden files as they are chosen; the window's place and
  size and the places' width when it closes; the progress window's
  delay.

It prints what happens (`folder PATH COUNT`, `selected N`, `view ...`,
`sort ...`, `refreshed`, `new-folder`, `renamed OLD NEW`, `copied N`,
`moved N`, `deleted N`, `question ...`, `properties ...`, `mode PATH
OCTAL`, `volume-added NAME`, `volume-removed NAME`, `folder-gone PATH`,
`error ...`) and where the things to click are (`place NAME X Y`). The
input test prepares a folder over the serial shell and switches views,
sorts by a header, opens a subfolder with a double click and goes Back,
makes a new folder and renames it with F2, copies a file with Ctrl+C and
Ctrl+V (the copy's digest the same), drags a file onto a folder (moved),
deletes one after the question, sees a file the serial shell makes
appear without a refresh, changes a permission in the properties (stat
reads the new mode), copies a folder tree onto the virtio disk's ext4
volume with the progress window (read back), answers Skip and then
Replace to a name already there, opens a text file in Notepad with a
double click (Notepad's title in the log), and asks it to end; and in
the USB hot-plug part sees the plugged disk among the places, opens it,
and sees it go (the window back at `/volumes`) when it is unplugged.
`make files-test` (part of `make test`) builds the plain logic on the
host (`tools/FilesTest`): paths, numbered names, the history, the order
and types of items, permission texts, what a drop does, file lists and
finding a name by typing.

### The terminal window

`terminal` (`userland/bin/terminal.pas`, units in `userland/terminal`)
is a window running the shell on a pseudo-terminal of its own;
`terminal` with no arguments opens one (`-x`, `-y` place it, `-e` runs
another program). Its parts:

- `Terminal.Session`: creates the pseudo-terminal, starts `/bin/sh` on
  it (`StartOnTerminal`: the shell's own group, its controlling
  terminal) and closes its own terminal handle. The message loop
  watches the master's output handle and the shell's process handle;
  what is typed waits in a buffer and goes to the input handle whenever
  it is ready, so a busy shell never holds the window up. When the
  shell ends, the output left is read and the window closes; closing
  the window closes the master side, which hangs the terminal up and
  ends the shell (status 129).
- `Terminal.Emulator`: a VT100/ANSI parser over UTF-8
  (`Terminal.Utf8Stream`, one U+FFFD for a broken sequence, also one
  split between two reads): bell, backspace, tab, carriage return, line
  feed as a new line; ESC 7/8, D, E, M, c; CSI cursor movement and
  positioning (A-H, a, d, e, f, `), erase in line and screen (K, J,
  J 3 for the scrollback), insert and delete lines and characters (L, M,
  @, P, X), scrolling (S, T) and scrolling regions (r), save and restore
  (s, u), SGR (`Terminal.Rendition`: bold, underline, reverse, the 8 and
  16 colours, 256-colour and RGB ones taken to the nearest of the
  sixteen), cursor position and status reports and the device
  attributes (answered through the session), `?25` (cursor shown),
  `?7` (wrap), `?47`/`?1047`/`?1049` (the alternate screen), and OSC 0
  and 2 for the window's title. Unknown sequences are read and dropped.
- `Terminal.Screen`: the cells (`Terminal.Cells`: a code point, palette
  colours or the defaults, bold, underline, reverse), the cursor with
  the VT100's pending wrap at the right edge, the scrolling region, and
  a scrollback of 2000 lines; resizing keeps the cursor's line on the
  screen (lines above it go to the scrollback, and come back when it
  grows).
- `Terminal.View`: a control drawing the cells in Terminus
  (`FixedFontFace`) at 11 points at the window's DPI (10x18 pixels at
  100 DPI), a block cursor (an outline without the focus), with a
  scroll bar; its size gives the rows and columns, which go to the
  pseudo-terminal (`ControlSetConsoleSize`). Keys become what a
  terminal sends (`Terminal.Keys`: characters as UTF-8, Ctrl+letters as
  control characters, Enter as CR, Backspace as DEL, the cursor and
  editing keys and F1-F12 as the console keyboard's escape sequences,
  Alt as an ESC first). The mouse selects (`Terminal.Selection`, kept on
  its text while output scrolls); Ctrl+Shift+C copies, Ctrl+Shift+V or
  Shift+Insert pastes (line ends sent as CR), and a right click offers
  Copy, Paste and Select All (`Controls.EditCommands`'s menu); the
  wheel and Shift+Page Up/Down scroll back, and typing goes back to the
  bottom. A bell flashes the view.
- `Terminal.Window`: the window holding them, 80 by 25 cells to start
  with; it prints its terminal, size and place, each new size, and how
  the shell ended.

The input test starts it under the display server, types
`echo terminal-ok > /tmp/term.txt` and Enter on the PS/2 keyboard (keys
go to the active window) and reads the file from the serial shell,
checks the window shows text in the terminal's colours, selects a word
of output with the tablet and copies and pastes it into a command,
resizes the window by its corner and checks that `stty size` in it
gives the rows and columns that fit, types `exit` (the window closes),
and closes a second terminal with Alt+F4 (its shell hung up, status
129). The size a terminal window has when it closes is kept in the
user's settings (`Terminal.Settings`: `Terminal/Rows`,
`Terminal/Columns`), and the next one starts at it (the second terminal
of the input test starts at the size the first was dragged to); the
text's size is `Terminal/FontSize` (tenths of a point, 110 by default).

### The desktop shell

`desktop` (units in `userland/desktop`) is the display server's shell:
it registers for the role through `Windowing.Shell` (`RegisterAsShell`;
the server's events about other programs' windows, the displays and the
notification icons reach `OnShellEvent` from the message loop, since
they are about no window of its own) and refuses to start while another
shell runs.

The desktop (`Desktop.DesktopWindow`): a desktop window (`WindowDesktop`)
covers each display, so it stays below everything else and is never
raised over a window, though clicking it gives it the keyboard. Its
wallpaper (`Desktop.Wallpaper`) is a drawn design: a night-blue sky
lightening downwards, a pale moon with a halo and three translucent
bands of rolling water, all anti-aliased, drawn once per size into a
surface of its own and copied from when the window paints. `-w IMAGE`
names a wallpaper image, kept for when libimage can read one (step 8).
On the first display the programs' icons (`Desktop.Programs`: Files, Terminal,
Notepad, Control Panel, Controls tour, Controls demo, Dialogs, Task Manager) stand in a grid of
equal cells in columns from the top left, all in logical units: a
picture above a caption, the selected one tinted with its caption on
the selection colour. A click selects, a double click (two presses
within 500 ms) or Enter starts the program, the arrow keys move the
selection. A program is started with `StartProgram` in a process group
of its own; one that is not installed, or cannot start, is reported in
a message box. The pictures (`Desktop.ProgramPictures`,
`Desktop.SmallPictures`) are the shell's own designs on a 32-step grid
(`Controls.PictureGrid`: rounded boxes, polygons, lines, discs and rings in
design units, scaled to the box with libdrawing's anti-aliased shapes).

The taskbar (`Desktop.Taskbar`): a topmost window that never takes the
keyboard, 30 logical units high along the bottom of the first display,
which the shell keeps out of that display's work area
(`SetWorkArea`), so maximized windows stop above it. It is placed again
(and the desktops too) when the server says the displays changed. The
Start button (`Desktop.StartButton`: a sunrise mark and a bold caption,
pressed in while its menu is open) opens the Start menu on the press
(`Desktop.StartMenu`: the programs, then Log off and Shut down, opened
just above the taskbar). Both ask in a message box, then ask the
session manager (`Windowing.Sessions`, see "Startup, services and
sessions"): Log off ends the session, Shut down turns the computer off
(the session manager is root; the user is not). A desktop started by
hand, with no session manager, ends itself to log off and calls the
system's shutdown itself. The window list
(`Desktop.WindowList`) follows the server's events; each window shown or
minimized has a button (`Desktop.TaskButtons`: a small window mark and
the title; pressed in on a lighter face, its title bold, for the active
window; the title greyed when minimized), the buttons sharing the room
between the Start button and the notification area, at most 160
logical units each. Since the taskbar never has the keyboard, a click
leaves the active window active: on its button it minimizes it, on
another's it activates that window (restoring it if minimized). A right
click, when let go, opens Restore, Minimize, Maximize and Close for that
window (each greyed when it cannot be done); a right click on the
taskbar itself opens a menu with the Task Manager (just above it).
Ctrl+Shift+Escape is a key the shell takes for the whole desktop (see
the display server's keys): it opens the task manager, or brings the
one the shell started forward if it still has a window (found by its
process in the window list), as the taskbar's menu does. The notification area
(`Desktop.NotificationArea`) is a sunken panel with the icons, left to
right in the order they came, and the clock (`Desktop.Clock`: HH:MM in
the local time of the system's time zone, `Sys.LocalTime`), checked
every second; a tooltip shows when the pointer has rested on an icon
for half a second. The shell shows one icon of its own through the same
interface as any program: the volume (`Desktop.VolumeIndicator`), the
default output's, looked at every second with the clock, a loudspeaker
crossed out when muted, its tooltip "Volume: 80%". A click on a volume
icon opens the volume control (`Desktop.VolumePopup`): a pop-up above
it, like a menu, with the volume on a slider and Mute, which act on the
output at once, and Settings..., which opens the Control Panel's Sound
page (`controlpanel sound`); when it closes, a change is kept by the
system settings service.

`desktop` prints what happens (`asking log off`, `logging off`, `task N STATE TITLE` and `task-gone N`
for the list, `started COMMAND`, `menu TEXT`, `context ITEM`, `clock
HH:MM`, `notification N TEXT`, `tooltip TEXT`, `hotkey task manager`,
`context task manager`, `volume-popup`, `volume N`, `mute on|off`,
`volume-kept N`) and where things are
(`place NAME X Y`: the Start button and menu items, the icons, the task
buttons and their menu's items, the clock, the notification icons). The
input test starts the server and the shell and checks the wallpaper on
both displays, the taskbar, the Start button, the clock and the volume
icon in screen dumps, that a second shell is refused; that a `wintest`
window gets a button (and its `-n` icon), that a click on the wallpaper
takes the keyboard from it and its button gives it back, that its
button then minimizes it (hidden, the program told) and restores it;
that maximized it is 1280x752 (the work area less its title bar) with
the taskbar still showing, and that its button's menu restores it; that
a new window low on the screen is moved up into the work area; that a
double click on an icon starts controlstour, whose button's menu closes
it; that the Start menu starts dialogtour and that Shut down asks first
(Escape says no); and that wintest's icon shows its tooltip and goes
when wintest ends.

### The task manager

`taskmanager` (units in `userland/taskmanager`) shows the programs, the
processes and how busy the system is, from the kernel's accounting
(see "Processor time and memory"). Each look (`TaskManager.Sampler`)
takes a snapshot of the processes and the system's usage and keeps the
one before: a process's CPU is the processor time it added over the
time that passed, out of all the processors (one of four kept busy is
25%, as task managers show it), a processor's the busy time it added
over all it added. Each look also adds a sample to one-minute histories
(`TaskManager.History`): all the processors, each one, the memory in
use. It looks every second; View > Update Speed offers twice a second,
every four seconds and paused, and Refresh Now (F5) looks at once. The
status bar shows the number of processes, CPU usage and memory in use.

- **Programs** (`TaskManager.ProgramsPage`): the windows the display
  server lists for it (`ListOtherWindows`: this user's programs, all
  for root) by title, with their state and process. Switch To (or a
  double click) activates one (`ManageWindow`); End Program asks its
  process to end (`AskProcessToEnd`) - a program with unsaved work asks
  what to do with it - and five seconds later, if it still runs, offers
  to end it outright, as it may have stopped responding.
- **Processes** (`TaskManager.ProcessesPage`): a list view with name,
  id, user, CPU, memory (private), threads, state and session, sorted by
  any column (the header; CPU, busiest first, to begin with; equal rows
  stay in id order so nothing shuffles at every look), several selected
  at once, brought up to date in place (rows of ended processes go, new
  ones come, the selection and focus stay with their processes). Only
  this user's processes are listed unless "Show processes from all
  users" is ticked. A right click (the list view's new `OnContextMenu`,
  which selects the row under the pointer first; Shift+F10 too) offers
  End (ask), End now (outright, `TerminateProcess` with status 137,
  after a confirmation), Stop and Continue (job control), Priority
  (High, Above normal, Normal, Below normal, Low: nice -10 to 10, the
  current one checked) and Properties (`TaskManager.PropertiesDialog`:
  everything the kernel says about the process). What this user may not
  do to another user's processes is greyed out; what fails anyway (only
  root raises a priority) is told in one message box naming each process
  and why (`TaskManager.ProcessActions`). The End Process button and the
  Delete key ask the selection to end.
- **Performance** (`TaskManager.PerformancePage`): a graph of all the
  processors, one for each processor, one of the memory in use
  (`TaskManager.UsageGraph`: a sunken field with a light grid, the
  newest sample at the right, the line and the area under it
  anti-aliased with libdrawing's new `DrawSmoothPolyline` and
  `FillSmoothPolygon`, all measured at the window's scale), and the
  numbers: processes, threads, up time, processors, context switches,
  and what the memory is used for.

The window's size, the tab, the sort column and order and the update
speed are kept in the user's settings (group `TaskManager`;
`TaskManager.Settings`). The desktop opens it with Ctrl+Shift+Escape,
from the Start menu and the taskbar's menu. It prints what happens
(`settings ...`, `tab NAME`, `process PID NAME CPU KB` for the first
rows after each look, `program WINDOW PID TITLE`, `cpu N% memory N%`,
`performance ...`, `graph NAME X Y W H`, `sort`, `asked PID`,
`ended-now PID`, `ended PID` once a process it ended is gone,
`stopped`, `continued`, `priority`, `properties`, `error TEXT`) and
where things are (`place NAME X Y`: the tabs, buttons, the first rows,
the context menu's items; told again if the server moved the window).
The input test opens it with Ctrl+Shift+Escape over two `burn` busy
loops (one ignoring requests to end) and a Notepad holding unsaved
text, and checks that both loops are at the top sorted by CPU, that
End asks the first and it ends, that the second stays when asked and
End now (confirmed) ends it, that the Performance tab's processor graph
moves on from one screen dump to the next, that the Programs tab lists
Notepad, Switch To brings it forward and End Program makes it ask
about saving (No) and end, and that the taskbar's menu brings the task
manager forward and, closed with Alt+F4, it has kept its tab and size.

### The Control Panel

`controlpanel [PAGE]` (units in `userland/controlpanel`) is the
system's settings in one window: a list of pages on the left, the page
chosen on the right (`ControlPanel.Pages`: a group box that shows the
settings as they are, `Load`, and makes the changes chosen on it,
`Apply`), and OK, Cancel and Apply along the bottom. Apply can be
pressed once a page was changed, and applies every page that was; OK
does the same and closes the window unless a change failed; Cancel and
the close button forget what was not applied. PAGE (`display`, `mouse`,
`keyboard`, `sound`, `datetime`, `users`) opens that page first; the
Start menu and a desktop icon open it, the volume control its Sound
page. Everything is in logical units and points, so it looks the same
at every scale.

| Page | What it changes | How |
|---|---|---|
| Display | each display's resolution (its modes) and scale (100% to 300%) | the display server (`Windowing.Displays`); then "Keep these display settings?" counts 15 seconds down (`ControlPanel.KeepSettingsDialog`): Keep asks again with `DisplayRemember` (the system's settings), anything else - Revert, Escape, the time running out - sets them back |
| Mouse | the pointer's speed and acceleration, left-handed buttons | the display server, kept in the user's settings (`Windowing.MouseSettings`) |
| Keyboard | the layout (US, UK, German, French: the kernel's tables), the repeat's delay and rate, and a box to try them | the display server, which asks the kernel; kept in the user's settings (`Windowing.KeyboardSettings`) |
| Sound | each output's volume and mute, the default output | the system settings service, which sets and keeps them (anyone may); without it the outputs directly, for this boot |
| Date and Time | the time zone (from the database, with each zone's offset now), the date and time (a local time of the zone chosen) | the system settings service, as an administrator |
| Users | add a user (name, full name, password, administrator), remove one (with their home or not), a new password, the full name and groups | the system settings service (`Util.AccountChanges`), at once when each dialog is accepted (`ControlPanel.UserDialogs`) |

**Root's changes from a user's Control Panel.** The Control Panel runs
as whoever started it. What only root may change goes to the system
settings service (see "Startup, services and sessions"), which runs as
root, asks the kernel who connected and decides
(`ControlPanel.Administrator`): an ordinary user is asked once for an
administrator's password (root's, or their own if they are in `wheel`),
which goes with every request until the Control Panel ends and is never
written anywhere; their own password needs their present one instead.
No program is set-user-ID for this and no file is opened to others.

It prints what happens (`page NAME`, `applied ...` for each change,
`keep-asked SECONDS`, `keep-countdown N`, `kept`, `reverted`,
`password-asked TITLE`, `dialog TITLE`, `typed TEXT` for the keyboard's
try box, `user-added NAME`, `user-removed NAME`, `password-changed
NAME`, `user-changed NAME`, `refused CODE ERROR`, `scale P`, `closed`,
`cancelled`) and where its controls are (`place NAME X Y`). The session
test opens it from the Start menu as the ordinary user and, on the
Display page, keeps 150% (remembered, the taskbar half as high again in
a screen dump) and 100% again, and leaves a smaller mode unanswered
until it goes back; sets the mouse's speed (the display server has it);
chooses the German layout and types z, y and the a-umlaut key into the
try box and, in a terminal it starts, a command whose output shows the
German characters, then US again; sets the volume (the output and the
system's settings have it, the volume icon shows it); chooses
Europe/Berlin, root's password asked (`date` and the taskbar clock
follow); adds a user and gives them a new password (not asked again),
then logs in as them through the login window, and later removes them
with their home.

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

**Volumes, mute and the default output.** Each output's volume (its
hardware's, `ControlAudioSetMasterVolume`) can be muted
(`ControlAudioSetMute`): the mixer then writes silence, whatever the
amplifier can do, and the volume is kept for when it is unmuted (the
monitor input records the silence too: it is what plays). One output is
the default (`ControlAudioGetDefaultOutput`, `...Set`, asked of or set
on any output; the first until another is chosen): where programs play
that name no output, since libaudio's `OpenAudioOutput(nil)` opens it.
The kernel keeps only the number, and says what each output is
(`ControlAudioGetKind`: HD Audio, AC'97, USB audio). Anyone may change
these, as anyone at the machine could turn its knobs (the devices are
open to everyone); the system settings service keeps them in the
system's settings (`Sound/N/Volume`, `Sound/N/Muted`,
`Sound/DefaultOutput`) and gives them to the kernel at every boot.

In user space, `libaudio` holds `Audio.Device` (format, volume, writing,
draining), `Audio.Outputs` (the outputs there are, their volumes, mutes
and kinds, the default one), `Audio.Wave` (PCM WAV files) and
`Audio.Synthesis` (sine tones from a quarter-sine table and a fixed
point phase).

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
(an output's volume and mute, `-l` the outputs, `-D N` the default
output, `-r` keeping the change through the system settings service),
`voicetest` (the engine's tests) and `effecttest`
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

## Networking

A TCP/IP stack in the kernel (`kernel/network`, units `Network.*`),
beneath BSD-style sockets that are handles like any other.

```
  programs: Sys.Sockets, Sys.NetworkInterfaces     ping ifconfig route arp
=========== system calls 104-123 (Processes.SocketCalls, .NetworkCalls) ====
  Network.SocketOperations   bind listen accept connect send receive ...
  Network.Sockets            the socket object, readiness events, waits
  Network.TcpSockets | Network.Udp | Network.IcmpSockets
  Network.Tcp*  (connections, segments, input, output, timers, states)
  Network.Ipv4  Network.Fragments  Network.Icmp  Network.Routing
  Network.Arp   Network.Ethernet   Network.Loopback
  Network.Interfaces          (one per adapter; lo is number 1)
  Network.Core                the lock, the receive queue, the wake-ups
  Network.Thread              received frames and timers
=========== Io.NetworkAdapters (the driver interface) ======================
  Drivers.VirtioNet (and the e1000/e1000e/RTL8139 drivers)
```

**The adapter interface** (`Io.NetworkAdapters`). A driver registers each
card with `RegisterNetworkAdapter`: a `Transmit` routine (copies one
Ethernet frame, at dispatch level or below, never waits; False when it
has no room, and the driver later calls `NetworkTransmitReady`), a
`LinkUp` routine and the Ethernet address. The adapter is named `eth0`,
`eth1`... in the order of registration. Received frames come back
through `NetworkFrameReceived` from the driver's deferred routine (the
frame is copied there into a packet and queued), a changed link through
`NetworkLinkChanged`. Registering sets the network layer up the first
time (so the loopback interface is always first); frames that arrive
before the network thread runs wait in the receive queue. Drivers
handle their own suspend and resume and keep their adapter across S3.

**Threads and levels.** No protocol work is done in an interrupt or a
deferred routine: they only queue the frame (a spin-locked queue of at
most 512 packets; more are dropped and counted) or mark the interface
(`PendingEvents`, atomically) and signal the network thread's event.
The network thread (`Network`, priority 13) takes the frames a batch at
a time, sends what waited on the interfaces, and runs the timers. All
other protocol work runs on the threads of programs inside their
socket calls. Everything happens at passive level.

**Locking.** One mutex, the network lock (`Network.Core`), covers all
protocol state: interfaces, routes, the ARP cache, fragments, sockets
and connections. The network thread takes it per batch; each socket
operation takes it for its work and drops it while it waits
(`WaitOnSocket`). Drivers' `Transmit` is called with the lock held
(drivers never wait), so sending needs no queueing; the loopback
interface's "transmit" puts the datagram on the receive queue, so a
datagram sent to this machine is handled later by the thread and never
re-enters the protocols inside the sender's call. Lock order: process
lock, then network lock, then spin locks (the receive queue, drivers').
The DNS server list has a spin lock of its own. Timers: whoever needs
to be called by a time asks the thread for a wake-up
(`RequestNetworkWakeAt`); the thread sleeps until the earliest, then
runs the ARP, reassembly and TCP timer routines, each of which asks
again from its own state.

**Buffers.** A packet (`Network.Packets`) is one heap block with room
for a whole frame after 128 bytes of headroom: each layer on the way
down prepends its header without copying. Received data is handled in
place and copied only where it is kept: into a socket's datagram queue
(at most 64 datagrams or 128 KiB), into a TCP connection's receive ring
(64 KiB), or into a reassembly buffer. TCP keeps sent data in a 64 KiB
send ring until it is acknowledged and retransmits from there.

**Ethernet and ARP.** Frames for another station and multicast frames
are dropped. The ARP cache (64 entries) keeps an answer for ten minutes;
a datagram to an unknown neighbour waits on its incomplete entry (up to
8 per entry) while a request is sent once a second, three times; then
the datagrams are dropped and each local sender gets an ICMP host
unreachable (sent to itself through lo, so ping shows "Destination Host
Unreachable"). Requests for our address are answered and the asker
remembered; a new address is announced with a gratuitous request.

**IPv4.** Datagrams are checked (version, lengths, header checksum) and
taken if addressed to any of this machine's addresses (the weak host
model), to 255.255.255.255, to the arrival interface's subnet
broadcast, or - UDP only - to anything on an interface with no address
yet (what a DHCP client needs). Nothing is forwarded. Fragments are put
together (RFC 815: one buffer, a bitmap of 8-byte blocks, at most 8
datagrams at once for 30 s each). Nothing is sent in fragments: a
datagram larger than the interface's MTU (1500) fails with
`ErrorMessageTooLong`, and TCP sets "don't fragment". The routing table
(`Network.Routing`) has an interface route for each interface's network
(added and removed with the address) and routes added by hand (the
default gateway); a lookup takes the longest prefix on an interface that
is up, the lowest metric among equals. Datagrams to this machine's own
addresses go through lo; a broadcast goes out of the interface it
belongs to (the bound one, the subnet's, else the default route's).

**ICMP.** Echo requests are answered (not broadcast ones). Echo replies
and errors about echo requests go to the ICMP echo sockets with the
request's identifier; raw ICMP sockets get every message. Destination
unreachable and time exceeded about UDP or TCP go to the socket or
connection; errors are sent for an unknown protocol, a closed UDP port
and a failed ARP, never about an ICMP error, a broadcast or a later
fragment.

**UDP.** A datagram goes to the socket bound to its port that fits best
(bound to its address before bound to every address, a connected one
before an unconnected one); a broadcast to every socket bound to the
port; with none, the sender gets port unreachable. A connected socket
hears of a port unreachable that comes back (`ErrorConnectionRefused`
on its next call). Broadcasts need `SocketOptionBroadcast`.

**TCP** (RFC 793 with RFC 1122, 5681, 6298). Connections
(`TTcpConnection`) live apart from sockets: a listener makes a child in
SYN_RECEIVED for each SYN while the backlog has room (counting children
not yet accepted), and the child joins the accept queue when the
handshake completes; a connection outlives its socket while it closes.

- *Input* follows "Segment Arrives": the window check (an unacceptable
  segment gets an ACK), trimming to the window, a reset believed only at
  exactly the expected sequence number (RFC 5961), a SYN in the window
  resets, the acknowledgment frees the send ring and moves FIN_WAIT_1,
  CLOSING and LAST_ACK on, the send window is updated by the RFC 793
  rule, data in order goes to the receive ring and segments that arrive
  ahead (up to 32) wait to be joined, a FIN in order ends the stream.
- *Output* sends what fits in the smaller of the peer's window and the
  congestion window, in segments of at most the MSS (the peer's MSS
  option, or 536, never more than our MTU allows; ours is advertised on
  the SYN), then the FIN. Nagle holds back small segments while data is
  in flight unless `SocketOptionNoDelay`.
- *Retransmission*: one timer per connection while anything is
  unacknowledged; its timeout is the smoothed round trip plus four times
  its variance, at least 200 ms, at most 60 s, doubled on each expiry;
  one segment at a time is timed, never a retransmitted one (Karn). An
  expiry goes back to the first unacknowledged byte and drops the
  congestion window to one segment; three duplicate ACKs retransmit at
  once and halve it. After 12 expiries (5 for a SYN) the connection is
  given up (`ErrorTimedOut`). A zero window is probed with one byte on
  each expiry.
- *Congestion control*: slow start from ten segments, then congestion
  avoidance (a segment per round trip).
- *ACKs* of received data wait up to 40 ms, or go at once for every
  second segment, out of order data and FINs; reading that opens the
  window by two segments sends a window update.
- *Closing*: a socket closed with unread data resets the connection
  (RFC 2525); otherwise the FIN is sent and the connection finishes on
  its own. TIME_WAIT lasts 60 s (twice an MSL of 30 s); FIN_WAIT_2 of a
  connection without its socket ends after 60 s. A closed listener
  resets the children it had not handed out.
- Initial sequence numbers follow the clock (4 per microsecond) plus a
  random offset taken at start. No window scaling or SACK yet: windows
  are at most 64 KiB.

**Sockets** (`Network.Sockets`) are objects of type `Socket`, so
`CallClose`, inheritance, `CallDuplicateHandle` and passing them in
messages work as for any handle (`HandleKindSocket` = 14). A socket
keeps two notification events in step with its state under the network
lock: Readable (data, a connection to accept, the end of the stream, an
error) and Writable (room to send, or a connection attempt that ended).
`CallWaitForHandles` waits on Readable; `CallWaitForSocket` on either.
`CallRead` and `CallWrite` work on sockets (a receive or send without
flags). Deleting the socket (its last handle closed) closes it.

Who may open what: TCP and UDP sockets, and **ICMP echo sockets**
(`SocketKindDatagram` with `ProtocolIcmp`), are everyone's - an echo
socket can only send echo requests, the kernel puts the socket's own
identifier in each and fills in the checksum, and it receives only the
replies (and errors) for that identifier, so ping needs no privileges
and nobody can forge other ICMP messages or read anyone else's (as
Linux's ping sockets with `ping_group_range` open to all). **Raw ICMP
sockets** (`SocketKindRaw`) are root's: they send any ICMP message and
receive a copy of every one. Binding a TCP or UDP port below 1024 and
binding a socket to an interface (`SocketOptionInterface`) are root's.

| Call | Number | Arguments |
|---|---|---|
| CreateSocket | 104 | family, kind (stream, datagram, raw; or'ed with non-blocking), protocol |
| BindSocket | 105 | handle, address |
| ListenSocket | 106 | handle, backlog (1-64) |
| AcceptSocket | 107 | handle, peer address out (or 0); returns a new handle |
| ConnectSocket | 108 | handle, address (non-blocking: `ErrorInProgress`) |
| SendSocket | 109 | handle, buffer, length, flags, address (0: the peer) |
| ReceiveSocket | 110 | handle, buffer, length, flags (peek, don't wait), address out |
| ShutdownSocket | 111 | handle, receive / send / both |
| GetSocketOption, SetSocketOption | 112, 113 | handle, option (, value) |
| GetSocketAddress | 114 | handle, local or peer, address out |
| WaitForSocket | 115 | handle, readable / writable, timeout |
| ListNetworkInterfaces | 116 | buffer, capacity (`TAbiNetworkInterface`) |
| ConfigureNetworkInterface | 117 | `TAbiInterfaceConfiguration` (root) |
| ChangeRoute | 118 | add or remove, `TAbiRoute` (root) |
| ListRoutes | 119 | buffer, capacity |
| ListArpEntries | 120 | buffer, capacity |
| ListSockets | 121 | buffer, capacity (every socket, and connections without one) |
| GetDnsServers, SetDnsServers | 122, 123 | `TAbiDnsServers` (setting: root) |

Addresses (`TAbiSocketAddress`) carry a family, sixteen address bytes
(IPv4 in the first four, in the order written) and a port in the
machine's byte order, so IPv6 needs no new calls. Options: receive and
send timeouts, broadcast, reuse address, time to live, non-blocking, the
pending error (how a non-blocking connect ended), no delay, the kind,
the received time to live (ping shows it), the interface, the bytes
readable. Send and receive take five arguments; the dispatcher now
passes R8 on. The ABI is in `shared/Abi.Networking.inc`; the new error
codes (`ErrorConnectionRefused`, `ErrorAddressInUse`,
`ErrorNetworkUnreachable`...) take Linux's numbers. `CallGetTime`
gained `TimeUptimeNanoseconds`, for timing ping replies.

**Configuration.** Anyone may list interfaces (name, description,
Ethernet address, flags up/running/loopback/broadcast, MTU, addresses,
packets, bytes, errors and drops each way), routes, the ARP cache and
the sockets; only root may change an interface (address and prefix,
up/down, MTU), the routes or the DNS servers. The kernel keeps the DNS
servers and search domain only for the resolver to read, as it keeps
the time zone's name. Changes are written to the kernel log.

**Startup.** `Io.Startup` starts the virtio-net cards (the other
drivers register theirs alike); `Kernel.Startup` then starts the
network thread (`StartNetworking`). The **network service**
(`/etc/services/network.service`, `networksetup`) applies the static
configuration of `/etc/settings/Network.settings` (libconfiguration)
once at start: per interface (`[Interfaces/eth0]`) a method (`static`
or `none`), the address with its prefix, the gateway (the default
route) and whether it is up, and the DNS servers. The default suits
QEMU's user networking: eth0 10.0.2.15/24, gateway 10.0.2.2, DNS
10.0.2.3. A DHCP client will take over interfaces with `Method = dhcp`;
`NetworkSetup.StaticConfiguration` is the piece kept beside it.

**virtio-net** (`Drivers.VirtioNet`): a receive queue that always holds
a 2 KiB buffer per descriptor and a transmit queue of one buffer per
frame (a 12-byte virtio header in front, short frames padded to 60
bytes); no offloads. Both queues and configuration changes (the link
status) interrupt through MSI-X entry 0 (`ConnectVirtioQueuesInterrupt`
in `Drivers.VirtioPci`, which now also offers many chains at once and
takes each finished one back by its head); without MSI-X a 10 ms timer
polls. Suspending marks the card (its frames wait in the network
layer); waking resets it, gives it its queues and receive buffers again
(`RestartVirtioDeviceQueues`) and reports the link and room to send.

**Tools.** `ping` (an ICMP echo socket; per-reply lines and the summary
with loss and min/avg/max/mdev like iputils; `-c -i -W -s -t -q`; hosts
are looked up in one place, `Sys.HostNames`, numeric for now), `ifconfig`
and `route` in the manner of net-tools (rather than an `ip` tool: their
output is what most people know to read, and each does one thing), and
`arp`.

**Tests.** A kernel self test on every boot checks the Internet
checksum, sequence number comparison, a UDP datagram over lo, a refused
connection and a TCP connection's states from the handshake to
TIME_WAIT, with data both ways. coretest runs `networktest` (loopback
ping; UDP echo with the largest datagram and one too large; a refused
broadcast; port unreachable; a megabyte of TCP echo through many windows
with a sender and a server thread; a refused connection; non-blocking
connect and waits; the socket listing; then `networksetup` on eth0,
pings to and the ARP entry of QEMU's gateway, and a TCP echo through
QEMU's `guestfwd` to `cat` at 10.0.2.100:7), `networktest
--unprivileged` as an ordinary user (raw sockets, low ports, every
change refused; ping allowed), and `ifconfig`, `route`, `arp` and
`ping` command lines; the session test checks that the network service
configured eth0. The QEMU command lines of all tests and `make run`
have a virtio-net card on user networking.

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

**Advisory locks** (`FileSystem.Locks`), as flock gives them: a shared
or an exclusive lock on a whole file or directory, asked for with
`CallControlHandle` (`ControlLockFile` with `FileLockShared` or
`FileLockExclusive`, and `FileLockNoWait` not to wait;
`ControlUnlockFile`; `LockFile` and `UnlockFile` in `Sys.Files`). A
lock belongs to the open file - every handle duplicated from it - and
lasts until it is given up or the open file's last handle is closed, so
a program that ends gives its locks up. Any number of shared locks or
one exclusive lock; asking for the other kind first gives up the one
held. Locks only hold back other lock requests, not reads or writes. A
shared lock needs read permission on the node, an exclusive one write
permission, so programs that may only read cannot hold writers up. The
state lives with the node (shared by every open of it through the node
cache), made with the first lock and freed when nobody holds or waits
for one; one mutex covers every lock state. Waiting is alertable (an
ended program stops waiting, `ErrorInterrupted`); each release signals
a synchronization event that wakes one waiter, which looks again; one
let in to a shared lock passes the signal on. The request references
the open file while it runs, since another thread may close the handle
during a long wait. The settings library takes its writers' lock this
way (see "Settings").

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

### Watching for changes

Programs watch folders and files for changes (`FileSystem.Watches`,
`FileSystem.NodeTrails`; `CallCreateWatch`, `CallReadWatch`). A watch is
an object behind a handle of its own kind, ready for
`CallWaitForHandles` while change records wait in it, so a window
program's message loop waits on it like on any handle
(`Windowing.HandleWatches`).

- **What is reported.** The VFS reports every change once it worked,
  whoever made it and whichever driver carried it out, so every file
  system reports the same way: names created (files, folders, links,
  hard links, named pipes), removed and renamed (with both names), file
  contents written or resized (`WatchContents`), and permissions,
  owners and times changed (`WatchAttributes`). Moving a name into a
  watched folder is reported as created, out of it as removed. A watch
  asks for any of the three groups; with `WatchSubtree` a folder's watch
  also reports every folder below it, the names being paths from the
  watched folder (`sub/file`). Records about the watched item itself
  have an empty name: written, attributes, moved (renamed, and the
  watch follows it), removed (the watch ends), and its volume gone (the
  watch ends).
- **Finding the watch.** A watch knows its folder or file by node
  number, not by path: a path may go through a symbolic link, use
  another letter case on FAT and exFAT, or one of several hard links,
  and a folder above may be renamed while it is watched. Every name
  change is reported with the trail of its folder: the node numbers and
  names the path resolution passed through from the volume's root
  (`ResolveInVolume` fills it). A watch finds its node anywhere on the
  trail and takes the names below it for the record. FAT and exFAT
  number nodes by their directory entry, which a rename changes, so a
  rename reports the number before and after, and the watch follows.
  Trails are only built while some watch exists; an open file on a
  writable volume always keeps the trail of its node (a compact copy),
  since its writes are reported in the folder it was opened in, under
  the name it was opened by.
- **The queue.** Up to `MaximumQueuedWatchRecords` (64) records wait;
  when it is full the last place goes to an overflow record, and
  nothing else is queued until the program has read it: it must look
  at the folder again. A write or attribute change repeating the newest
  record waiting (a file written in many pieces) is not queued again.
  `CallReadWatch` moves whole records (`TAbiWatchRecord`: size, kind,
  flags, the name and for renames the old name) into the program's
  buffer and never waits.
- **Permission.** A watch needs read permission on what it watches
  (and search permission on the folders of its path, as any path does).
  A subtree watch reports names in folders below that the watcher could
  not list itself.
- **Volumes.** `/volumes` (the namespace root) is the list of volumes: a
  watch on it reports a volume arriving (created) and going away
  (removed), named after it; with `WatchSubtree`, everything on every
  volume. Devices under `/dev` are not files of any volume and are not
  watched (`ErrorUnsupported`).
- **Locking.** One mutex guards every watch; changes are reported with
  the volume's lock held, and watches are made with it held too, so a
  change cannot slip by between resolving the path and watching it.

`watchtest` (run by coretest) checks it with a shell making the changes
in another process, on the system volume (ext4) and on the FAT16,
exFAT and ext2 test volumes; `watch` prints the changes of any path and
`volumes -w` the volumes coming and going.

### Volumes going away

When a disk is unplugged, `FileSystem.Volumes.RemoveVolumesOfDisk` takes
its volumes off the list (they leave `/volumes`), marks each gone
(`MarkVolumeGone`: under the volume's lock, so it waits for the
operation running), and tells the watchers: watches on the volume get
"volume gone" and end, watches on the list of volumes "removed". From
then on every operation on the volume fails with `StatusVolumeGone`
(`ErrorNoDevice`, "No such device"), except closing: open files go on
existing until their programs close them. The driver's data is given
back (its `Unmount`) once no node of the volume besides the root is in
use (`TVolume.NodesInUse`), which may be right away or when the last
open file is closed. The volume record itself is never freed: open
files, named pipes and image sections name volumes by address, and none
of them must take a later volume for it.

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
| Files | Open, Close, Read, Write, Seek, SetFileSize, GetHandleInformation, GetHandleKind, ControlHandle (terminal modes and size) |
| Terminals | CreatePseudoTerminal (see "Pseudo-terminals") |
| Paths | GetPathInformation, ReadDirectory, CreateDirectory, Remove, Rename, CreateSymbolicLink, ReadSymbolicLink, CreateHardLink, SetPathAttributes, Get/SetCurrentDirectory, SetRootDirectory |
| Processes | CreateProcess, WaitForProcess (with a timeout), TerminateProcess, Exit, GetProcessId, CreatePipe, DuplicateHandle, Sleep |
| Threads | CreateThread, ExitThread, WaitForThread, GetThreadId, SetThreadPointer, WaitOnAddress, WakeAddress |
| Users and processes (50-69) | ListProcesses, GetCredentials, SetUserIds, SetGroupIds, SetGroups, SetUmask, GetPriority, SetPriority, CreateFifo |
| Job control | StopProcesses, ContinueProcesses, WaitForProcessChange |
| Notifications (91-93) | SelectNotifications, ReceiveNotification, RequestEnd (see "Notifications and requests to end") |
| Memory | AllocateMemory, FreeMemory |
| Libraries | LoadLibrary, FindSymbol |
| System | GetTime, GetSystemInformation, ListVolumes, Sync |
| Watches (94-95) | CreateWatch, ReadWatch (see "Watching for changes") |
| Processor time and memory (96-97) | ListProcessDetails, GetSystemUsage (see "Processor time and memory") |
| Clock, time zone, keyboard (98-103) | SetWallClock, GetTimeZone, SetTimeZone, GetKeyboardSettings, SetKeyboardSettings, DescribeKeyboardLayout (changes root only; see "Time zones" and the keyboard above) |
| Sockets (104-115) | CreateSocket, BindSocket, ListenSocket, AcceptSocket, ConnectSocket, SendSocket, ReceiveSocket, ShutdownSocket, Get/SetSocketOption, GetSocketAddress, WaitForSocket (see "Networking") |
| Network configuration (116-123) | ListNetworkInterfaces, ConfigureNetworkInterface, ChangeRoute, ListRoutes, ListArpEntries, ListSockets, Get/SetDnsServers (changes root only) |

There is no fork: `CreateProcess` starts a program directly, with an
argument list, an environment, a working directory, the three handles
that become the new program's standard input, output and error, and its
group (the caller's, a new one, one to join, or a new one in the
foreground of its terminal: `GroupNewInForeground`).

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

### Processor time and memory

What a task manager, `ps` and `top` show comes from the kernel's own
accounting, read with two calls.

- **Processor time.** Each thread's run time is charged at every switch
  (`Kernel.ProcessorTime`, see "Scheduling"): exact to the clock rather
  than to a 10 ms tick, so a thread that runs in short bursts between
  ticks is charged what it ran. The clock tick only samples where it
  finds the thread (`UserTicks`, `KernelTicks`), and the exact time is
  divided in that proportion (`SplitRunTime`), so user and kernel time
  always add up to the total. A process's time is its threads' plus
  that of the threads that ended (`EndedThreadTimes`, added under its
  thread list lock as each one is reaped, so nothing is counted twice or
  lost; `GetProcessTimes`). Each processor's busy and idle time (its
  idle thread's) is charged at the same switches; they add up to the
  time it has run.
- **A process's memory** (`Processes.AddressSpace`): the pages it has
  mapped (resident, `CommittedPages`), the ones among them shared -
  program and library pages mapped from an image section until written
  to (copy on write gives the process its own), and section pages -
  (`SharedPages`), and the most it ever had (`PeakCommittedPages`);
  private is resident less shared. The size of what it may touch is the
  sum of its regions, the stack guards left out.
- **The system's memory** (`Memory.PhysicalPages`): the page allocator
  counts the pages of each use as they change hands (`TPageUsage`: a
  process's own pages, program images, sections, the block cache, the
  kernel heap, kernel stacks, page tables, the kernel image, the
  loader's data and the page database, drivers' buffers), so the figures
  add up to the RAM there is.
- **`ListProcessDetails` (96)**: (Buffer, Capacity) fills up to Capacity
  `TAbiProcessDetails` - ids, users, state (running, waiting, stopped,
  ending), threads, handles, nice and priority, start time (wall clock
  and uptime), processor time (total, user, kernel), memory (virtual,
  resident, shared, private, peak), name, controlling terminal and
  command line (the arguments it was started with, which the kernel now
  keeps, joined by spaces) - and returns how many processes there are,
  so a caller with too little room asks again (`Sys.ProcessList` does,
  keeping its buffer for the next snapshot). The list is taken under
  the registry lock, each record copied straight to the caller. Anyone
  may list every process, as with `ps` on Unix; another user's command
  line is shown only to root (`ProcessDetailsCommandLineHidden`), since
  arguments may carry what a user typed. The old `ListProcesses` (50)
  stays, its time now from the same accounting.
- **`GetSystemUsage` (97)**: a `TAbiSystemUsage` - the uptime, every
  processor's busy and idle time and whether it runs, the number of
  processes and threads (the kernel's too), context switches, and the
  memory by use (`Processes.SystemUsage`).

`Sys.ProcessList` (snapshots, a process's share of the processors
between two of them) and `Sys.SystemUsage` (a processor's busy share
between two samples, the memory in use) wrap them. `ps` shows %CPU (the
processor time over the time since the process started, 100 for one
processor kept busy), `rss`, `vsz`, `time`, the real `tty` and the
command line (`args`; another user's shows as `[name]`); `top` the
busiest processes since its last look, again every few seconds (`-b`
batch, `-d` delay, `-n` count). `sysinfo` shows the system at a glance
beside a logo (units in `userland/sysinfo`: `SystemInfo.Facts` gathers,
`SystemInfo.Logo` holds the ASCII logo): user and machine, system and
kernel, uptime, the programs in /bin, the shell, each display (only if
the display server already runs: `ConnectToDisplay(False)` tries once
rather than waiting for one), the terminal, the processor's model
(`Sys.Processor`, from CPUID: the processor tells every program), the
memory and processes from `GetSystemUsage`, each volume's use and the
time zone; then the sixteen colours as blocks (the text console now
takes bright backgrounds, 100-107, as well). Colours only on a terminal
and without `NO_COLOR` (`-c` forces them, `-C` turns them off); `-l`
leaves out the logo. `usagetest`,
run by coretest, checks that a busy loop is charged about the time it
ran (at most the wall time, at least 40% of it, most of it user time,
the processors' busy time growing with it), that a sleeping program is
charged next to nothing, that ended threads leave their time in the
process and the thread count follows them, that memory taken from the
kernel and touched shows as resident and private and goes when freed
(the peak staying), that each processor's busy and idle time add up to
its run time and the memory figures to the RAM, and that a list given
room for one says how many there are; coretest also checks `ps`'s new
columns (a `burn` busy loop above 10% CPU with its 8 MiB resident) and
who sees whose command line. `burn` (threads spinning, memory taken
and touched, `-i` to ignore requests to end) is the busy program the
tests use.

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
shell reports a program killed by that signal. Ending a program outright
is the last resort: `kill`, the service manager, the session manager and
the shutdown first ask it to end (next section). Running processes are kept
in a registry so they can be found by id.

### Notifications and requests to end

There are no Unix signals: nothing runs code in a program behind its
back. Instead the system tells a process what concerns it through the
process's **notification queue** (`Processes.NotificationQueue`), which
the process waits on like any other handle: the pseudo-handle
`NotificationsHandle` (-2) in `CallWaitForHandles` stands for the
caller's queue, ready while a notification waits. A program's message
loop, a shell's prompt or a service's main wait simply includes it, and
reads what came with `CallReceiveNotification` (92), a
`TAbiNotification`: a kind, a reason, the sending process (0 for the
system) and a value. Two kinds exist:

| Kind | Reason / value | Sent by |
|---|---|---|
| end requested | asked, service stop, shutdown, log off, hang-up, interrupt | `CallRequestEnd`, the shutdown, a terminal's hang-up and Ctrl-C |
| terminal resized | rows shl 16 or columns | `ControlSetConsoleSize` on the process's terminal, to its foreground group |

A process **selects** what it takes itself (`CallSelectNotifications`
(91): a mask with a bit per end reason and one for the terminal's
size; a new program starts with none, so nothing is inherited). What it
does not select never reaches its queue: for an end request the kernel
acts for it, and ends it at once with the reason's status - 143, 129
for a hang-up, 130 for Ctrl-C - exactly what happened before
notifications existed. So old programs, programs without a loop, and
programs that are stuck all behave as they always did, and the choice
is made in the kernel (`Processes.EndRequests`) rather than by a
handler thread in every program's runtime. A notification of the same
kind and reason as one still waiting is merged into it (the newer sender
and value win), so a queue of 16 never overflows and a sender never
waits. The queue's ready event is kept in step with its contents under
its spin lock.

**Asking to end.** `CallRequestEnd(TargetKind, TargetId, Reason)` (93)
asks a process (0: the caller), every process of a group or of a
session (0: the caller's; the caller itself is left out) to end, and
returns how many were asked. The permission is the one for ending a
process: the same user, or root; other users' processes are skipped,
and a request that reached nobody for that reason fails with
`ErrorNotPermitted`. A process already being ended counts as asked. A
process that took the request decides: it may tidy up and end (with a
status of its own), ask its user, or carry on - nothing waits for it
forever, since whoever asked may still end it outright
(`CallTerminateProcess`, `CallTerminateSession`) after waiting long
enough, as the service manager, the session manager and the shutdown
do. The terminal's signal thread uses the same routine: Ctrl-C asks the
foreground group (reason interrupt; processes that ignore interrupts
are spared, and if nobody was asked the reader gets the character), a
hang-up asks every process the terminal controls (reason hang-up), and
a new size is told to the foreground group's processes that selected
it. A stopped process that took a request acts on it once continued.

**In libsystem.** `Sys.Notifications`: `TakeNotifications` and
`LeaveNotifications` (it remembers the mask, so taking more never
leaves a moment with nothing taken), `ReceiveNotification`,
`WaitForNotification`, `AskProcessToEnd`, `AskGroupToEnd`,
`AskSessionToEnd`, `EndReasonName` and `EndStatusOf`.
`Sys.EndRequests.HandleEndRequests(Handler, Mask)` is for programs with
no wait of their own: a thread of the runtime waits for the requests
and calls the handler for each (it usually tidies up and calls Halt).

**Who takes what.**

| Program | Takes | Does |
|---|---|---|
| any program with windows (libwindowing) | asked, service stop, shutdown, log off | closes every window no other window owns, as its close button would (`Windowing.EndRequests`; overridable with `OnEndRequested`): Notepad asks to save, a terminal window hangs its shell up |
| the desktop | the same | ends (its windows hold nothing) |
| the session manager | the same | ends the user's session as Log off does (reason shutdown or log off), then ends |
| the service manager | the same | stops every service in order, as at a shutdown, then ends |
| the interactive shell | the same | at its prompt (or once the running command is over): saves its history, ends its stopped jobs, ends with 143 |
| `notifytest --tidy-service` | the same | (a test service) writes the reason into a file and ends |

Ctrl-C and hang-ups are taken by none of these, so they behave as
before: the interactive shell ignores Ctrl-C and is ended by a hang-up
(129). `kill` (`Util.Commands.SendSignal`) asks: TERM (the default),
HUP and INT become end requests with the reasons asked, hang-up and
interrupt, so a program that takes none of them still ends with 143,
129 or 130; KILL (`kill -9`) and the other ending signals end the
program at once whatever it takes; a negative PID asks a whole group
(`kill -TERM -- -PGID`). `pkill` and `timeout` send the same way.

`notifytest` (run by coretest) checks the program's own queue (empty,
an end request it sent itself waited for among other handles, a second
one merged into the first, bad reasons and processes), then children:
one that takes the request, waits for it among a timer and an event and
ends with its own status, having heard the reason and the sender;
requests it did not take ending it with 143, 129 and 130; a program
that takes nothing ending with 143; a group and a session asked as a
whole (each with its own status); a handler thread; an ordinary user
refused for root's process and its group; and, on a pseudo-terminal,
Ctrl-C taken by the foreground program and a new size told to it.
coretest also checks `kill`, `kill -9`, `-INT` and `-HUP` on programs
that take requests and programs that do not.

### File attributes

Drivers may implement `SetAttributes` (mode, owner, group, modification and
access time), `CreateHardLink` and `GetFreeSpace`. ext2/3/4 supports all of
them. FAT and exFAT map the mode onto the read-only attribute, store times
in their own resolution and refuse owners other than 0 and hard links.
A per-process root directory implements `chroot`: paths are taken relative
to it and ".." never leads above it.

File information includes the volume a node is on (`VolumeNumber`: a
number each volume gets as it is mounted, never given to another until
the system starts again, so two paths are on one volume, and a rename
can move between them, exactly when their numbers are equal; `stat -c
%d`), and `AllocatedBytes`, the space a node takes on its
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

**Account management.** `Util.AccountChanges` (libcoreutils) adds,
removes and changes accounts; `useradd [-c FULL-NAME] [-a] NAME` (the
password read twice from the terminal or standard input), `userdel [-r]
NAME`, `usermod [-c FULL-NAME] [-G GROUP,...] [-a] NAME` (root only) and
the system settings service (for the Control Panel) all use it, so the
same code changes the files however it is asked. A new user gets the
next id from 1000 free as both user and group id, a group of their own
(their primary group), `/home/NAME` (theirs, 0755), `/bin/sh` and their
password's salted hash; `-a` (or Administrator in the Control Panel)
puts them in `wheel`. A name is a small letter, then small letters,
digits, `_` and `-`, 31 at most; a full name holds no colon. Removing a
user takes their lines from the three files, their own group (unless
another user has it as theirs) and their place in other groups, and,
asked to, their home - only under `/home`. Root's account is never
removed. The files are written as settings are (`Util.AccountFiles`): all
of a file anew into `PATH.new`, its mode set before any text goes in
(0600 for `/etc/shadow`, so the hashes are never readable by others),
then renamed over the file, so a reader sees the old file or the new one
and a crash leaves one of them; whoever edits holds an exclusive lock
on `/etc` (only root can open it so), so useradd and the service take
turns. `passwd` writes the same way. `Util.Accounts` reads the files
again when their node, size or time changed (looked at once a second at
most, at once after an edit), so the session manager, which runs all
the time, logs in a user added after it started.

Root may start a program as another user: `TAbiProcessCreation.Identity`
names its user and group (real, effective and saved) and its
supplementary groups, which the kernel checks the program's execute
permission against. That is how `login`, the session manager and the
service manager start a user's programs while staying root themselves
(`Util.Logins` reads the account: the ids, the groups the user belongs
to in `/etc/group`, the home and the shell).

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
  once or periodically (`CallSetTimer`), to well under a millisecond; a
  periodic timer counts each time from when the last was due, so
  lateness does not add up.
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
  Receiving never waits: programs wait on the channel's handle. Each
  end knows who holds the other one (`CallGetChannelPeer`: the process,
  and its effective user and group, that connected, accepted, or made
  the pair), so a server can decide what a client may ask for.

`CallWaitForHandles` waits for the first of up to 64 handles to be ready,
with a timeout: an event or timer signaled, a process or thread ended, a
pipe's read end or a channel readable (data, or the other end gone), a
pipe's write end writable (room, or no reader left), a port with a
connection waiting, a watch with change records waiting, a device with
input (a driver may keep a
`ReadyEvent`: `/dev/events` does, and a terminal's says a read would
not wait - a line read but not handed out, or typed input, in line
editing mode a whole line), or a device opened only for writing with
room (its `WritableEvent`: a pseudo-terminal's master side, with room
to type). Each stands for a notification event kept
in step with the object (pipes gained `Readable` and `Writable` events
for this, apart from the synchronization events their readers and
writers wait on; a terminal updates its events under a lock of its own,
so two updates at once cannot leave it set the wrong way). The wait is
alertable, so ending or stopping the process ends it.

With the `WaitForAll` flag it waits until all of the handles are ready
at the same time, with the same timeout and alerts. As in other systems
with this kind of wait, the wait is satisfied atomically: a signaled
automatic reset event or timer is not consumed while the others are not
ready (another waiter may take it meanwhile), and once all are, they are
all consumed together, in one step.

Underneath is waiting on several kernel events (`WaitForAnyEvent`,
`WaitForAllEvents`): a waiting thread is linked into each event's
waiters by a wait block (on its stack, naming its event), and the first
event to release it takes all its blocks off and records which one it
was; timeouts and alerts take them off the same way. A single wait is
the same with one block. Signaling an event releases its waiters in
order while it stays signaled: one waiting for any is released at once;
one waiting for all only if every one of its events is signaled, which
then consumes the synchronization events among them; the others stay
queued.

`Sys.Objects` in libsystem wraps all of it (`WaitForAllHandles` for
the wait for all), with `CallChannel` for a request and its reply.
`ipctest` (run by coretest) checks every object, the waits and timeouts,
the wait for all (an automatic reset event consumed only once all are
ready, two timers due at different times), timers at 5 and 15 ms
periods and short sleeps against the uptime, a pipe's write end
becoming writable once the reader drains it, waiting on the console,
and a section shared with a second process: it
starts itself as a child that connects to its port, receives the section
and an event in a message, changes the section and signals the event.

### Startup, services and sessions

**Boot modes.** Without `init=`, the first program is the service
manager (`servicemanager`, units in `userland/servicemanager`). It
reads the boot mode from the kernel's command line (`CallGetKernelOptions`,
`Sys.KernelOptions`: anyone may read it): `mode=text` or `mode=graphical`
(the default). Each service lists the modes it belongs to:

| Service | Modes | What it is |
|---|---|---|
| `console` | text | `login -a` on the console (the screen and the serial port) |
| `serialconsole` | graphical | `login` on the console, which is only the serial port while the display server has the screen and the keyboards: a text console for debugging |
| `displayserver` | graphical | the display server; ready once its port takes clients |
| `session` | graphical | the session manager (needs `displayserver`) |
| `systemsettings` | text, graphical | the system settings service: the machine's remembered settings at start, root's changes for the users who may |

**Service definitions** are `/etc/services/NAME.service` (installed from
`userland/etc/services`), lines of `key = value` (`Services.Definitions`):
`description`, `program` (required), `arguments` (double quotes keep
spaces), `user` (root), `needs` (services that must be running and
ready first), `modes`, `restart` (`never`, `on-failure`, `always`),
`restart-limit` (restarts in a row before it is left failed; 0: none),
`restart-delay` and `ready-timeout` (seconds, fractions allowed),
`ready` (`started`, or `notify`: once it says so), `stop-timeout`
(seconds a stopped service has to end once asked; 5) and `console` (`yes`:
the console as its standard handles and its foreground; otherwise its
output goes to `/var/log/NAME.log`, its input is `/dev/null`). A wrong
line is reported with its number and the service never starts, nor does
one that needs a missing service, one that needs one that cannot start,
or one whose needs go round in a circle (`Services.Catalog`).
`servicemanager --check` prints the definitions read, their problems
and the start order of a mode.

**Starting.** The services of the boot mode are wanted, and with them
everything they need (in any mode). A wanted service starts as soon as
every service it needs is running and ready, so independent ones start
together (`Services.Supervisor`). Each runs as its user, in a session of
its own (below), in `/`, with PATH, HOME, USER, LOGNAME, SHELL, TERM and
`SERVICE_NAME`, `SERVICE_PORT` (`Services.Launch`). With `ready =
notify` it is "starting" until it tells the manager it is ready
(`NotifyServiceReady` in `Sys.ServiceControl`, or `service ready` from a
script): a request on the manager's port that is accepted only from a
process of the service's own session (the kernel says who connected).
The display server tells it once its port exists, so the session never
starts before it can connect. A service not ready within its
`ready-timeout` is ended, which counts as a failure.

**Restarts.** When a service's program ends, the rest of its session is
ended too, and its policy decides: started again after `restart-delay`
("restarting"), up to `restart-limit` times in a row (a run of half a
minute starts the count again), then "failed"; or "stopped". Every
start writes a line into the service's log, and the manager's own
lines (started, ready, ended, given up, stopped) go to the console and
`/var/log/servicemanager.log`.

**The `service` command** talks to the manager's port `servicemanager`
(`Sys.ServiceControl`: a `TServiceRequest`, answered with the status of
the services concerned): `service list`, `service status NAME`, and,
for root only (`CallGetChannelPeer`), `service start|stop|restart NAME`.
Starting wants the service and what it needs; stopping asks every
program of its session to end (reason "service stop"; a program that
does not take the request ends at once, one that does may tidy up) and
ends the session outright if the service's program still runs after
its `stop-timeout` ("did not stop in time"); when the service's program
ends, what is left of its session goes with it. Restarting stops it and
starts it again once it has ended. A manager asked to end itself stops
every service in order, as at a shutdown, and ends.

**Shutting down.** The manager, as the first program, takes the
kernel's shutdown event (`CallWatchShutdown`, root only, one process at a
time). Whatever starts a shutdown - the power button, `poweroff` and
`reboot`, the debug shell, the desktop's Shut down - the kernel signals
the event and waits up to 30 seconds for the manager to end. The
manager stops every service that no running service needs, waits for
them to end, and repeats (`Services.Shutdown`): the reverse of the
start order, services that do not depend on each other together (the
session and the serial console, then the display server), each asked
to end as `service stop` asks (reason "shutdown"). The session manager
takes the request and logs the user off first (below), so the user's
programs get to save; its `stop-timeout` (12 seconds) is longer than
the time it gives them. Then the manager ends, and the kernel asks
whatever is left to end, ends it, writes the disks out and powers off.

**Sessions.** Every process belongs to a session, inherited from its
parent; `ProcessNewSession` in `TAbiProcessCreation` makes the new
process lead a new one, whose id is its process id (`SessionId` in the
process list). `CallTerminateSession` asks every process of a session
(that the caller may end) to end at once; `CallRequestEnd` with
`EndTargetSession` asks them first. A service's session holds what it
started; a user's session on the screen holds the desktop and every
program started from it, the shells in its terminals included.

**Logging in.** `login` (root only) asks for a user name and a password
on its standard input (no echo on a terminal), up to three times, and
starts the user's shell (or `-e PROGRAM`) as the user (`Util.Logins`:
the ids, the supplementary groups from `/etc/group`, a fresh
environment, the home directory); on a terminal the shell is
interactive and has the foreground, and login waits for it while
ignoring Ctrl-C. `-f USER` logs a user in without a password; `-a`
logs in the user the kernel option `autologin=` names, which the text
mode's console service uses (every console login is then automatic).

**The graphical session.** The session manager (`sessionmanager`,
units in `userland/sessionmanager`, root) connects to the display
server and shows the login window (`Session.LoginWindow`: a user name, a
password box that shows dots - `TEditBox.HidesText` in libcontrols - and
OK). Right ones start `/bin/desktop` as the user, in a new session
(`Session.UserSession`). Log off asks every program of the user's
session to end (reason "log off"): programs with windows close them as
if their user had (Notepad asks whether to save), the desktop ends;
whatever still runs after 8 seconds is ended outright. The session is
over once none of its programs runs (watched every 100 ms); then the
login window comes back. A desktop that ends by itself leads to the
same: the rest is asked, then ended. Asked to end itself (its service
stopped, the shutdown), the session manager ends the user's session the
same way (telling the programs "shutdown", or "log off") and then ends.
`autologin=USER` logs USER in
without the window for the first session of a boot. The session
manager serves the port `session` (`Windowing.Sessions`,
`Session.Requests`), listened to only from the session's user or root:
log off (it answers, then ends the session as above), shut down and restart (it
calls `CallShutdown`, which a user may not). Its output, with the
desktop's (the desktop inherits it), is in `/var/log/session.log`:
`session: login window shown`, the places of the window's boxes, `login
refused for NAME`, `NAME logged in (session N)`, `logging off NAME`,
`asking session N to end (REASON)`, `C programs of session N did not
end in time: ending them`, `session of NAME ended (status S)`, `asked
to end (REASON)`.

**The system settings service.** `systemsettings` (units in
`userland/systemsettings`, root) makes the changes to the machine that
only root may make, for the users who may ask for them, and keeps what
is to last in the system's settings (`SystemSettings.Remembered`). At
start it gives the kernel the remembered time zone (`Time/Zone`), each
sound output's volume and mute and the default output (`Sound/...`);
then it serves the port `systemsettings` (`Sys.SystemSettings` has the
protocol: one `TSystemSettingsRequest` answered by one
`TSystemSettingsReply`): the time zone, the clock, a volume, the
default output, adding and removing a user, a password, a full name, a
user's groups, and asking whether a password is an administrator's.
Who may (`SystemSettings.Authorization`) is decided by who connected
(the kernel says, `CallGetChannelPeer`) and the password the request
carries: root asks for anything without one; anyone may set the sound;
a user may change their own password and full name with their own
password; everything else needs an administrator's password - root's,
or the caller's own when they are in `wheel`, as sudo asks. A wrong
password is answered (`ErrorAccessDenied`) after a pause of 1.5 seconds,
so passwords cannot be tried quickly. One program, small and checked,
holds every privileged change and checks every caller the same way,
rather than set-user-ID helpers each doing so; the Control Panel and the
tools (`timezone`, `date -s`, `mixer -r`, through `Util.SystemRequests`,
which asks for the password on the terminal) all ask it. It holds
nothing to tidy up (each change is written as it is made), so a stop
ends it at once. Its log, `/var/log/systemsettings.log`, has a line for
each change and each refusal, never a password.

**Tests.** coretest runs `servicetest`: `servicemanager --check` on good
and wrong definitions and on needs across modes (the order), then a
second manager (its own directory, logs and port; only the first
program watches for shutdowns) with services that become ready late,
need each other, fail every time (left failed after two restarts, three
starts in the log), log a line and end, are not ready in time, run as
the ordinary user, or wait to be started; then `service` list, status,
start, stop, restart, refusals for an ordinary user and for readiness
from outside a service, a stop ending a service's whole session, a
service that takes the stop request tidying up (it writes the reason
into a file) and ending by itself, one that ignores it ended after its
one-second `stop-timeout`, and the second manager asked to end stopping
its services and ending.
coretest also runs `login` with a right and a wrong password through a
pipe, `-f`, the user's environment and groups, and refuses it to a
user. The input test boots in text mode with `autologin=root`. The
session test (`scripts/test-session.py`, run by `make test`) boots the
default graphical mode with `autologin=user` and checks, without
typing, that the display server and the session start in order and
the desktop comes up as the user (the taskbar and wallpaper in a screen
dump, its lines in the log, read from a root shell on the serial
console after a wrong and a right password); then Log off brings the
login window back - Notepad, started from the Start menu with text
typed into it, asks whether to save, and the test answers No - which
refuses a wrong password and starts the desktop again with the right
one; and Shut down on the Start menu, with Notepad holding unsaved text
again and nobody answering, stops the services in order (the session
manager ends Notepad once its time is up, within the session's
stop-timeout) and powers off (QEMU exits). The input test checks that
`kill` makes Notepad close its window and end by itself (status 0).

### Time zones

The kernel keeps UTC (the wall clock, file times); people read local
time. **The database** (`Sys.TimeZones` in libsystem) is a compiled
table of 66 zones named as in the IANA database (`Europe/Berlin`,
`America/New_York`, `Australia/Sydney`, `Asia/Kolkata`...), each with
its standard offset, the abbreviations of its standard and daylight
times, and one of four daylight saving rules (daylight time is an hour
ahead):

| Rule | Daylight time |
|---|---|
| European | last Sunday of March 01:00 UTC to last Sunday of October 01:00 UTC |
| North American | second Sunday of March 02:00 standard time to first Sunday of November 02:00 daylight time |
| Australian | first Sunday of October 02:00 standard to first Sunday of April 03:00 daylight time |
| New Zealand | last Sunday of September 02:00 standard to first Sunday of April 03:00 daylight time |

The rules are today's, used for every year; places whose rules change
often (Egypt, Iran, Israel, Chile...) are left out rather than shown
wrong. A southern zone's daylight time spans the new year: the year a
moment falls in is taken by standard time, and daylight time is before
the April change or after the October one. A local time is turned back
into a moment by trying the daylight offset first (so the hour that
comes twice is taken the first time) and then the standard one (the
hour skipped when clocks go forward reads as if standard time went
on). Compiled in, the table is there for every program at once, with no
file to parse.

**The system's zone** is a name the kernel keeps (`CallGetTimeZone`,
anyone; `CallSetTimeZone`, root; "UTC" at boot), as other systems keep
their zone with the clock: every program finds it with one call, and a
change reaches them all at once. The system settings service gives the
kernel the remembered one (`Time/Zone`) at start and changes it for
administrators (`timezone ZONE`, the Control Panel). **Local times**
(`Sys.LocalTime`): `DecodeLocalTime` gives a moment's wall clock
reading, offset and abbreviation in the zone the program shows times in
- the environment variable `TZ` if it names a zone (`TZ=Asia/Tokyo
date`; an unknown name is UTC), else the system's. `date` (local by
default, `-u` for UTC, `%Z` and `%z`), `ls -l`, `stat`, Notepad's
Time/Date, the taskbar clock and the file manager show local times;
`date -d`, `touch -d` and `-t` read them (`Util.Dates`: a date or clock
time is local unless it ends in UTC or Z).

**Setting the clock.** `CallSetWallClock` (root) sets the wall clock and
writes the battery backed clock (`WriteRealTimeClock`: the clock held
still with status register B's SET bit while its registers are
written, in its own BCD or binary, 12 or 24 hour format), which holds
UTC. `date -s DATE` and the Control Panel ask the system settings
service for it. `timezone` prints the system's zone, `-l` lists the
database with each zone's offset now. coretest checks offsets and
abbreviations on both sides of each rule's changes (Berlin, New York,
Sydney both ways, Auckland), half and quarter hour zones, a local time
read back, the system's zone used by `date`, `touch` and `ls -l`,
refusals for a wrong password, and the clock set by root.

### Settings

Programs keep what they want to remember from one run to the next in
**settings** (libconfiguration), in two scopes:

| Scope | Where | Who | Modes |
|---|---|---|---|
| system | `/etc/settings/GROUP.settings` | read by everyone, written by root | files 0644, folder 0755 |
| user | `$HOME/.settings/GROUP.settings` | the user alone (root's home is `/`: `/.settings`) | files 0600, folder 0700 |

**Names.** A setting is a path of names: `GROUP/KEY` or
`GROUP/SECTION.../KEY` (`Notepad/WordWrap`, `Display/0/Scale`). The
group is a file of its own in each scope, usually one per program; the
names between it and the key are a section (sections nest). A name is
letters, digits, `_`, `-` and `.` (64 at most, not starting with `.` or
`-`), case-sensitive like file names (`Configuration.Names`).

**Files** are text, to be read and changed by hand
(`Configuration.Documents`):

    # Notepad's settings
    WordWrap = true
    Font = "DejaVu Sans Mono"

    [Window]
    Width = 640
    fixed Height = 480

Keys before the first `[SECTION]` header are the group's own. A value
is a string in double quotes (escapes `\"`, `\\`, `\n`, `\r`, `\t` and
`\xHH`; UTF-8 kept as it is), an integer (decimal or `0x` hexadecimal),
a boolean (`true`/`false`; `yes`/`no` and `on`/`off` are read too), a
list of strings (`["a", "b c"]`), or anything else as a bare string
(`/home/user/sky.bmp`), so hand-written files need no quotes; the
library always writes strings quoted, so `"true"` stays a string
(`Configuration.Values`). Comments take whole lines (`#` or `;`).
Changing a file changes only the lines it must: comments, order, blank
lines and lines that cannot be read survive. A broken line is ignored
when reading (`settings check` lists them), and keys under a broken
section header are not taken for the previous section's; a key that
appears twice is read from its first line. A file larger than 1 MiB is
taken for damaged: not read, and never written over.

**Layering** (`Configuration.Settings`): a program reads through a
`TSettings`, which looks in the user's scope, then the system's, then
gives the caller's default (`ReadString`, `ReadInteger`,
`ReadIntegerWithin`, `ReadBoolean`, `ReadList`, `Lookup` for the value
and its scope). A value of another kind than the one asked for counts as
none, so a hand-edited `Speed = fast` is not taken for a speed. A value
marked `fixed` in the system's scope wins over the user's (an
administrator deciding for everyone; `fixed` means nothing in a user's
file). Writes go to one scope, the user's unless told
(`WriteString`, ..., `WriteValue` with `Fixed`, `Delete` for a key, a
section or a whole group); they are seen by the program at once and
written by `Flush` (freeing the object flushes). `ListKeys` and
`ListSections` list both scopes (`''` lists the groups). Opening:
`OpenSettings` (the current user, from `HOME`, over the system's; the
system's alone without a home), `OpenSystemSettings`, and
`OpenSettingsOfHome` for root acting for a user
(`Configuration.Locations`). A `TSettings` is not thread-safe.

**Reading what is current** (`Configuration.Scopes`): a group is read
when first wanted and kept; every later read looks at the file's
version (node number, size and time: each write makes a new file, so
the node number changes) and reads it again if it changed, so a program
sees what anyone wrote last without being told.

**Writing safely** (`Configuration.FileStorage`): the new text goes to
`GROUP.settings.new` (its mode set before the text is written), which
is then renamed over `GROUP.settings`. Other programs see the old file
or the new one: a rename holds the volume's lock throughout. After a
crash: on ext3/ext4 the removal of the old file and the new name are
one journal transaction, committed after the new file's data reached
the disk (the commit flushes the disk first), so there is the old file
or the new one. On FAT, exFAT and ext2 the removal and the rename are
two steps, and a crash between them can leave only
`GROUP.settings.new`; it is complete (it was written before the rename
began), so the library reads it in place of the missing file, and the
next write puts things right. The system disk is ext4.

**Several writers.** A flush takes the scope's writers' lock, reads
the group's latest text, makes this program's changes to it and writes
the result, then gives the lock up. Two programs changing the same
group at once thus keep both changes; a failed write is not retried
(the changes are dropped and the group read again). The lock is an
exclusive advisory lock on the scope's folder (`ControlLockFile`, see
"File systems"), which needs write permission on the folder - that is,
permission to change those settings at all - so readers cannot hold
writers up. It goes with its handle, so a writer that crashes leaves no
stale lock. Readers take no lock. A group whose last key goes is
removed.

**Change notification.** `TSettings.CheckForChanges` calls `OnChanged`
for each group someone else changed since the program read it (it
compares versions). Today a program calls it when it wants; once the
kernel can watch folders, a watch on both scopes' folders will call it
as soon as a file changes, and programs need no change.

**Who keeps what.**

| Program | Scope | Settings |
|---|---|---|
| display server | system | `Display/N/Mode`, `Display/N/Scale` when a change asks to be remembered (`displaymode -r`, `displayscale -r`); starts with the system's `Mouse/*` |
| mousesettings `-r`, session manager | user | `Mouse/Speed`, `Mouse/Acceleration`, `Mouse/LeftHanded`: the session manager gives the display server the user's at login and the system's after the session (`Session.UserSettings`) |
| notepad | user | `Notepad/WordWrap`, `Notepad/StatusBar`, `Notepad/Font/Family`, `Notepad/Font/Size`, `Notepad/Font/Bold` |
| terminal | user | `Terminal/Rows`, `Terminal/Columns` (its size when it closed), `Terminal/FontSize` |
| desktop | user | `Desktop/Wallpaper` (`-w`, kept for when images can be read) |
| files | user | `Files/View`, `Files/SortColumn`, `Files/SortAscending`, `Files/ShowHidden` (as chosen), `Files/Window/*` and `Files/PlacesWidth` (when it closes), `Files/ProgressDelay` |
| keyboardsettings `-r`, Control Panel, session manager, display server | user (system: what the login window has) | `Keyboard/Layout`, `Keyboard/RepeatDelay`, `Keyboard/RepeatRate` (`Windowing.KeyboardSettings`), given to the display server as the mouse's are |
| system settings service | system | `Time/Zone`; `Sound/N/Volume`, `Sound/N/Muted`, `Sound/DefaultOutput`, given to the kernel at start |

A display's mode and scale are the machine's (the screen in front of
it, whoever logs in), so the display server, which runs as root, keeps
them in the system's settings itself. How the pointer moves is a matter
of taste, so the mouse's settings are the user's: written by the user's
own programs, applied by the session manager, which knows who sits at
the screen.

**The `settings` tool**: `settings get [-s|-u] PATH`, `settings set
[-s [-f]] [-t string|integer|boolean|list] PATH VALUE...`, `settings
delete [-s] PATH`, `settings list [-s|-u] [PATH]` and `settings check
[-s|-u] GROUP`. Without `-s` or `-u` it shows what programs see and
changes the user's; `-s` is the system's (only root may change them),
`-f` makes a system value fixed.

**Tests.** `make settings-test` checks names, values and escaping,
files (changes keeping comments and broken lines, damaged and binary
files), scopes over a storage in memory (changes seen before a flush,
two writers keeping both changes, others' changes noticed, an unreadable
group not written over) and layering (user over system over default,
fixed values, values of the wrong kind). coretest runs `settingstest`
(the locks: shared and exclusive, refused without waiting, a program
waiting until a lock is given up, a waiting program ended, a lock given
up by a program that ends; the files' and folder's modes, no file left
half-written, a crash's `.new` file read back, a damaged file, and three
programs writing 25 keys each into one group at once, every change
kept) and the `settings` tool: both scopes, a fixed value, an ordinary
user refused the system's settings but writing their own (0700 and
0600), unable to read root's, a damaged file. The input test keeps a
mode and a scale with `-r` and checks the next display server gives
them back (and the displays' own once deleted), and checks Notepad's
word wrap and the terminal's size survive a restart; the session test
keeps a user's mouse speed with `mousesettings -r` and checks the
session manager gives the system's back after Log off and the user's at
the next login.

### Handles

A process has a table of 64 handles, each naming a referenced object and
its kind: file, console (the console or a pseudo-terminal), pipe read end, pipe write end, process, thread,
watch, socket or the null device. Handles 0-2 are standard input, output and error.
`DuplicateHandle` copies one onto another number, which is how the shell
redirects its own output for builtins. A pipe counts its open ends
separately from object references, so a reader sees end of file once the
last write end is closed, and a writer gets a broken pipe error once no
reader is left.

### Paths

Programs see a Unix style tree: `/` is the root of the system volume (the
one labelled `FPOSROOT`, or named by `root=`), and `/volumes/<name>`
leads to every mounted volume, also those of disks plugged in later
(and they leave it when unplugged). `/dev` holds the devices (see "The
I/O manager").
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
  `Sys.Environment`, `Sys.Time`, `Sys.TimeZones` (the time zone
  database) and `Sys.LocalTime` (local times, the system's zone, setting
  it and the clock), `Sys.Libraries`, `Sys.Information`,
  `Sys.FileWatches` (watching files and folders: a watch, its changes
  read and handed out one by one), `Sys.FileCopies` (a file's contents
  copied in pieces with a progress routine that may stop it, no
  half-written file left behind, the side that failed told; links
  copied as links; permissions, times and, where allowed, owners kept),
  `Sys.Volumes` (the volumes with
  their labels, file systems, sizes, free space and mount points, and a
  watch on them coming and going),

  `Sys.Display` (the display devices: a framebuffer mapped, its size,
  format, DPI and modes), `Sys.Console` (terminal modes and size, on
  any terminal), `Sys.PseudoTerminals` (creating one, starting a
  program on it), `Sys.KernelOptions` (the kernel's command line),
  `Sys.ServiceControl` (talking to the service manager),
  `Sys.SystemSettings` (talking to the system settings service),
  `Sys.Keyboard` (the keyboards' layout and repeat, and the layouts),
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
  stretched copies by nearest neighbour, gradients), `Drawing.Shapes`
  (Bresenham lines with both ends, ellipses and polygons filling the
  pixels whose centres are inside, dotted lines of any thickness whose
  dots lie on a checkerboard of the surface, so pieces drawn apart
  meet without a seam) and
  `Drawing.Bevels` (raised and sunken edges, the focus frame). Every
  shape is drawn as horizontal spans through one routine (`FillSpan`),
  which clips them and blends translucent colours. It needs only the
  runtime library.

  Anti-aliased drawing sits beside the exact shapes, which the crisp
  edges of the interface keep using. `Drawing.Rasterizer` covers each
  pixel by exactly the area of it a shape covers: a shape is edges with
  fractional ends (several outlines may make one; non-zero rule, so an
  outline the other way round cuts a hole); each edge adds the signed
  area to its right to the rows it crosses, summing along a row gives
  every pixel's coverage, and runs of equal coverage go through
  `FillSpan` with the colour faded by it. `Drawing.SmoothLines` draws
  lines one pixel wide or thinner by Wu's algorithm and wider ones as
  their outlines through the rasterizer (strokes and round joints add
  up into one shape, so overlaps are not blended twice);
  `Drawing.SmoothShapes` fills and outlines ellipses (outlines of enough
  straight edges to stay within a hundredth of a pixel of the curve) and
  polygons. `Drawing.Scaling` scales a surface smoothly: bilinear when
  growing, area averaging when shrinking (each direction on its own,
  whole number weights, colours weighted by alpha so transparent pixels
  lend no colour), the same size an exact copy.
- **libfont.so** – text: `Font.Faces` (a face: a line height, the
  baseline and underline, and glyphs with their own advances, bearings
  and bitmaps, as bits or as 8-bit coverage, and kerning pairs; a
  monospaced face is one whose advances are equal), `Font.Psf` (PSF1
  and PSF2 bitmap fonts with their Unicode tables), `Font.Coverage`
  (coverage fonts, below), `Font.Utf8` (decoding, one U+FFFD for every
  bad sequence), `Font.Text` (font sets of one family; a face picked by
  point size and DPI, the largest pixel size not larger than asked;
  measuring and drawing with advances and kerning, coverage glyphs
  blending the text colour over what is there) and `Font.Files`
  (families, one directory each in `/lib/fonts` with their licences:
  `terminus`, Terminus in heights 12 to 32, regular and bold, the
  console's font, monospaced, a face standing for an em six sevenths of
  its height, so faces of both families picked for one size match;
  `dejavu-sans`, DejaVu Sans in every pixel size from 9 to 40, regular
  and bold, the interface's). Listing a
  family reads only the start of each file, its size and weight; a
  face's glyphs are read the first time it is picked, so a program does
  not load every size. Sizes are in points, so text is the same size on
  any display.

  The system has no font rasterizer yet (TrueType comes later), so the
  proportional font is rendered at build time: `tools/RenderFont`
  (Python with Pillow, which uses FreeType) draws DejaVu Sans, hinted
  and anti-aliased, into a coverage font (`.cvf`) per pixel size. The
  format, little-endian: a 40 byte header (magic `CVF1`, flags with
  bold, the pixel size, line height, ascent, underline top and
  thickness, the glyph and kerning pair counts, and where the glyph
  table, the kerning table and the coverage data are); glyphs by code
  point (advance, left bearing, top, width, height, where the bitmap
  is); kerning pairs by left then right code point (the adjustment in
  pixels, measured from the font's own tables through Raqm and scaled
  to each size); then the bitmaps, a byte a pixel. The characters are
  Terminus's western ones (ASCII, Latin-1, Latin Extended-A), the
  typographic punctuation, the euro and U+FFFD. `Font.Coverage` checks
  every offset, size and order before using any of it; a bad file gives
  no face. The build says so clearly if Pillow or DejaVu Sans is
  missing (`DEJAVU_SANS_FONT`, `DEJAVU_SANS_BOLD_FONT` and
  `DEJAVU_LICENSE` say where they are).

  Both libraries build on the host too, without `Font.Files`: `make
  drawing-test` (part of `make test`) runs `tools/DrawingTest`, which
  checks colour arithmetic, regions, clipped fills, the exact pixels of
  lines, ellipses and polygons, copies, gradients, bevels, malformed
  UTF-8, a PSF1 font built by the test, and Terminus glyphs drawn pixel
  for pixel against their bitmaps; the rasterizer's exact coverage on
  squares, half pixels and diagonals, holes and joins, cutting at the
  surface's side; smooth lines (whole rows, half rows, a whole pixel a
  column, the same from either end, symmetric diagonals, wide lines),
  ellipses and rings (symmetric, adding up to their areas), polygons
  and smooth scaling (exact values for growing, shrinking, thin lines
  and transparency); a coverage font built by the test (measured with
  kerning, drawn pixel for pixel, every truncation and broken table
  refused), DejaVu Sans as rendered (metrics, kerning, glyphs drawn
  exactly, ASCII within the line) and a family read only when picked;
  and writes a sample picture (`build/tools/drawing-sample.ppm`). On
  the system, `drawtest` draws a window on the display in DejaVu Sans,
  everything sized by the display's scale and DPI; the input test
  checks it in a screen dump.
- **libconfiguration.so** – settings, the user's over the system's (see
  "Settings" below): `Configuration.Names`, `Configuration.Values`,
  `Configuration.Documents`, `Configuration.Storage`,
  `Configuration.Scopes`, `Configuration.Settings`,
  `Configuration.FileStorage` and `Configuration.Locations`. It needs
  only libsystem; libwindowing uses it (`Windowing.MouseSettings`, `Windowing.KeyboardSettings`). All
  but the last two build on the host too: `make settings-test` (part of
  `make test`) runs `tools/SettingsTest` over a storage in memory.
- **libtlstest.so** – a small library in assembly with TLS and
  initializer arrays, which Free Pascal does not emit; `threadtest` uses
  it to test the loader and the runtime.
- **libcoreutils.so** – `Util.Options` (GNU style options: grouped short
  options, long options with abbreviations, `--help` and `--version`),
  `Util.Messages` ("program: message: error" diagnostics), `Util.Input`,
  `Util.Paths`, `Util.Sorting` (stable merge sort), `Util.Sizes`,
  `Util.Directories`, `Util.FileTree` (copying, on `Sys.FileCopies`, removing and walking
  trees), `Util.RegularExpressions` (POSIX BRE and ERE with groups),
  `Util.Modes` (chmod modes), `Util.Dates`, `Util.BaseEncoding`,
  `Util.DigestTool`, `Util.Accounts` (/etc/passwd and /etc/group, read
  again when they change), `Util.AccountFiles` (writing the account
  files safely, under their lock), `Util.AccountChanges` (adding,
  removing and changing accounts), `Util.SystemRequests` (asking the
  system settings service from a tool),
  `Util.Logins` (logging a user in: the account, the password, starting
  a program as the user) and `Util.Commands` (running a command, signal
  names).
- **sh** – lexer, parser to a syntax tree, word expansion and execution;
  on a terminal (the console or a pseudo-terminal) it reads lines through `Util.LineEditor` (cursor keys,
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
Standard output is written line by line on the console and in buffers
otherwise; error output (`StdErr`, `ErrOutput`) line by line wherever it
goes, so a program that hangs or crashes does not lose its diagnostics
(coretest checks the order through a pipe). Times are UTC in the
runtime (SysUtils' `Now`); programs show local times through
`Sys.LocalTime` (see "Time zones"). The runtime is checked by `rtltest` (strings, arrays,
exceptions, classes, generics, files, searching, threads, processes).

## Heap checking

Freed memory that keeps its old contents hides bugs: an object used after
it was freed goes on working until its memory is reused, often far from the
cause, and a test that repeats the same steps in another program may pass
by luck. Heap checking (in the spirit of the Windows debug heap, glibc's
`MALLOC_PERTURB_`, Linux's `slub_debug` and `init_on_free`, macOS's
`MallocScribble` and OpenBSD's junking and delayed reuse) makes such bugs
show where they happen, in the kernel heap and in every program's heap.
`make test` boots every test machine with it.

**Switching it on.** The kernel option `heapchecks` (or `heapchecks=all`)
turns on everything, `heapchecks=fill` only the fill patterns, guards and
double free detection (no quarantine), `heapchecks=off` nothing. The kernel
heap reads it before its first allocation. User programs take the
environment variable `HEAP_CHECKS` (same values; `1` also means all) and,
when it is not set, the kernel option - the environment does not reach
every program (login starts sessions with a fresh environment), the option
does. So one option checks the kernel and every program, and
`HEAP_CHECKS=off program` (or `HEAP_CHECKS=all program` on a system booted
without the option) changes it for one program. The level is decided before
anything is allocated (right after `InitHeap` in System's initialization,
reading the environment in place and the options into a stack buffer), so
every block of a program carries the checking header, and no block from
before the checks can be taken for a bad one.

**Patterns** (the same in the kernel and in user mode; each repeated over
eight bytes is a non-canonical address, so a pointer read from such memory
faults when it is followed):

| Byte  | Where | Catches |
|-------|-------|---------|
| `$A5` | new blocks (`GetMem`, `New`, the part `ReAllocMem` adds, `AllocateKernelMemory`) | reads of memory that was never set |
| `$DF` | freed blocks | use after free: a method call through a freed object reads the method table `$DFDFDFDFDFDFDFDF` and faults at once |
| `$FD` | the guard after the requested bytes | writes past the end, found when the block is freed |

`AllocMem`, `AllocateZeroedMemory` and `AllocateZeroedKernelMemory` still
return zeroed memory, `ReAllocMem` keeps the contents, and objects still
start with zeroed fields (`InitInstance`).

**Quarantine.** Freed blocks wait in a first in, first out queue before
their memory can be reused, so a stale pointer keeps finding `$DF` for a
while, and a write through it is found when the block leaves the queue: its
fill is checked, and a changed byte stops the program (or the system) with
the block, its size, the offset of the first changed byte, what it holds,
and where the block was freed. Freeing a block that is in the quarantine is
a double free. Sizes: the kernel keeps up to 1024 small blocks or 512 KiB
(`Memory.KernelHeapChecks`), a program up to 1024 blocks or 512 KiB
(`rtl/fpc/sysheapquarantine.inc`); blocks over 64 KiB in user mode are
filled and freed at once rather than pushing out everything else.

**User mode** (`rtl/fpc/sysheapcheck.inc` and the include files named in
`system.pp`): a memory manager in front of Free Pascal's heap. Every block
gets a 16-byte header (a state - allocated, quarantined, given back - and
the size asked for) and at least 8 guard bytes. `FreeMem`, `ReAllocMem` and
`MemSize` check the header: a freed block or a pointer that is not a heap
block is reported (with where it was freed before, if it is still in the
quarantine). `MemSize` returns the size asked for. `ReAllocMem` grows a
block in place while it fits and otherwise moves it (keeping room to grow,
so growing step by step stays cheap) - so a pointer kept into the old block
finds the free fill too. The quarantine has its own lock (the word lock of
`systhrd.inc`) and is never held while the heap's lock is taken; blocks
leaving it are checked and freed outside it. A failed check writes a report
to standard error and, when that is not the console, to the console (which
is the kernel log on the serial line), and ends the process at once with
exit status 204 (Free Pascal's "invalid pointer operation"); exit
procedures and finalizers do not run on a damaged heap:

```
heap check in /bin/heaptest (process 3070): memory was written after it was freed
  block:     $0000100000002050, 136 bytes
  offset:    10 holds $00 instead of $DF
  freed at: $00007F00001B425A $0000000000402A92 $0000000000402B79 ...
  found at: $00007F00001C0C73 ...
```

The code addresses come from the frame chain, which user code keeps for
this (`-OoNOSTACKFRAME` in `userland.mk`; it also gives the backtrace after
a runtime error). Program addresses can be looked up with
`addr2line -f -e build/amd64/user/bin/PROGRAM`; library addresses
(`$00007F...`) are relative to the library's load address (libraries are
placed one after another from `$00007F0000000000` in load order, libsystem
first).

A use after free usually needs no report: the program faults at once. The
processor raises a general protection fault, not a page fault, for a
non-canonical address, so the kernel looks at the faulting instruction
(`Kernel.Arch.PrivilegedInstructions`): only a privileged instruction is
reported as one (runtime error 218); anything else is an access violation
(runtime error 216, `EAccessViolation`), like any other bad pointer.

**Kernel** (`Memory.HeapChecks` for the setting, patterns and reports,
`Memory.KernelHeapChecks` for the checks of the kernel heap,
`Memory.HeapQuarantine` for the queue):

- Small blocks (up to 2 KiB) get the full treatment. The header's
  `RequestedBytes` marks where the guard starts. A free block always holds
  `$DF`: pages carved into blocks are filled, freed blocks are filled, and a
  block is checked again when it is handed out, so even a write long after
  the block left the quarantine is found at the next allocation. The
  header's magic tells allocated, quarantined and free blocks apart; freeing
  a quarantined or free block is a double free.
- Large blocks (their own mapped pages) are filled with `$A5` when
  allocated. Their pages are unmapped when they are freed, so a stale
  pointer faults; with the quarantine their address range waits too (up to
  256 ranges, 4 GiB of the 1 TiB dynamic region), so nothing is mapped there
  again soon. They have no guard.
- Reports are panics (`PanicHeapCorruption`) naming the problem, the block,
  its size, the offset and byte found, and the code that freed the block
  (`FreeKernelMemory` keeps a frame to find its return address; look it up
  with `addr2line -f -e build/amd64/kernel.elf`).
- The heap may be used at dispatch level, so the quarantine is a fixed
  table under a spin lock of its own (no memory of its own, no sleeping);
  the heap lock and the quarantine lock are never held together.
- Not covered: the physical page allocator (`Memory.PhysicalPages`: page
  tables, DMA buffers, user pages, kernel stacks - stacks have guard pages
  of their own), device mappings, and memory programs allocate with system
  calls directly (the heap's own chunks, threadvar blocks, sections). DMA
  buffers come from the page allocator, so filling heap blocks never changes
  memory a device is using; a device that writes into a freed heap block is
  caught as a write after free.

**Tests.** `heaptest` checks the promises (fills, zeroed memory,
`ReAllocMem`, `MemSize`, threads allocating at once) and makes each mistake
on purpose in a child process: coretest checks that a use after free ends
with runtime error 216 and that a write after free, a double free and a
write past the end end with status 204 and the right report. With the
quarantine on, the kernel self test `Kernel.HeapCheckTest` damages blocks
on purpose and checks that the functions the heap uses before it panics
find the damage at the right offset (then repairs it). The test scripts
fail when the log shows a heap check report from any other program, and
`Kernel.SelfTest`'s heap test empties the quarantine before it counts
pages.

**Not done:** a page heap (each block on its own pages, end-aligned against
an unmapped guard page, freed pages unmapped). User address spaces are a
sorted table of at most 1024 regions with first-fit reuse, so a region per
block would neither fit nor keep freed addresses unused; it needs a reserve
/ commit / decommit system call first (see TODO.md).

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
