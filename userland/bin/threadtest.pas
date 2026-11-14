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
  threadtest - tests for threads, thread-local storage and initialization

  Run by coretest. Without arguments it checks, printing one line per
  check:

    * threads incrementing a shared counter under a lock (Sys.Locks),
    * exit codes and ids of threads, and waiting with a timeout,
    * threadvars: every thread has its own copy,
    * thread-local storage of a library (libtlstest.so, in assembly):
      the general dynamic and initial exec models, each thread with a
      fresh copy of the TLS image,
    * initialization order: library initializers before unit
      initialization, a used unit before the unit using it (unit
      finalization and the library finalizer print at exit),
    * many short-lived threads, so leaks would show,
    * floating point in several threads at once: each keeps its own
      registers across thread switches and processors,
    * memory freed by one thread while another thread's system calls
      copy into it: the calls fail with ErrorBadAddress or succeed, and
      the kernel survives (Kernel.Arch.UserCopy).

  With an option it instead checks how a process ends with threads:

    --exit-with-threads-running   Halt(7) while threads spin and sleep
    --crash-in-thread             a thread dereferences nil (runtime
                                  error 216 ends the whole process)
    --last-thread-exits           the main thread exits first; the
                                  process ends with the last thread's
                                  exit code (5)

  Exits with status 0 when every check passed, 1 otherwise.
}
program threadtest;

{$mode objfpc}
{$pointermath on}

uses
  Sys.Environment,
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Format,
  Sys.Streams,
  Sys.Processes,
  Sys.Kernel,
  Sys.Files,
  Sys.Locks,
  Sys.Threads,
  ThreadTest.InitFirst,
  ThreadTest.InitSecond;

function tlstest_counter_address: PInt64; external name 'tlstest_counter_address';
function tlstest_initial_address: PInt64; external name 'tlstest_initial_address';

const
  CounterThreadCount = 4;
  IncrementsPerThread = 100000;
  ShortLivedThreadCount = 32;
  TlsInitialValue = 42;

var
  FailureCount: Integer;
  SharedCounter: Int64;
  CounterLock: TLock;
  { Held by the main thread to keep a thread waiting. }
  GateLock: TLock;

