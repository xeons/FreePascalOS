# FreePascalOS

A small, modern operating system written in Free Pascal (with inline assembly
where the hardware requires it), for 64-bit UEFI machines. The kernel is
layered in the style of Windows NT: a hardware abstraction layer at the
bottom, a kernel core for scheduling and synchronization, and executive-style
subsystems (memory, objects, processes) on top.

The first target is x86-64. The code is arranged so that a 64-bit ARM
(AArch64) port only has to supply its own versions of the architecture
specific units; see [docs/Architecture.md](docs/Architecture.md).

## What works today

- A UEFI loader that finds the framebuffer and ACPI tables, loads the kernel
  ELF image, builds the initial page tables, exits boot services and jumps to
  the kernel.
- A higher-half kernel with its own GDT, TSS (with separate stacks for double
  faults, NMIs and machine checks) and IDT, plus a register dump on any fatal
  exception.
- Interrupt priority levels (passive, dispatch, device, clock, high) mapped
  onto the local APIC task priority register, and spin locks built on them.
- A local APIC HAL with a calibrated periodic clock and self interrupts for
  deferred scheduling.
- Memory management: a page frame database, four level page tables, a kernel
  virtual range allocator, a size class heap, and guard-paged kernel stacks.
- A preemptive, priority based scheduler with time slices, sleeping, events
  and thread exit and cleanup, on **several processors**: the secondary
  processors are found in the ACPI MADT and started through a real mode
  trampoline; each has its own data block (reached through GS), descriptor
  tables, idle thread and clock, and they share the run queues. TLB
  shootdowns, rescheduling and the panic halt go between them by
  inter-processor interrupts. `processors=N` limits how many run.
- Mutexes (sleeping, recursive locks) alongside spin locks and events.
- An object manager with reference counting and named objects, plus process
  and thread objects.
- Device discovery through ACPI tables and PCI Express (ECAM) enumeration.
- Storage drivers: AHCI (all command slots, native command queuing,
  direct DMA, ATAPI optical drives), NVMe, virtio-blk, and USB mass
  storage on an xHCI driver; MSI and MSI-X interrupts; disk flushes.
  Block devices, GPT and MBR (including logical) partitions, and a
  write-back block cache with read-ahead.
- A virtual file system with path lookup, symbolic links, a shared node
  cache, open files, directory listings, and create / write / truncate /
  remove / rename, with read-write drivers for **FAT12, FAT16, FAT32 (with
  long file names), exFAT, ext2, ext3 and ext4** (extents, 64-bit, flex_bg,
  metadata checksums, htree directories for reading, sparse files, fast and
  slow symbolic links). ext3 and ext4 are written through their journal
  (ordered mode, with disk flushes), and replayed after a crash.
- Watching files and folders for changes made by any program (names
  created, removed and renamed, files written, attributes changed; a
  whole subtree if wanted) through waitable handles, on every file system
  (`watch PATH`); USB disks plugged in while the system runs are mounted
  under `/volumes` at once and announced, and unplugging one takes its
  volumes away cleanly (`volumes`, `volumes -w`).
- Sound: an audio framework (`/dev/audio`) with an Intel HD Audio driver,
  `libaudio`, and the `tone`, `play` and `mixer` programs.
- USB keyboards next to PS/2 ones, with dead keys for the German and
  French layouts; a framebuffer console with UTF-8 and escape sequences.
- A kernel debug shell (kernel option `kshell`).
- A real-time clock driver, so files get correct timestamps.
- I/O APIC interrupt routing (from the ACPI MADT), with interrupt-driven
  PS/2 keyboard and serial console input; interrupt handlers hand work to
  dispatch level through deferred calls. Keyboard layouts us, uk, de and
  fr (kernel option `keymap=`), AltGr, Num Lock and the lock lights.
- **The Free Pascal runtime library** for user programs: strings,
  dynamic arrays, exceptions, classes, generics, threads (TThread),
  SysUtils, Classes, StrUtils, DateUtils, Math, Variants and the rest of
  the RTL; processor exceptions become catchable exceptions
  (EAccessViolation, EDivByZero, EZeroDivide, ...); built from the
  compiler's sources with the operating system
  parts on this kernel (`rtl/fpc`); ordinary Free Pascal programs build
  and run.
