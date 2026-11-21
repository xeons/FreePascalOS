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
- [x] Growable region table: an address space's regions in a balanced tree
      (logarithmic fault lookup, overlap check and first-fit search) instead
      of a fixed 1024-entry table, bounded by a per-process region limit
- [x] Every region released with its owner: thread stacks, guards and thread
      data however a thread ends, threadvar blocks of threads ended from
      outside (AllocateForThread), heap chunks of ended threads kept by the
      heap check quarantine; checked by limittest
- [ ] Demand paging from files (map executables instead of copying them in)
- [x] Copy-on-write sharing of program and library pages between processes
      (image sections, reference counted physical pages)
- [ ] Keep relocated copies of image pages per load address, so loading a
      library needs no relocation work at all
- [x] Heap checking in the kernel heap and every program's heap (kernel option
      `heapchecks`, `HEAP_CHECKS`): fill patterns that make freed pointers
      non-canonical, guards after blocks, double free detection, a quarantine
      checked when blocks leave it; on in every test boot
- [ ] Page heap (opt-in per program): every block on pages of its own,
      end-aligned against an unmapped guard page, freed pages unmapped and
      their addresses kept from reuse. Needs a reserve / commit / decommit
      call and keeping freed addresses from first-fit reuse (the region
      tree holds a region per block now)
- [ ] Heap checking for the physical page allocator (fill freed pages, keep
      them from reuse for a while)

## Objects and processes

- [ ] Hierarchical object namespace (directories, e.g. `\Device\Keyboard`)
- [x] Per-process handle tables
- [x] Growable handle tables (two levels, lowest free number first) up to a
      per-process handle limit; limits for regions and handles
      (CallGetProcessResources, CallSetProcessLimit), inherited by children
- [x] Passing more handles than the standard three to a new process
      (ProcessPassHandles)
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
- [x] Ending a stuck program always works: checked for spinning threads,
      every kind of kernel wait, deadlocks, sockets and windows that stop
      being served (hangtest --check); a thread started during the ending
      never runs; kill -9 of a group; a process still there 10 s after it
      was told to end is reported with its threads ([ending])
- [ ] Bound the kernel's remaining non-alertable waits a user thread can
      reach (device open and close, block I/O, the wait after cancelling a
      request), so a driver that never completes cannot keep a process
      from ending
- [x] Ctrl-C on the console: process groups, a foreground group, programs may ignore it
- [x] Stopping and continuing programs (job control: kill -STOP/-CONT, Ctrl-Z)
- [x] Asynchronous notifications a program can handle: a notification queue
      waited on like a handle (requests to end with a reason - asked,
      service stop, shutdown, log off, hang-up, Ctrl-C - and the terminal's
      size); the kernel ends a program for a request it does not take, as
      before (timers are waitable objects; processor exceptions are catchable)
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
- [x] Sound: HDMI audio on the Raspberry Pi 5 (untested on the board; see
      the Raspberry Pi section), outputs without a hardware volume (the
      mixer scales)
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
        hubs; class drivers told when their device goes (root ports are done,
        with USB disks mounted and taken away; hubs remain)
  - [x] Composite devices: a class driver per interface, several per device
        (Drivers.UsbInterfaces; interrupt IN endpoints on several interfaces;
        a driver may claim more interfaces of its function: audio)
  - [ ] Interface association descriptors (IAD) for binding a function's
        interfaces, instead of each driver claiming its own
  - [ ] EHCI (USB 2.0) host controllers, with their companion controllers
  - [ ] UHCI and OHCI (USB 1.x) host controllers
  - [ ] Interrupt, bulk, control and isochronous transfers on every controller
  - [ ] USB Attached SCSI (UAS) for USB 3 disks
- [x] Block cache: write-back with flush and a background writer, a lock per line
      (no lock held across I/O, devices work in parallel), read-ahead

## Network cards

- [x] Intel e1000/e1000e (8254x, 8257x, I217/I218/I219): legacy descriptor rings,
      MSI or line interrupts, link changes, statistics, suspend to RAM
- [x] Realtek RTL8139
- [x] Realtek RTL8168/8111 and RTL8125/8126 (untested: QEMU has no model), with the
      RTL8125/8126 PHY firmware patches from /lib/firmware
- [ ] I217/I218/I219 quirks: PHY ultra low power exit and LANPHYPC toggle, the I219
      descriptor ring flush before a reset, K1/EEE workarounds, reading the flash NVM
- [ ] RTL8168 per-version PHY tuning and firmware patches; RTL8125/8126 PHY tuning
      tables and EPHY values; RTL8169 (PCI)
- [ ] Multicast filter lists (cards accept every multicast now), checksum and
      segmentation offload, several queues, MSI-X on the 82574L, jumbo frames
- [ ] Network cards plugged in while the system runs (USB, Thunderbolt)

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
- [x] First user mode program (`init=`; by default the service manager)
- [x] Pipes, console, /dev/null, handle duplication
- [x] User runtime and startup code; libsystem.so; libcoreutils.so
- [x] Shell: pipes, redirections, && ||, if/while/until/for, variables,
      $( ), $(( )), globbing, quoting, scripts, builtins
- [x] Core utilities: all of GNU coreutils (104 commands) except chcon and runcon
- [x] libcryptography: MD5, SHA-1/2, BLAKE2b, HMAC, CRCs, AES, ChaCha20, random
- [x] libcryptography for TLS: Poly1305, ChaCha20-Poly1305, AES-GCM (AES-NI,
      constant-time GHASH), HKDF, X25519, big numbers, RSA PKCS #1 / PSS and
      ECDSA P-256 / P-384 signature checks
- [x] Regular expressions (POSIX BRE and ERE) in libcoreutils
- [x] Named pipes in the file systems (mkfifo, mknod; ext only)
- [x] Scheduling priorities for programs (nice, renice), load averages (uptime)
- [x] Allocated block counts in file information (du, ls -s, stat %b)
- [x] su and passwd (salted SHA-256 hashes in /etc/shadow), user "user"
- [x] login, and initializing supplementary groups (from /etc/group) for every
      program started as a user (login, the session manager, services)
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
- [x] USB keyboard and mouse receivers (composite HID: a boot keyboard interface
      and a mouse interface with report ids; reports routed by id; report
      protocol keyboards, key arrays and bitmaps, turned into boot reports)
- [ ] USB consumer and system control reports (volume, play, sleep keys of
      receivers and keyboards: parsed but ignored)
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
- [x] Layout without hand-computed positions:
  - [x] Anchors (any of left, top, right, bottom: kept at their distance
        from the parent's edges when it resizes; left and right together
        stretch the control)
  - [x] Docking with margins and padding (Align exists: top, bottom, left,
        right, client; add Margin and Padding, and a dock order)
  - [x] AutoSize (a control sized to its content: labels, buttons, check
        boxes; containers to their children) and minimum and maximum sizes
  - [x] FlowLayoutPanel (children in a row or column, wrapping)
  - [x] TableLayoutPanel (rows and columns: fixed, automatic or a share of
        what is left; spanning cells)
  - [x] SplitContainer (two panels with a splitter between them, either
        orientation, minimum sizes, one panel fixed when resizing; builds
        on TSplitter)
  - [x] Panel improvements: scrolling when the content is larger (AutoScroll)
