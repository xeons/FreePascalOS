{
  System unit for FreePascalOS user programs: the Free Pascal runtime
  library on this kernel.

  Everything generic - strings and their reference counting, dynamic
  arrays, exceptions, classes and interfaces, variants, the heap
  manager, text and typed files, threads and threadvars - comes from the
  Free Pascal sources (rtl/inc and rtl/x86_64 of the compiler's source
  tree). This unit and the include files next to it supply the parts
  that depend on the operating system, on its system calls (Abi):

    sysosh.inc    platform types (handles, critical sections, ...)
    sysos.inc     the system call itself and error codes
    sysheap.inc   memory for the heap manager
    sysfile.inc   file handles: open, read, write, seek, ...
    sysdir.inc    directories
    systhrd.inc   the thread manager
    sysdl.inc     libraries loaded at run time

  The unit is part of libsystem.so, shared by every program, so one
  heap, one exception state per thread and one set of standard files
  serve the program and all its libraries. The compiler puts the unit
  tables (INITFINAL, the threadvar and resource string tables) into the
  program, which System in a library cannot reference directly: the
  startup code (si_prc) hands them over in a TEntryInformation, as Free
  Pascal does for its Windows DLLs (FPC_HAS_INDIRECT_ENTRY_INFORMATION).

  Startup: the kernel starts the program at _start (si_prc) with the
  stack pointer at the argument count; si_prc calls SysEntry, which
  takes over the tables and the arguments, runs the initializers of the
  libraries (from the auxiliary vector), and calls the main block. The
  main block initializes the units (System first), runs, and ends with
  Halt: exit procedures, unit finalization, the library finalizers and
  the exit system call.
}
unit System;

{*****************************************************************************}
                                    interface
{*****************************************************************************}

{ This is not Linux, even though the compiler targets its ELF and calling
  conventions. }
{$undef LINUX}
{$undef UNIX}

{$define FPC_IS_SYSTEM}
{$define FPC_HAS_INDIRECT_ENTRY_INFORMATION}
{$define FPC_SYSTEM_HAS_OSSETUPENTRYINFORMATION}
{ The thread and library managers are part of this unit. }
{$define DISABLE_NO_THREAD_MANAGER}
{$define DISABLE_NO_DYNLIBS_MANAGER}
{$define FPC_SYSTEM_HAS_SYSDLH}

{$I systemh.inc}

