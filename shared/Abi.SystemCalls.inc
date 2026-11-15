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
  CallAllocateMemory = 17;
  CallFreeMemory = 18;
  CallCreateProcess = 19;
  CallWaitForProcess = 20;
  CallGetProcessId = 21;
  CallCreatePipe = 22;
  CallDuplicateHandle = 23;
  CallSleep = 24;
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

  CallCount = 70;

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
  { Process states in TAbiProcessInformation. }
  ProcessStateRunning = 0;
  ProcessStateSleeping = 1;
  ProcessStateExiting = 2;
  ProcessStateStopped = 3;

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

  { The thread control block the thread pointer (%fs base) of every user
    thread points at (x86-64 TLS variant II: static thread-local storage
    lies just below it). The kernel fills in the self pointer and the
    thread id; the runtime word belongs to the user runtime (libsystem
    keeps the thread's threadvar block there). }
  ThreadBlockSelfOffset = 0;
  ThreadBlockRuntimeOffset = 8;
  ThreadBlockIdOffset = 16;
  ThreadBlockSize = 64;

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

  AbiNameCapacity = 256;
  AbiTextCapacity = 64;
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
    Reserved: LongWord;
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

  TAbiProcessInformation = record
    ProcessId: QWord;
    ParentProcessId: QWord;
    GroupId: QWord;
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
    Reserved: LongWord;
  end;
  PAbiVolumeInformation = ^TAbiVolumeInformation;

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
  end;
  PAbiProcessCreation = ^TAbiProcessCreation;

  { The registers of a thread when it raised an exception. }
  TAbiContext = record
    Rax, Rbx, Rcx, Rdx, Rsi, Rdi, Rbp, Rsp: QWord;
    R8, R9, R10, R11, R12, R13, R14, R15: QWord;
    Rip: QWord;
    Rflags: QWord;
  end;
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