- [ ] More controls:
  - [x] Checked list box (a check box per item, Space toggles, check events)
  - [x] Numeric up/down (an edit box with up and down buttons; minimum,
        maximum, step, decimal places; arrow keys and the wheel)
  - [x] Calendar (a month grid: today, a selected date or range, first day
        of the week, moving by month and year, keyboard navigation)
  - [x] Date and time picker (an edit box with fields for each part, a drop
        down calendar; date, time, or both; formats; uses the time zone)
  - [x] Picture box (shows an image: normal, stretched, zoomed to fit,
        centred; needs libimage from step 8 for files, surfaces before then)
  - [x] Paint box (a control the program draws in OnPaint: no focus, no
        background of its own, repainted when resized; every control has
        OnPaint already, this packages it like the picture box)
  - [x] Tooltip component (a Hint text on any control, shown after the
        pointer rests and hidden when it leaves or a key is pressed; the
        tooltip window exists, the timing is left to each program now)
  - [x] Image list (images of one size, several sizes for DPI, shared by
        list views, tree views, toolbars, tabs and menus)
  - [x] Timer component (OnTimer at an interval, Enabled; over the message
        loop's window timers)
  - [x] Chart control (line, bar, area and pie; axes, legends, scaling;
        Task Manager's graphs could move to it)

### 6. Desktop shell
- [x] Pseudo-terminals (for terminal windows)
- [x] Taskbar: Start menu, buttons for open windows, clock, notification area
- [x] Desktop: wallpaper, icons
- [x] Terminal window running the shell
- [x] Notepad
- [x] Program folders: graphical programs installed in /app/NAME with a
      program.info (name, description, category, icon, executable,
      keywords, version, hidden) and their own icons; the desktop's icons
      and the Start menu (a submenu per category) built from them; still
      started by name (FindProgramPath falls back to /app)
- [ ] Start menu: descriptions as tooltips (the menus have no tooltips
      yet), searching by name and keywords, programs installed while the
      desktop runs (it reads /app once)

### 7. Applications and session
- [x] Service manager (the first user process): service definitions in
      /etc/services (program, arguments, user, dependencies, restart policy),
      started in dependency order, restarted when they fail (with a limit),
      their output logged; a `service` command (start, stop, restart, status)
- [x] Boot modes: text (shells on the console) and graphical (the display
      server, then the session); chosen by a kernel option, graphical by default
      once it works; shutdown and reboot stop services in reverse order first
- [x] The graphical session starts by itself: login, then the desktop shell for
      that user; a text console stays available for debugging
- [x] Asking a service to stop before ending it (its session asked to end,
      ended after its stop-timeout); log off and shutdown ask first too
- [x] File manager: folders, icon and list views, copy, move, delete, rename,
      properties
- [x] Control Panel: display, mouse, keyboard layout, sound, date and time,
      network, users
- [x] Task Manager: processes, CPU and memory (programs with windows, every
      process with End / End now / Stop / Continue / Priority / Properties,
      processor and memory graphs; processor time timed at every switch,
      per-process and system memory figures, Ctrl+Shift+Escape)
- [x] Programs that stop responding: the display server pings each
      program's message loop and marks one that stops answering ("(Not
      responding)" after its titles, a flag in window lists); the task
      manager shows it and ends such a program outright (asked), and offers
      the same for any process still there when its wait after End is over
- [ ] The taskbar marking a program that is not responding; its windows'
      contents faded
- [x] Graphical login, locking, log off, shut down and suspend from the desktop
      (the lock enforced by the display server; Super+L, Ctrl+Alt+L, the
      Start menu, after idle minutes and before suspending)
- [x] File change notifications (folders refresh), volume arrival
- [x] Per-user settings store (libconfiguration): typed settings in text
      files, the user's over the system's over defaults, fixed values, safe
      writes under an advisory file lock (new kernel feature); the display
      server, the session manager (mouse), Notepad, the terminal and the
      desktop use it; the `settings` tool
- [x] Settings changed notifications (on top of folder watches): per
      group, the keys that changed (snapshots compared, so a rewrite
      that changes nothing is silent), bursts and safe writes' renames
      coalesced (`Configuration.Watcher`, `Windowing.SettingsChanges`,
      `settings watch`); the display server, session manager, desktop
      (clock format, wallpaper, time zone), terminal (font size,
      colours), Notepad, Control Panel pages and the network service
      apply changes live

### 8. Richer graphics
- [x] libcompression: deflate (inflate: stored, fixed and dynamic blocks,
      streaming, strict checks; deflate at levels 0-9 with hash chains and
      lazy matching), zlib and gzip wrappers (several members), Adler-32 and
      CRC-32; TInflater/TDeflater, stream adapters, one-call functions;
      `gzip`; checked on the host against zlib (`make compression-test`)
- [x] libcompression: preset dictionaries (zlib FDICT and raw, both
      ways), flushing mid-stream (sync and full flush points);
      `zcat`/`gunzip` names for gzip; checked against Python's zlib
- [ ] libcompression: zip archives
- [ ] libimage: one image model (pixels, frames with delays, colour
      profile, metadata) and a decoder/encoder per format, chosen by content
      (magic bytes) rather than file name:
  - [x] The model (`TImage`, `TAnimatedImage` with frames, delays, disposal,
        blend and loop count; resolution, orientation, ICC profile,
        metadata), surfaces shared without copying, a frame compositor for
        playing animations, the codec registry, `LoadImage`/`SaveImage`
        with `EImageError` reasons, `imageinfo`; `make image-test`
  - [x] BMP and DIB (all bit depths, RLE, bitfields; reading and writing)
  - [x] ICO and CUR (several sizes in one file, the nearest to the scale,
        hotspots; reading and writing; PNG entries through the PNG decoder)
  - [x] PNG (all colour types and depths, interlacing, transparency, text,
        profile, resolution, EXIF orientation; reading, and writing in the
        smallest colour type with adaptive filtering) and APNG frames
        (reading and writing)
  - [x] GIF, including animation (frames, delays, disposal, transparency,
        loop count; LZW; writing one frame) — the picture box plays it
        (`TFrameCompositor`; the picture box itself still to do)
  - [x] JPEG (baseline and progressive, chroma subsampling, EXIF orientation;
        reading, then writing baseline)
  - [x] TIFF (strips and tiles, several pages, BigTIFF; none, PackBits, LZW,
        deflate and JPEG compression; reading, and writing RGB/RGBA)
  - [x] TIFF: CCITT RLE, Group 3 (1D/2D) and Group 4, the floating point
        predictor and 16/32-bit float samples (tone mapped to 8 bits),
        old-style JPEG (interchange-format streams and a stream a strip)
  - [x] WebP (lossy VP8, lossless VP8L, alpha, animation; ICC, EXIF
        orientation, XMP; writing lossless, animations included)
  - [ ] WebP: lossy writing (VP8 encoder)
  - [x] JPEG XL (VarDCT and modular modes, animation; decoding only,
        splines refused)
  - Not planned: HEIC (its HEVC compression is patent-encumbered and licensed
    through pools; AVIF, the same HEIF container with royalty-free AV1, can
    be added instead if wanted)
  - [ ] AVIF (HEIF container, AV1 intra frames: a large decoder; until then
        the browser neither advertises nor accepts image/avif)
  - [x] Scalable images (`Image.Scalable`): drawn again at any size, the
        last renderings kept
  - [x] Colour management basics: ICC v2/v4 matrix/TRC, grey and LUT
        (mft1, mft2, mAB) profiles to sRGB with tables, wtpt/chad,
        PNG gAMA/cHRM, CMYK naive (`Image.ColorProfiles`,
        `TImage.ConvertToSrgb`, `ImageLoadConvertToSrgb`); checked
        against LittleCMS
  - [x] Scaling with good filtering: `Image.Resampling` (Lanczos-3,
        Mitchell, bilinear, box; separable, premultiplied alpha) beside
        `Image.Scaling`'s area averaging; checked against Pillow
- [x] libfont: TrueType outlines, hinting, antialiasing, glyph cache (any size,
      so any DPI): DejaVu Sans (the interface's) and DejaVu Sans Mono at every
      size, light vertical autohinting, gamma-correct blending; CFF outlines and
      the fonts' own bytecode hinting not done
- [x] Icons and cursors in several sizes (16, 24, 32, 48 px...); the nearest to
      the scale is used, scaled when none fits: an isometric icon set and
      the pointer's pictures drawn by code at build time (16 to 96 px),
      read through the icon theme (`Controls.IconFiles`,
      `Controls.IconTheme`) and the display server; window icons (a theme
      name or pictures, `RequestSetWindowIcon`) in title bars, on taskbar
      buttons and in the task manager, dialogs showing their owner's
- [x] Clipboard (text and images) and drag and drop
- [x] Themes: the theme as data (Sunrise, the default, and Classic), chosen by
      Appearance/Theme and followed live; Control Panel Appearance page
  - [x] Controls painted in the new look (scaled bevels, header bands, hot,
        flat, split and drop-down buttons, green and marquee progress bars),
        the earlier look kept as the classic control look
- [x] Paint (raster editing: tools, selection and the clipboard, undo, zoom,
      files in every format libimage writes)
- [x] Image viewer (zoom, pan, turns, animations, the folder's images,
      properties, colour management, copy, save as), calculator
      (standard, scientific, programmer; exact display; history) and
      volume control (outputs, mutes, peak meters, the default output),
      laid out by docking, tables, flows and split containers;
      `make apps-test`
- [x] Accelerated 2D: a virtio-gpu driver (2D resources on memory
      framebuffers, damaged rectangles flushed, scanouts and EDID modes,
      the host's cursor), only damage presented and the pointer never
      composed (the device's cursor, or blended while presenting);
      `displaybench`; `scripts/test-virtio-gpu.py` (skipped without
      QEMU's virtio-gpu module)

## Networking

### Phase 1: the stack, sockets, the first tools
- [x] Network adapters (`Io.NetworkAdapters`): the interface drivers
      register through; frames handed to the network thread, never
      handled in a driver's interrupt
- [x] Packet buffers, the network thread and its timers, one network lock
- [x] Ethernet II, ARP (cache with timeouts, pending datagrams), IPv4
      (checksums, fragment reassembly, no fragments sent, broadcasts),
      routing table with a default gateway, ICMP (echo, unreachable)
- [x] UDP; TCP: state machine, retransmission with RTT estimation,
      sliding windows, MSS, congestion control, fast retransmit, FIN/RST,
      TIME_WAIT, listen backlog, out-of-order segments kept
- [x] Loopback interface (lo, 127.0.0.1/8)
- [x] Sockets as handles (system calls 104-115): TCP, UDP, ICMP echo for
      everyone, raw ICMP for root; options, non-blocking, waits
- [x] Configuration calls (116-123): interfaces, routes, ARP cache,
      socket listing, DNS servers (changes root only)
- [x] libsystem: `Sys.Sockets`, `Sys.NetworkInterfaces`,
      `Sys.InternetAddresses`, `Sys.HostNames`
- [x] virtio-net driver (MSI-X, suspend and resume)
- [x] `ping`, `ifconfig`, `route`, `arp`
- [x] Static configuration at start from `/etc/settings/Network.settings`
      (the network service)
- [x] Tests: `networktest` (loopback, QEMU's gateway, a TCP echo through
      QEMU), coretest command lines, a kernel self test

### Phase 2
- [x] The network service runs for good (`/bin/network`): settings
      applied per interface (`static`, `dhcp`, `none`), changes to
      Network.settings applied as they are written (a folder watch),
      links and adapters that appear later followed (a kernel event,
      `CallWatchNetworkChanges`), state files in `/var/lib/network`
- [x] DHCP client (RFC 2131/2132): discover, offer, request, ack, nak,
      INIT-REBOOT, renewing (T1, unicast) and rebinding (T2, broadcast),
      expiry, randomised exponential retransmission, an ARP probe of the
      offered address and DECLINE, RELEASE when stopped or taken down
- [x] Sockets on one port bound to different interfaces do not conflict
- [x] The node name kept by the kernel and set by root
      (`CallSetNodeName`), `hostname`
- [x] DNS resolver in libsystem (`Sys.HostNames` over `Sys.DnsQueries`,
      `Sys.DnsMessages`, `Sys.DnsNames`, `Sys.HostsFile`): `/etc/hosts`,
      the kernel's server list, the search domain, retries across
      servers, TCP for truncated answers, CNAME chains, A, AAAA, PTR,
      name compression with loop protection, random ids and ports
- [x] `host` and `nslookup`; `ping` takes names
- [x] Tests: DHCP from QEMU and the state file, a settings change
      applied live, the lease given back (networktest); the resolver
      against a DNS server of its own (dnstest); host, nslookup and
      hostname command lines
- [x] A small per-process cache of DNS answers (TTLs, RFC 2308 negative
      caching, 64 answers); EDNS(0) for answers larger than 512 bytes
      over UDP (1232 advertised, FORMERR asked again without it)
- [x] DHCP: option overload (52), several offers compared (a second's
      window, the previous address preferred), the random 1-10 s wait
      before a cold start's first DISCOVER (`DhcpStartWait`, off in the
      shipped settings to start quickly)
- [x] `netstat` (`-tuwlanp`, `-r`, `-i`, `-s`; the socket listing gives
      the owner process, protocol counters in the kernel)
- [x] `nc` (OpenBSD options: `-l -k -u -z -v -w -n -N -q -p -d`)
- [x] `ss` (on top of netstat's pieces: -t -u -w -x -l -a -n -r -p -e -H
      -4/-6 -s, state filters and sport/dport/src/dst expressions)
- [ ] `ss -i` (TCP internals: the kernel keeps no window or round trip
      time to show yet); `ss -x` once there are local sockets
- [x] Reverse lookups and a services list for `netstat` without `-n`
      (`Netstat.Names`: /etc/hosts, PTR with a short timeout, /etc/ports)
- [x] `wget` (HTTP/1.1 and HTTPS: -O, -q, -S, -c, -T, -t, -U, redirects,
      chunked bodies, --no-check-certificate, --ca-certificate, --ciphers,
      a progress line); `wgettest` in QEMU against test servers on the host
- [x] TLS: libtls, a TLS 1.3 client (x25519; AES-GCM and ChaCha20-Poly1305;
      HelloRetryRequest, KeyUpdate, alerts) with X.509 chain, signature,
      validity and host name checks against the Mozilla CA list in
      /etc/ssl/certs; host tests with RFC 8448's handshake and OpenSSL
- [x] TLS: name constraints (certificates with them are refused for now),
      P-256 key exchange (only x25519 is offered), session resumption,
      OCSP / revocation, TLS 1.2 for servers without 1.3, Ed25519 and P-521
      certificates (also secp384r1/secp521r1 and X25519MLKEM768 with
      ML-KEM-768 and SHA-3 in libcryptography; OCSP is stapling only)
- [ ] TLS: CRLs and OCSP fetching (only stapled responses are checked),
      0-RTT early data, TLS 1.2 session resumption
- [x] wget: keep-alive, cookies (RFC 6265, Netscape cookie files),
      Basic and Digest authentication (RFC 7616) and .netrc, recursion
      (-r -l -np -k -p -A -R -P -nH -nd, robots.txt), --trust-server-names,
      gzip (--compression)
- [ ] wget later: -N (timestamps), -nc, --spider, -H with -D, CSS url()
      links for -p, --ask-password, SHA-512-256 and auth-int Digest
- [x] libhttp (userland/lib/http): the URL Standard (parser, setters,
      hosts with IPv4/IPv6/Punycode, URLSearchParams, origins); HTTP/1.1
      and HTTP/2 (HPACK, flow control, RFC 9218 priorities, GOAWAY,
      several threads sharing a connection); cookies after RFC 6265bis
      (SameSite, prefixes, public suffixes); a memory and disk cache;
      Basic/Digest; gzip/deflate; Alt-Svc with connection factories;
      fetch tasks on threads; wget moved onto it (HTTP/2 by ALPN,
      --no-http2); host tests (RFC 7541 appendix C, libnghttp2, curl
      against the test server) and HTTP/2 checks in wgettest
- [x] libhttp: HTTP/3 through libquic (libquic's Http3.HttpConnections
      and the "h3" factory EnableHttp3 registers; threads sharing a
      connection, cancel, trailers, GOAWAY, PRIORITY_UPDATE; new requests
      move to an advertised alternative, a failing one is broken for five
      minutes and TCP used); Alt-Svc with persist, bounds and a file
      (wget --alt-svc-file); one Huffman code and field record for HPACK
      and QPACK; wget --http3/--no-http3; QuicTest end to end with the
      TCP fallbacks
- [ ] libhttp HTTP/3 next: race QUIC against TCP (happy eyeballs) instead
      of waiting AltServiceTimeoutMilliseconds (3 s) on a silently blocked
      UDP path; HTTPS DNS records (RFC 9460: libsystem's resolver keeps
      no data of unknown record types, so it needs raw RDATA and an SVCB
      parser first); drop non-persist Alt-Svc entries when the network
      changes (needs a notification); an HTTP/3 check in wgettest (guestfwd
      is TCP only, but slirp passes UDP to 10.0.2.2 to the host's
      loopback: needs a host HTTP/3 server for many connections with a
      certificate under the test root); libquic's own waits (a full send
      buffer, MAX_STREAMS) to wait in slices too, so a large upload does
      not hold the connection's lock
- [x] libhttp: Brotli and zstd content codings, decoded in pieces as
      the body arrives (libcompression's streaming decoders)
- [ ] libhttp: proxies (http_proxy, CONNECT), 100-continue, a PING keep-alive and idle timeout for
      HTTP/2, the full UTS #46 mapping and NFC for IDNA, the full public
      suffix list on the system disk, a persistent cookie store for the
      browser, HSTS, CORS and the rest of Fetch's request modes (libweb)
- [x] wgettest's HTTP/2 server address (10.0.2.107) in the test
      certificate (server.pem reissued), so those checks verify
- [x] Control Panel network page (DHCP or a static address per interface,
      DNS servers, live status; changes through the system settings service)
- [x] Taskbar network icon (connected, connecting, no address, no cable, no
      adapter; a pop-up listing the interfaces); balloons when the link goes
      down or up wait for notification balloons on the desktop
- [x] IPv6: input and output over Ethernet and lo, extension headers,
      reassembly, ICMPv6, Neighbor Discovery (neighbour cache, DAD), router
      solicitation and advertisements (SLAAC, default route, MTU, RDNSS),
      MLDv2 reports, IPv6 routes, TCP/UDP/ICMP sockets of both families;
      resolver ordering (IPv6 first when reachable) and DNS over IPv6; ping
      -6, ifconfig inet6, route -6, ndp, netstat tcp6/udp6, nc -6, wget
      [v6] URLs; per interface Ipv6Method in Network.settings, the Control
      Panel and the network pop-up
- [x] DHCPv6 (RFC 8415) in the network service: the routers' M and O
      flags (kernel `Ipv6RouterFlags`), stateful addresses (IA_NA:
      Solicit/Advertise/Request/Reply, Renew/Rebind/Release) with their
      lifetimes in the kernel, information-request for DNS servers and
      the search list, a DUID-LLT kept in /var/lib/network; Ipv6Method
      dhcpv6; ifconfig, the state files and the Control Panel; host tests
- [ ] DHCPv6 later: Confirm after the link comes back, Reconfigure,
      prefix delegation (IA_PD), Decline of a duplicate, an in-QEMU test
      against a DHCPv6 server of the test script's own
- [x] IPv6 later: privacy addresses (RFC 8981), sending fragments and
      path MTU discovery (Packet Too Big, a destination cache, TCP's MSS),
      redirects, MLD and IGMP reports for groups programs join with
      multicast sockets, source address selection's full RFC 6724 policy
      table (and the resolver's destination order), v4-mapped addresses
      on IPv6 sockets, a stable-privacy identifier (RFC 7217) instead of
      EUI-64
- [ ] IPv6 and multicast later: drivers programming their multicast
      filters (the hook is there), the IPv6 options kept in
      Network.settings, IPv4 fragments sent and IPv4 path MTU for UDP,
      delayed (random) answers to MLD and IGMP queries, ping -s over
      fragments
- [ ] Wi-Fi (later, a project of its own): the Intel CNVi driver
      (Alder Lake-P, 8086:51f0) with its firmware from linux-firmware
      (iwlwifi licence, in firmware/ beside the Realtek files), scanning,
      WPA2/WPA3 (802.11 frames, the 4-way handshake, CCMP), and choosing
      a network from the desktop
- [x] TCP window scaling and SACK; keep-alives: window scaling,
      timestamps (PAWS, RTTM), SACK with RFC 6675 recovery and NewReno
      without, receive/send buffers that grow to 4 MiB, keep-alives
      (SocketOptionKeepAlive/KeepIdle/KeepInterval/KeepCount; sshd's
      TCPKeepAlive), TcpPathMtuChanged for path MTU discovery
  - [ ] D-SACK; CUBIC; limited transmit (RFC 3042)
- [x] SSH server: libssh (transport with rekeying, curve25519-sha256
      and its libssh.org name, strict key exchange, ext-info with
      server-sig-algs; chacha20-poly1305@openssh.com, aes256-gcm and
      aes128-gcm; ssh-ed25519 and ecdsa-sha2-nistp256 host keys made on
      the first start, in OpenSSH's key file format; publickey with
      ed25519, ecdsa and rsa-sha2-256/512 keys from
      ~/.ssh/authorized_keys, and password; session channels with
      pty-req, shell, exec, env, window-change, signal, flow control and
      exit-status, several per connection), `sshd` (a process per
      connection, the `sshd` service, /etc/ssh/sshd_config) and
      `sftp-server` (SFTP 3 with posix-rename, expand-path, fsync and
      limits); Ed25519 and deterministic ECDSA signing in
      libcryptography; host tests (RFC 8032, RFC 6979, packets, the kex
      hash, an in-memory client) and scripts/test-ssh.py with OpenSSH's
      ssh, scp and sftp
- [x] SSH later: post-quantum key exchange (mlkem768x25519-sha256 with
      ML-KEM-768 in libcryptography, offered first), port forwarding
      (direct-tcpip, tcpip-forward, AllowTcpForwarding, GatewayPorts,
      PermitOpen), agent forwarding (a named port per session:
      SSH_AUTH_SOCK=port:NAME), the authorized_keys options, user
      certificates (TrustedUserCAKeys, cert-authority) and a host
      certificate, keyboard-interactive, publickey-hostbound, server
      keep-alives (ClientAliveInterval/CountMax), sshd_config Match
      blocks, constant time P-256 signing, an ssh client with
      ssh-keygen and ssh-add
- [ ] SSH after that: sntrup761x25519-sha512 (only ML-KEM is there),
      scp in the system (an SFTP client), encrypted private key files
      (ssh-keygen -N, bcrypt-pbkdf and aes256-ctr), ssh_config files,
      a local ssh-agent, X11 forwarding
- [x] libquic (web platform phase 1): QUIC v1 client (RFC 9000/9001/9002:
      packets, coalescing, Initial keys, AES-GCM and ChaCha20-Poly1305
      protection, header protection, key updates, Retry and Version
      Negotiation, transport parameters, streams with flow control,
      ACK ranges, loss detection, PTO, NewReno, pacing, idle timeout,
      stateless reset, NEW_TOKEN, a 1452-byte path MTU probe), libtls's
      QUIC mode (Tls.Quic), QPACK (static table, Huffman, dynamic table
      decoder with blocked sections, static+literal encoder) and an
      HTTP/3 client (control and QPACK streams, SETTINGS, GOAWAY,
      streaming requests and responses, trailers); libquic.so, h3get;
      host tests (RFC 9001 and RFC 9204 vectors, loopback connections
      against a test server, curl's HTTP/3 against that server)
- [x] libquic: HTTP/3 in libhttp behind its protocol-independent
      interface with Alt-Svc discovery (phase 2); QPACK on libhttp's
      Huffman code (one copy)
- [ ] libquic next: h3get and coretest
      against real servers (not tried yet: no outside network in the
      tests); 0-RTT and session resumption over QUIC (libtls's QUIC
      mode turns tickets off); connection migration and NEW_CONNECTION_ID
      issued by the client (only the handshake's ID is used); CUBIC;
      ECN; DPLPMTUD beyond the single 1452-byte probe; a QPACK encoder
      that uses the dynamic table; server push (refused now); libtls
      matching IPv6 literals against the certificate
      (h3get to [::1] needs a name)

## ARM64 port

Target: Raspberry Pi 4 / 400 / CM4 with the EDK2 RPi4 UEFI firmware (ACPI
mode); developed on `qemu-system-aarch64 -machine virt,gic-version=2 -cpu
cortex-a72` (see "The AArch64 port" in docs/Architecture.md).

- [x] Toolchain: AArch64 cross compiler built from the FPC 3.2.2 sources
      (`make toolchain ARCH=arm64`), binutils for AArch64; the loader linked
      as a self-relocating PIE and converted to PE by `objcopy`
- [x] `ARCH=arm64` build (`build/arm64`), `make run ARCH=arm64`
- [x] `boot/uefi/arm64`: translation tables (RAM-only window, framebuffer
      write-combining, SPCR UART), EL2 to EL1 drop, hand-off
- [x] `kernel/core/arm64`: exception vectors, trap frames, context switch,
      priority levels (GIC priority mask), FP/SIMD state, user copies,
      SVC system call entry, cache and TLB maintenance
- [x] `kernel/memory/arm64`: translation tables (4 KiB granule, 48-bit,
      TTBR0 user / TTBR1 kernel, MAIR normal / device / non-cacheable)
- [x] `hal/arm64`: GICv2 (MADT), generic timer (GTDT), PL011 and mini UART
      (SPCR), PSCI (FADT): secondary processors, power off, reset
- [x] Device interrupts: GIC SPIs, message interrupts through GICv2m
- [x] Boots to the end of the kernel self tests under QEMU virt, with the
      firmware at EL1 and at EL2 (`make arm64-test`, not in `make test`)
- [ ] Wire `make arm64-test` into `make test` once qemu-system-aarch64 and
      edk2-aarch64 are standard requirements
- [x] User mode: an AArch64 exception context in the ABI (X0-X30, SP, PC,
      PSTATE; CallContinue), the user runtime library and programs built for
      AArch64, the ELF loader accepting AArch64 programs (TLS variant I,
      TLS descriptors), the system disk; text shells, coretest, the
      graphical session with a USB keyboard and tablet
      (`scripts/test-qemu-arm64-user.sh`, `scripts/test-arm64-session.py`)
- [x] Address space identifiers (no TLB flush on every address space switch)
- [x] Instruction cache synchronized for user code pages
- [x] The time of day from the firmware's GetTime (passed by the loader)
- [ ] 16-bit ASIDs where the processor has them (TCR_EL1.AS)
- [ ] AHCI finds no drives on QEMU's virt machine; PCI line interrupts
      (INTx: AC'97, e1000) never arrive there (coretest's AC'97 and optical
      drive checks fail on AArch64 for that)
- [ ] The AES instructions (ARMv8 Crypto Extension, where present: not on
      the Pi 4) and a hardware random seed (RNDR on ARMv8.5, or a kernel
      entropy call) for libcryptography on AArch64
- [ ] Floating point exceptions on AArch64: check FPSR in the runtime
      (Free Pascal 3.2.2 does not), so division by zero raises EZeroDivide
- [ ] Suspend to RAM (PSCI SYSTEM_SUSPEND) and the real-time clock (UEFI
      runtime GetTime, or PL031 / the Pi 5's RTC)
- [ ] GICv3 (system register CPU interface, redistributors, ITS) for
      machines that have it
- [ ] PCIe I/O space window (`Hal.PortIo.SetPortIoWindow`) from the root
      bridge's `_CRS`
- [ ] Boot test on a real Raspberry Pi 4
- Raspberry Pi 4 drivers (its PCIe and these devices are not cache
  coherent, and some reach only the low 1 GiB; none of this has run on a
  Pi yet, see "Trying it on a Raspberry Pi 4" in docs/Architecture.md):
  - [x] ACPI platform devices: the namespace walk (_HID, _CID, _UID, _STA,
        _CRS, inherited _CCA and _DMA, _DSD properties), drivers bound by
        id, `devices` in the kernel debug shell, `make acpi-device-test`
  - [x] DMA attributes and cache maintenance (`Io.Dma`,
        `Hal.DmaCoherency`): uncached shared buffers, cleaned/invalidated
        streaming buffers, _DMA bus address translation; the
        `noncoherentdma` option exercises them under QEMU
  - [x] xHCI as an ACPI platform device (the VL805 as the firmware set it
        up), sharing the core with the PCI attachment
  - [ ] BCM2711 PCIe host bridge (its own configuration access and MSI
        controller), for firmware that does not describe the xHCI and
        for the Compute Module 4's PCIe slot
  - [x] GENET v5 Gigabit Ethernet: written, untested
  - [ ] GENET on hardware: check the register offsets, reset sequence and
        RGMII delays; suspend to RAM
  - [x] EMMC2 and Arasan SD controllers (SDHCI, PIO and ADMA2, SDSC and
        SDHC/SDXC, 4-bit high speed, card detect, quirks), tested on
        QEMU's sdhci-pci in `make test` and `make arm64-test`
  - [ ] SD: UHS-I (1.8 V through the firmware's regulator), eMMC
        (Compute Module 4: MMC initialisation, 8-bit bus), SDIO (Wi-Fi)
  - [x] VideoCore mailbox: firmware properties (board, serial, Ethernet
        address, clocks, temperature, power domains), `board` in the
        kernel debug shell
  - [ ] VideoCore mailbox: display (framebuffer modes), and the "notify
        xHCI reset" tag should the VL805 ever be reset through PCIe
  - [ ] The other PCI drivers (AHCI, NVMe, virtio, e1000, Realtek, HD
        Audio, AC'97) through `Io.Dma`, for non-coherent PCIe
  - [ ] GPIO and the PWM audio jack; HDMI audio on the Pi 4 (the Pi 5's
        driver would carry over: BCM2711 HDMI, legacy DMA channels)
  - [x] Debugging without a serial cable: the kernel log over UDP
        (`netlog=`, `scripts/netlog.py`, replayed from the first line,
        sent on after a panic), the debug shell over TCP (`netshell=`),
        an address of the kernel's own (`netaddr=`, `netdhcp=`)
  - [x] The PM watchdog (armed by default for 15 s, petted by a kernel
        timer, `watchdog=`, `panicreset=`), behind a generic watchdog
        interface (`Io.Watchdog`; the i6300ESB driver tests it in QEMU);
        reset falls back to it after PSCI
  - [ ] Reset and power off through the UEFI runtime services (needs the
        runtime regions mapped: SetVirtualAddressMap or an identity map
        at the call); the Pi's firmware does them through PSCI anyway
  - [ ] Service output (standard error) to the network log; the service
        manager's own messages already reach it through the console
  - [x] Network boot: the loader fetches options.txt, the kernel and the
        system image (a RAM disk, `ramdisk0`) from `netboot=http://` or
        `tftp://`, or after a firmware PXE/HTTP boot
        (`scripts/netboot-serve.py`, `make pi-netboot-serve`,
        `make arm64-netboot-test`); `make pi-sd-image` builds the card
  - [ ] Network boot on the Pi: check the firmware's HTTP and PXE
        clients on GENET; the firmware's own PXE/HTTP boot of the loader
        is untested (QEMU's edk2 offers no network boot option)
  - [x] Network boot: a compressed system image (xz, 4.9 MB for the
        64 MiB image; the kernel unpacks xz and gzip,
        `Drivers.RamDiskDecompression`, `make decompression-test`)
  - [ ] Network boot over HTTPS (the firmware has TLS)
- [x] The ext4 write test leaves a damaged orphan list on AArch64 (e2fsck:
      "Inodes that were part of a corrupted orphan linked list found"):
      deletion times came from a wall clock starting at zero (no RTC),
      which e2fsck takes for orphan links; they are now kept above the
      inode count and the volume's last write time
- Raspberry Pi 5 (later): RP1 south bridge drivers (UART, Ethernet, USB),
  its UEFI port's tables, PAN and LSE atomics, its real-time clock
- Raspberry Pi 5, native boot (EEPROM bootloader, device tree, no UEFI;
  see "Trying it on a Raspberry Pi 5" in docs/Architecture.md):
  - [x] Boot media: `make pi5-sd-image` (config.txt, cmdline.txt, the
        device trees, fpos.img, system.img as the RAM disk),
        `make pi5-eeprom-image` (a recovery card setting BOOT_ORDER=0xf12
        and TFTP_IP; the bootconf.txt embedding in
        `scripts/pi5_eeprom_image.py`, `make pi5-eeprom-test`),
        `make pi5-netboot-serve` (TFTP with the serial number prefix)
  - [ ] First boot on the board: check that the firmware passes a
        simple-framebuffer node with `dtoverlay=vc4-kms-v3d-pi5`, and
        without it; which pixel format (framebuffer_depth=32 honoured?)
  - [ ] Network boot on the board: the bootloader's TFTP requests (the
        prefix probe, block size, whether the 64 MiB system image fits
        in TFTP_FILE_TIMEOUT with the Python server), the SD fallback
        time with the PC off
  - [ ] HTTP boot instead of TFTP (no root on the PC): boot.img/boot.sig
        signed with a key of our own written into the EEPROM (pubkey.bin:
        the RSA-2048 modulus and exponent, little endian)
  - [x] A compressed system image: system.img is
        build/arm64/system-disk.img.xz (4.9 MB, about 21 s at the
        firmware's 230 KB/s TFTP, where the plain 64 MiB image was cut
        off at 14 MB by TFTP_FILE_TIMEOUT); the kernel unpacks it
        (`SYSTEM_IMAGE_COMPRESSION=gzip|none` for the others)
  - [ ] A compressed kernel (the firmware unpacks a gzip kernel=); fpos.img
        is under 1 MiB, so not needed yet
  - [ ] Smaller system image content: the 24 MiB that is not free space
        is the files themselves (libsystem.so 4.3 MiB, the icon theme
        4.5 MiB of .ico, unstripped programs); ext4 leaves its free
        blocks zero, so they cost nothing compressed
  - [x] Native boot image and device tree foundation: `make ARCH=arm64
        native` (build/arm64/native/fpos.img: Linux arm64 Image header, a
        self-relocating stub carrying kernel.elf, boot information 6 with
        the tree), the device tree reader shared by stub and kernel
        (`shared/DeviceTree.*`, `make device-tree-test`), discovery
        without ACPI (GIC, timer, PSCI, processors, console UART,
        simple-framebuffer incl. r5g6b5, ECAM PCI hosts with BAR
        assignment and interrupt-map), DT platform devices bound by
        compatible (`Io.DeviceTreeDevices`, `Io.PlatformProperties`),
        `make arm64-native-test` (QEMU -kernel/-initrd, EL1 and EL2,
        netlog and the TCP shell over virtio-net)
  - [x] Pi 5 drivers, written from Linux's and NOT yet tested on the
        board (QEMU has no Pi 5): the BCM2712 PCIe root complex
        (`Drivers.BrcmPcie`: the firmware's link kept or a cold start,
        windows from ranges/dma-ranges, config space through the
        index/data window, BARs placed as the tree expects), the MIP
        (`Drivers.Bcm2712Mip`) as pcie2's message controller, RP1
        (`Drivers.Rp1`, `Drivers.Rp1Interrupts`: BARs, chip id, MSI-X
        through MSIX_CFG, its DT peripherals as platform devices with
        working memory and interrupts), the Cadence GEM Ethernet
        (`Drivers.CadenceGem`, `Drivers.EthernetPhy`), the DWC3 USB
        controllers as xHCI hosts (`Drivers.Dwc3`), the SD slot
        (`Drivers.Sdhci.Bcm2712`), the PM watchdog by its DT node; the
        kernel DHCP says "no network card" once
  - [x] Pi 5 PCIe cold start must not hang: no root complex access while
        the bridge reset line is asserted (PERST# was written then), resets
        through the tree's reset controllers (`Drivers.BrcmResets`), every
        wait timed out, `FAILED at step N` plus registers and the boot goes
        on; the watchdog armed before PCIe with its timer pets suspended
        during the probe; SErrors unmasked during the probe
  - [ ] Pi 5, first boot with the drivers: read the `[pcie]`, `[mip]`,
        `[rp1]`, `[gem]`, `[dwc3]` lines (docs/Architecture.md, "What the
        Pi 5 drivers log"); then netlog, SSH
  - [x] Pi 5 HDMI audio, written from Linux's vc4_hdmi.c and NOT yet
        tested on the board: the mailbox by its DT node, the BCM2712 DMA's
        40-bit channels with cyclic control blocks (`Drivers.Bcm2712Dma`),
        `Drivers.HdmiAudio` on the firmware's HDMI link (clocks checked
        through the mailbox, TMDS clock measured, N/CTS from the HDMI
        table, MAI, audio packets and InfoFrame, IEC 60958 slots played
        round by DMA, silence while idle), volume by the mixer;
        `make hdmi-audio-test`
  - [ ] Pi 5 HDMI audio on the board: `tone 440 2` over SSH and read the
        `[mailbox]`, `[dma]`, `[hdmi-audio]` lines (docs/Architecture.md,
        "What the Pi 5 drivers log")
  - [ ] HDMI audio: the EDID over DDC (a `brcm,brcmstb-i2c` driver) for
        the sink's audio formats and speakers; the hot plug interrupts
        (a display plugged in after boot); DMA interrupts instead of the
        10 ms timer; more than two channels and rates other than 48 kHz
        (the mixer's rate is fixed; N/CTS, MAI and channel status already
        take 32 to 192 kHz); the audio InfoFrame's speaker allocation from
        the EDID
  - [ ] Pi 5: the PHY reset line (RP1 GPIO 32, "phy-reset-gpios") if the
        PHY does not answer; an RP1 GPIO driver
  - [ ] Pi 5: UHS-I on the SD slot (1.8 V through the SD_IOVDD_SEL GPIO,
        tuning); RP1's UARTs (`arm,pl011-axi`), I2C, SPI; pcie1's INTx
        and devices behind a switch (only 01:00.0 is used)
  - [ ] Framebuffer fallback through the VideoCore mailbox (allocate a
        framebuffer as Circle does) when the firmware gives no
        simple-framebuffer
  - [ ] GICv3 driver (the tree's `arm,gic-v3` is parsed; the HAL drives
        GICv2 only), spin-table processors, virtio-mmio devices (listed
        as platform devices, no transport driver)
  - [ ] PCI bridges below an ECAM root bus get no windows assigned (QEMU
        virt has none); I/O BARs are assigned but the port window
        (`Hal.PortIo.SetPortIoWindow`) is not set

## Web platform: style engine (libcss)

- [x] CSS Syntax Level 3 tokenizer and parser with error recovery; CSS Nesting
- [x] Style sheet object model with CSSOM serialization; cssdump
- [x] Selectors Level 4 (:is/:where/:not/:has, nth-child of S, attribute flags,
      pseudo-elements), right-to-left matching, ancestor bloom filter, rule
      buckets by id, class and type
- [x] Values: units of Values 4, math functions, colors (Color 4/5 with
      color-mix), gradients, transforms, var() and env()
- [x] Property table (about 220 longhands, logical properties, 55 shorthands)
- [x] Media queries 4/5 with the range syntax; @supports; @layer; @import;
      @font-face, @keyframes, @page and @property parsed
- [x] Cascade 5 (origins, importance, layers, style attribute, revert,
      revert-layer) and computed values in shared, interned style structs;
      style sharing cache
- [x] HTML user agent style sheet and quirks mode additions
- [x] Host test (make css-test) and coretest lines for cssdump
- [ ] Container queries: evaluate @container once layout knows container sizes
- [ ] :visited privacy (two styles per link, only color differences shown)
- [ ] Relative color syntax, light-dark(), @scope, @counter-style,
      @font-feature-values
- [x] SVG painting properties (fill, stroke and its parts, stop-color,
      stop-opacity, text-anchor, paint-order, vector-effect, clip-rule)
- [ ] SVG's other properties (marker-*, mask as a property, filters'
      flood/lighting colours, dominant-baseline, geometry properties)
- [ ] Run transitions and animations (interpolation per animation type)
- [ ] Gamut mapping in OKLCh instead of clipping
- [ ] Incremental restyle (invalidation by changed class, id, attribute or state
      instead of restyling the subtree)

## SVG (libsvg)

- [x] XML parser (namespaces, entities from the internal subset, CDATA),
      styling with libcss (<style>, presentation attributes, style attribute)
- [x] Shapes, path data with arcs, fill rules, strokes (width, caps, joins,
      miter limit, dashes, non-scaling), transforms, viewBox and
      preserveAspectRatio, nested svg, use and symbol (restyled under the use)
- [x] Paint servers: linear and radial gradients (units, transforms, spread,
      href inheritance), patterns; opacity groups, clip paths, masks
- [x] Text (text, tspan, x/y/dx/dy/rotate, text-anchor, kerning, spacing),
      <image> with data: URLs (SVG included)
- [x] SVG as a scalable image in libimage's registry (img, CSS url(),
      favicons), inline SVG in libweb, drawn at the device size
- [x] Host test (make svg-test) and a webrender reference page
- [ ] Markers; textPath along its path; text decorations, vertical and
      bidirectional text
- [ ] Filters (feGaussianBlur, feColorMatrix, feOffset, feMerge, ... and CSS
      filter: url())
- [ ] SMIL animation; CSS transforms and animations on SVG elements
- [ ] External references (use and image of other URLs, through the loader),
      foreignObject's HTML, .svgz without Content-Encoding
- [ ] Hit testing inside inline SVG (pointer events per element)

## JavaScript engine

- [x] libjavascript: NaN-boxed values, Latin-1/UTF-16 strings with ropes, atoms
- [x] Shapes with weak transitions, dictionary mode, dense elements, inline caches
- [x] Lexer, parser, scope analysis, register bytecode, interpreter without Pascal recursion for JS calls
- [x] Precise mark-and-sweep collector at safe points; weak maps, WeakRef, FinalizationRegistry
- [x] ES5 and ES2015+ language: let/const/TDZ, classes (fields, static blocks, private names, accessors),
      destructuring, default/rest/spread, template and tagged literals, generators, async/await,
      async generators and for await, optional chaining, nullish operators, exponent, BigInt
- [x] Built-ins: Object, Function, Array, String, Number, Boolean, Symbol, Math, JSON, errors,
      Map/Set (with the set methods), weak collections, Promise, iterator helpers, Reflect, Proxy, Date, RegExp
- [x] RegExp engine: named groups, lookbehind, unicode and sticky flags, indices
- [x] Embedding API (Js.Engine): host functions and classes with native data, jobs, memory limit, interrupts
- [x] js shell with REPL, timers, print/load; host test with scripts, API checks and benchmarks
- [x] Modules (all import/export forms, live bindings, cycles, top-level await, import.meta, import(),
      JSON modules) with host resolve/fetch hooks; direct eval with the caller's scope; with
- [x] Typed arrays (all kinds, Float16Array), ArrayBuffer (resizable, transfer), SharedArrayBuffer,
      DataView, Atomics (one agent), Uint8Array base64/hex; buffers without copies in the embedding API
- [ ] structuredClone (with libweb: it is an HTML algorithm)
- [x] Intl (en-US: NumberFormat, DateTimeFormat, Collator, PluralRules, Segmenter, ListFormat),
      String.prototype.normalize, Annex B escape/unescape, HTML methods, RegExp legacy statics
- [ ] Unicode tables generated from the UCD for normalize and RegExp scripts (hand-written subsets now);
      more Intl locales
- [x] Sloppy mode mapped arguments
- [x] Incremental sweeping with pause statistics; lazy compilation of function bodies
- [ ] Incremental or generational marking (needs a write barrier on reference stores)
- [x] Polymorphic inline caches (four shapes per site)
- [ ] Fused instructions for more cases; deeper prototype chains in the inline caches

## Tooling

- [x] `make test`: boot headless in QEMU, fail on panic or missing self-test results
- [x] Test disk with one partition per supported file system
- [x] System disk (ext4, FPOSROOT) built from the userland without root rights
- [ ] Continuous integration running `make test`
- [ ] GDB helper script (load symbols, break on panic)
- [ ] Suspend: a cancel handshake when a processor fails to freeze (the
      "not suspending" path leaves its FreezeRequested set, so it would
      freeze later and never be woken)
- [ ] Rare hang under TCG (about 1 run in 10, seen twice): during the sound tests
      two threads (sh creating a process, tone writing to /dev/audio) spin in
      CpuRelax with the other processors idle. The hang dump now prints the
      kernel return addresses on the spinning stack: catch it again and follow
      them
- [ ] Rare boot hang under KVM: the SSH test once saw no shell prompt within
      180 s (it then passed 11 runs in a row); the serial log was lost, so
      catch it again
- [ ] Self test "exited threads did not release their stacks"
      (TestThreadExitAndCleanup) panicked once on arm64 with ten QEMU
      machines running at once: probably a fixed wait too short under load

## Web engine (libweb)

Part 1 (encodings, HTML parsing, DOM):
- [x] Atoms with the well-known HTML/SVG/MathML names as constants; 16 bit
      namespace ids
- [x] Encoding Standard: labels, streaming UTF-8 / UTF-16LE/BE / single-byte /
      x-user-defined / replacement decoders, BOM sniff, meta prescan, HTML
      encoding sniffing, UTF-8 encoder, UTF-16 offset helpers
- [ ] Decoders (and encoders) for the multi-byte CJK encodings: GBK, gb18030,
      Big5, EUC-JP, ISO-2022-JP, Shift_JIS, EUC-KR (labels recognized, read as
      windows-1252 for now); single-byte encoders for form submission
- [x] HTML tokenizer (all states, all 2231 named references, error codes),
      streaming in any pieces
- [x] Tree construction: all insertion modes, adoption agency, foster
      parenting, templates, foreign content, quirks, fragment parsing
- [x] Script hooks: script host at script end tags, insertion point,
      document.write, pause/resume; meta charset changes and restarts
- [ ] The 2025 customizable `<select>` parser changes (the classic "in select"
      modes are implemented)
- [ ] Declarative shadow roots (`<template shadowrootmode>`) and shadow trees
      in the DOM (slots, retargeting, composed events)
- [ ] Form owners of form-associated elements (the parser's form pointer)
- [x] DOM core: nodes, mutation algorithms with validity checks, Attr nodes,
      ids, live NodeList/HTMLCollection, DOMTokenList, NamedNodeMap, cloning,
      comparison, namespaces, observer hooks, lifetime (references and
      collection)
- [x] Events: EventTarget, capture/bubble dispatch, once/passive, stop flags
- [ ] Ranges and StaticRange, NodeIterator/TreeWalker (the mutation algorithms
      mark where live ranges are adjusted)
- [x] MutationObserver on the observer hook (the script bindings)
- [x] HTML fragment serialization, innerHTML/outerHTML/insertAdjacentHTML
- [x] `htmldump`; host test (`make web-test`) with html5lib-format cases
- [ ] Text kept in a document arena instead of one string per node (about
      150 bytes per node today, text included)

Part 2 (style, layout, painting):
- [x] libcss adapter over the DOM (atom map, no per-element allocation),
      document sheets (UA + engine additions, <style>, <link> from the
      resources, user sheets), style attributes, presentational hints,
      top-down styling with the bloom filter, incremental restyle through
      the document observer, change kinds (boxes / layout / paint)
- [x] Resources hook for the loader (`TDocumentResources`: element sheets,
      element images, url() images with `OnImageNeeded`, imports)
- [x] Fonts from /lib/fonts, family matching with generics, weight and
      slant, per-character fallback, measurement cache, DPI-independent
      layout in CSS px
- [x] Box tree: display types, anonymous boxes, ::before/::after/::marker,
      counters and quotes, display contents/none, box reuse on rebuild
- [x] Block layout with margin collapsing, floats and clear, inline layout
      (white space, breaking, alignment, vertical-align, spacing,
      transform), positioning (relative, absolute, fixed; sticky as
      relative), overflow and scroll containers, replaced elements with
      object-fit, flexbox (full algorithm), tables (auto layout, spans,
      captions, vertical-align), incremental relayout of dirty subtrees
- [x] Display list in Appendix E order, raster with damage rectangles
      (backgrounds, gradients, images, borders with radii, shadows, text,
      opacity, rounded clips), hit testing
- [x] `webrender` (/bin and host), `make web-layout-test` with reference
      pages and layout dumps
- [x] Grid layout, basic: templates with repeat()/minmax()/fr/auto-fill,
      areas, line and span placement, auto placement (row/column, sparse),
      implicit tracks, simplified track sizing, alignment, gaps
- [ ] Grid: subgrid, dense packing, baseline alignment, named lines, the full
      intrinsic track sizing algorithm
- [ ] Fixed table layout, collapsing borders, `visibility: collapse`
- [x] Synthetic bold and oblique for faces the system lacks; paint-only
      restyle without relayout
- [x] @font-face loading: TrueType and WOFF 1 faces join the font library
      (Web.Loading.LayoutSink, Web.Text.Woff); fonts re-bound in place
- [ ] Bidi and writing modes, shaping beyond kerning, WOFF2 and CFF web
      fonts (web fonts are process-wide, not per document),
      ::first-line/::first-letter
- [x] position: sticky (offsets at painting and hit testing time under
      the viewport, when the list is built in inner scroll containers)
- [x] CSS masks (mask-image and friends, -webkit- names, the shorthand),
      composited through the layers' alpha
- [x] :hover/:focus changes restyle only what selectors reading them reach
      (Css.StateInvalidation); the parser nests at most 512 deep
- [ ] Inline boxes split around blocks, relative inline boxes,
      transforms, filters, blend modes, clip-path,
      border-image, conic gradients, blurred text shadows
- [x] Scrollbars (the web view's: theme bars for the viewport, thin bars in
      scroll containers)
- [ ] Incremental display list updates

Later phases: loading through libhttp, JavaScript bindings (wrappers in
the node's rare data, `TScriptHost`, element interface classes via
`ElementClassFor`).

Part 2, loading side (event loop, fetch, loading, navigation):
- [x] Event loop: task queues by source, microtasks with an engine hook,
      delayed tasks, timers with nesting clamps, animation frame callbacks,
      rendering opportunities, thread-safe posting, WaitForWork
- [x] Fetch layer over libhttp: modes, credentials, destinations, referrer
      policy, CORS with preflight cache, mixed content, HSTS, data:,
      about:blank, file:, MIME sniffing, nosniff, CSP parsed and stored,
      redirects decided per hop, Sec-Fetch-* fields
- [x] Document loading: streaming parse, encoding restarts, text and image
      documents, readyState, DOMContentLoaded/load/pageshow timing, error
      pages, downloads
- [x] Subresources: link style sheets with @import chains, img with
      srcset/sizes/picture (decoded on threads, downscaled), @font-face,
      favicon, link preload, preload scanner, RFC 9218 priorities
- [x] Script scheduling (parser-blocking, defer, async, in-order, modules)
      for a `TScriptExecutor` (Web.Script.PageScripting runs them)
- [x] The layout's resource sink (Web.Loading.LayoutSink): sheets, imports
      of <style> sheets, images with natural sizes, url() images, web fonts;
      host test renders a fetched page
- [x] Navigable with session history: navigate, fragments, back/forward,
      reload, stop, meta refresh, unload events, observer notifications;
      `TWebPage` for embedders
- [x] Host test (`make web-load-test`) with an in-process HTTP server
- [ ] CSP enforcement and Subresource Integrity (stored on requests now)
- [x] history.pushState/replaceState (TNavigable.ChangeUrlFromScript)
- [ ] bfcache; popstate's state object across documents
- [x] Form submission from the web view (GET and POST, urlencoded)
- [x] iframes and nested navigables (child navigables, joint session history)
- [ ] multipart/form-data
- [ ] Animated images (only the first frame goes to the sink); decoding
      images progressively as they arrive
- [ ] ORB (opaque response blocking) for no-cors responses; blob: URLs
- [ ] Lazy @font-face loading driven by layout (`TFontLoader.LoadFace`
      exists; fonts load eagerly by default)
- [ ] The preload scanner sees only bytes that arrive while the parser
      waits; the parser's own unparsed input is not scanned

Script bindings (`Web.Bindings*`, `Web.Script*`):
- [x] WebIDL files and `make-bindings.py`: interfaces, mixins, partials,
      dictionaries, enums, callbacks, typedefs, overloads, constants,
      reflection by extended attributes; tables plus declared routines
- [x] Dispatcher with WebIDL conversions (integers with EnforceRange/Clamp,
      strings, nullable, unions, sequences, records, dictionaries, enums,
      callbacks), brand checks, [SameObject], [PutForwards], [Replaceable],
      [LegacyUnforgeable] on the window, legacy platform objects
- [x] Wrappers: one per node, kept by tree groups through a weak processor;
      events, owned and node-owned objects; bytes per wrapper reported
- [x] Interfaces: EventTarget, Event and the UI events, Node and its kinds,
      Document, DOMImplementation, Element, the HTML element interfaces with
      reflection, collections, DOMTokenList, NamedNodeMap, DOMStringMap,
      DOMException, CSSStyleDeclaration (inline style), Window, Location
      (read only), History and Navigator, TextEncoder/TextDecoder, URL,
      URLSearchParams, MutationObserver, atob/btoa, structuredClone, timers
- [x] Scripts: inline at the parser's script end tags, document.write,
      dynamically inserted scripts, external scripts through
      `TScriptEnvironment.FetchClassicScript`, event handler attributes and
      properties, errors to the console with file and line
- [x] Host test (`make web-script-test`, `JS_GC_STRESS=1` collects often)
- [x] Selectors through the style system's element adapter (hover, focus
      states shared)
- [x] Module scripts through the loader (resolver and fetcher per context)
- [ ] Import maps (bare specifiers fail)
- [x] The event loop's side of `TScriptEnvironment` (Web.Script.PageScripting:
      timers, navigation, history, prompts, cookies, viewport) and the
      loader's `TScriptExecutor`; host test with a scripted page
- [ ] ErrorEvent and window.onerror for reported exceptions;
      unhandledrejection
- [ ] document.open() replacing a loaded document; document.write from
      timers after loading (refused with NotSupportedError today)
- [ ] Event handler scope (form and document in the scope chain: needs the
      with statement or an environment hook in libjavascript), onerror's
      five arguments, body/frameset handlers forwarding to the window
- [x] getComputedStyle from the style system; layout answers (offset*,
      client*, scroll*, getBoundingClientRect, elementFromPoint) through
      `TScriptLayout`
- [x] Focus tracking (document.activeElement, Web.Dom.Focus's focusing
      steps from script and the input code)
- [ ] AbortSignal for addEventListener's signal option
- [x] Typed arrays: TextEncoder.encode gives a Uint8Array (checked in the
      browser)
- [x] Platform scripts (built-in JavaScript over natives): Performance,
      Storage, fetch/Request/Response/Headers, AbortController,
      XMLHttpRequest, Blob/File/FileReader/FormData, streams, crypto,
      matchMedia, screen, animation frames, idle callbacks, postMessage,
      MessageChannel, BroadcastChannel, IntersectionObserver,
      ResizeObserver, FontFace, CSS.supports/escape, Image/Option
- [x] iframes: about:blank and srcdoc windows in a realm of the parent's
      engine (libjavascript: several realms per runtime)
- [x] iframes with src documents: loading (sandbox, X-Frame-Options,
      frame-ancestors, lazy), layout, painting, input, cross-origin views,
      postMessage across origins; dedicated workers
- [ ] `<object>`/`<embed>` documents; frameset layout; a WindowProxy for
      sandboxed frames without scripts; Permissions Policy (allow)
- [ ] reCAPTCHA in the OS: the anchor renders, but in QEMU it showed
      "Could not connect to the reCAPTCHA service" (on the host the
      widget initializes); find out what times out
- [ ] Shadow DOM interfaces, Range/Selection, TreeWalker, CSSOM sheets
      (document.styleSheets, insertRule), Web Animations, synchronous XHR
- [x] Brotli and zstd content codings (Accept-Encoding offers gzip,
      deflate, br and zstd)
- [ ] Google search: the challenge runs (its token equals Firefox's for
      the same inputs) but Google sends this engine to its CAPTCHA page
- [ ] A cheaper interface object: native accessors keyed by property in
      libjavascript would let one getter serve every attribute (a window
      costs about 420 KB of script heap over the bare realm today)

## Web view and browser

- [x] libwebview: TWebView (event loop on the GUI thread, backing surface
      with scroll moves, theme scroll bars, hover/active/focus states,
      CSS cursors, links with dispositions, selection and copy, find,
      zoom with the display scale, forms, context menu, prompts, console)
- [x] Browser (/app/browser): tabs, address bar with URL detection and a
      search URL setting, back/forward/reload/stop/home, bookmarks bar and
      menu, history and about pages, downloads to ~/Downloads, find bar,
      zoom, settings (home page, search URL, HTTP/3, JavaScript); in
      test-input
- [x] Web view: KeyboardEvents to the page, a text editor in fields
      (caret, selection, word moves, clipboard, input events, implicit
      submission, change on blur); values in the DOM's control state
- [ ] Web view: drawing a field's selection, dragging the bars of inner
      scroll containers, drag and drop, IME
- [ ] Web view: lazy images near the viewport, animated images, printing
- [ ] Browser: session restore, per-site settings, a downloads window with
      cancel buttons, separate windows (Shift+click opens a tab), tab drag
- [x] webbrowse (make webbrowse): the engine on real sites from the host
      (PNG, layout, DOM, console, network log, phase times, memory, hover
      timing, a sampling profiler, a watchdog with stacks)
- [x] Wikipedia (Main Page, articles, search, en.m redirect) loads and
      renders: grid minmax(0, 1fr), sticky contents, masked icons, no
      crash on resize or on a layout before the first bytes; bounded HTTP
      and decode threads; slow layouts throttled in the web view
- [x] Wikipedia's JavaScript gets past ResourceLoader's compatibility
      check (localStorage, IntersectionObserver)
- [ ] Wikipedia's TOC and menus as with JS (check in the browser)
- [ ] Large pages in QEMU need the kernel's growable address-space region
      table (1024 regions run out on Wikipedia's Linux article)
- [ ] Interruptible style and layout (a first layout of a long page is one
      piece of work on the GUI thread)
- [x] getComputedStyle and layout metrics from the web view's layout
