{
  System unit for user programs.

  Every user program and library is compiled against this unit, which
  becomes part of libsystem.so. Besides the types the compiler needs, it
  holds the bare minimum a process needs before any library code runs:

    * the raw system call instruction,
    * program startup: it receives the initial stack laid out by the
      kernel (argument count, arguments, environment, auxiliary vector),
      runs the initializers of the program's libraries, prepares
      threadvars and runs the program's main block, which starts by
      initializing the program's units,
    * program exit: unit finalization, a hook so buffered output can be
      flushed, the library finalizers, then the exit system call,
    * thread-local storage support: FPC threadvars and __tls_get_addr.

  Startup and exit order:

      1. initializers (DT_INIT, DT_INIT_ARRAY) of the libraries and the
         program, dependencies first, as the kernel lists them in the
         auxiliary vector,
      2. unit initialization sections, in the order of the program's
         INITFINAL table (the compiler orders it so a unit comes after
         the units it uses, including those living in libraries),
      3. the main block,
      4. unit finalization sections, in reverse,
      5. ExitProcedure (libsystem flushes buffered output),
      6. finalizers (DT_FINI_ARRAY, DT_FINI), program first.

  Threadvars: FPC 3.2.2 does not use ELF thread-local storage for
  threadvars. Each threadvar is an ordinary global whose first word
  receives an offset, and every access calls FPC_THREADVAR_RELOCATE with
  that offset. At startup the program's FPC_THREADVARTABLES (which lists
  the threadvars of every unit the program uses, also those in
  libraries) is walked to hand out offsets; each thread then gets a
  zeroed threadvar block on its first access, kept in the runtime word
  of its thread control block (%fs:8) and released when the thread
  exits (Sys.Threads calls ReleaseThreadVariables).

  Everything else (files, memory, text, processes, threads) lives in the
  Sys.* units of libsystem.
}
unit System;

interface

{$mode fpc}
{$asmmode intel}
{$pointermath on}

{$include system.types.inc}