procedure Check(Passed: Boolean; Name: PChar);
begin
  if Passed then
    PrintFormatted('ok %s'#10, [ArgumentText(Name)])
  else
  begin
    PrintFormatted('FAIL %s'#10, [ArgumentText(Name)]);
    Inc(FailureCount);
  end;
end;

{ --- Shared counter -------------------------------------------------- }

function IncrementCounter(Argument: Pointer): LongInt;
var
  Index: Integer;
begin
  for Index := 1 to IncrementsPerThread do
  begin
    AcquireLock(CounterLock);
    SharedCounter := SharedCounter + 1;
    ReleaseLock(CounterLock);
  end;
  Result := 100 + LongInt(PtrUInt(Argument));
end;

procedure TestSharedCounter;
var
  Handles: array[0..CounterThreadCount - 1] of Int64;
  Index: Integer;
  ExitCode: LongInt;
  AllStarted: Boolean;
  ExitCodesRight: Boolean;
begin
  SharedCounter := 0;
  AllStarted := True;
  for Index := 0 to CounterThreadCount - 1 do
  begin
    Handles[Index] := CreateThread(@IncrementCounter, Pointer(PtrInt(Index)));
    if Handles[Index] < 0 then
      AllStarted := False;
  end;
  Check(AllStarted, 'threads start');

  ExitCodesRight := True;
  for Index := 0 to CounterThreadCount - 1 do
  begin
    if Handles[Index] < 0 then
      Continue;
    if (WaitForThread(Handles[Index], InfiniteWait, ExitCode) <> 0) or (ExitCode <> 100 + Index) then
      ExitCodesRight := False;
    CloseThreadHandle(Handles[Index]);
  end;
  Check(ExitCodesRight, 'thread exit codes');
  Check(SharedCounter = CounterThreadCount * IncrementsPerThread, 'shared counter under a lock');
end;

{ --- Ids and timeouts ------------------------------------------------ }

var
  ReportedThreadId: QWord;

function ReportThreadId(Argument: Pointer): LongInt;
begin
  ReportedThreadId := GetCurrentThreadId;
  Result := 0;
end;

function WaitAtGate(Argument: Pointer): LongInt;
begin
  AcquireLock(GateLock);
  ReleaseLock(GateLock);
  Result := 9;
end;

procedure TestIdsAndTimeouts;
var
  Handle: Int64;
  ExitCode: LongInt;
  Status: Int64;
begin
  Handle := CreateThread(@ReportThreadId, nil);
  WaitForThread(Handle, InfiniteWait, ExitCode);
  Check((ReportedThreadId <> 0) and (ReportedThreadId <> GetCurrentThreadId) and
    (QWord(GetThreadId(Handle)) = ReportedThreadId) and
    (QWord(GetThreadId(CurrentThreadHandle)) = GetCurrentThreadId), 'thread ids');
  CloseThreadHandle(Handle);

  AcquireLock(GateLock);
  Handle := CreateThread(@WaitAtGate, nil);
  Status := WaitForThread(Handle, 50, ExitCode);
  ReleaseLock(GateLock);
  Check(Status = -ErrorTimedOut, 'waiting for a thread times out');
  Status := WaitForThread(Handle, InfiniteWait, ExitCode);
  Check((Status = 0) and (ExitCode = 9), 'a thread waiting on a lock continues');
  CloseThreadHandle(Handle);
end;

{ --- Thread-local data ----------------------------------------------- }

type
  TLocalReport = record
    ThreadVarKept: Boolean;
    TlsInitialSeen: Int64;
    TlsCounterKept: Boolean;
    TlsInitialKept: Boolean;
    CounterAddress: PInt64;
  end;
  PLocalReport = ^TLocalReport;

var
  LocalReports: array[0..CounterThreadCount - 1] of TLocalReport;

{ Sets this thread's copies, lets the other threads run, and checks that
  nobody changed them. }
function UseThreadLocalData(Argument: Pointer): LongInt;
var
  Index: PtrInt;
  Report: PLocalReport;
  Round: Integer;
begin
  Index := PtrInt(PtrUInt(Argument));
  Report := @LocalReports[Index];
  Report^.TlsInitialSeen := tlstest_initial_address^;
  Report^.CounterAddress := tlstest_counter_address;

  ThreadOwnValue := 1000 * (Index + 1);
  tlstest_initial_address^ := Index;
  for Round := 1 to 10 do
  begin
    tlstest_counter_address^ := tlstest_counter_address^ + 1;
    SleepMilliseconds(2);
  end;

  Report^.ThreadVarKept := ThreadOwnValue = 1000 * (Index + 1);
  Report^.TlsCounterKept := tlstest_counter_address^ = 10;
  Report^.TlsInitialKept := tlstest_initial_address^ = Index;
  Result := 0;
end;

procedure TestThreadLocalData;
var
  Handles: array[0..CounterThreadCount - 1] of Int64;
  Index: Integer;
  Other: Integer;
  ExitCode: LongInt;
  ThreadVarsKept: Boolean;
  FreshImages: Boolean;
  TlsKept: Boolean;
  DistinctBlocks: Boolean;
begin
  ThreadOwnValue := -1;
  tlstest_counter_address^ := 77;
  for Index := 0 to CounterThreadCount - 1 do
    Handles[Index] := CreateThread(@UseThreadLocalData, Pointer(PtrInt(Index)));
  for Index := 0 to CounterThreadCount - 1 do
  begin
    WaitForThread(Handles[Index], InfiniteWait, ExitCode);
    CloseThreadHandle(Handles[Index]);
  end;

  ThreadVarsKept := ThreadOwnValue = -1;
  FreshImages := True;
  TlsKept := (tlstest_counter_address^ = 77) and (tlstest_initial_address^ = TlsInitialValue);
  DistinctBlocks := True;
  for Index := 0 to CounterThreadCount - 1 do
  begin
    if not LocalReports[Index].ThreadVarKept then
      ThreadVarsKept := False;
    if LocalReports[Index].TlsInitialSeen <> TlsInitialValue then
      FreshImages := False;
    if not LocalReports[Index].TlsCounterKept or not LocalReports[Index].TlsInitialKept then
      TlsKept := False;
    if LocalReports[Index].CounterAddress = tlstest_counter_address then
      DistinctBlocks := False;
    for Other := 0 to Index - 1 do
    begin
      if LocalReports[Index].CounterAddress = LocalReports[Other].CounterAddress then
        DistinctBlocks := False;
    end;
  end;
  Check(ThreadVarsKept, 'threadvars are per thread');
  Check(FreshImages, 'library TLS starts from its image in every thread');
  Check(TlsKept, 'library TLS is per thread');
  Check(DistinctBlocks, 'library TLS blocks are distinct');
end;

{ --- Initialization order -------------------------------------------- }

procedure TestInitializationOrder;
begin
  Check(TextIsEqual(@InitTrace[0], 'FS'), 'units initialized in dependency order');
  Check(LibraryInitCallsSeen = 1, 'library initializer ran before the units');
end;

{ --- Many short threads ---------------------------------------------- }

function DoNothing(Argument: Pointer): LongInt;
begin
  Result := LongInt(PtrUInt(Argument));
end;

procedure TestShortLivedThreads;
var
  Index: Integer;
  Handle: Int64;
  ExitCode: LongInt;
  AllRight: Boolean;
begin
  AllRight := True;
  for Index := 1 to ShortLivedThreadCount do
  begin
    { Small stacks, which still have a guard page. }
    Handle := CreateThread(@DoNothing, Pointer(PtrInt(Index)), 16 * 1024);
    if (Handle < 0) or (WaitForThread(Handle, InfiniteWait, ExitCode) <> 0) or (ExitCode <> Index) then
      AllRight := False;
    if Handle >= 0 then
      CloseThreadHandle(Handle);
  end;
  Check(AllRight, 'many short-lived threads');
end;

{ --- Floating point in several threads -------------------------------- }

const
  FloatThreadCount = 4;
  FloatTerms = 2000000;

{ A sum of FloatTerms terms that depends on every step; any register
  clobbered by another thread changes the result. }
function HarmonicSum(Offset: LongInt): Double;
var
  Index: LongInt;
begin
  Result := 0.0;
  for Index := 1 to FloatTerms do
    Result := Result + 1.0 / (Index + Offset);
end;

var
  ExpectedSums: array[0..FloatThreadCount - 1] of Double;

function ComputeSum(Argument: Pointer): LongInt;
var
  Number: LongInt;
begin
  Number := LongInt(PtrInt(Argument));
  if HarmonicSum(Number * 7) = ExpectedSums[Number] then
    Result := 1
  else
    Result := 0;
end;

procedure TestFloatingPoint;
var
  Handles: array[0..FloatThreadCount - 1] of Int64;
  Index: Integer;
  ExitCode: LongInt;
  AllRight: Boolean;
begin
  for Index := 0 to FloatThreadCount - 1 do
    ExpectedSums[Index] := HarmonicSum(Index * 7);
  AllRight := True;
  for Index := 0 to FloatThreadCount - 1 do
    Handles[Index] := CreateThread(@ComputeSum, Pointer(PtrInt(Index)), 0);
  for Index := 0 to FloatThreadCount - 1 do
  begin
    if (Handles[Index] < 0) or (WaitForThread(Handles[Index], InfiniteWait, ExitCode) <> 0) or
       (ExitCode <> 1) then
      AllRight := False;
    if Handles[Index] >= 0 then
      CloseThreadHandle(Handles[Index]);
  end;
  Check(AllRight, 'floating point registers are per thread');
end;

{ --- Memory freed during a system call -------------------------------- }

const
  RaceRounds = 3000;
  RaceBufferSize = 65536;

var
  { The buffer the main thread copies into; freed behind its back. }
  RaceBuffer: QWord;
  RaceFinished: Boolean;

function FreeAndReallocate(Argument: Pointer): LongInt;
var
  Round: Integer;
  Address: Int64;
begin
  for Round := 1 to RaceRounds do
  begin
    Address := KernelAllocateMemory(RaceBufferSize);
    if Address > 0 then
    begin
      RaceBuffer := QWord(Address);
      KernelFreeMemory(Pointer(Address));
    end;
  end;
  RaceFinished := True;
  Result := 0;
end;

procedure TestFreeWhileCopying;
var
  Handle: Int64;
  FileHandle: Int64;
  Outcome: Int64;
  ExitCode: LongInt;
  AllRight: Boolean;
begin
  AllRight := True;
  RaceFinished := False;
  RaceBuffer := 0;
  FileHandle := OpenFile('/bin/sh', OpenRead);
  Handle := CreateThread(@FreeAndReallocate, nil, 0);
  if (Handle < 0) or (FileHandle < 0) then
    AllRight := False
  else
  begin
    while not RaceFinished do
    begin
      if RaceBuffer = 0 then
        Continue;
      SeekFile(FileHandle, 0, SeekFromStart);
      Outcome := KernelRead(FileHandle, Pointer(RaceBuffer), RaceBufferSize);
      if (Outcome < 0) and (Outcome <> -ErrorBadAddress) then
        AllRight := False;
      Outcome := KernelGetCurrentDirectory(PChar(RaceBuffer), RaceBufferSize);
      if (Outcome < 0) and (Outcome <> -ErrorBadAddress) then
        AllRight := False;
    end;
    WaitForThread(Handle, InfiniteWait, ExitCode);
    CloseThreadHandle(Handle);
  end;
  if FileHandle >= 0 then
    CloseFile(FileHandle);
  Check(AllRight, 'memory freed during a system call');
end;

{ --- How processes end ----------------------------------------------- }

function SpinForever(Argument: Pointer): LongInt;
var
  Spins: QWord;
begin
  Spins := 0;
  while True do
    Inc(Spins);
  Result := 0;
end;

function SleepForever(Argument: Pointer): LongInt;
begin
  while True do
    SleepMilliseconds(1000);
  Result := 0;
end;

function WaitForeverOnLock(Argument: Pointer): LongInt;
begin
  AcquireLock(GateLock);
  Result := 0;
end;

procedure ExitWithThreadsRunning;
begin
  AcquireLock(GateLock);
  CreateThread(@SpinForever, nil);
  CreateThread(@SleepForever, nil);
  CreateThread(@WaitForeverOnLock, nil);
  SleepMilliseconds(30);
  Halt(7);
end;

function CrashOnPurpose(Argument: Pointer): LongInt;
var
  Nowhere: PInt64;
begin
  Nowhere := nil;
  Result := LongInt(Nowhere^);
end;

procedure CrashInThread;
var
  ExitCode: LongInt;
begin
  CreateThread(@SpinForever, nil);
  WaitForThread(CreateThread(@CrashOnPurpose, nil), InfiniteWait, ExitCode);
  { Not reached: the crash ends the whole process. }
  Halt(0);
end;

function ExitLater(Argument: Pointer): LongInt;
begin
  SleepMilliseconds(50);
  Result := 5;
end;

procedure LastThreadExits;
begin
  CreateThread(@ExitLater, nil);
  ExitThread(0);
end;

begin
  if ArgumentTotal > 1 then
  begin
    if TextIsEqual(ArgumentValues[1], '--exit-with-threads-running') then
      ExitWithThreadsRunning
    else if TextIsEqual(ArgumentValues[1], '--crash-in-thread') then
      CrashInThread
    else if TextIsEqual(ArgumentValues[1], '--last-thread-exits') then
      LastThreadExits;
    PrintLine('threadtest: unknown option');
    Halt(2);
  end;

  FailureCount := 0;
  TestInitializationOrder;
  TestSharedCounter;
  TestIdsAndTimeouts;
  TestThreadLocalData;
  TestShortLivedThreads;
  TestFloatingPoint;
  TestFreeWhileCopying;
  PrintFinalization := True;
  if FailureCount > 0 then
    Halt(1);
end.