- **User mode**: processes with their own address spaces (demand-zero
  memory, isolated crashes), system calls through `syscall`, per-process
  handle tables, pipes, devices under `/dev` (`null`, `zero`, `full`,
  `random`, `urandom`, `console`, `tty`, `keyboard`, `serial0` and every
  disk and partition) served by an NT-style I/O manager with driver
  objects, device objects and request packets that complete
  asynchronously (AHCI by MSI interrupt) and can be cancelled, and an ELF
  loader that maps position independent programs and the shared
  libraries they need, binding symbols at load time; images are kept as
  sections whose pages every process shares (copy on write). Programs can also load libraries at run
  time (`LoadLibrary` / `FindSymbol`), end, stop and continue other
  programs (`kill`, `timeout`, Ctrl-C, Ctrl-Z), wait with timeouts, change permissions, owners and times,
  make hard links, and run in a `chroot`.
- **Users and permissions**: processes run as real, effective and saved
  user and group ids with supplementary groups and a umask, all inherited;
  opening, creating, removing, renaming, searching directories, chmod,
  chown, setting times and running programs are checked against the
  Unix mode bits (root passes everything but needs one execute bit to run
  a file). Set-user-ID programs run as their owner; `su`, `passwd` and
  `login` check salted SHA-256 hashes in `/etc/shadow`.
- **Startup, services and sessions**: the first program is a service
  manager that starts the services of the boot mode (text or graphical)
  from definitions in `/etc/services` in the order of what they need,
  waits for each to be ready, starts failed ones again within limits,
  logs their output to `/var/log`, and stops them in reverse order when
  the system shuts down; `service list|status|start|stop|restart`. A
  login on the console, and a login window on the screen that starts
  the user's desktop in a session of its own (Log off ends it).
- **Processes and scheduling**: a process list (`ps`, `pgrep`, `pkill`)
  with CPU time counted per thread, nice values mapped to thread
  priorities (`nice`, `renice`), processor affinity (`taskset`), per
  processor run queues, and 1/5/15 minute load averages (`uptime`). Named pipes on ext volumes (`mkfifo`, `mknod NAME p`), and
  the space files take on the volume (`du`, `ls -s`, `stat %b`).
- **A userland written in Free Pascal**:
  - `libsystem.so`: system calls, heap, buffered streams, printf style
    formatting, files, processes, environment, time, console settings
  - `libcryptography.so`: MD5, SHA-1, SHA-224/256/384/512, BLAKE2b, HMAC,
    CRC-32 / CRC-32C / cksum CRC / BSD and System V sums, AES (CBC, CTR),
    ChaCha20 and a random number generator seeded from RDRAND
  - `libcoreutils.so`: GNU style option parsing, messages, sorting, tree
    walking and copying, POSIX regular expressions (BRE and ERE), shell
    style wildcards, chmod modes, date parsing, base64/32/16/2/z85, accounts
  - a POSIX style shell `sh` (pipes, redirections, `&&` `||`, `if` /
    `while` / `until` / `for` / `case`, functions with `local` and
    `return`, here-documents, variables and `${...}` expansions (`:-`
    `:=` `:+` `:?` `#` `##` `%` `%%` and lengths), `$( )` and `$(( ))`
    with assignments, globbing, quoting, `eval`, `exec`, `command`,
    `type`, scripts), with line editing (long lines scroll sideways),
    history and Tab completion on the console; Ctrl-C ends the running
    pipeline, or a loop of builtins; job control: Ctrl-Z stops it, `jobs`,
    `fg`, `bg`, `wait`, `$!` and `kill %N`
  - recreations of the GNU core utilities, 104 commands: arch b2sum
    base32 base64 basename basenc cat chgrp chmod chown chroot cksum comm
    cp csplit cut date dd df dir dirname du echo env expand expr factor
    false fmt fold groups head hostid id install join kill link ln logname
    ls md5sum mkdir mkfifo mknod mktemp mv nice nl nohup nproc numfmt od
    paste pathchk
    pinky pr printenv printf ptx pwd readlink realpath rm rmdir seq
    sha1sum sha224sum sha256sum sha384sum sha512sum shred shuf sleep sort
    split stat stdbuf stty sum sync tac tail tee test `[` timeout touch tr
    true truncate tsort tty uname unexpand uniq unlink uptime users vdir
    wc who whoami yes (not included: the SELinux tools chcon and runcon)
  - everyday tools beyond the core utilities: `grep` (with `egrep` and
    `fgrep`), `sed`, `find`, `xargs`, `diff` (normal, unified and context
    output, recursive), the pager `less` (also started as `more`), `ps`,
    `pgrep`, `pkill`, `renice`, `taskset`, `su`, `passwd`, `watch`
    (changes to files and folders as they happen) and `volumes` (the
    mounted volumes, and with `-w` volumes arriving and leaving)
