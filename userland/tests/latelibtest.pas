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
  latelibtest - libraries loaded late: the static TLS surplus, resource
  strings of Free Pascal libraries, relocated copies kept per load
  address

    latelibtest           the checks below
    latelibtest --child   loads libdynpascal.so, writes where its
                          greeting function is to the file named by
                          the next argument, exits 0 if it works

  1. Starts threads that wait, then loads libstatictls.so, whose TLS is
     reached with the initial exec model (TPOFF relocations): it must
     load (into the static surplus), and every thread - started before
     the load, after it, and the main thread - has its own block, with
     the image's 4321 and a zero, at a fixed distance from its thread
     pointer, keeping what it writes there.
  2. Loads libdynpascal.so: its resource string reads as compiled; after
     SetResourceStrings translates it, the library's string and the
     constant initialized with it read the translation.
  3. Runs "latelibtest --child" twice: the loader's statistics
     (CallGetImageCacheStatistics) must show relocated copies reused,
     and both children find the library's function at the same address
     (libraries keep their place, unless aslr=process or aslr=off).

  Prints "ok NAME" or "FAIL NAME" per check and "latelibtest: N checks,
  F failed" at the end; exits with 1 if a check failed.
}
program latelibtest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Classes,
  Sys.Streams,
  Sys.Threads,
  Sys.Locks,
  Sys.Libraries,
  Sys.Processes,
  Sys.MemoryStatus,
  Sys.KernelOptions,
  Sys.Files;

const
  EarlyThreadCount = 2;
  LateThreadCount = 2;
  ThreadCount = EarlyThreadCount + LateThreadCount;
  StaticInitialValue = 4321;
  CompiledGreeting = 'hello from libdynpascal';
  TranslatedGreeting = 'hallo aus libdynpascal';

type
  TAddressFunction = function: PInt64; cdecl;
  TTextFunction = function: PChar;

  TThreadReport = record
    Index: Integer;
    InitialSeen: Int64;
    CounterSeen: Int64;
    Counter: PInt64;
    Kept: Boolean;
  end;
  PThreadReport = ^TThreadReport;

var
  Checks: Integer = 0;
  Failures: Integer = 0;
  Gate: TLock;
  EndGate: TLock;
  ReportedCount: LongInt = 0;
  InitialAddress: TAddressFunction;
  CounterAddress: TAddressFunction;
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

procedure Finish;
begin
  PrintStringLine(Format('latelibtest: %d checks, %d failed', [Checks, Failures]));
  FlushStandardStreams;
  if Failures > 0 then
    Halt(1);
  Halt(0);
end;

{ --- 1. The static TLS surplus -------------------------------------------- }

function RunThread(Argument: Pointer): LongInt;
var
  Report: PThreadReport;
begin
  Report := PThreadReport(Argument);
  AcquireLock(Gate);
  ReleaseLock(Gate);
  Report^.Counter := CounterAddress();
  Report^.InitialSeen := InitialAddress()^;
  Report^.CounterSeen := Report^.Counter^;
  Report^.Counter^ := 1000 + Report^.Index;
  InitialAddress()^ := 2000 + Report^.Index;
  YieldThread;
  Report^.Kept := (CounterAddress()^ = 1000 + Report^.Index) and (InitialAddress()^ = 2000 + Report^.Index);
  AtomicAdd32(ReportedCount, 1);
  AcquireLock(EndGate);
  ReleaseLock(EndGate);
  Result := 0;
end;

function StartThread(Index: Integer): Int64;
begin
  Reports[Index].Index := Index;
  Result := CreateThread(@RunThread, @Reports[Index]);
  Check(Result >= 0, Format('thread %d starts', [Index]));
end;

procedure TestStaticSurplus;
var
  Handles: array[0..ThreadCount - 1] of Int64;
  StaticLibrary: Int64;
  Index: Integer;
  Other: Integer;
  ExitCode: LongInt;
  Started: LongInt;
  Distinct: Boolean;
  MainCounter: PInt64;
