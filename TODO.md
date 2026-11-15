# TODO

Roughly in the order they unblock each other. See `docs/Architecture.md` for
how the existing pieces fit together.

## Hardware discovery

- [x] Parse ACPI tables (RSDP from the loader → XSDT/RSDT → table lookup)
- [x] Use the MADT for I/O APICs and interrupt source overrides
- [x] Use the MADT processor list (starting the other processors)
- [x] FADT: power off, reset, sleep states (S3, S5)
- [ ] HPET
- [x] I/O APIC driver; route legacy IRQs onto the device vectors (0x30-0x3F)
- [x] Map MMIO with proper caching attributes (`Memory.DeviceMapping`)
- [x] PCI / PCI Express configuration space enumeration (ECAM from MCFG)
- [ ] Legacy configuration access (ports 0xCF8/0xCFC) for machines without MCFG
- [x] MSI interrupts for PCI devices (AHCI)
- [x] MSI-X (one vector per device, through table entry 0)

## Multiprocessor support

- [x] Per-processor data block (current thread, idle thread, scheduler state),
      reached through GS with SWAPGS on every user/kernel transition
- [x] Start application processors (INIT/SIPI trampoline below 1 MiB)
- [x] Per-processor GDT, TSS and interrupt stacks
- [x] Inter-processor interrupts: TLB shootdown, reschedule, panic halt (NMI)
- [x] Record the owning processor in the debug output lock
- [x] Save and restore floating point / SSE registers at thread switches
- [x] Per-processor run queues; placement by last processor, idle processors
      take work from busy ones
- [ ] Split the dispatcher lock (per-processor scheduling locks)
- [x] Device interrupts spread over the processors (round robin, not the boot one)
- [x] Batched TLB shootdowns for large unmaps (one interrupt per 32-page run)
- [x] Processor affinity for threads and processes (taskset)

## Kernel core

- [x] Timeouts on waits, and alertable waits (`WaitForEventWithOptions`)
- [x] Mutexes (owner tracking, recursion)
- [ ] Semaphores and reader/writer locks
- [ ] Wait on multiple objects
- [x] Deferred calls that run at dispatch level (for device drivers)
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
- [x] Copy-on-write sharing of program and library pages between processes
      (image sections, reference counted physical pages)
- [ ] Keep relocated copies of image pages per load address, so loading a
      library needs no relocation work at all

## Objects and processes

- [ ] Hierarchical object namespace (directories, e.g. `\Device\Keyboard`)
- [x] Per-process handle tables
- [x] Process creation and teardown
- [x] Waiting on process objects (exit notification)
- [x] Multiple threads per user process (CreateThread, ExitThread, WaitForThread,
      thread handles; an uncaught exception in one thread ends the whole process)
- [x] User-mode locks: atomic fast path, CallWaitOnAddress / CallWakeAddress
- [x] Exception fixups for kernel accesses to user memory (fault-tolerant copy
      routines, transfer buffers for reads and writes, SMAP when available)
- [ ] Libraries loaded with LoadLibrary that have thread-local storage or
      initializers (now ErrorUnsupported): dynamic TLS, running their initializers
