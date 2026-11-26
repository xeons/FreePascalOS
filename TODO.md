# TODO

Roughly in the order they unblock each other. See `docs/Architecture.md` for
how the existing pieces fit together.

## Hardware discovery

- [x] Parse ACPI tables (RSDP from the loader → XSDT/RSDT → table lookup)
- [x] Use the MADT for I/O APICs and interrupt source overrides
- [x] Use the MADT processor list (starting the other processors)
- [x] FADT: power off, reset, sleep states (S3, S5)
- [x] HPET: driver (ACPI table, 32/64-bit counter, one-shot and periodic
      comparators, FSB / I/O APIC / legacy replacement routes checked by test
      interrupts, suspend to RAM), calibration order (hypervisor leaf, kvmclock,
      CPUID 15h/16h, HPET, ACPI PM timer, PIT), HPET clock source and TSC
      watchdog, HPET broadcast timer for deep idle states, call 236
- [ ] HPET follow-ups: a comparator per processor where enough have FSB
      delivery (no wake-up IPI); FSB messages under interrupt remapping (an IRTE
      with the HPET's source id from the DMAR/IVRS device scope); /dev/hpet or
      comparators for programs; the PNP0103 device's _STA (firmware that hides
      the HPET); the watchdog per processor (counters out of step between
      processors); verify CPUID 15h crystal figures and the PIT probe on real
      hardware that gates the PIT off
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
- [x] Split the dispatcher lock (per-processor scheduling locks; the dispatcher
      lock keeps only wait queues; work stealing by try-lock, idle pull)
- [x] Device interrupts spread over the processors (round robin, not the boot one)
- [x] Batched TLB shootdowns for large unmaps (one interrupt per 32-page run)
- [x] Processor affinity for threads and processes (taskset)

## Kernel core

- [x] Timeouts on waits, and alertable waits (`WaitForEventWithOptions`)
- [x] Mutexes (owner tracking, recursion)
- [x] Semaphores and reader/writer locks (kernel; semaphore objects for programs,
      calls 140-142, waitable with wait-for-all)
- [x] Named objects (events, semaphores, mutexes, sections and timers named
      and opened by name, create-or-open in libsystem; calls 200-205) and
      mutex objects for programs (calls 206-207: owner, recursion, waits for
      all, abandonment reported as WaitAbandoned)
- [x] Use shared locks for more read-mostly lookups (handle table reads without
      the process lock, the process registry, the mount list)
- [ ] Node cache lookups without the volume's operation lock (every file
      operation holds the volume lock throughout; needs that lock split)
- [x] Wait on multiple objects
- [x] Deferred calls that run at dispatch level (for device drivers)
- [x] Priority boosting for threads woken from waits (by wake reason, decay per
      time slice, starvation boost; never the real-time class)
- [x] Stack back trace in the panic screen (frame pointer walk, kernel
      symbol table made at build time, also over netlog; testpanic option)
- [x] Kernel stack traces of any thread (kshell `trace`, the hang watch)
- [x] Crash reports with module names and load bases
      (CallGetProcessModules, symbolize.py --report)
- [x] Back traces of user programs from the kernel's own crash report
      (call frame information: loaded .eh_frame through .eh_frame_hdr,
      Free Pascal's .debug_frame from the module file; frame pointers
      elsewhere; named from .symtab or the dynamic symbols)
- [ ] User back traces through libraries a C program's dynamic linker
      maps itself (not in the kernel's module list: bare addresses)
- [x] Tickless idle: an idle processor's tick stops until its next due
      time (per-processor clock interrupt counters; coretest checks under
      5 a second per idle processor)
- [x] Idle states: MWAIT C-states (CPUID 5, ACPI _CST functional fixed
      hardware), PSCI CPU_SUSPEND standby states from the device tree
- [x] Nanosecond wall clock (CallGetPreciseTime), stepped or slewed
      (CallAdjustWallClock); invariant TSC check, kvmclock under KVM
- [x] SNTP client service (timesync, off by default)
- [x] Dynamic tick for busy processors (no tick while one thread runs
      alone on a processor: a residual tick a second; a thread queued
      there, a switch or an alert brings it back; dynamictick=off;
      powerstat --check-busy in coretest)
- [x] A shared read-only page with the clock's parameters (vDSO-style) so
      the runtime reads the time without a system call (TAbiClockPage,
      AuxiliaryClockPage; RDTSC / CNTVCT_EL0; Sys.Time, Now,
      GetTickCount64; ClockPageTest, timetest)
- [ ] The clock page under KVM's paravirtual clock (per-processor
      pvclock records mapped for programs; they make the system call
      for now)
- [x] Power-down idle states (PSCI CPU_SUSPEND power-down through the
      start-up entry, idle=powerdown-test on QEMU; deep and port C-states
      without ARAT) with a broadcast timer (boot processor; self test,
      idlebroadcast=force); _PDC/_OSC before _CST; ACPI P-states
      (_PSS/_PCT/_PPC, governor thread) or HWP for frequency scaling on PCs
- [x] Raspberry Pi 5: the fan through RP1's PWM (with RP1's clock
      generator) for speeds between off and full (built only; falls back
      to on/off when the PWM does not read back as set)
- [ ] Raspberry Pi 5: check the fan PWM, the clock governor, the fan pin
      and the thermal limit on the board; first check Drivers.Rp1Pwm's
      register offsets and pin function against Linux's clk-rp1, pwm-rp1
      and pinctrl-rp1 (written from memory, not from the sources)
- [ ] Uptime step back after resume under KVM (seen once in a suspend
      stress run; kvmclock guard added, cause not confirmed)
- [x] Core audit fixes: AArch64 suspend keeps FP/SIMD registers; freeze
      handshake (no processor left frozen); clock paused last; x86 user
      copy recovery bound to the copy routines, CLAC at interrupt entry,
      NMI/MC GS check; atomic idle check-and-wait; thread reaper thread;
      priority lowering reschedules; GIC/I/O APIC locks; ITS pending
      tables kept; release/acquire processor table; per-processor panic
      trace; strict UTF-8 decoding; bounded wall clock adjustments
- [x] A regression test for the idle lost wakeup and for priority lowering
      latency (Kernel.SchedulerLatencySelfTest: the idle window hook holds
      a processor between check and wait for a wake-up and a refused
      steal; an endless time slice for the priority lowering)
- [x] Interrupt remapping (VT-d / AMD-Vi) so device interrupts can reach
      x2APIC ids above 255 (on where an id is above 255, or intremap=on;
      make interrupt-remapping-test behind QEMU's intel-iommu and
      amd-iommu)

## Memory management

