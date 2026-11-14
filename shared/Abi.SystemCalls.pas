{
  The system call interface between user programs and the kernel.

  Calling convention (x86-64): the "syscall" instruction with the call
  number in RAX and up to six arguments in RDI, RSI, RDX, R10, R8, R9.
  The result comes back in RAX: a value of zero or more is success, and a
  negative value is an error, minus one of the Error* codes below.

  Paths passed to the kernel are UTF-8 and may be absolute or relative to
  the process's current directory. "/" is the root of the system volume;
  other volumes are reached under "/volumes/<name>".

  This unit is compiled into both the kernel and libsystem, so the record
  layouts must only use explicitly sized types.
}
unit Abi.SystemCalls;

{$mode objfpc}

interface

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
  CallGetVolumeInformation = 29;
  CallSync = 30;
  CallGetHandleKind = 31;
  CallListVolumes = 32;
  CallSetPathAttributes = 33;
  CallCreateHardLink = 34;
  CallTerminateProcess = 35;
  CallSetRootDirectory = 36;
  CallControlHandle = 37;
  CallCount = 38;

  { --- Arguments ------------------------------------------------------- }

  { Timeout of CallWaitForProcess meaning "wait as long as it takes". }
  InfiniteWait = -1;

  { Fields of TAbiAttributeChanges that apply. }
  ChangeFieldMode = $01;
  ChangeFieldOwner = $02;
  ChangeFieldGroup = $04;
  ChangeFieldModificationTime = $08;
  ChangeFieldAccessTime = $10;

  { Requests of CallControlHandle (on a console handle). }
  ControlGetConsoleMode = 1;
  ControlSetConsoleMode = 2;
  { Returns rows shl 16 or columns. }
  ControlGetConsoleSize = 3;
  ConsoleModeEcho = $01;
  ConsoleModeLineEditing = $02;

  { --- Error codes (returned negated) ---------------------------------- }

  ErrorNone = 0;
  ErrorInterrupted = 4;
  ErrorTimedOut = 110;
  ErrorNoSuchProcess = 3;
  ErrorNotPermitted = 1;
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

  { --- Handle kinds ---------------------------------------------------- }

  HandleKindFile = 1;
  HandleKindConsole = 2;
  HandleKindPipe = 3;
  HandleKindProcess = 4;
  HandleKindNullDevice = 5;

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
  end;
  PAbiFileInformation = ^TAbiFileInformation;

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
  end;
  PAbiProcessCreation = ^TAbiProcessCreation;

implementation

end.