- [x] Thread priorities set by programs (offsets from the process's)
- [ ] Thread names
- [x] Ending another program (TerminateProcess; kill, timeout)
- [x] Ctrl-C on the console: process groups, a foreground group, programs may ignore it
- [x] Stopping and continuing programs (job control: kill -STOP/-CONT, Ctrl-Z)
- [ ] Asynchronous notifications a program can handle (Ctrl-C, a request to end,
      timers); processor exceptions are already catchable
- [x] Users, groups and permission checks: real/effective/saved ids, supplementary
      groups, umask, set-user-ID programs; open, create, remove, rename, search,
      chmod, chown, times and execute are checked
- [x] Sticky directories (/tmp: only the owner may remove or replace a name)
- [ ] Permission checks on FAT and exFAT beyond their read-only attribute
- [x] Process list (ps, pgrep, pkill), per-thread CPU time

## I/O

- [x] I/O manager: driver objects, device objects, request packets; devices
      under /dev (memory devices, console, disks and partitions)
- [x] Keyboard, serial and AHCI drivers as driver objects; asynchronous requests
      with completion routines and cancellation; AHCI completes by MSI
- [x] Kernel timers (a deferred call after a delay)
- [x] AHCI: a timeout for every command; port reset after a failed or hung
      command (tested with a QEMU blkdebug disk that fails one sector)
- [x] Layered devices (filter drivers attached on top of a device); disk
      statistics filter
- [x] Programs report write errors on standard output at exit (echo > /dev/full)
- [x] PS/2 keyboard driver (interrupt driven, US layout, escape sequences for arrows)
- [x] Keyboard layouts us/uk/de/fr (keymap= option), AltGr, lock lights, Num Lock keypad
- [x] Dead keys for de/fr accents; Latin-1 and the euro sign in the framebuffer
      font, UTF-8 and escape sequences in the framebuffer console
- [x] USB keyboards (HID boot protocol on the xHCI driver)
- [ ] USB keyboards: key repeat, lock lights
- [x] Sound: audio framework (/dev/audio, periods ring, formats, volume, drain),
      Intel HD Audio driver, libaudio, tone, play and mixer
- [x] Sound: streams mixed in the kernel (any number of programs), per-stream and
      master volume, 8-32 bit integer and float samples, 1-8 channels, 8-192 kHz
- [x] Sound: voice engine in libaudio (source, submix and mastering voices, buffer
      loops and callbacks, pitch, matrices, filters, sends, operation sets,
      effect chains, offline rendering)
- [x] Sound: built-in effects (reverb, echo, equalizer, volume meter, limiter) and
      3D audio (panning, distance curves, cones, Doppler)
- [x] Sound: AC'97 output (polled)
- [x] Sound: recording (HD Audio input, capture streams in any format, monitor
      inputs for what is played)
- [x] Sound: USB audio output (audio class 1.0, xHCI isochronous transfers)
- [x] ACPI AML interpreter (namespace, methods, fields over memory, I/O and PCI
      configuration space), PCI interrupt routing from _PRT, shared level
      triggered lines; AC'97 on its line
- [x] ACPI events: SCI, power and sleep buttons (fixed and control method), GPEs
      with their _Lxx/_Exx methods, Notify; S5 power off; reset; orderly
      shutdown (poweroff, reboot, halt)
- [x] Suspend to RAM (S3): processors frozen and restarted through the start-up
      trampoline, interrupt controllers, PCI configuration and MSI-X restored,
      every driver brought back (AHCI, NVMe, virtio, xHCI and its USB devices,
      HD Audio, AC'97, serial, PS/2, display)
- [ ] Wake sources beyond the power button (RTC alarm, USB, network); MTRRs on
      secondary processors after waking
- [ ] More from the ACPI namespace: embedded controller regions, battery and
      thermal zones, processor hotplug (bringing a plugged processor online)
- [x] Interactive kernel debug console (kernel option kshell: ls, cat, volumes, disks,
      ps, mem, cache, uptime)
- [x] Shadow buffer for the framebuffer console so scrolling never reads
      video memory

## Storage

- [x] Block device layer and partition devices
- [x] GPT and MBR partition tables (with logical partitions)
- [x] AHCI SATA driver (interrupts by MSI, timeouts and port recovery)
- [x] AHCI: all command slots, NCQ, direct DMA into the request's pages
- [x] ATAPI (optical drives) on AHCI: read-only disks of the medium's block size
- [x] NVMe driver (admin and one I/O queue pair, MSI-X/MSI, PRP lists, namespaces)
- [x] virtio-blk driver (virtio 1.0 PCI, MSI-X, flushes)
- [x] xHCI (enumeration at start, control and bulk transfers, MSI-X/MSI) and USB mass
      storage (Bulk-Only Transport, SCSI)
- [ ] Full USB 1.x-3.x support:
  - [ ] A USB core independent of the host controller (devices, configurations,
        interfaces, endpoints, transfers; class drivers registered there, not
        with the xHCI driver)
  - [ ] Hubs: USB 2 hubs (transaction translators for low and full speed
        devices behind them) and USB 3 hubs, nested to the five tiers allowed
  - [ ] Hot plugging and removal (port status change events), on root ports and
        hubs; class drivers told when their device goes
  - [ ] Composite devices: a class driver per interface, several per device
  - [ ] EHCI (USB 2.0) host controllers, with their companion controllers
  - [ ] UHCI and OHCI (USB 1.x) host controllers
  - [ ] Interrupt, bulk, control and isochronous transfers on every controller
  - [ ] USB Attached SCSI (UAS) for USB 3 disks
- [x] Block cache: write-back with flush and a background writer, a lock per line
      (no lock held across I/O, devices work in parallel), read-ahead

## File systems

- [x] VFS: volumes, path resolution, symbolic links, open files, directory listing
- [x] FAT12 / FAT16 / FAT32 with long file names (read)
- [x] exFAT (read)
- [x] ext2 / ext3 / ext4 (read): block maps, extents, 64-bit, flex_bg, META_BG, htree
- [x] Write support: FAT family (create, write, truncate, remove, rename, mkdir)
- [x] Write support: exFAT
- [x] Write support: ext2/ext3/ext4 with metadata checksums
- [x] Shared node cache, per-volume locking, open flags (create, exclusive, truncate, append)
- [x] Host side verification of written volumes in `make test`
- [x] ext3/ext4: write through the journal (ordered mode, revoke records, v3
      checksums) and replay it on mount; disk flushes (AHCI FLUSH CACHE EXT)
- [ ] ext3/ext4: writing journals with v1/v2 checksums, fast commits, external
      journals (replayed if possible, but the volume stays read-only)
- [x] ext3/ext4 orphan list: files removed while open, freed at mount after a crash
- [ ] ext4: the orphan file feature (orphans are kept on the classic list)
- [ ] ext4: modify htree indexed directories (currently read-only)
- [ ] ext4: extent trees deeper than one index level when writing
- [ ] ext4: allocate from block groups still marked uninitialized
- [ ] ext4: bigalloc, quota, encryption and case folding (currently force read-only)
- [x] Hard links (ext), attributes (mode, owner, group, times) on all formats
- [x] Replacing an existing file on rename (one journal transaction on ext3/ext4)
- [x] Delete-on-last-close for files removed while open (FAT and exFAT lose the
      clusters if the system goes down before the close; fsck reclaims them)
- [ ] ext4: inline data larger than the inode, encrypted and case-folded directories,
      metadata checksum verification
- [ ] exFAT / FAT: verify and use the backup boot sector when the main one is damaged
- [ ] Hierarchical mount points (mount a volume at any directory) and a boot volume alias
- [ ] File timestamps beyond modification time; ext4 nanosecond timestamps

## User mode

- [x] Ring 3 transition and system call entry (`syscall`, return with `iretq`)
- [x] System call table and argument validation
- [x] ELF loader for position independent programs and shared libraries
      (DT_NEEDED, eager binding, run time LoadLibrary / FindSymbol)
- [x] First user mode program (`init=`, default `/bin/sh`)
- [x] Pipes, console, /dev/null, handle duplication
- [x] User runtime and startup code; libsystem.so; libcoreutils.so
- [x] Shell: pipes, redirections, && ||, if/while/until/for, variables,
      $( ), $(( )), globbing, quoting, scripts, builtins
- [x] Core utilities: all of GNU coreutils (104 commands) except chcon and runcon
- [x] libcryptography: MD5, SHA-1/2, BLAKE2b, HMAC, CRCs, AES, ChaCha20, random
- [x] Regular expressions (POSIX BRE and ERE) in libcoreutils
- [x] Named pipes in the file systems (mkfifo, mknod; ext only)
- [x] Scheduling priorities for programs (nice, renice), load averages (uptime)
- [x] Allocated block counts in file information (du, ls -s, stat %b)
- [x] su and passwd (salted SHA-256 hashes in /etc/shadow), user "user"
- [ ] login, and initializing supplementary groups for the first program
- [x] `coretest`: user mode tests run by `make test`
- [ ] Lazy binding (PLT resolution on first call) and symbol versioning;
      binding stays eager, which is simpler and costs little with few libraries
- [x] Thread local storage (PT_TLS, static model) and FPC threadvars in user mode
- [x] Unit initialization and finalization sections; DT_INIT / DT_INIT_ARRAY /
      DT_FINI_ARRAY run in dependency order by the user runtime
- [x] The Free Pascal runtime library for user programs (System, SysUtils,
      Classes, StrUtils, DateUtils, Math, Variants, fgl, Contnrs, SyncObjs, ...;
      threads, Unicode string manager with the root collation); one heap
- [x] Kernel calls the runtime needed: volume information by path, setting
      attributes by handle, thread priorities, suspending, resuming and
      ending other threads
- [x] Hang watch (hangdump=SECONDS): dumps every user thread when no
      process starts or ends for that long
- [ ] TThread.Suspend from another thread (the kernel supports it; Classes
      still uses the Unix TThread, which refuses)
- [ ] Time zones (the real-time clock is taken as UTC, and so is everything else)
- [x] Processor exceptions passed to the program (exception record on the
      user stack, runtime dispatcher); catchable EAccessViolation,
      EDivByZero, EZeroDivide, ...; x87 and SIMD exceptions enabled
- [x] Continuing after an exception at a changed context (CallContinue, like
      NtContinue); exception filters (Sys.Exceptions)
- [x] Stack overflow as a catchable exception (a reserve at the bottom of each
      stack, armed again once the stack is clear)
- [x] A system call whose buffer lies in the stack's reserve completes, and the
      stack overflow is raised as it returns
- [x] Frames larger than the stack reserve: a stack access below the stack is
      taken for a stack overflow (record at the top of the opened reserve)
- [x] A 256 MiB guard below every stack, so a huge frame never reaches other
      memory (frames beyond that would need compiler emitted stack probes)
- [ ] Synchronized buffered output (Sys.Streams) for multi-threaded programs
- [x] Shell line editing (cursor keys, Ctrl-A/E/K/U/W), history file, Tab completion
- [x] Shell: case, functions (local, return), here documents, ${...} forms,
      eval, exec, command, type, wait, arithmetic assignment
- [x] Ctrl-C for loops made only of builtins (pending-interrupt console request)
- [x] Line editor: lines longer than the screen scroll sideways
- [x] Job control: stopping and continuing processes (kill -STOP/-CONT), Ctrl-Z,
      background readers of the console stop; shell jobs, fg, bg, wait, $!, kill %N
- [ ] Shell: background compound commands ("( ... ) &", "while ...; done &") still
      run in the foreground; job text is rebuilt from the expanded words
- [ ] Line editor: characters beyond ASCII (UTF-8) count as one column
- [x] More programs outside coreutils: grep (egrep, fgrep), find, xargs, sed, diff, less (more)
- [x] ps, pgrep, pkill
- [x] Interrupt driven console input (keyboard and serial)

## Graphical user interface

A desktop in the spirit of Windows 2000 (an original look, not a copy),
built in this order; each step unblocks the next.

DPI aware throughout: drawing is in device pixels, but sizes the user sees
are not. Fonts are sized in points; window sizes, metrics and layout are in
logical units (1/96 inch) that the display's scale turns into pixels;
icons and cursors come in several sizes; absolute pointer positions are
normalized (0-65535), not pixels.

### 1. Pointing devices and input events
- [x] PS/2 mouse (8042 second port, IntelliMouse wheel)
- [x] USB HID mouse and USB tablet (report descriptor parsed; absolute
      coordinates: QEMU's usb-tablet, for testing)
- [x] Input event device (/dev/events): timestamped key and pointer events
      (press/release, key code, character, relative motion, absolute position
      normalized to 0-65535, buttons, wheel)
- [x] The text console keeps the keyboards until a program takes them
- [x] Mouse settings: acceleration, sensitivity and left-handed buttons (in the
      display server, step 4)

### 2. Drawing and fonts
- [x] Display device (/dev/display): framebuffer information, mapping the
      framebuffer into a process, taking the screen from the text console and
      giving it back
- [x] Display DPI: from EDID (physical size) where it can be read, else a
      configured value, else 96; a scale factor (1.0, 1.25, 1.5, 2.0...)
- [x] Mapping device memory into user processes (write-combining)
- [x] Display modes: changing the resolution (Bochs DISPI, later native
      drivers), EDID's list of modes, and the DPI following the mode
- [x] libdrawing: pixel buffers, rectangles, lines, shapes, blits, clipping
      regions, alpha blending, gradients, 3D bevels
- [x] libfont: bitmap fonts (Terminus PSF, 12 to 32 pixels, regular and bold),
      picked by point size and DPI; text measuring and drawing, UTF-8
- [x] Host-side tests for libdrawing and libfont (pixel-exact)
- [x] Proportional fonts for the interface (bitmap, or TrueType in step 8); kerning
- [x] Anti-aliased lines and shapes; scaling surfaces (for icons at other sizes)

### 3. Kernel infrastructure for a display server
- [x] Shared memory sections (create, map into several processes, handle-based)
- [x] Wait on multiple objects (handles: events, processes, threads, pipes,
      input devices, channels) with a timeout
- [x] Event objects for user mode (create, set, reset, wait)
- [x] Local message channels: request/reply messages that can carry handles
- [x] Waitable timers (in milliseconds)
- [x] Finer timers: one-shot local APIC timer interrupts for the first timer
      or timeout due, timed by the time stamp counter (the 100 Hz tick stays
      for time slices and CPU time)
- [x] Waiting on the console and pipe write ends (room to write) through handles
- [x] Waiting for all of several handles at once

### 4. Display server
- [x] One process owns the screen and input; clients connect through a channel
- [x] Windows: create, destroy, move, resize, show, hide, z-order, focus,
      activation, input routing, capture
- [x] Client surfaces in shared memory; damage tracking; compositing with
      clipping; the mouse cursor
- [x] Window frames: title bar, borders, minimize/maximize/close, move and resize
      by dragging
- [x] System colours and metrics (the theme), metrics in logical units
- [x] Scale per display: logical units to pixels, the cursor at that scale
- [x] Several displays, each with its own scale; moving a window between them
- [x] Pressed and hot looks for the title buttons; double-click on the title bar
- [x] Pointer shapes per window area (resize arrows, text beam), from files
- [x] Copying only what moved when a window is dragged (instead of redrawing)

### 5. Windowing and controls
- [x] libwindowing: connecting, windows, the message loop (paint, keys, mouse,
      resize, close, activate, timers), surfaces and invalidation; windows and
      positions in logical units, told the scale
- [x] Messages between a program's parts: delivered at once or posted to the
      message loop (from any thread), program-defined codes
- [x] Told when the scale changes (a window moved to another display)
- [x] libcontrols base: controls in a tree, docking, painting with clipping,
      pointer capture, focus and Tab order, default and cancel buttons; new
      controls by subclassing, On... events, notifications to the parent
- [x] libcontrols: button, check box, radio button, label, edit box (one line),
      scroll bar, status bar, progress bar, panel, group box
- [x] libcontrols: multi-line edit box, list box, combo box, menu bar and pop-up
      menus, toolbar, tab control, tree view, list view (details)
- [x] List view: icon views, several selected, sorting helpers; tree view lines
- [x] Clipboard for the edit boxes (step 8 has the system clipboard)
- [x] Dialogs: layout, keyboard focus, tab order, default and cancel buttons,
      accelerators; message boxes; layout in logical units, scaled
- [x] Mnemonics (Alt+underlined letter) for menus, buttons and labels; F10 and Alt
      for the menu bar
- [x] Owned windows: a dialog stays above its owner; the owner disabled for real
      (the server refuses to activate it)
- [x] Common dialogs: open and save a file, choose a colour, choose a font

### 6. Desktop shell
- [x] Pseudo-terminals (for terminal windows)
- [x] Taskbar: Start menu, buttons for open windows, clock, notification area
- [x] Desktop: wallpaper, icons
- [x] Terminal window running the shell
- [x] Notepad

### 7. Applications and session
- [ ] Service manager (the first user process): service definitions in
      /etc/services (program, arguments, user, dependencies, restart policy),
      started in dependency order, restarted when they fail (with a limit),
      their output logged; a `service` command (start, stop, restart, status)
- [ ] Boot modes: text (shells on the console) and graphical (the display
      server, then the session); chosen by a kernel option, graphical by default
      once it works; shutdown and reboot stop services in reverse order first
- [ ] The graphical session starts by itself: login, then the desktop shell for
      that user; a text console stays available for debugging
- [ ] File manager: folders, icon and list views, copy, move, delete, rename,
      properties
- [ ] Control Panel: display, mouse, keyboard layout, sound, date and time, users
- [ ] Task Manager: processes, CPU and memory
- [ ] Graphical login, locking, log off, shut down and suspend from the desktop
- [ ] File change notifications (folders refresh), volume arrival
- [ ] Per-user settings store (libconfiguration)

### 8. Richer graphics
- [ ] libcompression: deflate
- [ ] libimage: BMP and ICO, then PNG (reading and writing), JPEG (reading)
- [ ] libfont: TrueType outlines, hinting, antialiasing, glyph cache (any size,
      so any DPI)
- [ ] Icons and cursors in several sizes (16, 24, 32, 48 px...); the nearest to
      the scale is used, scaled when none fits
- [ ] Clipboard (text and images) and drag and drop
- [ ] Themes; Paint; image viewer; calculator; volume control
- [ ] Accelerated 2D (virtio-gpu or bochs-display blits), hardware cursor

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
- [ ] Rare hang under TCG (about 1 run in 10, seen twice): during the sound tests
      two threads (sh creating a process, tone writing to /dev/audio) spin in
      CpuRelax with the other processors idle. The hang dump now prints the
      kernel return addresses on the spinning stack: catch it again and follow
      them