begin
  InitializeLock(Gate);
  InitializeLock(EndGate);
  AcquireLock(Gate);
  AcquireLock(EndGate);
  for Index := 0 to EarlyThreadCount - 1 do
    Handles[Index] := StartThread(Index);

  StaticLibrary := LoadLibrary('libstatictls.so');
  Check(StaticLibrary >= 0, 'a library with initial exec TLS loads after threads started');
  if StaticLibrary < 0 then
  begin
    ReleaseLock(Gate);
    ReleaseLock(EndGate);
    Exit;
  end;
  InitialAddress := TAddressFunction(FindSymbol(StaticLibrary, 'statictls_initial_address'));
  CounterAddress := TAddressFunction(FindSymbol(StaticLibrary, 'statictls_counter_address'));
  Check(Assigned(InitialAddress) and Assigned(CounterAddress), 'libstatictls entry points found');
  if not Assigned(InitialAddress) or not Assigned(CounterAddress) then
    Finish;

  MainCounter := CounterAddress();
  Check((InitialAddress()^ = StaticInitialValue) and (MainCounter^ = 0), 'main thread: the block starts right');
  Check((PtrUInt(MainCounter) and 63) = 0, 'the block keeps its 64-byte alignment');
  MainCounter^ := 99;

  ReleaseLock(Gate);
  for Index := EarlyThreadCount to ThreadCount - 1 do
    Handles[Index] := StartThread(Index);
  Started := 0;
  for Index := 0 to ThreadCount - 1 do
    if Handles[Index] >= 0 then
      Inc(Started);
  while ReportedCount < Started do
    YieldThread;
  Distinct := True;
  for Index := 0 to ThreadCount - 1 do
  begin
    Check(Reports[Index].InitialSeen = StaticInitialValue,
      Format('thread %d: the block starts from the image', [Index]));
    Check(Reports[Index].CounterSeen = 0, Format('thread %d: the block starts zeroed', [Index]));
    Check(Reports[Index].Kept, Format('thread %d: the block keeps its values', [Index]));
    if Reports[Index].Counter = MainCounter then
      Distinct := False;
    for Other := Index + 1 to ThreadCount - 1 do
      if Reports[Index].Counter = Reports[Other].Counter then
        Distinct := False;
  end;
  Check(Distinct, 'every thread has its own block');
  ReleaseLock(EndGate);
  for Index := 0 to ThreadCount - 1 do
    if Handles[Index] >= 0 then
    begin
      WaitForThread(Handles[Index], -1, ExitCode);
      CloseThreadHandle(Handles[Index]);
    end;
  Check(MainCounter^ = 99, 'main thread keeps its value');
end;

{ --- 2. Resource strings -------------------------------------------------- }

function Translate(Name, Value: AnsiString; Hash: LongInt; Argument: Pointer): AnsiString;
begin
  if LowerCase(Name) = 'dynpascalstate.sdynpascalgreeting' then
    Result := TranslatedGreeting
  else
    Result := '';
end;

procedure TestResourceStrings;
var
  PascalLibrary: Int64;
  Greeting: TTextFunction;
  GreetingCopy: TTextFunction;
begin
  PascalLibrary := LoadLibrary('libdynpascal.so');
  Check(PascalLibrary >= 0, 'LoadLibrary libdynpascal.so');
  if PascalLibrary < 0 then
    Exit;
  Greeting := TTextFunction(FindSymbol(PascalLibrary, 'dynpascal_greeting'));
  GreetingCopy := TTextFunction(FindSymbol(PascalLibrary, 'dynpascal_greeting_copy'));
  Check(Assigned(Greeting) and Assigned(GreetingCopy), 'libdynpascal greeting functions found');
  if not Assigned(Greeting) or not Assigned(GreetingCopy) then
    Exit;
  Check(string(Greeting()) = CompiledGreeting, 'the library''s resource string reads as compiled: ' +
    string(Greeting()));
  Check(string(GreetingCopy()) = CompiledGreeting, 'and the constant made from it');
  SetResourceStrings(@Translate, nil);
  Check(string(Greeting()) = TranslatedGreeting, 'a translation reaches the library''s resource string: ' +
    string(Greeting()));
  Check(string(GreetingCopy()) = TranslatedGreeting, 'and the constant made from it: ' + string(GreetingCopy()));
