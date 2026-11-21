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
  dynlibtest - libraries with thread-local storage and initializers,
  loaded with LoadLibrary by a program that already runs threads

  Starts threads that wait, then loads

    * libdyntls.so (userland/lib/dyntls, assembly): ELF thread-local
      storage (an initialized and a zeroed variable, reached through
      __tls_get_addr and, on AArch64, TLS descriptors), an initializer
      and a finalizer,
    * libdynpascal.so (userland/lib/dynpascal): a Free Pascal library
      with threadvars and a unit initialization of its own,

  and checks: each initializer ran once, before LoadLibrary returned,
  and not again when the library is loaded a second time; every thread
  (those started before the load, those started after, and the main
  thread) has its own copy of every variable, starting with the
  library's initial values (ELF) or zero (threadvars - but the loading
  thread keeps what the unit initialization set), and keeps what it
  writes there. When the program ends, the finalizers print
  "dynpascal: unit finalized" and "dyntls: library finalizer ran".

  Prints "ok NAME" or "FAIL NAME" per check and "dynlibtest: N checks, F
  failed" at the end; exits with 1 if a check failed.
}
program dynlibtest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Sys.Streams,
  Sys.Threads,
  Sys.Locks,
  Sys.Libraries;

const
  EarlyThreadCount = 3;
  LateThreadCount = 2;
  ThreadCount = EarlyThreadCount + LateThreadCount;
  ElfInitialValue = 1234;
  CounterIncrements = 1000;
  LoaderMark = 77;

type
  TAddressFunction = function: PInt64; cdecl;
  TPascalAddressFunction = function: PInt64;
  TPascalNumberFunction = function: LongInt;

  TThreadReport = record
    Index: Integer;
    ElfInitialSeen: Int64;
    ElfCounterSeen: Int64;
    ElfCounter: PInt64;
    ElfInitial: PInt64;
    ElfPathsAgree: Boolean;
    ElfKept: Boolean;
    PascalMarkSeen: LongInt;
    PascalCounterSeen: Int64;
    PascalCounter: PInt64;
    PascalKept: Boolean;
  end;
  PThreadReport = ^TThreadReport;

var
  Checks: Integer = 0;
  Failures: Integer = 0;
  Gate: TLock;
  ElfCounterAddress: TAddressFunction;
  ElfCounterAddressSlow: TAddressFunction;
  ElfInitialAddress: TAddressFunction;
  ElfInitializerCalls: PLongInt;
  PascalCounterAddress: TPascalAddressFunction;
  PascalMark: TPascalNumberFunction;
  PascalInitializations: TPascalNumberFunction;
  Reports: array[0..ThreadCount - 1] of TThreadReport;

procedure Check(Passed: Boolean; const Name: string);
begin
  Inc(Checks);
  if Passed then
    PrintStringLine('ok ' + Name)
  else
  begin
    PrintStringLine('FAIL ' + Name);
    Inc(Failures);
  end;
end;

{ What one thread sees of the libraries, and whether its own values
  stay its own. }
function RunThread(Argument: Pointer): LongInt;
var
  Report: PThreadReport;
  Step: Integer;
begin
  Report := PThreadReport(Argument);
  { Threads started before the load wait for it here. }
  AcquireLock(Gate);
  ReleaseLock(Gate);

  Report^.ElfCounter := ElfCounterAddress();
  Report^.ElfInitial := ElfInitialAddress();
  Report^.ElfPathsAgree := (Report^.ElfCounter <> nil) and (ElfCounterAddressSlow() = Report^.ElfCounter);
  if (Report^.ElfCounter = nil) or (Report^.ElfInitial = nil) then
    Exit(1);
  Report^.ElfCounterSeen := Report^.ElfCounter^;
  Report^.ElfInitialSeen := Report^.ElfInitial^;
  Report^.PascalCounter := PascalCounterAddress();
  Report^.PascalCounterSeen := Report^.PascalCounter^;
  Report^.PascalMarkSeen := PascalMark();

  Report^.ElfInitial^ := 5000 + Report^.Index;
  Report^.PascalCounter^ := 100 * Report^.Index;
  for Step := 1 to CounterIncrements do
  begin
    ElfCounterAddress()^ := ElfCounterAddress()^ + 1;
    if Step mod 100 = 0 then
      YieldThread;
  end;
  Report^.ElfKept := (ElfCounterAddress()^ = CounterIncrements) and (ElfInitialAddress()^ = 5000 + Report^.Index);
  Report^.PascalKept := PascalCounterAddress()^ = 100 * Report^.Index;
  Result := 0;
end;

function StartThread(Index: Integer): Int64;
begin
  Reports[Index].Index := Index;
  Result := CreateThread(@RunThread, @Reports[Index]);
  Check(Result >= 0, Format('thread %d starts', [Index]));
end;

function LoadOrFail(Name: PChar): Int64;
begin
  Result := LoadLibrary(Name);
  Check(Result >= 0, Format('LoadLibrary %s', [Name]));
  if Result < 0 then
  begin
    PrintStringLine(Format('dynlibtest: %d checks, %d failed', [Checks, Failures]));
    Halt(1);
  end;
end;

