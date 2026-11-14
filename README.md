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
  and thread exit and cleanup.
- Mutexes (sleeping, recursive locks) alongside spin locks and events.
- An object manager with reference counting and named objects, plus process
  and thread objects.
- Device discovery through ACPI tables and PCI Express (ECAM) enumeration.
- An AHCI SATA driver, block devices, GPT and MBR (including logical)
  partitions, and a block cache.
- A virtual file system with path lookup, symbolic links, a shared node
  cache, open files, directory listings, and create / write / truncate /
  remove / rename, with read-write drivers for **FAT12, FAT16, FAT32 (with
  long file names), exFAT, ext2, ext3 and ext4** (extents, 64-bit, flex_bg,
  metadata checksums, htree directories for reading, sparse files, fast and
  slow symbolic links).
- A real-time clock driver, so files get correct timestamps.
- I/O APIC interrupt routing (from the ACPI MADT), with interrupt-driven
  PS/2 keyboard and serial console input; interrupt handlers hand work to
  dispatch level through deferred calls.
- **User mode**: processes with their own address spaces (demand-zero
  memory, isolated crashes), system calls through `syscall`, per-process
  handle tables, pipes, a console and `/dev/null`, and an ELF loader that
  maps position independent programs and the shared libraries they need,
  binding symbols at load time. Programs can also load libraries at run
  time (`LoadLibrary` / `FindSymbol`), end other programs (`kill`,
  `timeout`), wait with timeouts, change permissions, owners and times,
  make hard links, and run in a `chroot`.
- **Users and permissions**: processes run as real, effective and saved
  user and group ids with supplementary groups and a umask, all inherited;
  opening, creating, removing, renaming, searching directories, chmod,
  chown, setting times and running programs are checked against the
  Unix mode bits (root passes everything but needs one execute bit to run
  a file). Set-user-ID programs run as their owner; `su` and `passwd`
  check salted SHA-256 hashes in `/etc/shadow`.
- **Processes and scheduling**: a process list (`ps`, `pgrep`, `pkill`)
  with CPU time counted per thread, nice values mapped to thread
  priorities (`nice`, `renice`), and 1/5/15 minute load averages
  (`uptime`). Named pipes on ext volumes (`mkfifo`, `mknod NAME p`), and
  the space files take on the volume (`du`, `ls -s`, `stat %b`).
- **A userland written in Free Pascal**:
  - `libsystem.so`: system calls, heap, buffered streams, printf style
    formatting, files, processes, environment, time, console settings
  - `libcryptography.so`: MD5, SHA-1, SHA-224/256/384/512, BLAKE2b, HMAC,
    CRC-32 / CRC-32C / cksum CRC / BSD and System V sums, AES (CBC, CTR),
    ChaCha20 and a random number generator seeded from RDRAND
  - `libcoreutils.so`: GNU style option parsing, messages, sorting, tree
    walking and copying, POSIX regular expressions (BRE and ERE), chmod
    modes, date parsing, base64/32/16/2/z85, accounts
  - a POSIX style shell `sh` (pipes, redirections, `&&` `||`, `if` /
    `while` / `until` / `for`, variables, `$( )` and `$(( ))`, globbing,
    quoting, scripts), with line editing, history and Tab completion on
    the console; Ctrl-C ends the running pipeline
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
  - beyond coreutils: `ps`, `pgrep`, `pkill`, `renice`, `su`, `passwd`
- Debug output to the serial port and to a text console drawn on the
  framebuffer.
- Kernel self tests that run on every boot, including file system read and
  write tests against a disk image with one partition of every supported
  format. After a test run, `make test` checks every written partition with
  the format's own tools (fsck.fat, fsck.exfat, e2fsck, mtools, debugfs).
  `make test` then runs `coretest` in user mode, which drives the shell and
  every utility through about 210 command lines and checks their output.

## Requirements

- Free Pascal 3.2.2 (`fpc`, x86-64 compiler)
- GNU binutils (`ld`, `objcopy`, `objdump`)
- QEMU (`qemu-system-x86_64`) and OVMF UEFI firmware, for running it
- `sfdisk` and mtools, for `make image`
- dosfstools, exfatprogs, e2fsprogs and Python 3, for the test disk used by
  `make run` and `make test`

On Arch based systems:
`pacman -S fpc qemu-system-x86 edk2-ovmf mtools dosfstools exfatprogs e2fsprogs python`.

## Building and running

```
make              # build build/amd64/esp (loader + kernel)
make userland     # build the libraries and programs into build/amd64/user
make system-disk  # build the ext4 system volume (/bin, /lib, /etc, /tmp, /home)
make run          # boot in QEMU with the test and system disks; the kernel log
                  # and then the shell appear on the terminal
make debug        # same, but wait for GDB on localhost:1234
make test         # boot headless, run every self test and coretest,
                  # print TEST PASSED or TEST FAILED
make image        # build build/amd64/FreePascalOS.img (GPT, one EFI partition)
make clean
```

Type into the QEMU window (PS/2 keyboard) or the terminal (serial port).
After startup the kernel runs `/bin/sh` from the system volume (the volume
labelled `FPOSROOT`, or the one named by the `root=` option) on the serial
console, as root; `init=/bin/program` picks another first program. Programs see the
system volume as `/`; every mounted volume is also reachable as
`/volumes/disk1p1`, `/volumes/disk1p2`, ...

The system volume has two accounts: `root` (password `root`) and `user`
(uid 1000, home `/home/user`, password `user`). `su user` becomes the
ordinary user, `passwd` changes a password.

Kernel options can be put in `\FreePascalOS\options.txt` on the boot volume
(see `kernel/core/Kernel.Options.pas`).

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
  io/               I/O startup, PCI, block devices, partitions, block cache,
                    pipes, console and null device
  drivers/storage/  AHCI SATA driver
  drivers/input/    PS/2 keyboard and serial input drivers
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
  userland.mk       Userland build rules (included by the Makefile)
tools/PsfToPascal/  Converts a PSF console font into a Pascal include file
scripts/            QEMU launcher, test runner, disk image builders
docs/               Architecture notes
```

## Licenses of included material

The console font in `kernel/debug/Debug.ConsoleFont.inc` is generated from
Terminus (ter-116n), distributed under the SIL Open Font License 1.1; the
license is in `kernel/debug/Debug.ConsoleFont.LICENSE`.