- [x] Reclaim the loader's boot data pages once the kernel no longer needs them
      (all but the boot stack and the device tree, after phase 1's self tests)
- [x] Map .text/.rodata/.data by their permissions with no-execute (EFER.NXE
      in the loader; the window, heap, stacks and devices no-execute; the
      window's view of the code and read-only data read-only), verified by a
      page table walk at every start (W^X) and by deliberate violations
      (`selftest=nx|textwrite|userexec|useraccess|pagepoison`)
- [x] SMEP and UMIP on x86-64, PAN on AArch64 (with SMAP and PXN: the kernel
      never runs user code and reaches user memory only through the copy
      routines)
- [x] Object reference counts saturate (with a warning) instead of wrapping
- [x] Contiguous physical allocations (for DMA buffers): a free-frame
      bitmap next to the doubly linked free list, searched a word at a
      time for runs with an alignment, a boundary and an address range
      (Memory.FrameRuns, AllocatePhysicalRun); Io.Dma takes its buffers
      from them (AllocateAlignedDmaBuffer, LimitDmaBoundary; xHCI 64 KiB);
      tools/FrameRunTest and kernel self tests
- [x] Per-process address spaces (copy the kernel half of the top level table)
- [x] Page fault handling for demand-zero memory
- [x] Growable region table: an address space's regions in a balanced tree
      (logarithmic fault lookup, overlap check and first-fit search) instead
      of a fixed 1024-entry table, bounded by a per-process region limit
- [x] Every region released with its owner: thread stacks, guards and thread
      data however a thread ends, threadvar blocks of threads ended from
      outside (AllocateForThread), heap chunks of ended threads kept by the
      heap check quarantine; checked by limittest
- [x] Demand paging from files (map executables instead of copying them in):
      program and library pages come from the file's mapped pages
      (Processes.MappedFiles) on first touch, shared between processes;
      image sections keep only headers and the few built pages
- [x] Reserve / commit / decommit / protect / query (CallReserveMemory 160 ..
      CallSetMemoryPolicy 165), user W^X with a dynamic code opt-in, one-shot
      guard pages, commit charge per process (ProcessLimitCommit) and system
      wide (Memory.CommitCharge)
- [x] File mappings (CallMapHandle on regular files): read-only shared and
      private copy on write, coherent with write() for shared mappings,
      private ones keeping what they saw; maptest
- [x] A removed or replaced file is freed once nothing maps it: the image
      section cache drops a file's sections when it loses a name
      (AddFileRemovedHook), so a removed library or a program replaced
      while running no longer leaves an orphan inode at unmount; coretest
      checks the system disk's used space around it (and e2fsck after)
- [x] Shared writable file mappings (through a handle open for writing):
      pages marked dirty on the first write, write access taken from every
      mapping before a write-back, written back on CallSyncMemory (214),
      unmap and process end, sync, after 5 s on the background writer and
      when the mapped file goes; write() copies only the changed bytes into
      resident pages; filemaptest, mapped file self test
- [x] Evicting mapped file pages under memory pressure: the "mapped files"
      shrinker drops clean pages nobody maps, and (hard) unmaps clean mapped
      ones through the mapped file's list of mapping regions to read them
      again on the next touch; preserved snapshot pages and dirty pages stay;
      CallTrimMappedFiles (217), CallQueryMemoryResidency (215),
      CallGetMappedFileStatistics (216)
- [x] read() is served from a mapped file's resident pages (it also sees
      what a shared writable mapping wrote before it is written back)
- [ ] Mapped file pages could be the block cache's line pages themselves
      (PinCachedPage, needs a file-page-to-disk-block query from each file
      system and care when blocks move, e.g. after a truncate): a page read
      for a mapping is still in the cache too until the cache drops it
- [ ] A mapped file's page table does not grow: a file that grew after it was
      first mapped can be mapped only up to its old size until every mapping
      of it is gone
- [x] Copy-on-write sharing of program and library pages between processes
      (image sections, reference counted physical pages)
- [x] Keep relocated copies of image pages per load address, so loading a
      library needs no relocation work at all (Processes.RelocatedCopies:
      keyed by the bias and every symbol resolution, kept with the image
      section, dropped under memory pressure; libraries keep the place
      their section was given first, aslr=process for per-process
      places; CallGetImageCacheStatistics 208; latelibtest)
- [x] Heap checking in the kernel heap and every program's heap (kernel option
      `heapchecks`, `HEAP_CHECKS`): fill patterns that make freed pointers
      non-canonical, guards after blocks, double free detection, a quarantine
      checked when blocks leave it; on in every test boot
- [x] Page heap (HEAP_CHECKS=pages): every block on pages of its own,
      end-aligned against a reserved page, freed pages decommitted and their
      reservations kept back (the last 1024) from reuse
- [x] Heap checking for the physical page allocator (fill freed pages, keep
      them from reuse for a while, check them when they leave the quarantine)

## Objects and processes

- [x] Hierarchical object namespace (directories `\Device`, `\Storage`,
      `\Kernel`, `\Ports`, `\Shared`; owners, modes and the sticky bit on
      names and directories; objls)
- [x] Per-process handle tables
- [x] Growable handle tables (two levels, lowest free number first) up to a
      per-process handle limit; limits for regions and handles
      (CallGetProcessResources, CallSetProcessLimit), inherited by children
- [x] Passing more handles than the standard three to a new process
      (ProcessPassHandles)
- [x] Out-of-memory policy: the largest process by resident and committed pages ends
      with 137 (OOM score adjustment, the initial program and adjustment -1000 spared
      unless asking, kernel log and NotificationProcessEndedForMemory); per-user process
      limit (ProcessLimitProcesses); CallGetMemoryPressure, free
- [x] Commitments feed the OOM policy (Processes.MemoryCharges.SetCommitCounters, from
      the reserve/commit work): the footprint counts commitments not
      resident yet; CallGetProcessMemoryCharge (209) shows any process's
      charge and score; memorytest charge
- [x] Process creation and teardown
- [x] Waiting on process objects (exit notification)
- [x] Multiple threads per user process (CreateThread, ExitThread, WaitForThread,
      thread handles; an uncaught exception in one thread ends the whole process)
- [x] User-mode locks: atomic fast path, CallWaitOnAddress / CallWakeAddress
- [x] Exception fixups for kernel accesses to user memory (fault-tolerant copy
      routines, transfer buffers for reads and writes, SMAP when available)
- [x] Libraries loaded with LoadLibrary that have thread-local storage or
      initializers: dynamic TLS (per-thread blocks made on first touch, for
      ELF TLS and the threadvars of Free Pascal libraries), DT_INIT /
      DT_INIT_ARRAY before LoadLibrary returns, DT_FINI_ARRAY / DT_FINI at
      the end, Free Pascal libraries' own unit initialization (si_dll)
- [x] Resource strings of Free Pascal libraries loaded at run time (their
      tables merged into the program's, so SetResourceStrings reaches
      them); initial and local exec TLS accesses into libraries loaded
      late (a 2 KiB static TLS surplus, filled into every thread when
      the load succeeds); latelibtest with libstatictls
