{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

{
  The system call interface: call numbers, flags, error codes and record
  layouts (see Abi.SystemCalls for the calling convention).

  Included by the unit Abi.SystemCalls, and directly by the user System
  unit (rtl/fpc), which cannot use other units.
}
const
  { --- Call numbers ---------------------------------------------------- }

  CallExit = 0;
  CallWrite = 1;
  CallRead = 2;
  CallOpen = 3;
  CallClose = 4;
  CallSeek = 5;
  CallGetHandleInformation = 6;
  CallGetPathInformation = 7;
  CallReadDirectory = 8;
  CallCreateDirectory = 9;
  CallRemove = 10;
  CallRename = 11;
  CallCreateSymbolicLink = 12;
  CallReadSymbolicLink = 13;
  CallSetFileSize = 14;
  CallGetCurrentDirectory = 15;
  CallSetCurrentDirectory = 16;
  { (Length, Flags): Length bytes of fresh zeroed memory (whole pages);
    returns its address. Flags: 0, or AllocateForThread. }
  CallAllocateMemory = 17;
  { (Address): frees memory from CallAllocateMemory or CallMapHandle. }
  CallFreeMemory = 18;
  CallCreateProcess = 19;
  CallWaitForProcess = 20;
  CallGetProcessId = 21;
  CallCreatePipe = 22;
  CallDuplicateHandle = 23;
  CallSleep = 24;
  { (Which): TimeWallClock (Unix time), TimeUptimeMilliseconds or
    TimeUptimeNanoseconds (timing ping replies). }
  CallGetTime = 25;
  CallLoadLibrary = 26;
  CallFindSymbol = 27;
  CallGetSystemInformation = 28;
  { (Path, InformationAddress): the volume Path is on
    (TAbiVolumeInformation). }
  CallGetVolumeInformation = 29;
  CallSync = 30;
  CallGetHandleKind = 31;
  CallListVolumes = 32;
  CallSetPathAttributes = 33;
  CallCreateHardLink = 34;
  CallTerminateProcess = 35;
  CallSetRootDirectory = 36;
  CallControlHandle = 37;
  CallSetInterruptIgnored = 38;
  CallGetProcessGroup = 39;

  { Threads and thread synchronization (40-49). }
  { (Entry, Argument, StackSize): starts a thread of the calling process
    at Entry with Argument in the first argument register and a stack of
    StackSize bytes (0 = default). Returns a thread handle. }
  CallCreateThread = 40;
  { (ExitCode): ends the calling thread; the last thread to end ends the
    process. Never returns. }
  CallExitThread = 41;
  { (Handle, TimeoutMilliseconds or InfiniteWait, ExitCodeAddress): waits
    for the thread to end and stores its exit code (a LongInt). }
  CallWaitForThread = 42;
  { (Address): sets the calling thread's thread pointer (%fs base). }
  CallSetThreadPointer = 43;
  { (Handle): the id of the thread behind a thread handle, or of the
    calling thread for CurrentThreadHandle. }
  CallGetThreadId = 44;
  { (Address, ExpectedValue, TimeoutMilliseconds or InfiniteWait): if the
    32-bit value at Address still equals ExpectedValue, sleeps until
    CallWakeAddress wakes it, the timeout passes (ErrorTimedOut) or the
    process is asked to end (ErrorInterrupted). Returns ErrorBusy at once
    if the value differs. }
  CallWaitOnAddress = 45;
  { (Address, Count): wakes up to Count threads waiting on Address;
    returns how many were woken. }
  CallWakeAddress = 46;
  { (Handle or CurrentThreadHandle): suspends the thread at its next safe
    point (a system call or interrupt returning to it) until it is
    resumed as often as it was suspended; returns the previous suspend
    count. A system call it was waiting in runs again afterwards. }
  CallSuspendThread = 47;
  { (Handle): undoes one suspension; returns the previous count. }
  CallResumeThread = 48;
  { (Handle, ExitCode): ends another thread of the process at its next
    safe point, as if it had called CallExitThread. }
  CallTerminateThread = 49;

  { Users, permissions, process information and priorities. }
  CallListProcesses = 50;
  CallGetCredentials = 51;
  CallSetUserIds = 52;
  CallSetGroupIds = 53;
  CallSetGroups = 54;
  CallSetUmask = 55;
  CallGetPriority = 56;
  CallSetPriority = 57;
  CallCreateFifo = 58;

  { Job control. A target is a process id (> 0), a process group (its
    negation) or the caller's own group (0); the calls return how many
    processes they stopped or continued. }
  CallStopProcesses = 59;
  CallContinueProcesses = 60;
  { (Handle, TimeoutMilliseconds or InfiniteWait): like CallWaitForProcess,
    but also returns WaitStatusStopped, once, when the process stops. }
  CallWaitForProcessChange = 61;

  { Processor affinity of a process (0 means the caller): the mask of the
    processors its threads may run on, bit N for processor N, limited to
    the processors that run. Setting needs the same right as
    CallSetPriority, and a mask with no running processor is refused. }
  CallGetAffinity = 62;
  CallSetAffinity = 63;

  { Thread priorities: an offset (-15 .. 15) from the priority the
    process's nice value gives. (Handle or CurrentThreadHandle, Offset);
    only root may raise a thread above its process. CallGetThreadPriority
    returns the offset plus ThreadPriorityOffsetBias, so it is never
    negative. }
  CallSetThreadPriority = 64;
  CallGetThreadPriority = 65;

  { (Handle, ChangesAddress): like CallSetPathAttributes, for the file
    behind a handle (TAbiAttributeChanges). }
  CallSetHandleAttributes = 66;

  { Processor exceptions in user mode (an access violation, a division by
    zero, ...). (Address): the process's exception dispatcher, 0 for
    none. With one, a thread that raises an exception continues at
    Address with RDI pointing at a TAbiExceptionRecord on its stack
    (below the 128 byte red zone), as if called; the dispatcher must not
    return. Without one, or if the record does not fit on the stack, the
    process ends with status ExitStatusException. A stack overflow is
    passed on like the others, as long as the stack's reserve is armed. }
  CallSetExceptionDispatcher = 67;
  { (): the dispatcher has taken over the record. A thread raising an
    exception again before this ends the process: its dispatcher failed. }
  CallExceptionDispatched = 68;
  { (ContextAddress): continues the calling thread with the registers of
    a TAbiContext (an exception's, possibly changed), like NtContinue.
    Does not return; fails with ErrorInvalidArgument if the context does
    not lead back into user memory. Of RFLAGS only the arithmetic flags
    and the direction flag are taken. }
  CallContinue = 69;
  { (Action): shuts the system down: ShutdownPowerOff, ShutdownReboot or
    ShutdownHalt. Root only (ErrorNotPermitted). Every process is asked
    to end, the file systems are written out, then the machine powers
    off (ACPI S5), resets or halts. Returns 0 once it has started. }
  CallShutdown = 70;
  { (): suspends to RAM (ACPI S3) and returns once the machine woke: 0,
    or ErrorUnsupported (no S3), ErrorBusy. Root only. }
  CallSuspend = 71;
  { (Handle, Offset, Length): maps Length bytes at Offset (page aligned)
    of what Handle stands for into the program: a device offering memory
    (/dev/display: the framebuffer). Returns the address; writable if the
    handle was opened for writing. Unmapped with CallFreeMemory.
    ErrorUnsupported if the handle has no memory to map. }
  CallMapHandle = 72;

  { --- Objects for programs that work together ---------------------------
    Events, timers, sections, ports and channels are objects behind
    handles, like files: closed with CallClose, passed to children and in
    messages. }

  { (Flags: EventManualReset, EventSignaled): a new event. A manual reset
    event stays signaled until reset and releases every waiter; an
    automatic reset one releases one waiter and resets itself. }
  CallCreateEvent = 73;
  { (Handle): signals or resets an event. }
  CallSetEvent = 74;
  CallResetEvent = 75;
  { (Flags: TimerManualReset): a new timer, not armed. }
  CallCreateTimer = 76;
  { (Handle, DueMilliseconds, PeriodMilliseconds): arms the timer: its
    event is signaled once due, then every Period (0: once), each time
    counted from the last due time. Due 0 stops it. Timers keep to well
    under a millisecond. }
  CallSetTimer = 77;
  { (HandlesAddress, Count, TimeoutMilliseconds or InfiniteWait, Flags):
    waits until one of Count handles (Int64s) is signaled and returns its
    place in the list. Signaled means: an event or timer signaled (an
    automatic reset one is consumed), a process or thread ended, a pipe's
    read end or a channel has something to read (or its other end is
    gone), a pipe's write end has room (or no reader is left), a port
    has a connection waiting, a device has input (/dev/events, and the
    console when a read would not wait). With WaitForAll in Flags, waits
    until all of them are signaled at the same time and returns 0; the
    automatic reset ones are consumed only then, all together.
    ErrorTimedOut, ErrorInterrupted, ErrorUnsupported (a handle that
    cannot be waited on). At most MaximumWaitHandles. }
  CallWaitForHandles = 78;
  { (Length): a new section: Length bytes of zeroed memory to share,
    mapped with CallMapHandle (offset and length within it, page
    aligned) into every process holding a handle to it. }
  CallCreateSection = 79;
  { (NameAddress): a port others connect to by its name (up to
    MaximumPortNameLength characters). ErrorExists if the name is taken. }
  CallCreatePort = 80;
  { (NameAddress): connects to a port: one end of a new channel, whose
    other end waits at the port to be accepted. ErrorNotFound. }
  CallConnectPort = 81;
  { (PortHandle): the end of the oldest connection waiting at the port,
    or ErrorWouldBlock. }
  CallAcceptConnection = 82;
  { (HandlesAddress): two connected channel ends, as two Int64s. }
  CallCreateChannel = 83;
  { (Channel, MessageAddress): sends a TAbiMessage: Length bytes at Data
    and HandleCount handles at Handles (they stay the sender's too).
    ErrorWouldBlock if the other end has MaximumQueuedMessages waiting,
    ErrorBrokenPipe if it is gone. }
  CallSendMessage = 84;
  { (Channel, MessageAddress): receives the oldest message into a
    TAbiMessage's buffers (Length and HandleCount are their capacities on
    the way in, what arrived on the way out; the handles are new handles
    of the receiver). Returns the length. ErrorWouldBlock if there is
    none, ErrorBrokenPipe if none will come, ErrorMessageTooLong if it
    does not fit (Length and HandleCount then say what it needs). }
  CallReceiveMessage = 85;

  { (TerminalAddress, Size): a new pseudo-terminal: a terminal like the
    console (/dev/ptsN) for programs, and its master side for the
    program that shows it (a terminal window). Fills a
    TAbiPseudoTerminal with two handles to the master side - one to read
    what programs write to the terminal, one to write what is typed -
    a handle to the terminal itself (to give a child as its standard
    handles) and N. Size is the window size, rows shl 16 or columns (0
    for 25 by 80). Closing every handle to the master side hangs the
    terminal up: its readers get end of file and the processes it
    controls are ended (status 129). ErrorBusy when every
    pseudo-terminal is taken. }
  CallCreatePseudoTerminal = 86;

  { --- Startup, services and sessions ------------------------------------ }

  { (BufferAddress, Capacity): copies the kernel's command line (the
    options the loader read from options.txt) into the buffer, at most
    Capacity - 1 characters ended by a zero, and returns the whole
    line's length (more than was copied when it did not fit). Anyone
    may read it. }
  CallGetKernelOptions = 87;
  { (Channel, PeerAddress): who holds the other end of a channel: fills
    a TAbiChannelPeer with the process (and its user and group, as they
    were) that connected to the caller's port, or that accepted the
    caller's connection, or that made the pair. ErrorNotFound while a
    connection waits to be accepted. }
  CallGetChannelPeer = 88;
  { (SessionId, ExitCode): asks every process of a session (see
    ProcessNewSession) but the caller to end, as CallTerminateProcess
    would each; returns how many were asked. A process the caller may
    not end is skipped. }
  CallTerminateSession = 89;
  { (): makes the caller the process a shutdown waits for (the service
    manager): returns an event handle signaled when a shutdown starts
    (the power button, CallShutdown, the debug shell). The shutdown then
    waits up to ShutdownCoordinatorSeconds for the caller to end before
    it asks every other process to end. Root only; ErrorBusy while
    another living process has taken it. }
  CallWatchShutdown = 90;

  { --- Notifications -------------------------------------------------------
    The system tells a process things through its notification queue,
    which it waits on with the pseudo-handle NotificationsHandle among
    its other handles (CallWaitForHandles: ready while a notification
    waits) and reads with CallReceiveNotification. A process takes only
    the notifications it selects; for the others the system acts for it
    (see CallRequestEnd). }

  { (Mask): the notifications the process takes itself (Notify*), in
    place of the ones it took; returns the previous mask. A new program
    starts with none. }
  CallSelectNotifications = 91;
  { (NotificationAddress): takes the oldest notification into a
    TAbiNotification. ErrorWouldBlock if none waits. }
  CallReceiveNotification = 92;
  { (TargetKind, TargetId, Reason): asks a process (EndTargetProcess,
    TargetId 0: the caller), every process of a group (EndTargetGroup)
    or of a session (EndTargetSession) to end, for Reason (EndReason*).
    A process that selected the reason's Notify* bit is sent an
    end-requested notification and decides itself what to do (the
    sender may end it outright later, as the service manager does after
    a service's stop timeout); any other is ended at once with the
    reason's status (EndStatusOf: 143, 129 for a hang-up, 130 for an
    interrupt), as it always was. Groups and sessions leave the caller
    out. Returns how many were asked; ErrorNoSuchProcess for none,
    ErrorNotPermitted if all of them belong to another user (root may
    ask anyone). }
  CallRequestEnd = 93;

  { The pseudo-handle of the calling process's notification queue, for
    CallWaitForHandles. }
  NotificationsHandle = -2;

  { TAbiNotification.Kind }
  { Something asks the process to end: Reason says who or why. }
  NotificationEndRequested = 1;
  { The size of the process's controlling terminal changed while the
    process was in its foreground group: Value is rows shl 16 or
    columns. Nothing happens for processes that do not select it. }
  NotificationTerminalResized = 2;

  { Reasons of an end request (TAbiNotification.Reason). }
  { Someone asked (kill, the default). }
  EndReasonAsked = 1;
  { The service manager stops the service the process belongs to. }
  EndReasonServiceStop = 2;
  { The system is shutting down. }
  EndReasonShutdown = 3;
  { The user logs off: the process's session ends. }
  EndReasonLogOff = 4;
  { The process's controlling terminal hung up. }
  EndReasonHangUp = 5;
  { Ctrl-C on the process's controlling terminal (the foreground group). }
  EndReasonInterrupt = 6;
  HighestEndReason = 6;

  { Bits of CallSelectNotifications: an end request for each reason
    (1 shl the reason), and the terminal's size. }
  NotifyEndAsked = $0002;
  NotifyEndServiceStop = $0004;
  NotifyEndShutdown = $0008;
  NotifyEndLogOff = $0010;
  NotifyEndHangUp = $0020;
  NotifyEndInterrupt = $0040;
  { The requests that come from people and the system rather than from
    a terminal: what a program with windows takes. }
  NotifyEndRequests = NotifyEndAsked or NotifyEndServiceStop or NotifyEndShutdown or NotifyEndLogOff;
  NotifyTerminalResized = $10000;
  NotifyEverything = NotifyEndRequests or NotifyEndHangUp or NotifyEndInterrupt or NotifyTerminalResized;

  { Targets of CallRequestEnd. }
  EndTargetProcess = 0;
  EndTargetGroup = 1;
  EndTargetSession = 2;

  { The status of a process ended because it did not take an end
    request: 128 plus the Unix signal's number (TERM, HUP, INT). }
  EndStatusRequested = 143;
  EndStatusHangUp = 129;
  EndStatusInterrupted = 130;

  { --- Watching files and folders for changes ------------------------------ }

  { (PathAddress, Flags): a watch on the folder or file at Path: a handle
    that is ready (CallWaitForHandles) while change records wait in it.
    Flags choose what is reported (WatchNames, WatchContents,
    WatchAttributes; at least one) and WatchSubtree, which also reports
    changes in every folder below a watched folder. Records about the
    watched item itself (removed, moved, its volume gone) and the
    overflow record always come. Watching needs read permission on the
    item. "/volumes" is the list of volumes: a watch on it reports a
    volume arriving (WatchChangeCreated) and going away
    (WatchChangeRemoved). ErrorNotFound, ErrorAccessDenied,
    ErrorUnsupported (/dev). }
  CallCreateWatch = 94;
  { (Handle, BufferAddress, Capacity): moves the oldest change records
    that fit into the buffer, one TAbiWatchRecord after another, and
    returns how many bytes they take. Never waits: ErrorWouldBlock if
    there is none; ErrorMessageTooLong if the first does not fit. }
  CallReadWatch = 95;

  { --- Processor time and memory: what a task manager shows ----------------- }

  { (BufferAddress, Capacity): describes the running processes, one
    TAbiProcessDetails each, as many as fit in Capacity records; returns
    how many processes there are (more than Capacity: call again with
    room for them). Anyone may list every process; the command line of
    another user's process is shown only to root (the others get it
    empty, with ProcessDetailsCommandLineHidden). }
  CallListProcessDetails = 96;
  { (UsageAddress): the system's processor time and memory, as a
    TAbiSystemUsage. }
  CallGetSystemUsage = 97;

  { --- The clock, the time zone and the keyboard ----------------------------
    Settings of the machine that the kernel keeps for everyone: anyone
    may read them, only root may change them (ErrorNotPermitted). The
    system settings service (userland/systemsettings) gives the kernel
    the remembered ones at start. }

  { (UnixTime): sets the wall clock to UnixTime (seconds since
    1970-01-01 00:00:00 UTC) and writes it to the battery backed clock,
    which holds UTC. Root only. }
  CallSetWallClock = 98;
  { (BufferAddress, Capacity): copies the name of the system's time zone
    (TimeZoneNameCapacity at most, with its #0; "UTC" until one is set):
    the zone local times are shown in, by the time zone database of
    libsystem (Sys.TimeZones). Returns the name's length. }
  CallGetTimeZone = 99;
  { (NameAddress): the system's time zone from now on. The kernel does
    not know the zones; it keeps the name for programs to read. Root
    only; ErrorInvalidArgument for an empty or too long name. }
  CallSetTimeZone = 100;
  { (SettingsAddress): the keyboards' layout and key repeat, as a
    TAbiKeyboardSettings. }
  CallGetKeyboardSettings = 101;
  { (SettingsAddress): a new layout and key repeat for every keyboard
    (the console's and the display server's input alike). Root only;
    ErrorNotFound for a layout the kernel does not have, the repeat
    kept within its range. }
  CallSetKeyboardSettings = 102;
  { (Index, LayoutAddress): the layout numbered Index (from 0) as a
    TAbiKeyboardLayout; ErrorNotFound after the last. }
  CallDescribeKeyboardLayout = 103;

  { 104-124: networking (sockets, interfaces, routes, statistics), in
    Abi.Networking.inc. }

  { (NameAddress): the machine's node name (its host name, which
    CallGetSystemInformation reports) from now on: 1 to 63 letters,
    digits, hyphens and dots, starting with a letter or digit. Root
    only; ErrorInvalidArgument for another name. }
  CallSetNodeName = 124;

  { 125: CallWatchNetworkChanges, 126: CallGetNetworkStatistics and 127:
    CallListNeighbors, in Abi.Networking.inc. }

  { (DescriptionAddress): what the processor is, as a
    TAbiProcessorDescription: its maker and model as the processor tells
    them (CPUID on x86-64, MIDR_EL1 on AArch64, which user mode cannot
    read there). }
  CallGetProcessorDescription = 128;

  { (BufferAddress, Capacity): what machine this is, as its maker names
    it ("Raspberry Pi 5 Model B Rev 1.0": the device tree's model, or the
    Raspberry Pi firmware's board), into the buffer, at most Capacity - 1
    characters ended by a zero; returns the whole model's length (0 when
    it is not known, as on PCs for now). Anyone may read it. }
  CallGetMachineModel = 129;

  { --- Limits of a process ---------------------------------------------- }

  { (ProcessId, ResourcesAddress): what the process (0: the caller)
    holds against its limits, as a TAbiProcessResources: its regions
    (ranges of its address space: program and library segments, stacks,
    allocations, mappings), handles, threads and memory. Anyone may ask
    about any process; ErrorNotFound if none has that id. }
  CallGetProcessResources = 130;
  { (Limit, Value): sets one of the caller's limits (ProcessLimit*),
    which the processes it starts inherit. Lowering is always allowed
    (what is already there stays); raising above the default needs root
    (ErrorNotPermitted). ErrorInvalidArgument above the limit's ceiling
    or for an unknown limit. Returns the previous value. }
  CallSetProcessLimit = 131;

  { --- Crash reports ---------------------------------------------------- }

  { (BufferAddress, Capacity): the caller's loaded modules - the program
    and its libraries, in load order - as up to Capacity
    TAbiModuleInformation records; returns how many there are (which may
    be more than Capacity). The runtime's crash reports name them, so the
    addresses in a report can be symbolized wherever the modules were
    loaded (scripts/symbolize.py). }
  CallGetProcessModules = 136;

  { --- Thread names and libraries loaded at run time (148-151) ------------ }

  { (ThreadId or CurrentThreadHandle, NameAddress): names a thread of the
    calling process (by its id, as CallGetThreadId gives it), as hang
    reports, the debug shell, ps and the task manager show it. At most
    ThreadNameCapacity - 1 characters are kept; an empty name gives the
    thread its process's name again. ErrorNotFound if the process has
    no thread with that id. }
  CallSetThreadName = 148;
  { (ProcessId (0: the caller), BufferAddress, Capacity): describes the
    threads of a process, one TAbiThreadDetails each, as many as fit in
    Capacity records; returns how many there are. Anyone may list any
    process's threads; ErrorNotFound if no process has that id. }
  CallListThreads = 149;
  { (ModuleHandle, AddressOfTAbiModuleTls): the thread-local storage of
    a library loaded with CallLoadLibrary after the program started (a
    module whose TLS module id carries TlsDynamicModuleTag): where its
    initialization image is and how large and aligned each thread's
    block must be. The user runtime makes a thread's block the first
    time the thread touches the library's thread-local variables.
    ErrorNotFound for a module without thread-local storage. }
  CallGetModuleTls = 150;
  { (ModuleHandle, AddressOfTAbiModuleInitializers): the initializers
    (DT_INIT, then DT_INIT_ARRAY, dependencies first) and finalizers
    (DT_FINI_ARRAY backwards, then DT_FINI, in the reverse order) of the
    libraries that CallLoadLibrary loaded for ModuleHandle, given once:
    they are copied into the record's arrays and forgotten, so a second
    call gets none. The user runtime calls the initializers before
    LoadLibrary returns and the finalizers when the program exits.
    ErrorMessageTooLong (with the counts filled in, nothing given) if an
    array is too small. }
  CallTakeModuleInitializers = 151;

  CallCount = 152;

  AbiModuleNameCapacity = 64;

  TimeWallClock = 0;
  TimeUptimeMilliseconds = 1;
  TimeUptimeNanoseconds = 2;

  TimeZoneNameCapacity = 48;
  KeyboardLayoutNameCapacity = 16;
  KeyboardLayoutDescriptionCapacity = 48;
  { The key repeat: the delay before a held key repeats, and the rate it
    then repeats at (what PS/2 keyboards can do). }
  MinimumKeyRepeatDelay = 250;
  MaximumKeyRepeatDelay = 1000;
  MinimumKeyRepeatRate = 2;
  MaximumKeyRepeatRate = 30;

  { How long a shutdown waits for the process watching it. }
  ShutdownCoordinatorSeconds = 30;

  EventManualReset = $01;
  EventSignaled = $02;
  TimerManualReset = $01;
  MaximumWaitHandles = 64;
  { CallWaitForHandles: every handle at once. }
  WaitForAll = $01;
  MaximumPortNameLength = 24;
  MaximumMessageBytes = 16 * 1024;
  MaximumMessageHandles = 8;
  MaximumQueuedMessages = 64;

  ShutdownPowerOff = 0;
  ShutdownReboot = 1;
  ShutdownHalt = 2;

  { Exit status of a process ended by an exception nobody dispatched. }
  ExitStatusException = 139;

  { TAbiExceptionRecord.Code }
  ExceptionAccessViolation = 1;
  ExceptionIntegerDivide = 2;
  ExceptionIntegerOverflow = 3;
  ExceptionBoundRange = 4;
  ExceptionIllegalInstruction = 5;
  ExceptionBreakpoint = 6;
  ExceptionFloatingPoint = 7;
  ExceptionSimdFloatingPoint = 8;
  ExceptionAlignment = 9;
  ExceptionPrivilegedOperation = 10;
  { The stack ran into its reserve; the reserve now holds the record and
    is armed again once the stack is well clear of it. }
  ExceptionStackOverflow = 11;
  { TAbiExceptionRecord.Access for access violations }
  AccessKindRead = 0;
  AccessKindWrite = 1;
  AccessKindExecute = 8;

  { CallWaitForProcessChange: the process stopped instead of exiting. }
  WaitStatusStopped = 256;

  { "Leave unchanged" for CallSetUserIds and CallSetGroupIds. }
  IdUnchanged = -1;
  { Nice values: -20 (most favoured) .. 19 (least). }
  NiceLowest = -20;
  NiceHighest = 19;
  MaximumSupplementaryGroups = 32;
  { Process states in TAbiProcessInformation and TAbiProcessDetails:
    running (a thread runs or is ready to), waiting for something,
    ending, stopped (job control). }
  ProcessStateRunning = 0;
  ProcessStateSleeping = 1;
  ProcessStateExiting = 2;
  ProcessStateStopped = 3;
  { TAbiProcessDetails.Flags: its command line is another user's, kept
    from the caller; Ctrl-C does not end it (an interactive shell). }
  ProcessDetailsCommandLineHidden = $01;
  ProcessDetailsIgnoresInterrupt = $02;

  { --- Arguments ------------------------------------------------------- }

  { Timeout of CallWaitForProcess meaning "wait as long as it takes". }
  InfiniteWait = -1;

  { Handle of the thread calls meaning "the calling thread". }
  CurrentThreadHandle = -1;
  ThreadPriorityOffsetLowest = -15;
  ThreadPriorityOffsetHighest = 15;
  ThreadPriorityOffsetBias = 15;
  { Stack size CallCreateThread uses when given 0, and its limit. }
  DefaultThreadStackSize = 1024 * 1024;
  MaximumThreadStackSize = 64 * 1024 * 1024;

{$ifdef CPUAARCH64}
  { The thread control block the thread pointer (TPIDR_EL0) of every
    user thread points at (AArch64 TLS variant I: the control block is
    the ABI's 16 bytes, and static thread-local storage follows it). The
    kernel fills in the thread id; the runtime word belongs to the user
    runtime (libsystem keeps the thread's threadvar block there). }
  ThreadBlockRuntimeOffset = 0;
  ThreadBlockIdOffset = 8;
  ThreadBlockSize = 16;
  { A word below the control block, zero when a thread starts, for the
    user runtime: libsystem keeps the thread's dynamic thread-local
    storage vector there (Sys.DynamicTls in rtl/fpc). }
  ThreadBlockDynamicVectorOffset = -8;
{$else}
  { The thread control block the thread pointer (%fs base) of every user
    thread points at (x86-64 TLS variant II: static thread-local storage
    lies just below it). The kernel fills in the self pointer and the
    thread id; the runtime word belongs to the user runtime (libsystem
    keeps the thread's threadvar block there). }
  ThreadBlockSelfOffset = 0;
  ThreadBlockRuntimeOffset = 8;
  ThreadBlockIdOffset = 16;
  { A word for the user runtime, zero when a thread starts: libsystem
    keeps the thread's dynamic thread-local storage vector there. }
  ThreadBlockDynamicVectorOffset = 24;
  ThreadBlockSize = 64;
{$endif}

  { Auxiliary vector entries the kernel adds to the initial stack for
    the user runtime: the initializers (DT_INIT, DT_INIT_ARRAY) and
    finalizers (DT_FINI_ARRAY, DT_FINI) of the program and its libraries,
    as arrays of code addresses in the order they must be called. }
  AuxiliaryInitializers = $1000;
  AuxiliaryInitializerCount = $1001;
  AuxiliaryFinalizers = $1002;
  AuxiliaryFinalizerCount = $1003;

  { Fields of TAbiAttributeChanges that apply. }
  ChangeFieldMode = $01;
  ChangeFieldOwner = $02;
  ChangeFieldGroup = $04;
  ChangeFieldModificationTime = $08;
  ChangeFieldAccessTime = $10;
  { The given times are "now": the kernel fills them in, and someone with
    write permission may do this to a file they do not own. }
  ChangeFieldTimesAreNow = $20;

  { Requests of CallControlHandle (on a console handle). }
  ControlGetConsoleMode = 1;
  ControlSetConsoleMode = 2;
  { Returns rows shl 16 or columns. }
  ControlGetConsoleSize = 3;
  { The process group that Ctrl-C ends. }
  ControlSetForegroundGroup = 4;
  ControlGetForegroundGroup = 5;
  { Sets the size (rows shl 16 or columns): what the terminal's window
    shows. Programs are not told; they ask with ControlGetConsoleSize
    when they lay something out. }
  ControlSetConsoleSize = 6;
  { N for the pseudo-terminal /dev/ptsN (either side); ErrorUnsupported
    for the console. }
  ControlGetTerminalNumber = 7;
  { Returns 1 (and forgets it) if Ctrl-C was passed to the reader since
    the last call, else 0. }
  ControlTakePendingInterrupt = 10;
  { Requests of CallControlHandle on an audio output (/dev/audio). Each
    open of the device is a stream of its own, mixed with the others. A
    format is the sample rate shl 16 or the channels shl 8 or the sample
    kind (AudioSample*): rates 8000 to 192000, 1 to 8 channels (in the
    WAVE order: front left, front right, centre, LFE, back left, back
    right, side left, side right). }
  ControlAudioGetFormat = 100;
  ControlAudioSetFormat = 101;
  { The stream's volume in percent (0-100). }
  ControlAudioGetVolume = 102;
  ControlAudioSetVolume = 103;
  { Waits until everything written to the stream has been played. }
  ControlAudioDrain = 104;
  { The output's volume (for every stream), percent. }
  ControlAudioGetMasterVolume = 105;
  ControlAudioSetMasterVolume = 106;
  { Bytes written to the stream and not yet mixed. }
  ControlAudioGetQueued = 107;
  { Frames of the stream mixed so far. }
  ControlAudioGetPosition = 108;
  { Audio inputs: frames dropped because the reader fell behind. }
  ControlAudioGetDropped = 109;
  { The output is muted (1) or not (0): it plays silence, its volume
    kept for when it is unmuted. }
  ControlAudioGetMute = 110;
  ControlAudioSetMute = 111;
  { The default output's number (0 for /dev/audio, 1 for /dev/audio1...):
    where programs play when they name no output (libaudio's
    OpenAudioOutput). Asked of, or set on, any output. }
  ControlAudioGetDefaultOutput = 112;
  ControlAudioSetDefaultOutput = 113;
  { What the output is: AudioOutputKind*. }
  ControlAudioGetKind = 114;

  AudioOutputKindHdAudio = 1;
  AudioOutputKindAc97 = 2;
  AudioOutputKindUsb = 3;
  AudioOutputKindHdmi = 4;

  { The displays (/dev/display, then /dev/display1, /dev/display2...: the
    first is the one the firmware showed the boot on). Opening one takes
    it for the program (the first from the text console, which gets it
    back on closing); its framebuffer is mapped with CallMapHandle at
    offset 0 (pitch times height bytes). }
  { Width or (height shl 32), in pixels. }
  ControlDisplayGetSize = 200;
  { Bytes from one line of the framebuffer to the next. }
  ControlDisplayGetPitch = 201;
  { DisplayFormat*: how a pixel's four bytes hold its colour. }
  ControlDisplayGetFormat = 202;
  { Dots per inch (from the display's EDID, the dpi kernel option, else
    96), and the scale it gives in percent: 100, 125, 150, 175, 200... }
  ControlDisplayGetDpi = 203;
  ControlDisplayGetScale = 204;
  { Width or (height shl 32) in millimetres; 0 if not known. }
  ControlDisplayGetPhysicalSize = 205;
  { The modes the display can be set to: how many, and the one the
    argument numbers (from 0, largest last) as width or (height shl 32)
    in pixels. Every mode has 4 bytes a pixel. }
  ControlDisplayGetModeCount = 206;
  ControlDisplayGetMode = 207;
  { Sets the mode the argument gives (width or (height shl 32)), one of
    the list. The size, pitch, DPI and scale follow; the framebuffer must
    be mapped again. Closing the display gives back the mode it had when
    it was opened. ErrorUnsupported if the display's mode cannot be
    changed (a firmware framebuffer without a driver). }
  ControlDisplaySetMode = 208;
  { DisplayCapability*: what the display does beyond a plain framebuffer. }
  ControlDisplayGetCapabilities = 209;
  { The rectangle the argument gives (X or (Y shl 16) or (Width shl 32)
    or (Height shl 48), pixels of the mode) was drawn in the framebuffer:
    a display with DisplayCapabilityNeedsFlush shows it only now (its
    framebuffer is memory the device copies from). Nothing to do, and
    ErrorNone, on any other display. }
  ControlDisplayFlush = 210;
  { Displays with DisplayCapabilityHardwareCursor: the pointer drawn by
    the device over the picture, moved without drawing anything. Its
    image is DisplayCursorSize x DisplayCursorSize pixels ($AARRGGBB,
    straight alpha, lines from the top, no gap between them), written
    into the cursor area, mapped with CallMapHandle at
    DisplayCursorImageOffset (DisplayCursorImageBytes long); this request
    makes the device take it, the argument the hotspot (X or (Y shl
    16)). }
  ControlDisplaySetCursorImage = 211;
  { Where the hotspot is (pixels of the mode, X or (Y shl 32), each a
    signed 32-bit number: the image may hang off the edge). }
  ControlDisplayMoveCursor = 212;
  { Shows the cursor (argument 1) or hides it (0); it starts hidden, and
    closing the display hides it. }
  ControlDisplayShowCursor = 213;
  { Where the cursor is and whether it shows: X or (Y shl 16) (each
    clamped to 0..65535) or (1 shl 32 when shown), and the moves the
    device was told of since the display was opened from bit 33 up. }
  ControlDisplayGetCursorState = 214;
  { Requests of CallControlHandle on a file or directory handle: an
    advisory lock on the whole file, as flock does it. The lock belongs
    to the open file (shared by handles duplicated from it, passed to
    children or sent in messages) and lasts until ControlUnlockFile or
    until the open file's last handle is closed (a program that ends
    gives its locks up). Locks only hold back other lock requests, not
    reads or writes. The argument is FileLockShared or FileLockExclusive,
    with FileLockNoWait to fail with ErrorWouldBlock instead of waiting.
    Any number of shared locks or one exclusive lock may be held; asking
    again with the other kind first gives up the one held. A shared lock
    needs read permission on the file, an exclusive one write permission
    (so readers cannot hold up writers); ErrorAccessDenied otherwise.
    ErrorInterrupted if the wait is interrupted (Ctrl-C, the program
    being ended). }
  ControlLockFile = 300;
  ControlUnlockFile = 301;
  FileLockShared = 1;
  FileLockExclusive = 2;
  FileLockNoWait = $100;
  { Blue, green, red, unused (a little-endian LongWord $00RRGGBB). }
  DisplayFormatBlueGreenRed = 1;
  { Red, green, blue, unused ($00BBGGRR). }
  DisplayFormatRedGreenBlue = 2;
  { The DPI that is scale 100%. }
  DisplayBaseDpi = 96;
  { Capabilities of a display (ControlDisplayGetCapabilities). }
  { What is drawn in the framebuffer shows only after ControlDisplayFlush
    names it (virtio-gpu). }
  DisplayCapabilityNeedsFlush = $01;
  { A cursor the device draws (ControlDisplaySetCursorImage...). }
  DisplayCapabilityHardwareCursor = $02;
  { The framebuffer is ordinary memory (cheap to read), not video
    memory. }
  DisplayCapabilityMemoryFramebuffer = $04;
  DisplayCursorSize = 64;
  DisplayCursorImageBytes = DisplayCursorSize * DisplayCursorSize * 4;
  { Far past any framebuffer: the cursor's area, not the picture's. }
  DisplayCursorImageOffset = QWord($10000000000);
  AudioSampleUnsigned8 = 1;
  AudioSampleSigned16 = 2;
  AudioSampleSigned24 = 3;
  AudioSampleSigned32 = 4;
  AudioSampleFloat32 = 5;
  ConsoleModeEcho = $01;
  ConsoleModeLineEditing = $02;
  { Ctrl-C ends the foreground process group instead of being read. }
  ConsoleModeInterruptKey = $04;

  { GroupId of TAbiProcessCreation. }
  GroupInherit = 0;
  GroupNew = -1;
  { A new group led by the new process, which is the foreground group of
    its controlling terminal from the start (so it never reads it from
    the background, as it could if the group were handed over after it
    started): if its standard input is a terminal, that terminal becomes
    its controlling terminal (and its children's: a terminal window's
    shell); otherwise it keeps the caller's. The controlling terminal is
    the one /dev/tty opens, whose hang-up ends the process, and whose
    foreground group decides whether reading it stops the process. }
  GroupNewInForeground = -2;

  { Flags of CallAllocateMemory. }
  { The memory belongs to the calling thread (a threadvar block, a
    dynamic thread-local storage block): if the thread ends without
    freeing it (ended by another thread, say), the kernel frees it. }
  AllocateForThread = $01;

  { The TLS module id (R_*_DTPMOD64) of a library loaded after the
    program started is this tag plus its module handle, and a TLS
    descriptor's argument (R_AARCH64_TLSDESC) the tag plus the handle
    shifted left by TlsDynamicHandleShift plus the variable's offset:
    such libraries' blocks are made per thread when first touched
    (CallGetModuleTls). The other ids are offsets from the thread
    pointer (static TLS), which never carry the tag. }
  TlsDynamicModuleTag = QWord($4000000000000000);
  TlsDynamicHandleShift = 32;
  TlsDynamicHandleMask = QWord($FFFFFF);

  { The longest thread name, with its zero (CallSetThreadName). }
  ThreadNameCapacity = 32;

  { States of TAbiThreadDetails. }
  ThreadDetailsRunning = 0;
  ThreadDetailsReady = 1;
  ThreadDetailsWaiting = 2;
  ThreadDetailsSuspended = 3;
  ThreadDetailsExiting = 4;

  { CallSetProcessLimit: the most regions and the most handles a process
    may have, by default and at most. }
  ProcessLimitRegions = 1;
  ProcessLimitHandles = 2;
  DefaultProcessRegionLimit = 65536;
  ProcessRegionLimitCeiling = 1048576;
  DefaultProcessHandleLimit = 16384;
  ProcessHandleLimitCeiling = 65536;

  { Flags of TAbiProcessCreation. }
  { The new process leads a new session: it and the processes it starts
    (unless they start sessions of their own) can be ended together with
    CallTerminateSession (a service and its helpers, a user's logon).
    Without it a process belongs to its parent's session. }
  ProcessNewSession = $01;
  { The record goes on with PassedHandles and PassedHandleCount: the
    new process gets those handles of the caller too, with the same
    numbers (after the three standard ones, which a passed handle with
    the number 0, 1 or 2 replaces). ErrorBadHandle if one is not open,
    ErrorInvalidArgument for a thread handle (those belong to the
    caller) or more than the handle limit. }
  ProcessPassHandles = $02;

  { Flags of CallCreateWatch: what to report. }
  { Names created, removed and renamed (files, folders, links). }
  WatchNames = $01;
  { A file's contents or size changed. }
  WatchContents = $02;
  { Permissions, owner, group or times changed. }
  WatchAttributes = $04;
  { Changes in every folder below the watched one too; their names are
    paths relative to the watched folder ("sub/file"). }
  WatchSubtree = $08;

  { TAbiWatchRecord.Kind. Names are relative to the watched folder; a
    record about the watched item itself has an empty name. }
  WatchChangeCreated = 1;
  WatchChangeRemoved = 2;
  { Name is the new name, OldName the old one (both inside the watched
    folder; moving out of it is reported as removed, into it as
    created). }
  WatchChangeRenamed = 3;
  WatchChangeWritten = 4;
  WatchChangeAttributes = 5;
  { The watched item was removed: the watch reports nothing more. }
  WatchChangeWatchedItemRemoved = 6;
  { The watched item was renamed or moved (Name: its new name); the
    watch follows it. }
  WatchChangeWatchedItemMoved = 7;
  { The watched item's volume went away (unplugged): nothing more
    comes. }
  WatchChangeVolumeGone = 8;
  { Records were lost because nobody read them: look at the folder
    again. }
  WatchChangeOverflow = 9;

  { TAbiWatchRecord.Flags: the item is a folder. }
  WatchRecordDirectory = $01;
  { At most this many records wait in a watch; then comes the overflow
    record. }
  MaximumQueuedWatchRecords = 64;

  { --- Error codes (returned negated) ---------------------------------- }

  ErrorNone = 0;
  ErrorInterrupted = 4;
  ErrorTimedOut = 110;
  ErrorNoSuchProcess = 3;
  ErrorNotPermitted = 1;
  ErrorAccessDenied = 13;
  ErrorNotFound = 2;
  ErrorIo = 5;
  ErrorBadHandle = 9;
  ErrorNoChildProcess = 10;
  ErrorOutOfMemory = 12;
  ErrorBadAddress = 14;
  ErrorBusy = 16;
  ErrorExists = 17;
  ErrorCrossVolume = 18;
  ErrorNotDirectory = 20;
  ErrorIsDirectory = 21;
  ErrorInvalidArgument = 22;
  ErrorTooManyHandles = 24;
  ErrorNoSpace = 28;
  ErrorIllegalSeek = 29;
  ErrorReadOnly = 30;
  ErrorBrokenPipe = 32;
  ErrorNameTooLong = 36;
  ErrorNotImplemented = 38;
  ErrorDirectoryNotEmpty = 39;
  ErrorTooManyLinks = 40;
  ErrorBadExecutable = 8;
  ErrorCorrupted = 117;
  ErrorUnsupported = 95;
  { Nothing to take now (an empty channel, no pending connection), or no
    room (a full channel). }
  ErrorWouldBlock = 11;
  { A message larger than the buffer given for it. }
  ErrorMessageTooLong = 90;
  { The volume (or the device) went away: a USB disk was unplugged. }
  ErrorNoDevice = 19;
  { Networking (the numbers Linux gives them). }
  ErrorDestinationRequired = 89;
  ErrorProtocolNotSupported = 93;
  ErrorAddressFamilyNotSupported = 97;
  ErrorAddressInUse = 98;
  ErrorAddressNotAvailable = 99;
  ErrorNetworkUnreachable = 101;
  ErrorConnectionAborted = 103;
  ErrorConnectionReset = 104;
  ErrorAlreadyConnected = 106;
  ErrorNotConnected = 107;
  ErrorConnectionRefused = 111;
  ErrorHostUnreachable = 113;
  ErrorAlreadyInProgress = 114;
  ErrorInProgress = 115;

  { --- Standard handles ------------------------------------------------ }

  StandardInputHandle = 0;
  StandardOutputHandle = 1;
  StandardErrorHandle = 2;
  NoHandle = -1;

  { --- Open flags ------------------------------------------------------ }

  OpenRead = $01;
  OpenWrite = $02;
  OpenCreate = $04;
  OpenExclusive = $08;
  OpenTruncate = $10;
  OpenAppend = $20;

  { --- Seek origins ---------------------------------------------------- }

  SeekFromStart = 0;
  SeekFromCurrent = 1;
  SeekFromEnd = 2;

  { --- Node kinds ------------------------------------------------------ }

  KindFile = 0;
  KindDirectory = 1;
  KindSymbolicLink = 2;
  KindOther = 3;
  KindFifo = 4;
  KindCharacterDevice = 5;
  KindBlockDevice = 6;

  { --- Handle kinds ---------------------------------------------------- }

  HandleKindFile = 1;
  HandleKindConsole = 2;
  HandleKindPipe = 3;
  HandleKindProcess = 4;
  HandleKindNullDevice = 5;
  HandleKindThread = 6;
  { Any other device under /dev (and the /dev directory). }
  HandleKindDevice = 7;
  HandleKindEvent = 8;
  HandleKindTimer = 9;
  HandleKindSection = 10;
  HandleKindPort = 11;
  HandleKindChannel = 12;
  HandleKindWatch = 13;
  { A network socket (Abi.Networking.inc). }
  HandleKindSocket = 14;

  AbiNameCapacity = 256;
  AbiTextCapacity = 64;
  AbiTerminalNameCapacity = 16;
  AbiCommandLineCapacity = 256;
  AbiMaximumProcessors = 32;
  MaximumArguments = 256;

type
  TAbiFileInformation = record
    Kind: LongWord;
    Mode: LongWord;
    SizeInBytes: QWord;
    NodeNumber: QWord;
    LinkCount: LongWord;
    OwnerId: LongWord;
    GroupId: LongWord;
    { The volume it is on: a number given to each volume as it is
      mounted and never to another until the system starts again, so
      two paths are on one volume (a rename can move between them)
      exactly when their numbers are equal. 0 for /volumes itself and
      for devices. }
    VolumeNumber: LongWord;
    ModificationTime: Int64;
    AccessTime: Int64;
    ChangeTime: Int64;
    { Space taken on the volume. }
    AllocatedBytes: QWord;
  end;
  PAbiFileInformation = ^TAbiFileInformation;

  TAbiCredentials = record
    RealUserId: LongWord;
    EffectiveUserId: LongWord;
    SavedUserId: LongWord;
    RealGroupId: LongWord;
    EffectiveGroupId: LongWord;
    SavedGroupId: LongWord;
    Umask: LongWord;
    Nice: LongInt;
    GroupCount: LongWord;
    Reserved: LongWord;
    Groups: array[0..MaximumSupplementaryGroups - 1] of LongWord;
  end;
  PAbiCredentials = ^TAbiCredentials;

  { One process, as CallListProcessDetails describes it. Times are in
    nanoseconds of processor time; memory in bytes. }
  TAbiProcessDetails = record
    ProcessId: QWord;
    ParentProcessId: QWord;
    GroupId: QWord;
    SessionId: QWord;
    RealUserId: LongWord;
    EffectiveUserId: LongWord;
    { ProcessState*. }
    State: LongWord;
    ThreadCount: LongWord;
    HandleCount: LongWord;
    Nice: LongInt;
    { The thread priority its nice value gives (1 .. 31; 8 for nice 0). }
    Priority: LongWord;
    { ProcessDetails*. }
    Flags: LongWord;
    { Seconds since 1970, and milliseconds since the system started, at
      the same moment: when it started. }
    StartTime: Int64;
    StartUptimeMilliseconds: QWord;
    { The processor time of all its threads, those that ended included,
      and how it divides between user mode and the kernel (sampled by
      the clock: the two add up to the total). }
    ProcessorNanoseconds: QWord;
    UserNanoseconds: QWord;
    KernelNanoseconds: QWord;
    { The size of what it may touch (its regions), the memory it has
      (resident), the part of that shared with other processes
      (program and library pages, sections) and its own (private), and
      the most it ever had. }
    VirtualBytes: QWord;
    ResidentBytes: QWord;
    SharedBytes: QWord;
    PrivateBytes: QWord;
    PeakResidentBytes: QWord;
    Name: array[0..AbiTextCapacity - 1] of Char;
    { Its controlling terminal ("console", "pts2"), empty if none. }
    Terminal: array[0..AbiTerminalNameCapacity - 1] of Char;
    { The arguments it was started with, joined by spaces. }
    CommandLine: array[0..AbiCommandLineCapacity - 1] of Char;
  end;
  PAbiProcessDetails = ^TAbiProcessDetails;

  TAbiProcessorUsage = record
    { How long it has run threads, and its idle thread, since it
      started, in nanoseconds. }
    BusyNanoseconds: QWord;
    IdleNanoseconds: QWord;
    { 1 if it runs. }
    Online: LongWord;
    Reserved: LongWord;
  end;

  { What CallGetSystemUsage gives. Memory in bytes. }
  TAbiSystemUsage = record
    UptimeNanoseconds: QWord;
    { Processors started; Processors[0 .. ProcessorCount - 1] hold
      their times. }
    ProcessorCount: LongWord;
    ProcessCount: LongWord;
    { Every thread, the kernel's included. }
    ThreadCount: LongWord;
    Reserved: LongWord;
    ContextSwitches: QWord;
    { The RAM the system has, and what is free. }
    TotalMemory: QWord;
    FreeMemory: QWord;
    { What the rest is used for: processes' own memory, program and
      library files, memory shared between processes, disk blocks kept
      in memory, the kernel's heap, its threads' stacks, page tables,
      the kernel itself (its image, the loader's data, the page
      database) and drivers' buffers. }
    UserMemory: QWord;
    ProgramImageMemory: QWord;
    SectionMemory: QWord;
    BlockCacheMemory: QWord;
    KernelHeapMemory: QWord;
    KernelStackMemory: QWord;
    PageTableMemory: QWord;
    KernelImageMemory: QWord;
    DriverMemory: QWord;
    Processors: array[0..AbiMaximumProcessors - 1] of TAbiProcessorUsage;
  end;
  PAbiSystemUsage = ^TAbiSystemUsage;

  TAbiProcessInformation = record
    ProcessId: QWord;
    ParentProcessId: QWord;
    GroupId: QWord;
    { The session it belongs to: the id of the process that leads it. }
    SessionId: QWord;
    RealUserId: LongWord;
    EffectiveUserId: LongWord;
    State: LongWord;
    ThreadCount: LongWord;
    Nice: LongInt;
    Reserved: LongWord;
    { Committed user memory, in pages. }
    MemoryPages: QWord;
    CpuMilliseconds: QWord;
    { Seconds since 1970. }
    StartTime: Int64;
    Name: array[0..AbiTextCapacity - 1] of Char;
  end;
  PAbiProcessInformation = ^TAbiProcessInformation;

  { Arguments of CallSetPathAttributes, passed by address. }
  TAbiAttributeChanges = record
    Fields: LongWord;
    Mode: LongWord;
    OwnerId: LongWord;
    GroupId: LongWord;
    ModificationTime: Int64;
    AccessTime: Int64;
  end;
  PAbiAttributeChanges = ^TAbiAttributeChanges;

  TAbiDirectoryEntry = record
    Kind: LongWord;
    Reserved: LongWord;
    NodeNumber: QWord;
    Name: array[0..AbiNameCapacity - 1] of Char;
  end;
  PAbiDirectoryEntry = ^TAbiDirectoryEntry;

  TAbiProcessorDescription = record
    { "GenuineIntel", "AuthenticAMD", "ARM", "Broadcom", ... }
    Vendor: array[0..AbiTextCapacity - 1] of Char;
    { "AMD Ryzen 7 5800X 8-Core Processor", "Cortex-A72", ...; empty if
      the processor does not tell it. }
    Model: array[0..AbiTextCapacity - 1] of Char;
    { The processor's own identification: CPUID leaf 1 EAX (family,
      model, stepping) on x86-64, MIDR_EL1 on AArch64. }
    Identification: QWord;
  end;
  PAbiProcessorDescription = ^TAbiProcessorDescription;

  TAbiModuleInformation = record
    { The load bias: a symbol's address in the process is Base plus its
      value in the module's file (for a position independent module,
      where its first page was put). }
    Base: QWord;
    { The end of the module's mapped pages: an address belongs to the
      module if it lies from Base up to Limit. }
    Limit: QWord;
    { The file's name ("files", "libsystem.so"). }
    Name: array[0..AbiModuleNameCapacity - 1] of Char;
  end;
  PAbiModuleInformation = ^TAbiModuleInformation;

  TAbiSystemInformation = record
    SystemName: array[0..AbiTextCapacity - 1] of Char;
    Release: array[0..AbiTextCapacity - 1] of Char;
    Version: array[0..AbiTextCapacity - 1] of Char;
    Machine: array[0..AbiTextCapacity - 1] of Char;
    NodeName: array[0..AbiTextCapacity - 1] of Char;
    TotalMemory: QWord;
    FreeMemory: QWord;
    UptimeMilliseconds: QWord;
    ProcessorCount: LongWord;
    Reserved: LongWord;
    { Average number of runnable threads over 1, 5 and 15 minutes, in
      hundredths. }
    LoadAverages: array[0..2] of LongWord;
    RunnableThreads: LongWord;
  end;
  PAbiSystemInformation = ^TAbiSystemInformation;

  TAbiVolumeInformation = record
    Name: array[0..AbiTextCapacity - 1] of Char;
    FileSystemType: array[0..AbiTextCapacity - 1] of Char;
    VolumeLabel: array[0..AbiTextCapacity - 1] of Char;
    TotalBytes: QWord;
    { Valid when HasFreeSpace is not zero. }
    FreeBytes: QWord;
    IsReadOnly: LongWord;
    IsSystemVolume: LongWord;
    HasFreeSpace: LongWord;
    { On a disk that can be unplugged (a USB disk). }
    IsRemovable: LongWord;
  end;
  PAbiVolumeInformation = ^TAbiVolumeInformation;

  { One change record of a watch (CallReadWatch). The name follows the
    record, then (renames) the old name, each ended by a zero. }
  TAbiWatchRecord = record
    { Bytes from the start of this record to the next one (a multiple
      of 8). }
    Size: LongWord;
    { WatchChange*. }
    Kind: Word;
    { WatchRecord*. }
    Flags: Word;
    { Bytes of the name and of the old name, without their zeros. }
    NameLength: LongWord;
    OldNameLength: LongWord;
  end;
  PAbiWatchRecord = ^TAbiWatchRecord;

  { A user to start a program as (TAbiProcessCreation.Identity). }
  TAbiProcessIdentity = record
    UserId: LongWord;
    GroupId: LongWord;
    GroupCount: LongWord;
    Reserved: LongWord;
    Groups: array[0..MaximumSupplementaryGroups - 1] of LongWord;
  end;
  PAbiProcessIdentity = ^TAbiProcessIdentity;

  { Arguments of CallCreateProcess, passed by address. }
  TAbiProcessCreation = record
    Path: PChar;
    Arguments: PPChar;          { nil terminated }
    Environment: PPChar;        { nil terminated }
    WorkingDirectory: PChar;    { nil = inherit }
    InputHandle: Int64;         { handles of the caller to pass on }
    OutputHandle: Int64;
    ErrorHandle: Int64;
    { GroupInherit, GroupNew (a group led by the new process) or the id
      of an existing group to join. }
    GroupId: Int64;
    { nil: the caller's user and groups. Otherwise who the new process
      runs as (its real, effective and saved ids and its supplementary
      groups); root only (ErrorNotPermitted), for starting a user's
      programs (login, the session manager, services). }
    Identity: ^TAbiProcessIdentity;
    { ProcessNewSession, ProcessPassHandles, or 0. }
    Flags: QWord;
    { Read only with ProcessPassHandles (older programs end the record
      above): the address of PassedHandleCount Int64 handles. }
    PassedHandles: ^Int64;
    PassedHandleCount: QWord;
  end;
  PAbiProcessCreation = ^TAbiProcessCreation;

  { What CallGetProcessResources gives. }
  TAbiProcessResources = record
    RegionCount: LongWord;
    RegionLimit: LongWord;
    HandleCount: LongWord;
    HandleLimit: LongWord;
    ThreadCount: LongWord;
    Reserved: LongWord;
    { The regions' sizes (stack guards left out), in bytes; the pages
      mapped now (resident), the most there ever were, and those of them
      shared with other processes. }
    VirtualBytes: QWord;
    CommittedPages: QWord;
    PeakCommittedPages: QWord;
    SharedPages: QWord;
  end;
  PAbiProcessResources = ^TAbiProcessResources;

  { One thread, as CallListThreads describes it. }
  TAbiThreadDetails = record
    ThreadId: QWord;
    { Its processor time, in nanoseconds. }
    ProcessorNanoseconds: QWord;
    { ThreadDetails*. }
    State: LongWord;
    { Its scheduling priority now (1 .. 31). }
    Priority: LongWord;
    { The processor it last ran on. }
    LastProcessor: LongWord;
    Reserved: LongWord;
    Name: array[0..ThreadNameCapacity - 1] of Char;
  end;
  PAbiThreadDetails = ^TAbiThreadDetails;

  { What CallGetModuleTls gives: each thread's block is BlockSize bytes
    aligned to Alignment, starting as a copy of the ImageSize bytes at
    ImageAddress followed by zeros. }
  TAbiModuleTls = record
    ImageAddress: QWord;
    ImageSize: QWord;
    BlockSize: QWord;
    Alignment: QWord;
  end;
  PAbiModuleTls = ^TAbiModuleTls;

  { CallTakeModuleInitializers: arrays of code addresses the caller
    provides (address and capacity) and the kernel fills (count). }
  TAbiModuleInitializers = record
    Initializers: QWord;
    InitializerCapacity: QWord;
    InitializerCount: QWord;
    Finalizers: QWord;
    FinalizerCapacity: QWord;
    FinalizerCount: QWord;
  end;
  PAbiModuleInitializers = ^TAbiModuleInitializers;

  { Who the other end of a channel is (CallGetChannelPeer). }
  { What CallReceiveNotification gives. }
  TAbiNotification = record
    { Notification* }
    Kind: LongWord;
    { EndReason* for NotificationEndRequested; 0 otherwise. }
    Reason: LongWord;
    { The process that sent it; 0 for the system (a terminal, the
      shutdown). }
    SenderProcessId: QWord;
    { What goes with it (NotificationTerminalResized: the size). }
    Value: QWord;
  end;
  PAbiNotification = ^TAbiNotification;

  { CallGetKeyboardSettings and CallSetKeyboardSettings. }
  TAbiKeyboardSettings = record
    { us, uk, de, fr: see CallDescribeKeyboardLayout. }
    Layout: array[0..KeyboardLayoutNameCapacity - 1] of Char;
    { Milliseconds before a held key repeats (MinimumKeyRepeatDelay to
      MaximumKeyRepeatDelay). }
    RepeatDelay: LongWord;
    { Characters a second while it repeats (MinimumKeyRepeatRate to
      MaximumKeyRepeatRate). }
    RepeatRate: LongWord;
  end;
  PAbiKeyboardSettings = ^TAbiKeyboardSettings;

  { CallDescribeKeyboardLayout. }
  TAbiKeyboardLayout = record
    Name: array[0..KeyboardLayoutNameCapacity - 1] of Char;
    { In English: "German (QWERTZ)". }
    Description: array[0..KeyboardLayoutDescriptionCapacity - 1] of Char;
  end;
  PAbiKeyboardLayout = ^TAbiKeyboardLayout;

  TAbiChannelPeer = record
    ProcessId: QWord;
    { The effective ids when it connected or accepted. }
    UserId: LongWord;
    GroupId: LongWord;
  end;
  PAbiChannelPeer = ^TAbiChannelPeer;

  { What CallCreatePseudoTerminal gives. }
  TAbiPseudoTerminal = record
    { The master side: reading gives what programs wrote to the
      terminal (ready to wait on when there is some); writing types into
      the terminal (ready when there is room). }
    OutputHandle: Int64;
    InputHandle: Int64;
    { The terminal itself, read and write: a console for programs. }
    TerminalHandle: Int64;
    { The terminal is /dev/ptsN. }
    Number: Int64;
  end;
  PAbiPseudoTerminal = ^TAbiPseudoTerminal;

  { The registers of a thread when it raised an exception. }
{$ifdef CPUAARCH64}
  TAbiContext = record
    { X0-X28, the frame pointer (X29) and the link register (X30). }
    X: array[0..30] of QWord;
    Sp: QWord;
    Pc: QWord;
    { PSTATE as SPSR holds it; a context may change only the condition
      flags (N, Z, C, V: bits 31-28). }
    Pstate: QWord;
  end;
{$else}
  TAbiContext = record
    Rax, Rbx, Rcx, Rdx, Rsi, Rdi, Rbp, Rsp: QWord;
    R8, R9, R10, R11, R12, R13, R14, R15: QWord;
    Rip: QWord;
    Rflags: QWord;
  end;
{$endif}
  PAbiContext = ^TAbiContext;

  { What the exception dispatcher gets (CallSetExceptionDispatcher). }
  TAbiExceptionRecord = record
    Code: LongWord;
    { Access violations: AccessKind*. }
    Access: LongWord;
    { The instruction that raised it (for a breakpoint, the one after). }
    Address: QWord;
    { Access violations: the address that could not be accessed. }
    FaultAddress: QWord;
    Context: TAbiContext;
  end;
  PAbiExceptionRecord = ^TAbiExceptionRecord;

  { Input events (/dev/events): what keyboards and pointing devices do,
    for programs that take the input (a display server). Reads return
    whole events. }
  TAbiInputEvent = record
    { Milliseconds since the system started. }
    Time: QWord;
    { InputEvent*. }
    Kind: Word;
    { Which device (a number per keyboard or pointing device). }
    Source: Word;
    { Keys: the key code (scan code set 1, KeyCodeExtended added for the
      keys after an E0 prefix). Buttons: Button*. }
    Code: LongWord;
    { Keys and buttons: 1 pressed, 0 released. Wheels: steps, positive
      away from the user. }
    Value: LongInt;
    { Motion: how far it moved (device units, right and down positive).
      Position: where it is, 0 to InputPositionMaximum across the whole
      screen (not pixels: the screen may be any size or scale). }
    X: LongInt;
    Y: LongInt;
    { Key presses: the character typed (Unicode), 0 if none (dead keys,
      modifiers, keys that send sequences). }
    Character: LongWord;
    { Modifier* held or on when it happened. }
    Modifiers: LongWord;
    Reserved: LongWord;
  end;
  PAbiInputEvent = ^TAbiInputEvent;

  { A message on a channel (CallSendMessage, CallReceiveMessage). }
  TAbiMessage = record
    Data: QWord;
    Length: QWord;
    { The address of HandleCount Int64 handles. }
    Handles: QWord;
    HandleCount: QWord;
  end;
  PAbiMessage = ^TAbiMessage;

const
  InputEventKey = 1;
  InputEventMotion = 2;
  InputEventPosition = 3;
  InputEventButton = 4;
  InputEventWheel = 5;

  KeyCodeExtended = $100;
  ButtonLeft = 1;
  ButtonRight = 2;
  ButtonMiddle = 3;
  ButtonFourth = 4;
  ButtonFifth = 5;

  InputPositionMaximum = 65535;

  ModifierShift = $01;
  ModifierControl = $02;
  ModifierAlt = $04;
  ModifierAltGr = $08;
  ModifierCapsLock = $10;
  ModifierNumLock = $20;
  ModifierScrollLock = $40;
  { The Super (Windows logo) key, left or right. }
  ModifierSuper = $80;

{$include Abi.Networking.inc}