type
  TExitProcedure = procedure;
  { Called by threadvar accesses; returns the calling thread's copy. }
  TRelocateThreadVarHandler = function(Offset: DWord): Pointer;

  { Tables the compiler puts in every program, handed over by si_prc. }
  TProgramTables = record
    InitFinalTable: Pointer;   { INITFINAL }
    ThreadVarTables: Pointer;  { FPC_THREADVARTABLES }
  end;
  PProgramTables = ^TProgramTables;

var
  { Set by the main block or Halt; passed to the kernel on exit. }
  ExitCode: LongInt;
  ArgumentCount: LongInt;
  ArgumentValues: PPChar;
  EnvironmentValues: PPChar;
  { Runs just before the process ends (libsystem flushes output here). }
  ExitProcedure: TExitProcedure;
  fpc_threadvar_relocate_proc: TRelocateThreadVarHandler; public name 'FPC_THREADVAR_RELOCATE';

{ Performs system call Number with up to six arguments; see
  Abi.SystemCalls for the numbers and the meaning of the result. }
function SystemCall(Number: QWord; Argument1, Argument2, Argument3, Argument4,
  Argument5, Argument6: QWord): Int64;

{ Called by the startup code (si_prc) with the initial stack pointer. }
procedure StartProgram(InitialStack: PQWord; MainBlock: Pointer; Tables: PProgramTables);

{ Ends the program with an exit code. }
procedure Halt(Code: LongInt);

{ The calling thread's thread pointer (its thread control block). }
function ThreadPointer: Pointer;
{ The id the kernel stored in the calling thread's control block. }
function CurrentThreadId: QWord;
{ Frees the calling thread's threadvar block; for exiting threads. }
procedure ReleaseThreadVariables;

procedure fpc_initializeunits; compilerproc;
procedure fpc_do_exit; compilerproc;

implementation

const
  { Kept in step with Abi.SystemCalls, which this unit cannot use. }
  SystemCallExit = 0;
  SystemCallAllocateMemory = 17;
  SystemCallFreeMemory = 18;
  ThreadBlockRuntimeOffset = 8;
  AuxiliaryNull = 0;
  AuxiliaryInitializers = $1000;
  AuxiliaryInitializerCount = $1001;
  AuxiliaryFinalizers = $1002;
  AuxiliaryFinalizerCount = $1003;
  ExitCodeNoThreadVariables = 134;

type
  TMainBlock = procedure;
  TInitializer = procedure(Count: LongInt; Arguments, Environment: PPChar);
  TFinalizer = procedure;

  TInitFinalEntry = record
    InitProc: TFinalizer;
    FinalProc: TFinalizer;
  end;
  TInitFinalTable = record
    TableCount: PtrUInt;
    InitCount: PtrUInt;
    Entries: array[1..32767] of TInitFinalEntry;
  end;
  PInitFinalTable = ^TInitFinalTable;

  TThreadVarEntry = packed record
    VariableAddress: Pointer;
    Size: LongWord;
  end;
  PThreadVarEntry = ^TThreadVarEntry;
  TThreadVarTables = packed record
    Count: LongWord;
    { Each points at a pointer to a unit's list, ended by a nil address. }
    Lists: packed array[0..32767] of PPointer;
  end;
  PThreadVarTables = ^TThreadVarTables;

  TTlsIndex = record
    Module: QWord;
    Offset: QWord;
  end;
  PTlsIndex = ^TTlsIndex;

var
  InitFinal: PInitFinalTable;
  ThreadVarBlockSize: QWord;
  Initializers: PQWord;
  InitializerCount: QWord;
  Finalizers: PQWord;
  FinalizerCount: QWord;
  IsEnding: Boolean;

function SystemCall(Number: QWord; Argument1, Argument2, Argument3, Argument4,
  Argument5, Argument6: QWord): Int64; assembler; nostackframe;
asm
  { Our arguments arrive in RDI, RSI, RDX, RCX, R8, R9 and on the stack;
    the kernel wants the number in RAX and the arguments in RDI, RSI,
    RDX, R10, R8, R9. }
  mov rax, rdi
  mov rdi, rsi
  mov rsi, rdx
  mov rdx, rcx
  mov r10, r8
  mov r8, r9
  mov r9, [rsp + 8]
  syscall
end;

{ --- Thread-local storage -------------------------------------------- }

function ThreadPointer: Pointer; assembler; nostackframe;
asm
  mov rax, qword ptr fs:[0]
end;

function CurrentThreadId: QWord; assembler; nostackframe;
asm
  mov rax, qword ptr fs:[16]
end;

function ReadRuntimeWord: Pointer; assembler; nostackframe;
asm
  mov rax, qword ptr fs:[ThreadBlockRuntimeOffset]
end;

procedure WriteRuntimeWord(Value: Pointer); assembler; nostackframe;
asm
  mov qword ptr fs:[ThreadBlockRuntimeOffset], rdi
end;

{ Variant II TLS for code using the general dynamic model; the kernel
  makes a module's id its offset from the thread pointer. }
function TlsGetAddress(Index: PTlsIndex): Pointer; [public, alias: '__tls_get_addr'];
begin
  TlsGetAddress := Pointer(PtrUInt(ThreadPointer) + Index^.Module + Index^.Offset);
end;

{ Hands out offsets in the threadvar block. }
procedure InitializeThreadVariables(Tables: PThreadVarTables);
var
  TableIndex: LongWord;
  Entry: PThreadVarEntry;
  Offset: QWord;
  Alignment: QWord;
begin
  Offset := 0;
  if Tables <> nil then
  begin
    TableIndex := 0;
    while TableIndex < Tables^.Count do
    begin
      Entry := PThreadVarEntry(Tables^.Lists[TableIndex]^);
      while (Entry <> nil) and (Entry^.VariableAddress <> nil) do
      begin
        if Entry^.Size >= 16 then
          Alignment := 16
        else
          Alignment := 8;
        Offset := (Offset + Alignment - 1) and not (Alignment - 1);
        PLongWord(Entry^.VariableAddress)^ := LongWord(Offset);
        Offset := Offset + Entry^.Size;
        Inc(Entry);
      end;
      Inc(TableIndex);
    end;
  end;
  ThreadVarBlockSize := Offset;
end;

function RelocateThreadVariable(Offset: DWord): Pointer;
var
  Block: Pointer;
  Address: Int64;
begin
  Block := ReadRuntimeWord;
  if Block = nil then
  begin
    { Fresh pages are zero, as threadvars must start out. }
    Address := SystemCall(SystemCallAllocateMemory, ThreadVarBlockSize, 0, 0, 0, 0, 0);
    if Address <= 0 then
      while True do
        SystemCall(SystemCallExit, ExitCodeNoThreadVariables, 0, 0, 0, 0, 0);
    Block := Pointer(Address);
    WriteRuntimeWord(Block);
  end;
  RelocateThreadVariable := Pointer(PtrUInt(Block) + Offset);
end;

procedure ReleaseThreadVariables;
var
  Block: Pointer;
begin
  Block := ReadRuntimeWord;
  if Block = nil then
    Exit;
  WriteRuntimeWord(nil);
  SystemCall(SystemCallFreeMemory, QWord(Block), 0, 0, 0, 0, 0);
end;

{ --- Startup and exit ------------------------------------------------ }

procedure ReadAuxiliaryVector(Entry: PQWord);
begin
  while Entry[0] <> AuxiliaryNull do
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

procedure RunInitializers;
var
  Index: QWord;
begin
  Index := 0;
  while Index < InitializerCount do
  begin
    TInitializer(Pointer(Initializers[Index]))(ArgumentCount, ArgumentValues, EnvironmentValues);
    Inc(Index);
  end;
end;

procedure RunFinalizers;
var
  Index: QWord;
begin
  Index := 0;
  while Index < FinalizerCount do
  begin
    TFinalizer(Pointer(Finalizers[Index]))();
    Inc(Index);
  end;
end;

procedure FinalizeUnits;
var
  Index: PtrUInt;
begin
  if InitFinal = nil then
    Exit;
  while InitFinal^.InitCount > 0 do
  begin
    Index := InitFinal^.InitCount;
    { Counted down first, so a unit that halts is not finalized twice. }
    InitFinal^.InitCount := Index - 1;
    if Assigned(InitFinal^.Entries[Index].FinalProc) then
      InitFinal^.Entries[Index].FinalProc();
  end;
end;

procedure EndProcess(Code: LongInt);
begin
  { Halt from a finalization section goes straight out. }
  if not IsEnding then
  begin
    IsEnding := True;
    FinalizeUnits;
    if Assigned(ExitProcedure) then
      ExitProcedure();
    RunFinalizers;
    Code := ExitCode;
  end;
  while True do
    SystemCall(SystemCallExit, QWord(Code), 0, 0, 0, 0, 0);
end;

procedure StartProgram(InitialStack: PQWord; MainBlock: Pointer; Tables: PProgramTables);
var
  Slot: PQWord;
begin
  ArgumentCount := LongInt(InitialStack^);
  ArgumentValues := PPChar(InitialStack + 1);
  EnvironmentValues := PPChar(InitialStack + 2 + ArgumentCount);
  ExitCode := 0;
  ExitProcedure := nil;
  IsEnding := False;

  { The auxiliary vector follows the environment's terminating nil. }
  Slot := PQWord(EnvironmentValues);
  while Slot^ <> 0 do
    Inc(Slot);
  ReadAuxiliaryVector(Slot + 1);

  InitFinal := PInitFinalTable(Tables^.InitFinalTable);
  InitializeThreadVariables(PThreadVarTables(Tables^.ThreadVarTables));
  fpc_threadvar_relocate_proc := @RelocateThreadVariable;

  RunInitializers;
  TMainBlock(MainBlock)();
  EndProcess(ExitCode);
end;

procedure Halt(Code: LongInt);
begin
  ExitCode := Code;
  EndProcess(Code);
end;

procedure fpc_initializeunits; [public, alias: 'FPC_INITIALIZEUNITS']; compilerproc;
var
  Index: PtrUInt;
begin
  if InitFinal = nil then
    Exit;
  Index := 1;
  while Index <= InitFinal^.TableCount do
  begin
    if Assigned(InitFinal^.Entries[Index].InitProc) then
      InitFinal^.Entries[Index].InitProc();
    InitFinal^.InitCount := Index;
    Inc(Index);
  end;
end;

procedure fpc_do_exit; [public, alias: 'FPC_DO_EXIT']; compilerproc;
begin
  EndProcess(ExitCode);
end;

end.