- Debug output to the serial port and to a text console drawn on the
  framebuffer.
- Kernel self tests that run on every boot, including file system read and
  write tests against a disk image with one partition of every supported
  format. After a test run, `make test` checks every written partition with
  the format's own tools (fsck.fat, fsck.exfat, e2fsck, mtools, debugfs).
  `make test` then runs `coretest` in user mode, which drives the shell and
  every utility through about 210 command lines and checks their output.

## Requirements

- Free Pascal 3.2.2 (`fpc`, x86-64 compiler) and its sources (`fpc-src`,
  expected in `/usr/lib/fpc/src`; set `FPC_SOURCE` otherwise): user
  programs get the Free Pascal runtime library built from them
- GNU binutils (`ld`, `objcopy`, `objdump`)
- QEMU (`qemu-system-x86_64`) and OVMF UEFI firmware, for running it
- `sfdisk` and mtools, for `make image`
- dosfstools, exfatprogs, e2fsprogs and Python 3, for the test disk used by
  `make run` and `make test`
- The system's fonts: Terminus (`terminus-font`), and DejaVu Sans
  (`ttf-dejavu`) with Python's Pillow (`python-pillow`), which renders it
  into the interface's anti-aliased bitmap fonts at build time

On Arch based systems:
`pacman -S fpc fpc-src qemu-system-x86 edk2-ovmf mtools dosfstools exfatprogs e2fsprogs python terminus-font ttf-dejavu python-pillow`.

## Building and running

```
make              # build build/amd64/esp (loader + kernel)
make userland     # build the libraries and programs into build/amd64/user
make system-disk  # build the ext4 system volume (/bin, /lib, /etc, /tmp, /home)
make run          # boot in QEMU with the test and system disks; the kernel log
                  # and then the shell appear on the terminal (the test disk
                  # is a fresh copy each time; the system disk is a copy of
                  # its own that keeps changes between runs, until
                  # make system-disk rebuilds the image, and never
                  # reaches the image the tests use)
make debug        # same, but wait for GDB on localhost:1234
make test         # boot headless, run every self test and coretest, type
                  # into the console, boot the graphical session; print
                  # TEST PASSED, INPUT TEST PASSED and SESSION TEST PASSED
make image        # build build/amd64/FreePascalOS.img (GPT, one EFI partition)
make clean
```

`ACCEL=kvm make test` (or `make run`) uses KVM: much faster, and with the
processor's own behaviour where QEMU's emulator differs (it does not raise
SIMD floating point exceptions). `PROCESSORS=N` sets the processor count.

After startup the kernel runs the service manager (`/bin/servicemanager`)
from the system volume (the volume labelled `FPOSROOT`, or the one named by
the `root=` option). It starts the services of the boot mode, defined in
`/etc/services` (`service list` shows them):

- **Graphical** (the default): the display server, then the login window;
  logging in starts the desktop as that user. The Start menu has Log off
  (back to the login window) and Shut down. The serial port (the terminal
  `make run` starts in) keeps a text login for debugging.
- **Text** (kernel option `mode=text`): a login on the console, the screen
  and the serial port.

`autologin=USER` logs USER in without asking: the first session on the
screen in graphical mode, every console login in text mode. So
`autologin=user` boots straight to the desktop, and `mode=text
autologin=root` to a root shell. `init=/bin/program` runs another first
program instead of the service manager (the tests use `init=/bin/coretest`);
`init=/bin/sh` gives a root shell on the console with no services. Programs
see the system volume as `/`; every mounted volume is also reachable as
`/volumes/disk1p1`, `/volumes/disk1p2`, ... (a USB disk plugged in later
appears there too). The services' output is in
`/var/log/NAME.log`.

The system volume has two accounts: `root` (password `root`) and `user`
(uid 1000, home `/home/user`, password `user`). `su user` becomes the
ordinary user, `passwd` changes a password.