end;

{ --- 3. Relocated copies -------------------------------------------------- }

function RunChild(const ReportFile: string): Boolean;
var
  Arguments: array[0..3] of PChar;
  Options: TProcessOptions;
  Handle: Int64;
  ExitCode: LongInt;
begin
  Arguments[0] := 'latelibtest';
  Arguments[1] := '--child';
  Arguments[2] := PChar(ReportFile);
  Arguments[3] := nil;
  DefaultProcessOptions(Options);
  Handle := StartProgram('/bin/latelibtest', @Arguments[0], Options);
  Result := False;
  if Handle < 0 then
    Exit;
  Result := (WaitForProgramWithTimeout(Handle, 60000, ExitCode) = 0) and (ExitCode = 0);
  CloseFile(Handle);
end;

function ReadReport(const ReportFile: string): string;
var
  Lines: TStringList;
begin
  Result := '';
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(ReportFile);
      if Lines.Count > 0 then
        Result := Lines[0];
    except
      on EStreamError do
        Result := '';
    end;
  finally
    Lines.Free;
  end;
end;

procedure TestRelocatedCopies;
var
  Before: TImageCacheStatistics;
  After: TImageCacheStatistics;
  First: string;
  Second: string;
  Placement: string;
  Shared: Boolean;
begin
  Shared := not (GetKernelOption('aslr', Placement) and ((Placement = 'process') or (Placement = 'off')));
  Check(GetImageCacheStatistics(Before) = 0, 'the loader''s statistics can be read');
  Check(RunChild('/tmp/latelib-child1.txt'), 'a child loads libdynpascal.so and calls it');
  Check(RunChild('/tmp/latelib-child2.txt'), 'and a second child');
  GetImageCacheStatistics(After);
  First := ReadReport('/tmp/latelib-child1.txt');
  Second := ReadReport('/tmp/latelib-child2.txt');
  DeleteFile('/tmp/latelib-child1.txt');
  DeleteFile('/tmp/latelib-child2.txt');
  Check(After.CachedSections > 0, Format('image sections are kept (%d)', [After.CachedSections]));
  if not Shared then
  begin
    PrintStringLine('latelibtest: aslr=' + Placement + ', libraries are not placed alike');
    Exit;
  end;
  Check(After.RelocationsReused >= Before.RelocationsReused + 2,
    Format('the children''s libraries came from relocated copies (%d -> %d reused)',
      [Before.RelocationsReused, After.RelocationsReused]));
  Check(After.SharedPlacements >= Before.SharedPlacements + 2,
    Format('the libraries kept their place (%d -> %d)', [Before.SharedPlacements, After.SharedPlacements]));
  Check(After.RelocatedCopies > 0, Format('relocated copies are kept (%d, %d pages)',
    [After.RelocatedCopies, After.RelocatedPages]));
  Check((First <> '') and (First = Second), 'both children found the library at the same place (' + First +
    ', ' + Second + ')');
end;

{ The child: loads libdynpascal.so and reports where it is. }
procedure RunAsChild(const ReportFile: string);
var
  PascalLibrary: Int64;
  Greeting: TTextFunction;
  Lines: TStringList;
begin
  PascalLibrary := LoadLibrary('libdynpascal.so');
  if PascalLibrary < 0 then
    Halt(2);
  Greeting := TTextFunction(FindSymbol(PascalLibrary, 'dynpascal_greeting'));
  if not Assigned(Greeting) or (string(Greeting()) <> CompiledGreeting) then
    Halt(3);
  Lines := TStringList.Create;
  try
    Lines.Add(IntToHex(PtrUInt(Pointer(Greeting)), 16));
    Lines.SaveToFile(ReportFile);
  finally
    Lines.Free;
  end;
  Halt(0);
end;

begin
  if (ParamCount = 2) and (ParamStr(1) = '--child') then
    RunAsChild(ParamStr(2));
  TestStaticSurplus;
  TestResourceStrings;
  TestRelocatedCopies;
  Finish;
end.
