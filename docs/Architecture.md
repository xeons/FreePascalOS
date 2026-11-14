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

## I/O and storage

Started from phase 1 by `Io.Manager`, in dependency order:

1. **ACPI** (`Firmware.Acpi`) finds the system description tables through
   the RSDP the loader passed on.
2. **PCI** (`Io.Pci`) scans every bus in the MCFG table's ECAM windows.
   Buses with devices stay mapped (uncached, via `Memory.DeviceMapping`).
3. **Storage drivers** (`Drivers.Ahci`) register whole-disk block devices
   named `disk0`, `disk1`, ... The AHCI driver currently polls one command
   slot per port and moves data through a page-sized bounce buffer.
4. **Partitions** (`Io.Partitions`) are read from GPT (with CRC checks) or
   MBR (including logical partitions) and registered as `disk1p2` etc. A
   partition device forwards requests to its disk with an offset.
5. **File systems** are mounted on every partition (and on disks without a
   partition table) by the first driver whose probe accepts it.

Block devices are objects of type `BlockDevice`. All file system metadata
and data reads go through `Io.BlockCache`, which caches 4 KiB lines per
device, evicts least recently used first, and lets callers read any byte
range regardless of the device's block size.

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
as a segmentation fault on Unix).

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

| Area | Calls |
|---|---|
| Files | Open, Close, Read, Write, Seek, SetFileSize, GetHandleInformation, GetHandleKind |
| Paths | GetPathInformation, ReadDirectory, CreateDirectory, Remove, Rename, CreateSymbolicLink, ReadSymbolicLink, Get/SetCurrentDirectory |
| Processes | CreateProcess, WaitForProcess, Exit, GetProcessId, CreatePipe, DuplicateHandle, Sleep |
| Memory | AllocateMemory, FreeMemory |
| Libraries | LoadLibrary, FindSymbol |
| System | GetTime, GetSystemInformation, ListVolumes, Sync |

There is no fork: `CreateProcess` starts a program directly, with an
argument list, an environment, a working directory and the three handles
that become the new program's standard input, output and error.

### Handles

A process has a table of 64 handles, each naming a referenced object and
its kind: file, console, pipe read end, pipe write end, process or the
null device. Handles 0-2 are standard input, output and error.
`DuplicateHandle` copies one onto another number, which is how the shell
redirects its own output for builtins. A pipe counts its open ends
separately from object references, so a reader sees end of file once the
last write end is closed, and a writer gets a broken pipe error once no
reader is left.

### Paths

Programs see a Unix style tree: `/` is the root of the system volume (the
one labelled `FPOSROOT`, or named by `root=`), and `/volumes/<name>`
leads to every mounted volume. `/dev/null` is the null device.
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
point), as on Linux.

### The userland

Everything in user mode is Free Pascal, compiled with `-Cg` (position
independent) against `rtl/user/system.pas`:

- **System unit** – the `syscall` instruction, program start (reads the
  initial stack and runs the main block) and exit (with a hook so buffered
  output is flushed).
- **si_prc** – the `_start` entry point linked into each program.
- **libsystem.so** – `Sys.Kernel` (one wrapper per system call),
  `Sys.Memory` (size class heap on top of AllocateMemory), `Sys.Streams`
  (buffered standard input, output and error), `Sys.Format` (printf style),
  `Sys.Text`, `Sys.Files`, `Sys.Processes` (PATH search, start, wait),
  `Sys.Environment`, `Sys.Time`, `Sys.Libraries`, `Sys.Information`.
- **libcoreutils.so** – `Util.Options` (GNU style options: grouped short
  options, long options with abbreviations, `--help` and `--version`),
  `Util.Messages` ("program: message: error" diagnostics), `Util.Input`,
  `Util.Paths`, `Util.Sorting` (stable merge sort), `Util.Sizes`,
  `Util.Directories`, `Util.FileTree` (copying and removing trees).
- **sh** – lexer, parser to a syntax tree, word expansion and execution.
  Pipelines start their external programs first and then run builtins and
  compound commands inside the shell, so no stage waits for one that has
  not started.
- **coreutils** – one program per file in `userland/bin`.

Free Pascal units do not use initialization sections or threadvars in user
mode; libraries are plain collections of routines and data.

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