const
  LineEnding = #10;
  LFNSupport = True;
  DirectorySeparator = '/';
  DriveSeparator = '';
  ExtensionSeparator = '.';
  PathSeparator = ':';
  AllowDirectorySeparators: set of Char = ['\', '/'];
  AllowDriveSeparators: set of Char = [];
  MaxExitCode = 255;
  MaxPathLen = 4096;
  AllFilesMask = '*';

  UnusedHandle = -1;
  StdInputHandle = 0;
  StdOutputHandle = 1;
  StdErrorHandle = 2;

  FileNameCaseSensitive: Boolean = True;
  FileNameCasePreserving: Boolean = True;
  CtrlZMarksEOF: Boolean = False;
  sLineBreak = LineEnding;
  DefaultTextLineBreakStyle: TTextLineBreakStyle = tlbsLF;

var
  argc: LongInt;
  argv: PPChar;
  envp: PPChar;

{ --- FreePascalOS specific ------------------------------------------------ }

{ Performs system call Number with up to six arguments; see
  Abi.SystemCalls for the numbers and the meaning of the result. }
function SystemCall(Number: QWord; Argument1, Argument2, Argument3, Argument4,
  Argument5, Argument6: QWord): Int64;

{ The calling thread's id, as the kernel knows it. }
function CurrentThreadId: QWord;

{ The Abi error of the last failed file or thread operation of this
  thread (for SysUtils.GetLastOSError). }
function GetLastSystemError: LongInt;
procedure SetLastSystemError(Error: LongInt);

{ Called by the startup code (si_prc). }
procedure SysEntry(constref Information: TEntryInformation);

{*****************************************************************************}
                                 implementation
{*****************************************************************************}

procedure OsSetupEntryInformation(constref Information: TEntryInformation); forward;

{$I system.inc}

{*****************************************************************************
                                Entry and exit
*****************************************************************************}

var
  InitialStackPointer: Pointer;
  Initializers: PQWord;
  InitializerCount: QWord;
  Finalizers: PQWord;
  FinalizerCount: QWord;

type
  { ELF initializers get the arguments and the environment. }
  TInitializer = procedure(Count: LongInt; Arguments, Environment: PPChar); cdecl;
  TFinalizer = procedure; cdecl;

procedure ReadAuxiliaryVector(Entry: PQWord);
begin
  if Entry = nil then
    Exit;
  while Entry[0] <> 0 do
  begin
    case Entry[0] of
      AuxiliaryInitializers: Initializers := PQWord(Entry[1]);
      AuxiliaryInitializerCount: InitializerCount := Entry[1];
      AuxiliaryFinalizers: Finalizers := PQWord(Entry[1]);
      AuxiliaryFinalizerCount: FinalizerCount := Entry[1];
    end;
    Inc(Entry, 2);
  end;
end;

procedure OsSetupEntryInformation(constref Information: TEntryInformation);
begin
  argc := Information.OS.argc;
  argv := Information.OS.argv;
  envp := Information.OS.envp;
  InitialStackPointer := Information.OS.stkptr;
  ReadAuxiliaryVector(Information.OS.auxv);
end;

procedure RunInitializers;
var
  Index: QWord;
begin
  Index := 0;
  while Index < InitializerCount do
  begin
    TInitializer(Pointer(Initializers[Index]))(argc, argv, envp);
    Inc(Index);
  end;
end;

procedure RunFinalizers;
var
  Index: QWord;
  Count: QWord;
begin
  { Each runs once, even if a finalizer ends the process again. }
  Count := FinalizerCount;
  FinalizerCount := 0;
  Index := 0;
  while Index < Count do
  begin
    TFinalizer(Pointer(Finalizers[Index]))();
    Inc(Index);
  end;
end;

procedure SysEntry(constref Information: TEntryInformation);
begin
  SetupEntryInformation(Information);
  RunInitializers;
  Information.PascalMain();
end;

procedure System_exit;
begin
  RunFinalizers;
  while True do
    SystemCall(CallExit, QWord(LongWord(ExitCode)), 0, 0, 0, 0, 0);
end;

function CurrentThreadId: QWord; assembler; nostackframe;
asm
  movq %fs:16, %rax
end;

{ ELF thread-local storage of libraries, for code using the general
  dynamic model: the kernel lays it out statically below the thread
  pointer (variant II) and makes a module's id its offset from it. }
type
  PTlsIndex = ^TTlsIndex;
  TTlsIndex = record
    Module: QWord;
    Offset: QWord;
  end;

function ThreadPointer: Pointer; assembler; nostackframe;
asm
  movq %fs:0, %rax
end;

function TlsGetAddress(Index: PTlsIndex): Pointer; [public, alias: '__tls_get_addr'];
begin
  TlsGetAddress := Pointer(PtrUInt(ThreadPointer) + Index^.Module + Index^.Offset);
end;

{*****************************************************************************
                       Misc. system dependent functions
*****************************************************************************}

function ParamCount: LongInt;
begin
  ParamCount := argc - 1;
end;

function ParamStr(L: LongInt): String;
begin
  if (L >= 0) and (L < argc) then
    ParamStr := StrPas(argv[L])
  else
    ParamStr := '';
end;

procedure Randomize;
begin
  RandSeed := LongInt(SystemCall(CallGetTime, 1, 0, 0, 0, 0, 0)) xor
    LongInt(SystemCall(CallGetTime, 0, 0, 0, 0, 0, 0));
end;

function GetProcessID: SizeUInt;
begin
  GetProcessID := SizeUInt(SystemCall(CallGetProcessId, QWord(Int64(NoHandle)), 0, 0, 0, 0, 0));
end;

function CheckInitialStkLen(StkLen: SizeUInt): SizeUInt;
begin
  CheckInitialStkLen := StkLen;
end;

procedure SysInitStdIO;
begin
  OpenStdIO(Input, fmInput, StdInputHandle);
  OpenStdIO(Output, fmOutput, StdOutputHandle);
  OpenStdIO(ErrOutput, fmOutput, StdErrorHandle);
  OpenStdIO(StdOut, fmOutput, StdOutputHandle);
  OpenStdIO(StdErr, fmOutput, StdErrorHandle);
end;

{*****************************************************************************
                         System unit initialization
*****************************************************************************}

const
  MainStackSize = 8 * 1024 * 1024;

begin
  IsConsole := True;
  StackLength := CheckInitialStkLen(MainStackSize);
  StackBottom := InitialStackPointer - StackLength;
  InitHeap;
  SysInitExceptions;
  InitUnicodeStringManager;
  { Text is UTF-8 everywhere: file names, the console, files. }
  DefaultSystemCodePage := CP_UTF8;
  DefaultFileSystemCodePage := CP_UTF8;
  DefaultRTLFileSystemCodePage := CP_UTF8;
  SysInitStdIO;
  InOutRes := 0;
  InitSystemThreads;
  InitSystemDynLibs;
end.