procedure FindEntryPoints(ElfLibrary, PascalLibrary: Int64);
begin
  ElfCounterAddress := TAddressFunction(FindSymbol(ElfLibrary, 'dyntls_counter_address'));
  ElfCounterAddressSlow := TAddressFunction(FindSymbol(ElfLibrary, 'dyntls_counter_address_slow'));
  ElfInitialAddress := TAddressFunction(FindSymbol(ElfLibrary, 'dyntls_initial_address'));
  ElfInitializerCalls := PLongInt(FindSymbol(ElfLibrary, 'dyntls_init_calls'));
  PascalCounterAddress := TPascalAddressFunction(FindSymbol(PascalLibrary, 'dynpascal_counter_address'));
  PascalMark := TPascalNumberFunction(FindSymbol(PascalLibrary, 'dynpascal_mark'));
  PascalInitializations := TPascalNumberFunction(FindSymbol(PascalLibrary, 'dynpascal_initializations'));
  Check(Assigned(ElfCounterAddress) and Assigned(ElfCounterAddressSlow) and Assigned(ElfInitialAddress) and
    (ElfInitializerCalls <> nil), 'libdyntls entry points found');
  Check(Assigned(PascalCounterAddress) and Assigned(PascalMark) and Assigned(PascalInitializations),
    'libdynpascal entry points found');
  if Failures > 0 then
  begin
    PrintStringLine(Format('dynlibtest: %d checks, %d failed', [Checks, Failures]));
    Halt(1);
  end;
end;

procedure CheckReports(MainElfCounter, MainPascalCounter: PInt64);
var
  Index: Integer;
  Other: Integer;
  Distinct: Boolean;
begin
  for Index := 0 to ThreadCount - 1 do
  begin
    Check(Reports[Index].ElfInitialSeen = ElfInitialValue,
      Format('thread %d: ELF TLS starts from the image', [Index]));
    Check(Reports[Index].ElfCounterSeen = 0, Format('thread %d: ELF TLS starts zeroed', [Index]));
    Check(Reports[Index].ElfPathsAgree, Format('thread %d: __tls_get_addr and the descriptor agree', [Index]));
    Check(Reports[Index].ElfKept, Format('thread %d: ELF TLS keeps its values', [Index]));
    Check((Reports[Index].PascalMarkSeen = 0) and (Reports[Index].PascalCounterSeen = 0),
      Format('thread %d: threadvars of the library start zeroed', [Index]));
    Check(Reports[Index].PascalKept, Format('thread %d: threadvars of the library keep their values', [Index]));
  end;

  Distinct := True;
  for Index := 0 to ThreadCount - 1 do
  begin
    if (Reports[Index].ElfCounter = MainElfCounter) or (Reports[Index].PascalCounter = MainPascalCounter) then
      Distinct := False;
    for Other := Index + 1 to ThreadCount - 1 do
      if (Reports[Index].ElfCounter = Reports[Other].ElfCounter) or
         (Reports[Index].PascalCounter = Reports[Other].PascalCounter) then
        Distinct := False;
  end;
  Check(Distinct, 'every thread has its own copies');
end;

var
  Handles: array[0..ThreadCount - 1] of Int64;
  ElfLibrary: Int64;
  PascalLibrary: Int64;
  Index: Integer;
  ExitCode: LongInt;
  AllEnded: Boolean;
  MainElfCounter: PInt64;
  MainPascalCounter: PInt64;
begin
  InitializeLock(Gate);
  AcquireLock(Gate);
  for Index := 0 to EarlyThreadCount - 1 do
    Handles[Index] := StartThread(Index);

  ElfLibrary := LoadOrFail('libdyntls.so');
  PascalLibrary := LoadOrFail('libdynpascal.so');
  FindEntryPoints(ElfLibrary, PascalLibrary);

  Check(ElfInitializerCalls^ = 1, 'the ELF initializer ran once, before LoadLibrary returned');
  Check(PascalInitializations() = 1, 'the unit initialization ran once');
  Check(PascalMark() = LoaderMark, 'the loading thread keeps what the initialization set');

  MainElfCounter := ElfCounterAddress();
  MainPascalCounter := PascalCounterAddress();
  Check((ElfInitialAddress()^ = ElfInitialValue) and (MainElfCounter^ = 0), 'main thread: ELF TLS starts right');
  MainElfCounter^ := 77;
  MainPascalCounter^ := 88;

  ReleaseLock(Gate);
  for Index := EarlyThreadCount to ThreadCount - 1 do
    Handles[Index] := StartThread(Index);
  AllEnded := True;
  for Index := 0 to ThreadCount - 1 do
  begin
    if (Handles[Index] < 0) or (WaitForThread(Handles[Index], -1, ExitCode) < 0) or (ExitCode <> 0) then
      AllEnded := False;
    if Handles[Index] >= 0 then
      CloseThreadHandle(Handles[Index]);
  end;
  Check(AllEnded, 'the threads end');
  CheckReports(MainElfCounter, MainPascalCounter);
  Check((ElfCounterAddress()^ = 77) and (PascalCounterAddress()^ = 88) and (PascalMark() = LoaderMark),
    'main thread keeps its values');

  Check((LoadLibrary('libdyntls.so') = ElfLibrary) and (LoadLibrary('libdynpascal.so') = PascalLibrary),
    'loading again gives the same libraries');
  Check((ElfInitializerCalls^ = 1) and (PascalInitializations() = 1), 'initializers do not run again');

  PrintStringLine(Format('dynlibtest: %d checks, %d failed', [Checks, Failures]));
  FlushStandardStreams;
  if Failures > 0 then
    Halt(1);
end.
