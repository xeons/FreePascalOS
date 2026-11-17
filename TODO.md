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
- [x] Heap checking in the kernel heap and every program's heap (kernel option
      `heapchecks`, `HEAP_CHECKS`): fill patterns that make freed pointers
      non-canonical, guards after blocks, double free detection, a quarantine
      checked when blocks leave it; on in every test boot
- [ ] Page heap (opt-in per program): every block on pages of its own,
      end-aligned against an unmapped guard page, freed pages unmapped and
      their addresses kept from reuse. Needs a reserve / commit / decommit
      call and an address space that is not a 1024-entry region table with
      first-fit reuse
- [ ] Heap checking for the physical page allocator (fill freed pages, keep
      them from reuse for a while)

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
  - [ ] Composite devices: a class driver per interface, several per device
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
      `Controls.IconTheme`) and the display server; window title icons
      not yet
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
- [ ] A small per-process cache of DNS answers; EDNS(0) for answers
      larger than 512 bytes over UDP
- [ ] DHCP: option overload (52), several offers compared, the random
      1-10 s wait before the first DISCOVER (left out to start quickly)
- [x] `netstat` (`-tuwlanp`, `-r`, `-i`, `-s`; the socket listing gives
      the owner process, protocol counters in the kernel)
- [x] `nc` (OpenBSD options: `-l -k -u -z -v -w -n -N -q -p -d`)
- [ ] `ss` (on top of netstat's pieces)
- [ ] Reverse lookups and a services list for `netstat` without `-n`
      (`Netstat.Names`)
- [x] `wget` (HTTP/1.1 and HTTPS: -O, -q, -S, -c, -T, -t, -U, redirects,
      chunked bodies, --no-check-certificate, --ca-certificate, --ciphers,
      a progress line); `wgettest` in QEMU against test servers on the host
- [x] TLS: libtls, a TLS 1.3 client (x25519; AES-GCM and ChaCha20-Poly1305;
      HelloRetryRequest, KeyUpdate, alerts) with X.509 chain, signature,
      validity and host name checks against the Mozilla CA list in
      /etc/ssl/certs; host tests with RFC 8448's handshake and OpenSSL
- [ ] TLS: name constraints (certificates with them are refused for now),
      P-256 key exchange (only x25519 is offered), session resumption,
      OCSP / revocation, TLS 1.2 for servers without 1.3, Ed25519 and P-521
      certificates
- [ ] wget: keep-alive (one request per connection now), cookies,
      authentication, recursion (-r), --trust-server-names, gzip
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
- [ ] IPv6 later: DHCPv6 (stateful addresses, the M and O flags), privacy
      addresses (RFC 8981), sending fragments and path MTU discovery
      (packet too big is ignored), redirects, MLD reports for groups
      programs join (no multicast sockets yet), source address
      selection's full RFC 6724 policy table, v4-mapped addresses on IPv6
      sockets, a stable-privacy identifier (RFC 7217) instead of EUI-64
- [ ] Wi-Fi (later, a project of its own): the Intel CNVi driver
      (Alder Lake-P, 8086:51f0) with its firmware from linux-firmware
      (iwlwifi licence, in firmware/ beside the Realtek files), scanning,
      WPA2/WPA3 (802.11 frames, the 4-way handshake, CCMP), and choosing
      a network from the desktop
- [ ] TCP window scaling and SACK; keep-alives

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
