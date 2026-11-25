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
  System unit for FreePascalOS user programs: the Free Pascal runtime
  library on this kernel.

  Everything generic - strings and their reference counting, dynamic
  arrays, exceptions, classes and interfaces, variants, the heap
  manager, text and typed files, threads and threadvars - comes from the
  Free Pascal sources (rtl/inc and rtl/x86_64 or rtl/aarch64 of the compiler's source
  tree). This unit and the include files next to it supply the parts
  that depend on the operating system, on its system calls (Abi):

    sysosh.inc    platform types (handles, critical sections, ...)
    sysos.inc     the system call itself and error codes, with the
                  processor's part in syscpu_x86_64.inc or
                  syscpu_aarch64.inc
    sysheap.inc   memory for the heap manager
    sysheapcheck.inc  heap checking (HEAP_CHECKS), with
                  sysheapchecklevel.inc, sysheapcheckreport.inc and
                  sysheapquarantine.inc; syspageheap.inc the page heap
    sysfile.inc   file handles: open, read, write, seek, ...
    sysdir.inc    directories
    systhrd.inc   the thread manager
    sysdl.inc     libraries loaded at run time
    syscrash.inc  crash reports naming each address's module

  Processor exceptions (an access violation, a division by zero, a
  floating point exception) are passed to the program by the kernel: the
  thread continues in SysDispatchException, which turns them into the
  runtime errors Free Pascal uses everywhere (216, 200, 208, 202 for a
  stack overflow, ...), unless an ExceptionFilter deals with them and
  continues the thread (ContinueAtContext). With
  SysUtils those become exceptions (EAccessViolation, EDivByZero,
  EZeroDivide, ...) that try/except can catch; without it the program
  ends with "Runtime error 216" as usual.

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

{ The time from the clock page, without a system call: Which is
  TimeWallClock (nanoseconds since 1970) or TimeUptimeNanoseconds.
  False if the page cannot give it (no page, or a kernel clock programs
  cannot read): then CallGetPreciseTime does. }
function ReadClockPageTime(Which: LongWord; out Nanoseconds: Int64): Boolean;

{ The Abi error of the last failed file or thread operation of this
  thread (for SysUtils.GetLastOSError). }
function GetLastSystemError: LongInt;
procedure SetLastSystemError(Error: LongInt);

{ Called by the startup code (si_prc). }
procedure SysEntry(constref Information: TEntryInformation);

{ Called by the startup code of a Free Pascal library loaded at run time
  (si_dll, its DT_INIT) with its unit tables (INITFINAL,
  FPC_THREADVARTABLES, FPC_RESOURCESTRINGTABLES, FPC_RESSTRINITTABLES):
  gives its own units' threadvars their blocks, adds its own units'
  resource string tables to the program's (so SetResourceStrings reaches
  them) and initializes those units. Returns what SysUnregisterLibrary
  (its DT_FINI) takes to finalize them. }
function SysRegisterLibrary(InitFinalTable, ThreadvarTables, ResourceStringTables,
  ResourceStringInitTables: Pointer): Pointer;

{ Loads a library (CallLoadLibrary) and runs the initializers it brought
  in, as LoadLibrary does: the kernel's handle, or a negative Abi error
  code. }
function SysLoadLibraryHandle(Name: PChar): Int64;
procedure SysUnregisterLibrary(Registration: Pointer);

type
  { Sees every processor exception (with a PAbiExceptionRecord, see
    Abi.SystemCalls) before it becomes a runtime error. Returning True
    means the program dealt with it: the thread continues at the record's
    context, which the filter may have changed (Sys.Exceptions has the
    typed interface). }
  TExceptionFilter = function(ExceptionRecord: Pointer): Boolean;

var
  ExceptionFilter: TExceptionFilter = nil;

{ Continues the calling thread with the registers of a TAbiContext; does
  not return (a context that does not lead back into the program ends it
  with runtime error 216). }
procedure ContinueAtContext(Context: Pointer); noreturn;

{*****************************************************************************}
                                 implementation
{*****************************************************************************}

procedure OsSetupEntryInformation(constref Information: TEntryInformation); forward;

{$I system.inc}

{$I sysheapchecklevel.inc}
{$I sysheapcheckreport.inc}
{$I sysheapquarantine.inc}
{$I syspageheap.inc}
{$I sysheapcheck.inc}
{$I syscrash.inc}

{*****************************************************************************
                                Entry and exit
*****************************************************************************}

var
  InitialStackPointer: Pointer;
  Initializers: PQWord;
  InitializerCount: QWord;
  Finalizers: PQWord;
  FinalizerCount: QWord;
  ClockPage: PAbiClockPage;

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
      AuxiliaryClockPage: ClockPage := PAbiClockPage(Entry[1]);
    end;
    Inc(Entry, 2);
  end;
end;

{$I ClockPageMath.inc}

function ReadClockPageTime(Which: LongWord; out Nanoseconds: Int64): Boolean;
var
  Copy: TAbiClockPage;
  Before: LongWord;
  Counter: QWord;
  Uptime: QWord;