- [x] Thread priorities set by programs (offsets from the process's)
- [x] Thread names (CallSetThreadName, CallListThreads; TThread, hang
      reports, the debug shell's threads command, ps -L/-T, the task
      manager's properties)
- [x] Address space layout randomization: the program, each library, the
      allocation area, thread stacks and data, the main stack (aslr=off for
      the old fixed layout); Kernel.Random (ChaCha20, hardware and boot
      entropy)
- [x] Ending another program (TerminateProcess; kill, timeout)
- [x] Ending a stuck program always works: checked for spinning threads,
      every kind of kernel wait, deadlocks, sockets and windows that stop
      being served (hangtest --check); a thread started during the ending
      never runs; kill -9 of a group; a process still there 10 s after it
      was told to end is reported with its threads ([ending])
- [x] Bound the kernel's remaining non-alertable waits a user thread can
      reach (device open and close, block I/O, the wait after cancelling a
      request), so a driver that never completes cannot keep a process
      from ending (Io.BoundedRequests: given up 5 s after a cancel or
      once the thread must end; audio drain stops on a stalled device)
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
- [x] Permission checks on FAT and exFAT beyond their read-only attribute (uid=, gid=, umask=,
      fmask=, dmask= mount options; the read-only attribute kept)
- [x] Process list (ps, pgrep, pkill), per-thread CPU time
- [x] Audit of memory, processes and objects fixed (loadertest, ctest security):
      crafted ELF files confined to their module and user space, the kernel's
      window into a process limited to its own private writable pages, fork
      copy on write whatever the protection, exec/spawn/LoadLibrary check and
      load one open file, AT_SECURE, reference counted address spaces, fork
      limits, signals per process, pending signals kept across exec, hard
      process limits, sections charged to their creator, handle reserved
      before a thread starts, mapped files joined under the volume lock
- [x] A private mapping of a large file another program writes: the file
      system reports the range before each change (TFileChangingHook), and a
      private mapped file becomes a snapshot that reads only the pages a
      change touches (marked preserved), not the whole file; filemaptest
      checks one page read for a 1 MiB file
- [x] Executing a program the caller may run but not read (mode 0711): opened
      on the kernel's authority after the execute check, AT_SECURE set and the
      process marked (TProcess.ImageUnreadable)
- [x] Spawn joins only a group of the caller's session (CallCreateProcess
      GroupId), as setpgid does

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
- [x] USB keyboards: key repeat (a timer, the kernel's repeat settings), lock
      lights (SET_REPORT output reports, the "UsbLights" thread)
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
- [x] AML hardening: field and buffer field bounds, 128 KiB stack budget, reference,
      package and field nesting limits, calls on the loop budget, table length caps,
      malformed-table host test (AmlTest --malformed); PCI decoding left off for a BAR
      that found no window
- [x] ACPI events: SCI, power and sleep buttons (fixed and control method), GPEs
      with their _Lxx/_Exx methods, Notify; S5 power off; reset; orderly
      shutdown (poweroff, reboot, halt)
- [x] Suspend to RAM (S3): processors frozen and restarted through the start-up
      trampoline, interrupt controllers, PCI configuration and MSI-X restored,
      every driver brought back (AHCI, NVMe, virtio, xHCI and its USB devices,
      HD Audio, AC'97, serial, PS/2, display)
- [x] Wake sources beyond the power button (RTC alarm, USB, network: _PRW,
      _DSW/_PSW, PME; calls 228-230, suspend -t, powerstat --wake); MTRRs
      on secondary processors after waking (and at start)
- [x] ACPI thermal zones (_TMP, _PSV, _CRT, _TZP: passive throttling by
      clock modulation, clean shutdown at critical) and batteries (_BIF,
      _BIX, _BST), CallListThermalZones, CallListBatteries, powerstat
- [x] More from the ACPI namespace: embedded controller regions (batteries
      and zones whose methods read them; ECDT, _REG, queries), active
      cooling (_ACx/_ALx, fans; CallListCoolingDevices), thermal
      notifications (Notify 0x80/0x81/0x82), processor hotplug (bringing a
      plugged processor online)
- [ ] Processor hot removal (ACPI eject); QEMU test of interrupts to an
      x2APIC id above 255 (needs a guest with that many processors)
- [ ] Wake from USB and network on real hardware (QEMU's xHCI and e1000
      never wake the machine; only the host test checks the arming)
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
- [x] Block cache sized from RAM (blockcache=, blockcachemin=, blockcacheshare=): grows
      on misses while memory is plentiful, gives lines back under memory pressure;
      dirty list, page lookup for file mappings (PinCachedPage)
- [x] Memory pressure: low and critical watermarks in the page allocator, shrinkers
      (block cache, heap check quarantine), the MemoryPressure thread; the kernel heap
      reclaims before failing
- [x] Discard: NVMe Dataset Management, AHCI TRIM, virtio-blk DISCARD, the RAM disk
      frees pages; ext/FAT/exFAT discard what they free (batched, after the metadata is
      durable, ext after its commit; discard=off); fstrim (CallTrimVolume)
- [x] Hostile or faulty devices fail only themselves (driver audit): HID report
      offsets in 64 bits, reports over 1 KiB refused, key arrays cut at 256; endpoint
      0, reserved bits and repeated endpoints refused; xHCI gives up timed out
      transfers (Stop Endpoint, Set TR Dequeue Pointer, else the slot disabled),
      recovers halted bulk endpoints, aborts timed out commands, frees the slot and
      memory of failed enumerations, takes away devices that do not resume; USB storage
      Bulk-Only reset recovery; NVMe matches completion identifiers and resets the
      controller on a timeout; AHCI port recovery in a thread; ACPI table lengths
      checked; usb-descriptor-test (crafted and fuzzed descriptors on guarded
      pages), nvme-queue-test, acpi-table-test
- [ ] USB class probes run in the port watcher thread with its port lock held: a
      slow probe (a disk getting ready) delays unplug handling and suspend (bounded
      now: a probe stops at the first timeout); bind in a thread of the device's own,
      with removal racing the probe handled
- [ ] A coretest that unplugs and replugs a USB disk mid-transfer through QEMU's
      monitor (test-qemu.sh has no monitor socket yet); a fault-injecting xHCI or
      NVMe model for the timeout paths
- [ ] Discard on USB disks (SCSI UNMAP) and SD cards (ERASE); a nodiscard mount option
      once mount options exist; shrinking the image section cache under pressure

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
- [x] Hierarchical mount points (mount a volume at any directory) and a boot volume alias
      (/volumes/system); mount, umount, /etc/fstab read by the service manager
- [x] tmpfs (FileSystem.Memory) on /tmp, pages from the page allocator, size= limit
- [ ] Mount namespaces / bind mounts; mount propagation; remounting read-only to read-write
- [ ] Watches across mount points (a subtree watch stops at a mounted volume)
- [ ] Setting times with nanoseconds (utimensat); ext nanoseconds kept when stamping (now cleared)
- [x] File timestamps beyond modification time; ext4 nanosecond timestamps (access, change,
      birth; CallGetFileTimes, stat, ls --time=)
- [x] Damaged and hostile disks (file system audit): ext, FAT and exFAT refuse, mount
      read-only or report StatusCorrupted instead of overrunning buffers or looping
      (geometry, names, extent headers, orphan list, cluster chains, journal recovery
      limits); host test with crafted and fuzzed images (make file-system-image-test)
- [x] VFS: an open root survives a forced unmount; chmod/chown/utimes checked on the node
      under its volume's lock; exec checks the file it loads; unmount and rename checks
      under the lock; renaming a folder with a mount below refused; tmpfs files capped
- [ ] ext: verify metadata checksums when reading (a damaged inode is only caught where
      its fields are used)
- [ ] Discards: a gone volume's batch record stays in the registry (as its TVolume does)
- [ ] Mount records keep paths as text: renaming above a mount point is refused rather
      than followed

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
- [x] Controls for a tabbed file manager in libcontrols: a tab strip
      (reordered by dragging, dragged out into a window), a breadcrumb
      address bar (chevron menus, overflow, editing with suggestions), a
      command bar (drop-downs, an overflow menu), a progress dialog (pause,
      cancel, a speed graph; transfer rates checked on the host) and their
      icons
- [x] File manager as a tabbed browser: tabs, breadcrumbs with chevrons and
      completion, search with a query syntax streaming results, a command bar
      and context menus (the classic menu behind "Show more options"), a
      navigation pane (Home, Gallery, pinned folders, Computer with volumes
      and free space, Network, the recycle bin), eight views with groups,
      chooseable columns, thumbnails and check boxes (libcontrols' item view),
      details and preview panes (web pages, pictures, text), Home (pinned,
      favourites, recent) and Gallery pages, the recycle bin with restore
      (Util.Trash), ZIP and tar archives browsed, made and extracted
      (libarchive), undo and redo, batch rename, Open with by program.info
      Extensions/MimeTypes and a default per type, options, properties with
      General, Security and Details pages, view settings per folder
- [ ] File manager: Network places (only a placeholder page), MP3 and other
      sound lengths (only WAV is read), video thumbnails, dragging column
      headers to reorder them, a real share sheet behind Share
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
- [x] libarchive: zip reading (ZIP64, stored/deflated, CRC checks, UTF-8
      and CP437 names, Unix modes, links, data descriptors; encrypted
      members reported and refused) and writing (deflate or stored,
      ZIP64 when needed or forced), tar/ustar/GNU/pax and tar.gz reading,
      ExtractAll with safe names, folder browsing (`make archive-test`)
- [x] libarchive: tar.zst (streaming, libcompression's Zstandard decoder)
      and tar.xz (the whole-buffer xz decoder, into memory) reading, told by
      content (`make archive-test`)
- [ ] libarchive: tar.xz streaming (the xz decoder works on whole buffers,
      so a .tar.xz is unpacked into memory, at most 512 MiB)
- [ ] libarchive: 7z reading
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
  - [ ] AVIF (HEIF container, AV1 intra frames: libav1 decodes the frames,
        the HEIF container is left; until then the browser neither
        advertises nor accepts image/avif)
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
      size, light vertical autohinting, gamma-correct blending; the fonts' own
      bytecode hinting not done
- [x] libfont: CFF and CFF2 outlines (OpenType .otf, CID-keyed Noto CJK,
      variable fonts' default instance), TrueType collections (.ttc, a face by
      index), CBDT/CBLC colour emoji scaled from the nearest strike (PNG through
      libimage's decoder hook), cmap format 14 and symbol maps
- [x] Freely licensed fonts in /lib/fonts with their licences and a MANIFEST
      (scripts/fonts.list; full set on amd64, core set for the Pi's RAM disk):
      Liberation (Arial/Times New Roman/Courier New metrics), DejaVu, Noto
      with 34 scripts, CJK and colour emoji, Source Sans 3, Cantarell, Roboto,
      Open Sans, Hack, Inconsolata, the URW base 35, Droid Sans Fallback
- [x] The fonts kept in the repository (userland/fonts/<family>/ with LICENSE
      and SOURCE, MANIFEST); the build installs them from there
      (scripts/install-fonts.py, FONT_SET full/core/base), never from the
      host; make update-fonts (scripts/update-fonts.py) refreshes them from
      the host packages with the licence checks; font-test and
      web-layout-test take their fonts from the repository
- [x] Font configuration (/etc/fonts.conf, Font.Configuration): generic
      families and common names to installed faces, per-script fallback
      chains; per-character fallback in libweb and in the toolkit's text
      (Font.Text's FallbackFaceFinder); the interface stays DejaVu Sans
- [ ] COLR/CPAL colour glyphs (v0 and v1), sbix and SVG-in-OpenType; full
      variable-font instances (fvar/gvar/HVAR, CFF2 blends at other axes)
- [ ] Choosing a collection's face by language (Noto CJK's JP face is used
      for Chinese and Korean too) and by the lang attribute
- [ ] Emoji ZWJ sequences, flags and keycaps as single glyphs (needs GSUB)
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
- [x] libhttp: WebSocket connections (RFC 6455: handshake, frames,
      masking, ping/pong, the closing handshake, the failures with their
      close codes) with permessage-deflate (RFC 7692), on threads of
      their own (Http.WebSockets)
- [ ] libhttp: WebSockets over HTTP/2 (RFC 8441) and HTTP/3 (RFC 9220),
      and through proxies
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
- [x] Network stack hardening (an audit's findings): 127.0.0.0/8 and
      ::1 only from lo, and other martian sources and destinations
      dropped (Network.InputFilter); RFC 6528 initial sequence numbers,
      RFC 6056 ports, RFC 7739 IPv4 identifications and per-connection
      timestamp offsets from SipHash keys; RFC 5961 challenge ACKs (SYN,
      in-window RST, old and new ACKs), rate limited; half-open children
      without buffers, bounded in all and pushing out their own; zero
      windows probed while closing, orphans given up; ICMP errors checked
      against the quoted sequence and source, ICMP and ICMPv6 errors and
      echo replies rate limited; RFC 5722 overlapping fragments and RFC
      7112 header chains; router advertisements leave static routes
      alone; learned path MTUs kept; per-user shares of change watchers,
      multicast memberships and shared UDP ports; one TCP listener per
      shared port; netshell timeouts; the kernel DHCP client's sanity
      checks (TcpTest, Ipv6Test, Kernel.NetworkHardeningSelfTest)
- [ ] Network hardening later: SYN cookies (a backlog full of children
      not yet accepted still drops new SYNs), IPv4 reassembly limits per
      source like IPv6's, rate limits per destination as well as overall
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
- [x] The AArch64 boot tests, coretest and panic trace test in `make test`
      when qemu-system-aarch64, edk2-aarch64, the cross compiler and
      binutils are there (`scripts/arm64-test-requirements.sh` says what
      is missing otherwise); `make arm64-test` adds the GICv3 coretest
      and the session test
- [x] User mode: an AArch64 exception context in the ABI (X0-X30, SP, PC,
      PSTATE; CallContinue), the user runtime library and programs built for
      AArch64, the ELF loader accepting AArch64 programs (TLS variant I,
      TLS descriptors), the system disk; text shells, coretest, the
      graphical session with a USB keyboard and tablet
      (`scripts/test-qemu-arm64-user.sh`, `scripts/test-arm64-session.py`)
- [x] Address space identifiers (no TLB flush on every address space switch)
- [x] Instruction cache synchronized for user code pages
- [x] The time of day from the firmware's GetTime (passed by the loader)
- [x] 16-bit ASIDs where the processor has them (TCR_EL1.AS), `asidbits=`
      for rollover tests
- [x] AHCI finds no drives on QEMU's virt machine (the port signature was
      read before FIS receive was on); AC'97 never worked there (its I/O
      ports had no window, not its line interrupt): coretest has the
      optical drive on AHCI and AC'97 on AArch64 too
- [ ] The AES instructions (ARMv8 Crypto Extension, where present: not on
      the Pi 4) and a hardware random seed (RNDR on ARMv8.5, or a kernel
      entropy call) for libcryptography on AArch64
- [x] Floating point exceptions on AArch64: user code compiled with `-CE`
      (the compiler checks FPSR, the RTL raises unmasked ones), so
      division by zero raises EZeroDivide
- [x] Suspend to RAM through PSCI SYSTEM_SUSPEND (where PSCI_FEATURES
      offers it) and the PL031 real-time clock (read, and set when the
      wall clock is stepped)
- [ ] Suspend to RAM on a machine whose PSCI really has SYSTEM_SUSPEND
      (QEMU's has not: only the refused path is tested, with
      `suspendtest psci-suspend=force`); the Pi 5's RTC (on its PMIC)
- [x] GICv3 (system register CPU interface, redistributors, affinity
      routing, LPIs through the ITS) for machines that have it
- [ ] GICv3: device ids through the IORT's ID mappings (the requester id
      is taken as the device id, as on QEMU virt), more than one ITS,
      ITS indirect device tables (device ids above 8191), GICv4
- [x] PCIe I/O space window (`Hal.PortIo`) from the root bridge's `_CRS`
      or the device tree host's `ranges` (`Io.PciPortWindow`)
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
  - [x] The other PCI drivers (AHCI, NVMe, virtio, e1000, Realtek, HD
        Audio, AC'97) through `Io.Dma`, for non-coherent PCIe, and
        `GetPciDmaAttributes` taking a BrcmPcie host's dma-ranges (untested on
        the Pi 5; 32-bit-only cards cannot reach its RAM above 4 GiB)
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
  - [x] GICv3 driver (with its ITS, from the tree too)
  - [ ] Spin-table processors, virtio-mmio devices (listed as platform
        devices, no transport driver)
  - [ ] PCI bridges below an ECAM root bus get no windows assigned (QEMU
        virt has none); the port window is set from the host's ranges

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

## Native Free Pascal

- [x] FPC targets of our own, x86_64-freepascalos and aarch64-freepascalos,
      as patches against 3.2.2 (toolchain/fpc); the userland compiled for
      them (code identical to the borrowed linux target)
- [x] The internal ELF linker writes position independent executables (no
      binutils needed on x86-64)
- [x] ppcx64 / ppca64 and the fpc driver as FreePascalOS programs, with
      fpc.cfg and the units on the system disk (units in libraries marked by
      ppumove, linked shared with -XD)
- [x] In the guest: hello, several units, a library (linked and loaded at
      run time), userland tools against libcoreutils/libcryptography, and the
      compiler compiling itself
- [x] fcl-process (TProcess, pipe streams) for FreePascalOS
- [x] Tests: a coretest line (compile and run in the guest), native-fpc-test
      on the host
- [x] AArch64 in the guest: GNU as and ld for *-freepascalos from the
      binutils port (ports/devel/binutils, on the system disk with the C
      toolchain; also on x86-64 for C work); the coretest line compiles and
      runs a program there, and skips without /usr/local/bin/as
- [ ] An `as`/`ld`-free AArch64 (an internal assembler and ELF linker for
      AArch64 are only in FPC trunk)
- [ ] Express it as a port once the ports framework lands (ports/, pkg)
- [ ] More packages for Lazarus: fcl-xml, fcl-json, fcl-image, fcl-res,
      fcl-registry, paszlib, simpleipc; fpmake/fpcmake knowing the OS
- [ ] The LCL widget set over libwindowing/libcontrols, then the IDE
      (see "Towards Lazarus" in docs/Architecture.md)
- [ ] A debugger for the IDE (GDB port or FpDebug on kernel calls for
      debugging other processes)
- [ ] Compiler sources on the system or a package, so `make cycle` can run in
      the guest without an extra disk

## Ports and packages

- [x] Ports tree (`ports/CATEGORY/NAME/port.toml`, patches, files),
      port.schema.json, a licence allowlist (SPDX), ports/README.md
- [x] `scripts/ports.py`: fetch (mirrors, DISTDIR cache), verify (SHA-256,
      size, gpg or Ed25519 signatures), extract, patch, configure, build,
      stage, package, clean, test, info, deps (graph, order, dot), list,
      search, outdated, makepatch, makesum, lint, repo, keygen,
      install-to-image; options and flavours; a build log per port;
      reproducible packages; cookies and rebuilds when a port changes
- [x] Build systems: autotools, meson (cross file), cmake (toolchain file;
      skipped on a build machine without cmake), make, fpc (the
      build's compiler and runtime, as userland.mk), custom, none
- [x] C ports skipped (not failed) while the C toolchain is missing;
      a sysroot per port with its build dependencies' packages
- [x] Packages: tar.zst with +MANIFEST (every file's mode, size and
      SHA-256), +DESC, scripts, licences in share/licenses
- [x] Repositories: INDEX with sizes and SHA-256s, Ed25519-signed
- [x] pkg: install (files or repositories, with dependencies), remove,
      info, list, which, verify, search, update, upgrade, test; /var/db/pkg;
      every check before anything changes, staged files renamed into
      place, everything undone on failure; a lock
- [x] The system disk carries ports/image.list's packages installed
- [x] /usr/local/bin on every default PATH
- [x] Host tests (`make ports-test`, `make pkg-test`), coretest installs,
      verifies and removes a package
- [x] Pascal ports: hello, pkg-selftest, ptop (from the Free Pascal source
      release, with a patch for standard input and output)
- [ ] Build and test the C ports once `make c-toolchain` exists: zlib, lua,
      sqlite3, then bash (committed, status "untested")
- [x] The program loader finds shared libraries in /usr/local/lib after /lib
      (needed libraries and LoadLibrary by a bare name; coretest checks it)
- [ ] Ported graphical programs: a package installing a program folder the
      desktop finds (/usr/local/app or a second program folder root)
- [ ] pkg: autoremove (packages installed as dependencies nothing needs
      any more), pkg fetch, a progress line while downloading
- [ ] A public package repository with a signing key the system disk carries

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
- [x] Ranges and StaticRange (live ranges adjusted by the mutation
      algorithms), the document's selection
- [ ] NodeIterator/TreeWalker
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
- [x] @font-face loading: TrueType, OpenType (CFF too), collections, WOFF 1
      and WOFF2 (Web.Text.Woff2: Brotli, the glyf/loca and hmtx transforms)
      faces join the font library (Web.Loading.LayoutSink, Web.Text.Woff);
      fonts re-bound in place
- [ ] Bidi and writing modes, shaping beyond kerning (Arabic draws
      unjoined), web fonts per document rather than process-wide,
      ::first-line/::first-letter
- [x] position: sticky (offsets at painting and hit testing time under
      the viewport, when the list is built in inner scroll containers)
- [x] CSS masks (mask-image and friends, -webkit- names, the shorthand),
      composited through the layers' alpha
- [x] :hover/:focus changes restyle only what selectors reading them reach
      (Css.StateInvalidation); the parser nests at most 512 deep
- [x] Transforms beyond translation (scale, rotate, skew, matrix, 3D
      flattened, transform-origin) painted as transform groups, hit
      tested and measured through them
- [x] CSS animations and transitions (keyframes, easing, fill modes,
      iterations, directions, play state; numbers, lengths, colors,
      transforms) run each frame with an injectable clock; animation and
      transition events
- [ ] Inline boxes split around blocks, relative inline boxes,
      perspective and preserve-3d, filters, blend modes, clip-path,
      border-image, conic gradients, blurred text shadows; Web
      Animations (element.animate)
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
- [x] CSP Level 3 enforcement: requests by destination with fallback
      lists (frame-src against the embedder), nonces, hashes,
      'strict-dynamic', 'unsafe-hashes', inline scripts, style blocks and
      attributes, event handler attributes, eval/Function/string timers
      (libjavascript's compile-strings hook), form-action, base-uri,
      report-only, securitypolicyviolation events, report-uri and
      report-to with Reporting-Endpoints
- [ ] CSP: the sandbox directive, workers' own policies, nonce hiding,
      nonces passed to module imports, Trusted Types
      (require-trusted-types-for, trusted-types)
- [x] WebSocket and CloseEvent (the page's channels: libhttp's
      connections in the process, the browser's network service in a
      browser; mixed content, HSTS and CSP connect-src applied)
- [ ] WebSocket in workers; WebSocketStream
- [ ] Subresource Integrity (stored on requests now)
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
- [x] reCAPTCHA: MessagePorts between realms (frames of any origin,
      workers), frames by name; the anchor, worker and challenge frame
      handshakes complete (they timed out on the host too: webbrowse
      quit before the 5 and 15 s timeouts); the demo and Google's
      /sorry/ page show the widget without script errors
- [ ] reCAPTCHA under TCG (no KVM): its 860 KB script runs three times
      (page, anchor, challenge frame) and can miss its 15 s handshake
      timeout before the anchor retries; faster script start-up
- [x] Range/Selection (window/document.getSelection, selectionchange,
      tied to the web view's selection), the CSSOM (document.styleSheets,
      sheets, rules, insertRule appended rules indexed at once,
      constructable sheets, adoptedStyleSheets)
- [ ] Shadow DOM interfaces, TreeWalker, Web Animations, synchronous XHR,
      XML parsing (DOMParser's XML types, responseXML), the
      unhandledrejection event, Selection.modify
- [x] DOMParser (text/html), SVGElement/SVGGraphicsElement/SVGSVGElement,
      document.open/write/close outside the parser, Location's setters,
      HTML's cloning steps (scripts that ran, control values), isTrusted
      kept for the engine's events, unhandled rejections on the console
- [x] Event lifetime: engine events released, not freed (the DuckDuckGo
      crash); events hold only node targets
- [ ] Pascal exceptions raised inside the interpreter loop (by built-ins)
      are not turned into JavaScript errors; a stray one unwinds past the
      script's frames
- [x] Brotli and zstd content codings (Accept-Encoding offers gzip,
      deflate, br and zstd)
- [ ] Google search: the challenge runs (its token equals Firefox's for
      the same inputs) but Google sends this engine to its CAPTCHA page
- [ ] A cheaper interface object: native accessors keyed by property in
      libjavascript would let one getter serve every attribute (a window
      costs about 420 KB of script heap over the bare realm today)
- [x] html5test.co runs to its score (273 of 588; Firefox 547): HTML-like
      comments after white space, images outside the document (pending
      activity keeping their listeners), image natural sizes and
      complete, resolved width/height in getComputedStyle, input value
      sanitization with valueAsNumber/valueAsDate/stepUp/stepDown,
      fieldset.elements, EventSource, PointerEvent and pointer capture,
      ClipboardEvent and DataTransfer's string data, access keys, table
      colspan widths, the preload scanner's double fetches
      (docs/html5test-gaps.md)
- [x] IndexedDB 3.0 (databases and versions with upgradeneeded, blocked
      and versionchange, object stores with key paths and key generators,
      indexes with unique and multiEntry, every cursor direction,
      continuePrimaryKey and advance, key ranges, getAll/getAllKeys,
      transactions with auto-commit, commit(), abort and their events)
      on a storage service (Web.IndexedDb.*) in the browser process
      (IPC 340-342; refuses other sites' origins; private windows in
      memory; a file per origin; quota) or in the program; structured
      serialization to bytes (Blob, File, typed arrays, Map, Set, Date,
      RegExp, BigInt, errors, cycles); navigator.storage (estimate,
      persist, persisted); the Cache API on the same service; available
      to dedicated workers; html5test storage 35/35
- [ ] IndexedDB follow-ups: a storage format that writes only what
      changed (the service writes an origin's whole file), eviction of
      best-effort origins under disk pressure, the persistent-storage
      permission's state following persist(), getAllRecords() and
      IDBRecord (IndexedDB 3.0 editor's draft), structuredClone and
      postMessage moved onto the same serializer (ArrayBuffer, typed
      arrays, Blob), the OPFS (navigator.storage.getDirectory)
- [x] Canvas 2D (CanvasRenderingContext2D complete: paths and Path2D
      with SVG path data, transforms, fill rules, strokes with dashes,
      caps and joins, linear/radial/conic gradients, patterns, shadows,
      globalAlpha with every compositing operator and blend mode, clips,
      text with fillText/strokeText/measureText from libfont's outlines,
      drawImage, ImageData, the filter property), toDataURL and toBlob
      (PNG, JPEG, WebP), OffscreenCanvas (also in workers, transferable),
      ImageBitmap and createImageBitmap, bitmaprenderer, DOMMatrix;
      canvases shown through the layout's image providers
      (html5test: canvas 24 of 25, offscreen 3 of 3; 300 of 588)
- [ ] Canvas: imageSmoothingQuality (always bilinear), display-p3 and
      float16 colour spaces, the canvas element's own computed font and
      colour for relative font sizes, currentcolor and direction:
      inherit, a GPU path, hit regions (addHitRegion, dropped by the
      standard)
- [ ] The html5test gaps (docs/html5test-gaps.md has them by size):
      custom elements, shadow DOM, Web Animations, media playback and
      Web Audio, the Fullscreen API, file inputs with FileList and
      multipart uploads, foreignObject, relative
      positioning of inline boxes,
      designMode/execCommand, date and time pickers
- [x] Workers (html5test 273 -> 284; 336 merged with IndexedDB and
      Canvas): service workers (register, update,
      unregister, install/activate with waitUntil, skipWaiting,
      clients.claim, fetch interception of navigations and controlled
      clients, the Clients API, messages both ways, navigation preload),
      caches shared with the pages' storage service, SharedWorker,
      BroadcastChannel across the process,
      MessagePorts between heaps (message links), worker agents on
      satellite event loops; registrations kept by the browser
      (IpcOriginDataLoad/Save 343-344); WebLoadTest.Workers and a
      web-platform-tests subset (wpt-workers.html)
- [ ] Access violation in TJsShape.Find (from the interpreter's Call): a
      listener a platform script adds to a frame's window while the
      platform is installed, once the frame was removed and the
      collector ran (WebScriptTest frames.js with such a listener in
      68-service-workers.js); the listener's function is apparently
      not kept alive (or not dropped) with the closed frame's realm.
      68-service-workers.js avoids it for now
- [ ] Workers left: module workers, push messages and notifications
      (needs a push service), Background Sync, openWindow/focus (need
      notification clicks), WindowClient.navigate resolving to the new
      client, dedicated/shared workers as service worker clients, one
      shared or service worker per site across content processes, update
      checks of imported scripts

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
- [x] Editing without libcontrols (WebView.FieldEditing) and a fuzz test
      typing into a page that replaces its fields under the editor
      (WebLoadTest.Editing); elements held across click and submit events
- [x] No crash selecting text after scrolling (Wikipedia's Linux article):
      the pointer path holds what it fires events at and looks boxes and
      places up again after them (WebView.PageSelection); triple click,
      mousemove while pressed, dblclick, autoscroll, the wheel during a
      drag; sticky and transformed text selected where it is shown; a
      pointer fuzz test (WebLoadTest.Pointer) and webbrowse pointer steps
- [ ] DOM: TreeWalker, NodeIterator and NodeFilter (document.createTreeWalker
      is missing)
- [ ] Web view: selecting text inside frames (a press in a frame clears the
      selection)
- [ ] Web view: drawing a field's selection, dragging the bars of inner
      scroll containers, drag and drop, IME
- [ ] Web view: lazy images near the viewport, animated images, printing
- [x] Web view: what the Firefox 3.6 chrome needs - session history lists,
      going several entries at once and session restore across processes,
      find with wrap and match count and highlight all, Page Info, context
      menu details, images off, text-only zoom, No Style, the encoding
      override, pop-up blocking (window.open), private browsing, offline,
      the cache's size, cookies and their policy, connection security and
      the trust store's certificates (protocol version 2)
- [ ] Web view: a WindowProxy for windows window.open made (it returns
      null); text zoom, No Style and the encoding override in frames;
      connection security of HTTP/3 connections; Page Info of frames
- [x] Browser laid out and used as browsers were before they hid their
      menus: the full menu bar (File, Edit, View, History, Bookmarks,
      Tools, Help, with their access keys and shortcuts; hidden, Alt shows
      it), customizable Navigation and Bookmarks toolbars (palette, icons
      or text, small icons), Back and Forward with their history, the
      location bar (site identity and its pop-up, star and its panel,
      suggestions from history and bookmarks as you type), the search bar
      with an engine menu (none chosen until the user picks one), tabs
      under the toolbars (scroll arrows, list of tabs, drag to reorder,
      drag out to a window, context menu), status bar, find bar with
      highlight all and wrap messages; Options (Main, Tabs, Content,
      Applications, Privacy, Security, Advanced), Library, Downloads
      window (pause, resume, cancel, retry, open, show in folder), Page
      Info, Page Source, Error Console, Clear Recent History, Manage Search
      Engines, bookmark folders, tags and keywords, several windows,
      private browsing, session restore with recently closed tabs and
      windows; host test (make browser-test) and test-input checks
- [ ] Browser: printing (File > Print shows it is not available), feeds,
      spelling, add-ons, update checks and forgery reports (stubs); the
      saved-passwords list is never filled (no form capture yet) and is
      not encrypted; the proxy settings, default font and the advanced
      JavaScript switches are kept but not applied; Import from HTML
- [ ] Browser: a dragged-out tab loads its page again in the new window
      (views cannot move between windows); Restore Session page after a
      crash (the session is restored at once); per-site pop-up and image
      exceptions
- [x] webbrowse (make webbrowse): the engine on real sites from the host
      (PNG, layout, DOM, console, network log, phase times, memory, hover
      timing, a sampling profiler, a watchdog with stacks)
- [x] Wikipedia (Main Page, articles, search, en.m redirect) loads and
      renders: grid minmax(0, 1fr), sticky contents, masked icons, no
      crash on resize or on a layout before the first bytes; bounded HTTP
      and decode threads; slow layouts throttled in the web view
- [x] Wikipedia's JavaScript gets past ResourceLoader's compatibility
      check (localStorage, IntersectionObserver)
- [x] www.wikipedia.org no longer freezes the browser: a line that did not
      fit beside its own float placed the float again each time it moved
      down, for ever (the fundraising banner); a float is placed once
- [x] The slow script watchdog: a script (or a chain of promise jobs)
      running longer than 10 s on the page thread is stopped
- [x] CSS animation frames paced by their cost (at most half the GUI
      thread)
- [x] scripts/compare-sites.py: ~27 common pages rendered by webbrowse
      and by Firefox (Marionette) at 1280x800 and 400x800, scored, with a
      smoke test (scrolling, hovering, a drag, typing, links and Back);
      scripts/qemu-browser-smoke.py does the user's part with the real
      browser under QEMU
- [x] Fixes from it: inline element geometry (getBoundingClientRect,
      getClientRects), <center> centring tables, empty lines around a
      block in a link, lazy async arrows, await in async arrows in class
      fields, import maps, module graph and module loader crashes,
      performance.measure, TreeWalker / NodeIterator, unicode-range and
      the fallback font, column flex items' min/max width, calc() in
      media queries, details/summary
- [ ] Custom elements (customElements is missing: reddit, MDN's widgets,
      YouTube) and shadow DOM (attachShadow: lit components, archive.org)
- [x] WOFF2 web fonts
- [x] A metric-compatible sans-serif: sans-serif, Arial and Helvetica are
      Liberation Sans (fonts.conf), Times New Roman Liberation Serif,
      Courier New and monospace Liberation Mono
- [ ] details: the summary's activation behavior in the DOM (a script's
      summary.click() does nothing; libwebview's ActOnClick toggles on a
      user's click), and the default summary of a details without one
- [ ] A NodeIterator moved when the node it rests on is removed
- [ ] Parse large scripts off the GUI thread (Wikipedia's 790 KB module
      bundle holds the window about 7 s under TCG, half of it parsing)
- [ ] Wikipedia's TOC and menus as with JS (check in the browser)
- [x] DuckDuckGo: typing in the search box (suggestions from /ac/), Enter,
      the results page (main and html.duckduckgo.com/html/, whose late
      sheet now restyles), later searches; no crash (released events,
      translations of transforms,
      z-index auto layers, computed shorthands, positioned boxes not left
      due, for-of over Map iterators, lone surrogates in case mapping)
- [x] DuckDuckGo: following a result on the main results page (its hidden
      /post3.html iframe, then /l/ to the site); html.duckduckgo.com's
      results follow too
- [x] window.getSelection (DuckDuckGo's result clicks no longer log an
      error)
- [x] Transforms beyond translation (scale, rotate, skew) in painting and
      hit testing; CSS animations and transitions in the web view's frames
- [ ] Large pages in QEMU need the kernel's growable address-space region
      table (1024 regions run out on Wikipedia's Linux article)
- [ ] Interruptible style and layout (a first layout of a long page is one
      piece of work on the GUI thread)
- [x] Browser process model: pages in content processes (/bin/webcontent),
      process per site (registrable domain), libwebipc (typed messages in
      pieces over channels, WebIpcTest), frames through shared sections
      with damage and acknowledgements, an IPC thread and a network
      service in the browser (cookies, storage, local files and about
      pages refused to other sites' processes, HSTS), cross-site
      navigations moving the tab, async scrolling of the last frame
- [x] Crashed tab page with Reload, "not responding" bar with Wait and
      Stop (pings, repeated watchdog stops), about:crash, about:kill,
      about:hang; dialogs modal per tab
- [x] Kernel process restrictions (ProcessLimitRestrictions: no sockets,
      no file writes, reads only under /lib and /etc, no processes, no
      ports, no control of others; inherited, never lifted); renderers
      sandboxed, memory-limited, background ones first to go when memory
      runs out
- [ ] Out-of-process iframes (cross-site frames still render in their
      embedder's process; plan in "Browser process model")
- [ ] A separate network process; IME text and drag and drop through the
      content process; storage events across processes
- [x] getComputedStyle and layout metrics from the web view's layout
- [x] 4chan's boards: for...of over HTMLCollection (indexed collections
      iterate as arrays), thumbnails no longer covered by posts once an
      icon loads (escaping floats never skipped; block-in-inline float
      edges), quote previews, catalog; initMouseEvent for DuckDuckGo
- [x] The renderer's frames on the browser's side apart from the control
      (WebView.RemoteFrames, bounded sizes) with a fake-renderer test;
      a wheel storm in the pointer fuzz
- [ ] Fast wheel on Wikipedia reported "Access violation" in QEMU: not
      reproduced (KVM and TCG wheel storms with resizes, scroll-bar drags,
      PageDown/End, hovering; host loops); webcontent prints
      "webcontent: input failed: ..." with a back trace to look for
- [ ] Named access on the Window object (an element's id as a global)
- [ ] Margins of blocks inside an inline box collapse with each other
- [x] Web view: range inputs as sliders (pointer and keys), meters and
      progress bars drawn at their values, pointer events with pointer
      capture before the mouse events, mouseenter and mouseleave,
      clipboard events before copy, cut and paste, Alt+Shift access keys
- [ ] Web view: date and time pickers, a colour picker, a file chooser for
      input type=file

## Media: AV1 video (libav1)

- [x] libav1 (`userland/lib/av1`): the AV1 decoding process written out
      from the specification, tables generated from its sources
      (`make-tables.py`)
  - [x] OBUs, sequence and frame headers, operating point 0, frame
        size changes and reference scaling, show_existing_frame, error
        resilience and switch frames, forward key frames
  - [x] Every coding tool: partitions to 4:1, intra (directional with
        angle deltas and edge filters, smooth, Paeth, filter intra, CfL,
        palettes, intra block copy), inter (motion vector prediction with
        temporal candidates, OBMC, local and global warp, compound
        average, distance, wedge and difference weighted, inter-intra),
        transforms of every size and type, lossless, quantizer matrices,
        segmentation, delta q and loop filter
  - [x] Deblocking, CDEF, superres, loop restoration (Wiener and
        self-guided), film grain synthesis
  - [x] 8, 10 and 12 bits; 4:2:0, 4:2:2, 4:4:4, monochrome
  - [x] Tiles on several threads, post filters by rows (`Av1.WorkerPool`)
  - [x] `make av1-test`: aomenc (each tool and format), SVT-AV1 and rav1e
        streams bit-exact against aomdec, on one thread and four, with a
        coding tool coverage report, the same streams in WebM, MP4,
        Matroska and OBU files through libmedia, damaged streams refused
        cleanly; `av1check` and `mediaplay -k` on AV1 WebM in coretest
  - [x] libmedia's AV1 `TVideoDecoder` (`Av1.MediaDecoder`)
  - [ ] Faster: SIMD (SSE2/AVX2, NEON) inline assembly for the inter
        filters, inverse transforms, CDEF and the deblocking filter, with
        the Pascal loops as the fallback; frame-parallel decoding
  - [ ] Large scale tile decoding (Annex D, tile list OBUs)
  - [ ] Streams with intra-only frames and short reference signaling
        (the code follows the specification but no test stream has them;
        the host encoders do not produce them)

## Planned: driver model (loading only the drivers the machine needs)

Today every driver is compiled into the kernel and `Io.Startup` calls each
one's initializer in turn (`InitializeAhciControllers`,
`InitializeE1000Adapters`, ...); each scans for its own hardware. Options,
in the order they would be built:

- [ ] **A. Match tables and a device manager (first step, small).** Every
      driver declares what it drives: PCI vendor/device or class/subclass,
      USB class/vendor/product, ACPI `_HID`/`_CID`, device tree
      `compatible` strings, platform names. The buses enumerate devices
      once and a device manager (an NT "Plug and Play manager"-like role)
      binds each device to the best-matching driver, calling the driver's
      `AddDevice`/start routine only for devices that exist. Removal and
      hot plug (USB, PCIe hot plug, Thunderbolt later) go through the same
      path. Drivers stay compiled in, but nothing initializes for absent
      hardware, and boot order follows device dependencies instead of a
      fixed list.
- [ ] **B. Loadable driver modules (the main step).** Drivers built as
      separate kernel modules (relocatable ELF or shared objects linked
      against an exported kernel interface with versioned symbols),
      kept in `/lib/drivers/` with a small `.info` manifest each (name,
      version, match IDs, load group: boot / system / on demand,
      dependencies). The build generates a match index; the device
      manager loads a module the first time a matching device appears and
      can unload it when its last device goes. Boot-critical drivers
      (storage and the file system holding /lib/drivers, the display)
      come from the boot image (the ESP or the RAM disk) so the root
      volume can be reached; everything else loads from disk.
      Needs: a stable kernel driver interface (versioned), a module
      loader with relocations and symbol resolution, signature checks
      (optional, Ed25519 as for packages), `driverctl list|load|unload|
      info`, and Task Manager / sysinfo showing devices and their drivers.
- [ ] **C. User-mode drivers (later, for isolation).** Selected classes
      (USB HID, audio, printers, scanners, some network cards) run as
      processes: the kernel maps the device's MMIO/ports into the
      process, forwards its interrupts as events, and restricts DMA
      (IOMMU when available). A crashing driver is restarted without
      taking the system down. The process restrictions added for the
      browser sandbox are a starting point.
- [ ] Recommendation: A now, then B with A's match tables as the
      manifests' content, then C for classes where a crash matters more
      than speed.

## Media (libmedia)

- [x] libmedia: frame records (`Media.Frames`, the contract with the video
      libraries), tracks and packets, the demuxer and decoder classes, the
      video decoder registry, `ConvertFrameToBgra` (BT.601/709/2020, SMPTE
      240M, FCC, identity; limited and full range; 10/12-bit)
- [x] Containers: WAV (RIFF, RF64, extensible), native FLAC (seek table,
      bisection), Ogg (Vorbis, Opus, FLAC; chained; granule timing;
      bisection seeking), Matroska/WebM (lacing, header stripping, unknown
      sizes, cues, DiscardPadding, CodecDelay), MP4 (sample tables, edit
      lists, fragmented MP4 read as it is appended), MP3 (ID3, Xing/LAME
      gapless, VBRI, seeking)
- [x] Audio decoders: PCM, FLAC (bit exact, MD5 checked), Vorbis (within
      2e-7 of libvorbis), Opus (SILK, CELT, hybrid, multistream; RFC 8251
      vectors with exact final ranges), MP3 (MPEG-1/2/2.5 Layer III, ISO
      11172-4 full accuracy)
- [x] Resampler (polyphase Kaiser windowed sinc), channel mixer (BS.775
      downmix), conversion to the audio devices' sample kinds
- [x] `mediaplay`: playback on the audio device, `-i` track info, `-k`
      decoding checksums (per video frame once a video library registers)
- [x] `make media-test` (host, fixtures from ffmpeg/flac/lame at build
      time) and a coretest line
- [x] libvideo: VP8 (RFC 6386) and VP9 (profiles 0-3, 8/10/12-bit,
      4:2:0/4:2:2/4:4:0/4:4:4, tiles, superframes, scaled references,
      intra-only and show-existing frames) decoders, bit exact with libvpx;
      VP8 partition rows and VP9 tile columns and loop filter rows on
      worker threads; registered with `Media.VideoDecoders` and linked into
      mediaplay (`-k` checksums WebM/MP4 VP8/VP9 video); `make video-test`
      (vpxenc streams, WebM/MP4 through libmedia, damaged streams, the
      libvpx test vectors when present) and a coretest line
- [ ] Register libav1's decoder with `Media.VideoDecoders.RegisterVideoDecoder`
      and link it into mediaplay
- [ ] libvideo: frame-parallel VP9 decoding (the next frame's rows as
      their references' rows finish) and row-parallel decoding of
      single-tile VP9 streams (parsing and reconstruction apart);
      SIMD (FPC inline assembler) for the 8-tap filters, transforms and
      loop filters (now about a fifth of libvpx's speed single threaded)
- [ ] `Media.Frames`: a layout for 4:4:0 (VP9 profile 1/3); such frames
      say pl420 with full width chroma planes
- [x] libav1's decoder registered (`Av1.MediaDecoder`) and linked into
      mediaplay: `-k` gives per-frame checksums of AV1 in WebM, Matroska,
      MP4, IVF and OBU files (`Media.Ivf`, `Media.ObuStream`)
- [ ] MP3 Layers I and II; Vorbis floor 0 and MP3 intensity stereo / mixed
      blocks checked against streams that use them (no host encoder writes
      them); Theora timing in Ogg; mfra-based MP4 seeking; zlib-compressed
      Matroska frames
- [ ] A player application (video window, seeking bar, playlists) and the
      browser's HTMLMediaElement / MSE on libmedia (next batch)
- [ ] Decoding audio ahead in a thread of its own while playing (mediaplay
      decodes and writes on one thread)

## Planned: 3D graphics (OpenGL and Vulkan)

- [ ] **Kernel GPU interface** (a DRM/KMS-like role, generic names):
      display modes and outputs (scanout, page flips, vblank events,
      hot-plugged monitors via EDID), GPU memory objects (allocate, map,
      share between processes by handle), command submission with fences
      and sync objects, per-process GPU contexts, and a device file per
      GPU. Drivers: virtio-gpu 3D first (QEMU: virgl for OpenGL, venus
      for Vulkan), then real hardware (Intel, AMD) much later.
- [x] **libgl / libvulkan via Mesa**, software rendering: the ports
      graphics/mesa (26.3.1: llvmpipe, softpipe, lavapipe) and devel/llvm
      (23.1.6, LLVM's libraries for the system); EGL's native platform
      and a Vulkan WSI backend (`VK_FPOS_window_surface`) for the display
      server's shared-memory windows, `<freepascalos/windowing.h>` (the
      protocol for C); gldemos (gltest, glgears, vkcube) on the system
      disk. See docs/Architecture.md "OpenGL, OpenGL ES, EGL and Vulkan
      (Mesa)".
- [ ] Mesa, what is left: a Vulkan loader (the Khronos loader, taught
      `VK_FPOS_window_surface`; programs open libvulkan_lvp.so
      themselves today); vsync'd presentation and frame pacing
      (the swap interval and FIFO are accepted and ignored); zero-copy
      presentation (a window surface per swapchain image, or the
      renderer drawing straight into the section); the shader cache
      (disabled: needs a cache folder policy); GPU buffers and
      virgl/venus once the kernel GPU interface exists, then hardware
      drivers. Pascal bindings (OpenGL and Vulkan headers for FPC) so
      Pascal programs can use them.
- [ ] Display server: GPU-composited windows (optional; keep the CPU path),
      a way for a window's content to be a GPU buffer, and vsync'd
      presentation.
- [ ] WebGL in the browser on top of libgl (later).
- [x] Demos: glxgears-like and vkcube-like programs (gldemos: glgears,
      vkcube; gltest checks EGL and three GL APIs headless, a coretest
      line runs it on llvmpipe and softpipe).
- [ ] Conformance subsets (piglit / VK-GL-CTS pieces) run in QEMU, later
      with virtio-gpu.

## Planned: installer image

- [ ] A bootable installer image (UEFI, hybrid ISO + USB image; an SD
      image for the Raspberry Pi) running a live session with the
      installer program, and a text-mode fallback.
- [ ] Steps: language, region and time zone, keyboard layout (with a test
      field), network (optional; for package repositories and time),
      disk setup (guided "erase disk" and manual partitioning: GPT
      tables, create, delete, resize where the file system allows,
      format ext4 / FAT32 / exFAT, the EFI system partition, swap later,
      mount points written to /etc/fstab), user account (name, login,
      password, administrator rights, automatic login), computer name,
      optional packages from the ports repository, a summary, then the
      installation with progress and a log.
- [ ] Installing: copy the system, write fstab and settings (keyboard,
      locale, time zone, hostname), create the user and home folder, and
      install the boot loader: the ESP files plus a UEFI boot entry
      through the runtime variable services (needs SetVariable support
      in the kernel), or the Pi's boot partition and config.txt.
- [ ] Libraries/tools it needs: a partitioning library (GPT/MBR reading
      and writing, alignment, resize checks), mkfs tools for ext4, FAT
      and exFAT inside the OS (check which exist), file system resize
      (ext4 grow/shrink, FAT), UEFI variable access, and a keyboard
      layout system (layouts as data files, a setting, switching in the
      display server and the console).
- [ ] First-boot setup for preinstalled images (the same steps without
      disk setup), and an "upgrade an existing installation" path.
- [ ] Tests: a scripted install in QEMU onto an empty virtual disk
      (guided and manual), then booting the installed system and checking
      the user, settings and boot entry.

## C library and toolchain

- [x] Targets `x86_64-freepascalos` and `aarch64-freepascalos` in binutils
      2.47 and GCC 16.2 (`toolchain/patches`), built by
      `toolchain/build-toolchain.sh` (`make c-toolchain`)
- [x] mlibc 7.0 with FreePascalOS sysdeps (`toolchain/mlibc/sysdeps/freepascalos`)
- [x] libgcc (shared and static), libstdc++ (shared and static)
- [x] PT_INTERP: C programs start in mlibc's `ld.so`
- [x] mmap/munmap with MAP_FIXED, threads on caller-made stacks (180, 181, 185)
- [x] fork (copy on write), exec in place (other threads end first), waitpid (182-184)
- [x] POSIX signals: dispositions, masks, handlers, SIGCHLD, SIGPIPE,
      Ctrl-C/hang-up/TERM as signals, faults as SIGSEGV/SIGFPE/SIGILL (186-192)
- [x] Process groups and sessions, getppid (193-196)
- [x] C test suite and C++ test (`toolchain/ctest`, `make c-test`, a coretest line)
- [x] Both architectures: the toolchain built and ctest passing on amd64
      (KVM) and arm64 (QEMU virt)
- [ ] The C runtime on the Raspberry Pi 5 (built, not tried on the board)
- [x] SA_RESTART (with the POSIX calls that never restart), sigaltstack (stack
      overflows handled on it), sigtimedwait/sigwaitinfo, sigqueue, real-time
      signal queues with siginfo values in order (240-242)
- [x] AF_UNIX sockets (stream, datagram, seqpacket; paths and the
      abstract namespace; socketpair; SCM_RIGHTS, SCM_CREDENTIALS,
      SO_PEERCRED; shutdown, names) (253-258); pseudo-terminal masters as
      one descriptor (/dev/ptmx, /dev/pts/N, posix_openpt/ptsname/openpty)
- [ ] Local sockets: collect sockets passed in messages queued on
      themselves (cycles stay until shutdown); /dev/pts as a directory
      to list
- [x] epoll/inotify/eventfd/timerfd/signalfd (calls 260-269: kernel event
      counters, timer descriptors, signal descriptors, event polls and
      watch groups; mlibc's linux-epoll/eventfd/timerfd/signalfd options
      and its own inotify, without Linux's headers)
- [ ] inotify: IN_OPEN, IN_ACCESS, IN_CLOSE_WRITE/NOWRITE (the VFS reports
      no opens, closes or reads); recursive watches are not wanted
- [ ] epoll: EPOLLEXCLUSIVE wakes every waiter (accepted, not one at a
      time); a nested poll is ready while its ready list is not empty
      (not checked deeper)
- [ ] signalfd reports the signals of the process that made it (after
      fork the child's reads take its own, readiness follows the
      parent's); timerfd: absolute real time timers do not follow the
      clock read again on resume (other processors frozen then)
- [x] Atomic pread/pwrite (250, 251; preadv/pwritev), per-file fsync
      through tagged block cache lines (252), nanosecond file times in
      stat, utimensat and futimens
- [ ] fdatasync skipping metadata that is not needed to read the data
      (it does what fsync does)
- [x] setitimer/getitimer/alarm: all three interval timers in the kernel (248)
- [x] timer_create and friends (REALTIME, MONOTONIC, process and thread CPU
      time; SIGEV_SIGNAL/NONE/THREAD), ITIMER_VIRTUAL/PROF; CPU-time clocks
      from real per-thread times, clock_getcpuclockid/pthread_getcpuclockid (243-249)
- [x] Absolute CLOCK_REALTIME timers follow steps of the wall clock; signalfd
      reads the real-time queues with their values
- [ ] SIGEV_THREAD_ID; thread-directed queued signals (pthread_sigqueue,
      tgkill with a value)
- [x] Clang driver support (`--target=x86_64-freepascalos`, `aarch64-freepascalos`):
      LLVM 23.1.6 patches, `make clang-toolchain`, ctest built by Clang
- [x] msync and mincore in mlibc's sysdeps (CallSyncMemory 214,
      CallQueryMemoryResidency 215); clock_gettime from the clock page
      (AuxiliaryClockPage) instead of a system call
- [x] C ports through the ports tool (config.sub and libtool taught the
      target automatically): zlib, lua, sqlite3, bash tried on the system