Kernel options can be put in `\FreePascalOS\options.txt` on the boot volume
(one line, words separated by spaces, e.g. `mode=text autologin=root`; see
`kernel/core/Kernel.Options.pas`).

Heap checking catches use after free, writes after free, writes past the end
of a block, double frees and reads of memory that was never set, in the
kernel heap and in every program: the kernel option `heapchecks` turns it on
for both (`make test` always does), `heapchecks=fill` without the quarantine.
For one program, the environment variable overrides the option:
`HEAP_CHECKS=all program`, `HEAP_CHECKS=fill program` or `HEAP_CHECKS=off
program`. A failed check ends the program with a report on standard error
and the console (exit status 204); in the kernel it is a panic. See "Heap
checking" in `docs/Architecture.md`.

The disk image can be written to a USB stick to boot real hardware, with
Secure Boot disabled. Writing it erases the stick:

```
sudo dd if=build/amd64/FreePascalOS.img of=/dev/sdX bs=1M conv=fsync
```

## Source layout

```
boot/uefi/          UEFI loader (built as a PE32+ EFI application)
  amd64/            Page table setup and kernel hand-off for x86-64
shared/             Code and definitions used by more than one of loader,
                    kernel and userland (system call ABI, ELF, text, memory)
  amd64/            Virtual address layout for x86-64
rtl/                System units for the compiler: freestanding/ (loader and
                    kernel), user/ (user programs, with the si_prc startup
                    unit), common/ (units both need)
hal/amd64/          Hardware abstraction layer: APIC, PIT, PIC, serial, ports
kernel/
  Kernel.Startup    Entry point and phase 0 / phase 1 initialization
  Kernel.SelfTest   Boot-time self tests
  Kernel.FileSystemTest  File system self test
  core/             Priority levels, spin locks, mutexes, interrupts,
                    scheduler, clock, events, options, panic
  core/amd64/       Descriptor tables, interrupt stubs, context switch, CPU
  memory/           Physical pages, virtual ranges, heap, stacks
  memory/amd64/     Page tables
  objects/          Object manager
  processes/        Processes, threads, address spaces, handles, the ELF
                    image loader, system calls and the first user program
  firmware/         ACPI tables
  io/               I/O manager, device files, I/O startup, PCI and MSI,
                    block devices, partitions, block cache, pipes, console
                    and its input, input devices
  drivers/storage/  AHCI SATA driver
  drivers/input/    PS/2 keyboard and serial port drivers
  drivers/devices/  Memory devices, console device, disk devices
  filesystems/      VFS (types, volumes, open files, attributes, hard links)
                    and the FAT, exFAT and ext2/3/4 drivers
  runtime/          Linked lists, atomics, checksums, Unicode
  debug/            Debug log and framebuffer console (+ font)
  link/             Kernel linker scripts
userland/
  lib/system/       libsystem.so: the Sys.* units
  lib/cryptography/ libcryptography.so: the Crypto.* units
  lib/coreutils/    libcoreutils.so: the Util.* units shared by the tools
  lib/plugin/       libplugin.so, loaded at run time by coretest
  bin/              One file per program (/bin/<name>)
  sh/               The shell's units (lexer, parser, expansion, execution)
  notepad/          Notepad's units (files, the document, menus, Go To)
  userland.mk       Userland build rules (included by the Makefile)
tools/PsfToPascal/  Converts a PSF console font into a Pascal include file
tools/RenderFont/   Renders a TrueType font into coverage fonts (.cvf)
tools/DrawingTest/  Checks libdrawing and libfont on the host
tools/TextTest/     Checks the multi-line edit box's logic on the host
scripts/            QEMU launcher, test runner, disk image builders
docs/               Architecture notes
```

## License

FreePascalOS is free software: you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option)
any later version. See `LICENSE` for the full text.

## Licenses of included material

The console font in `kernel/debug/Debug.ConsoleFont.inc` is generated from
Terminus (ter-116n), distributed under the SIL Open Font License 1.1; the
license is in `kernel/debug/Debug.ConsoleFont.LICENSE`.

The system volume carries Terminus (`/lib/fonts/terminus`, SIL Open Font
License 1.1) and DejaVu Sans rendered into bitmaps (`/lib/fonts/dejavu-sans`,
the Bitstream Vera licence with DejaVu's changes, which are in the public
domain), each with its licence in the same directory.