begin
  ReadClockPageTime := False;
  Nanoseconds := 0;
  if (ClockPage = nil) or ((Which <> TimeWallClock) and (Which <> TimeUptimeNanoseconds)) then
    Exit;
  { A consistent copy and the counter read while it held: the kernel
    makes Sequence odd while it changes the page. }
  repeat
    Before := ClockPage^.Sequence;
    ReadBarrier;
    Copy := ClockPage^;
    Counter := ReadProcessorCounter;
    ReadBarrier;
  until ((Before and 1) = 0) and (ClockPage^.Sequence = Before);
  if Copy.Mode <> ClockPageModeCounter then
    Exit;
  Uptime := ClockPageUptimeAt(Copy, Counter);
  if Which = TimeWallClock then
    Nanoseconds := ClockPageWallClockAt(Copy, Uptime)
  else
    Nanoseconds := Int64(Uptime);
  ReadClockPageTime := True;
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
  WriteCrashModuleList;
  RunFinalizers;
  while True do
    SystemCall(CallExit, QWord(LongWord(ExitCode)), 0, 0, 0, 0, 0);
end;

function CurrentThreadId: QWord;
begin
  CurrentThreadId := KernelThreadId;
end;

{ ELF thread-local storage of libraries, for code using the general
  dynamic model. The program's and its startup libraries' storage is
  laid out statically next to the thread pointer (below it on x86-64,
  variant II; above it on AArch64, variant I), and such a module's id is
  its offset from it. A library loaded later has dynamic TLS: its id is
  TlsDynamicModuleTag plus its module handle, and its blocks are made
  per thread (sysdyntls.inc). }
type
  PTlsIndex = ^TTlsIndex;
  TTlsIndex = record
    Module: QWord;
    Offset: QWord;
  end;

const
  { The bits that tell a dynamic module's id from a static offset (a
    static offset is small, or negative on x86-64). }
  TlsDynamicModuleTagMask = QWord($C000000000000000);

function TlsGetAddress(Index: PTlsIndex): Pointer; [public, alias: '__tls_get_addr'];
begin
  if (Index^.Module and TlsDynamicModuleTagMask) = TlsDynamicModuleTag then
    TlsGetAddress := DynamicTlsAddress(PtrUInt(Index^.Module and TlsDynamicHandleMask), PtrUInt(Index^.Offset))
  else
    TlsGetAddress := Pointer(PtrUInt(ThreadPointer) + Index^.Module + Index^.Offset);
end;

{*****************************************************************************
                             Processor exceptions
*****************************************************************************}

{ The runtime error Free Pascal reports for an exception. }
function RuntimeErrorFor(const ExceptionRecord: TAbiExceptionRecord): LongInt;
begin
  case ExceptionRecord.Code of
    ExceptionAccessViolation, ExceptionIllegalInstruction, ExceptionGuardPage: RuntimeErrorFor := 216;
    ExceptionPrivilegedOperation: RuntimeErrorFor := 218;
    ExceptionIntegerDivide: RuntimeErrorFor := 200;
    ExceptionIntegerOverflow: RuntimeErrorFor := 215;
    ExceptionBoundRange: RuntimeErrorFor := 201;
    ExceptionAlignment: RuntimeErrorFor := 214;
    ExceptionFloatingPoint, ExceptionSimdFloatingPoint:
      RuntimeErrorFor := FloatExceptionRuntimeError(ExceptionRecord.Code);
    ExceptionStackOverflow: RuntimeErrorFor := 202;
  else
    RuntimeErrorFor := 212;
  end;
end;

procedure ContinueAtContext(Context: Pointer);
begin
  SystemCall(CallContinue, QWord(Context), 0, 0, 0, 0, 0);
  RunError(216);
end;

{ Where the kernel lets a thread continue after a processor exception,
  with the record on the thread's stack. Raises the runtime error (an
  exception with SysUtils) as if the faulting instruction had done so;
  never returns. }
procedure SysDispatchException(ExceptionRecord: PAbiExceptionRecord);
var
  Information: TAbiExceptionRecord;
  Error: LongInt;
begin
  Information := ExceptionRecord^;
  SystemCall(CallExceptionDispatched, 0, 0, 0, 0, 0, 0);
  if Assigned(ExceptionFilter) and ExceptionFilter(@Information) then
    ContinueAtContext(@Information.Context);
  Error := RuntimeErrorFor(Information);
  { Clear the floating point exception, or the next instruction using
    the unit would raise it again. }
  if Information.Code in [ExceptionFloatingPoint, ExceptionSimdFloatingPoint] then
    SysResetFPU;
  HandleErrorAddrFrame(Error, CodePointer(Information.Address), ContextFramePointer(Information.Context));
  Halt(Error);
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
  { Error output is written line by line wherever it goes (a file, a
    pipe), not only on the console: diagnostics of a program that hangs
    or crashes are not lost in a buffer. }
  TextRec(ErrOutput).FlushFunc := TextRec(ErrOutput).InOutFunc;
  TextRec(StdErr).FlushFunc := TextRec(StdErr).InOutFunc;
end;

{*****************************************************************************
                         System unit initialization
*****************************************************************************}

const
  MainStackSize = 8 * 1024 * 1024;

begin
  SystemCall(CallSetExceptionDispatcher, QWord(@SysDispatchException), 0, 0, 0, 0, 0);
  IsConsole := True;
  StackLength := CheckInitialStkLen(MainStackSize);
  StackBottom := InitialStackPointer - StackLength;
  InitHeap;
  { Before the first allocation: every block then has the checking
    heap's header, or none has. }
  InitHeapChecks;
  SysInitExceptions;
  BackTraceStrFunc := @ModuleBackTraceStr;
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
