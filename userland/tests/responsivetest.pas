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
  responsivetest - the system stays usable whatever one program does

  responsivetest

  What scripts/test-responsiveness.sh boots as the first program. With
  a program spinning 16 threads (burn) and another taking memory
  without end (memorytest hog), it checks:

  * priority classes: this program may make itself Interactive (it
    runs as root); a program it starts begins Normal; a program of its
    own may not raise itself above Normal;
  * latency: a loop sleeping 10 ms at a time sees bounded lateness,
    first alone (the baseline), then beside the busy program both in
    the Normal class (fair share and wake boosts must keep it close)
    and the Interactive class (strictly above the busy program);
  * memory: the kernel reports its commit policy and limits (by default
    overcommitment: one commitment bounded below the RAM, all of them
    above it; strict accounting under commitlimit=PERCENT: below the
    RAM); a commitment larger than the RAM is refused at once; the
    hog's allocations fail or it is ended (status 0 after "could not
    take more", 203 if its heap was refused, or 137 - when
    overcommitting, the out-of-memory policy ends it), while this
    program goes on measuring; the kernel counts what it refused or
    ended;
  * afterwards: a program still starts and ends, 32 MiB can still be
    taken and touched, free memory comes back;
  * jobs: a hog started in a job limited to 48 MiB beyond what is
    charged already is refused at that limit.

  Each check prints a line; "responsivetest: N of M checks passed" ends
  the run, and the exit status is 0 only if every check passed.
}
program responsivetest;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.Files,
  Sys.Memory,
  Sys.MemoryStatus,
  Sys.PriorityClasses,
  Sys.Jobs,
  Sys.Processes,
  Sys.Streams,
  Sys.Time;

const
  Mebibyte = QWord(1024) * 1024;
  PageBytes = 4096;
  SleepMillisecondsPerRound = 10;
  Rounds = 200;
  Millisecond = QWord(1000000);
  { Lateness allowed beyond the baseline: generous, for emulated
    processors. }
  NormalPercentileAllowance = 60 * Millisecond;
  NormalWorstAllowance = 600 * Millisecond;
  InteractivePercentileAllowance = 25 * Millisecond;
  InteractiveWorstAllowance = 250 * Millisecond;
  ExitStatusEndedForMemory = 137;
  { Run time error 203: the heap could not grow. }
  ExitStatusHeapRefused = 203;
  BusyThreads = 16;

type
  TLateness = record
    Percentile95: QWord;
    Worst: QWord;
  end;

var
  Checks: Integer = 0;
  Failures: Integer = 0;

procedure Check(Condition: Boolean; const What: string);
begin
  Inc(Checks);
  if Condition then
    PrintStringLine('responsivetest: ok   ' + What)
  else
  begin
    Inc(Failures);
    PrintStringLine('responsivetest: FAIL ' + What);
  end;
end;

function Milliseconds(Nanoseconds: QWord): string;
begin
  Result := Format('%d.%.1d ms', [Nanoseconds div Millisecond, (Nanoseconds mod Millisecond) div 100000]);
end;

{ Sleeps 10 ms Rounds times; how late each wake-up was. }
function MeasureLateness: TLateness;
var
  Late: array[0..Rounds - 1] of QWord;
  Round: Integer;
  Before: QWord;
  Elapsed: QWord;
  Wanted: QWord;
  Swapped: Boolean;
  Index: Integer;
  Temporary: QWord;
begin
  Wanted := SleepMillisecondsPerRound * Millisecond;
  for Round := 0 to Rounds - 1 do
  begin
    Before := MonotonicNanoseconds;
    SleepMilliseconds(SleepMillisecondsPerRound);
    Elapsed := MonotonicNanoseconds - Before;
    if Elapsed > Wanted then
      Late[Round] := Elapsed - Wanted
    else
      Late[Round] := 0;
  end;
  { Few enough to sort simply. }
  repeat
    Swapped := False;
    for Index := 0 to Rounds - 2 do
      if Late[Index] > Late[Index + 1] then
      begin
        Temporary := Late[Index];
        Late[Index] := Late[Index + 1];
        Late[Index + 1] := Temporary;
        Swapped := True;
      end;
  until not Swapped;
  Result.Percentile95 := Late[Rounds * 95 div 100];
  Result.Worst := Late[Rounds - 1];
end;

function Describe(const Lateness: TLateness): string;
begin
  Result := '95% within ' + Milliseconds(Lateness.Percentile95) + ', worst ' + Milliseconds(Lateness.Worst);
end;

function Start(const Path: string; const Arguments: array of string): Int64;
var
  Texts: array of string;
  Pointers: array of PChar;
  Index: Integer;
  Options: TProcessOptions;
begin
  SetLength(Texts, Length(Arguments) + 1);
  SetLength(Pointers, Length(Arguments) + 2);
  Texts[0] := Path;
  for Index := 0 to High(Arguments) do
    Texts[Index + 1] := Arguments[Index];
  for Index := 0 to High(Texts) do
    Pointers[Index] := PChar(Texts[Index]);
  Pointers[High(Pointers)] := nil;
  DefaultProcessOptions(Options);
  Result := StartProgram(PChar(Path), @Pointers[0], Options);
end;

{ The exit status, or -1 if it did not end within Seconds. }
function WaitForStatus(Handle: Int64; Seconds: QWord): LongInt;
var
  ExitCode: LongInt;
begin
  if WaitForProgramWithTimeout(Handle, Seconds * 1000, ExitCode) <> ErrorNone then
    Exit(-1);
  Result := ExitCode;
end;

procedure EndAndClose(Handle: Int64);
var
  ExitCode: LongInt;
begin
  if Handle < 0 then
    Exit;
  TerminateProgram(QWord(ProcessIdOf(Handle)), 143);
  WaitForProgramWithTimeout(Handle, 10000, ExitCode);
  CloseFile(Handle);
end;

{ --- Checks --------------------------------------------------------------- }

procedure CheckClasses;
var
  Child: Int64;
  ChildClass: LongInt;
begin
  Check(GetPriorityClass(0) = PriorityClassNormal, 'this program starts in the Normal class');
  Check(SetPriorityClass(0, PriorityClassBackground) = ErrorNone, 'it may go down to Background');
  Check(SetPriorityClass(0, PriorityClassNormal) = ErrorNone, 'and back to Normal');
  Check(SetPriorityClass(0, 9) <> ErrorNone, 'an unknown class is refused');
  Child := Start('/bin/burn', ['-s', '2']);
  Check(Child >= 0, 'started a short busy program');
  if Child >= 0 then
  begin
    SetPriorityClass(0, PriorityClassInteractive);
    ChildClass := GetPriorityClass(QWord(ProcessIdOf(Child)));
    Check(ChildClass = PriorityClassNormal, Format('it runs in the Normal class (%d)', [ChildClass]));
    Check(SetPriorityClass(QWord(ProcessIdOf(Child)), PriorityClassInteractive) = ErrorNone,
      'an Interactive process may lift it to its own class');
    Check(SetPriorityClass(QWord(ProcessIdOf(Child)), PriorityClassNormal) = ErrorNone, 'and put it back');
    WaitForStatus(Child, 20);
    CloseFile(Child);
  end;
  SetPriorityClass(0, PriorityClassNormal);
end;

procedure CheckMemoryHog(const Baseline: TLateness; Busy: Int64); forward;

procedure CheckLatency(out Baseline: TLateness);
var
  Busy: Int64;
  Normal: TLateness;
  Interactive: TLateness;
begin
  Baseline := MeasureLateness;
  PrintStringLine('responsivetest: alone, ' + Describe(Baseline));
  Busy := Start('/bin/burn', ['-t', IntToStr(BusyThreads)]);
  Check(Busy >= 0, Format('started a program spinning %d threads', [BusyThreads]));
  if Busy < 0 then
    Exit;
  { Its usage builds up and fair share takes hold. }
  SleepMilliseconds(1500);
  Normal := MeasureLateness;
  Check((Normal.Percentile95 <= Baseline.Percentile95 + NormalPercentileAllowance) and
    (Normal.Worst <= Baseline.Worst + NormalWorstAllowance),
    'in the Normal class beside it: ' + Describe(Normal));
  SetPriorityClass(0, PriorityClassInteractive);
  Interactive := MeasureLateness;
  Check((Interactive.Percentile95 <= Baseline.Percentile95 + InteractivePercentileAllowance) and
    (Interactive.Worst <= Baseline.Worst + InteractiveWorstAllowance),
    'in the Interactive class beside it: ' + Describe(Interactive));
  CheckMemoryHog(Baseline, Busy);
  EndAndClose(Busy);
end;

{ The limits the policy reports: overcommitting, one commitment is
  bounded below the RAM and all of them together above it; strictly,
  the limit is below the RAM (at the default 100%). }
procedure CheckCommitLimits(const Pressure: TMemoryPressure);
begin
  Check(Pressure.CommitLimitPages > 0, Format('there is a commit limit (%d MiB of %d MiB, policy %d)',
    [Pressure.CommitLimitPages * PageBytes div Mebibyte, Pressure.TotalPages * PageBytes div Mebibyte,
     Pressure.CommitPolicy]));
  case Pressure.CommitPolicy of
    AbiCommitPolicyOvercommit:
      begin
        Check((Pressure.LargestCommitPages > 0) and (Pressure.LargestCommitPages < Pressure.TotalPages),
          Format('overcommitting: one commitment up to %d MiB, below the RAM',
          [Pressure.LargestCommitPages * PageBytes div Mebibyte]));
        Check(Pressure.CommitLimitPages > Pressure.TotalPages, 'and all of them together beyond it');
      end;
    AbiCommitPolicyStrict:
      Check(Pressure.CommitLimitPages < Pressure.TotalPages, 'strict: below the RAM there is');
  else
    Check(False, 'a commit policy with a limit');
  end;
end;

{ A commitment larger than the RAM can never be backed: refused at once,
  and counted. }
procedure CheckOversizedCommitment(const Pressure: TMemoryPressure);
var
  Bytes: QWord;
  Reservation: Int64;
  After: TMemoryPressure;
begin
  Bytes := (Pressure.TotalPages + 1024) * PageBytes;
  Reservation := KernelReserveMemory(Bytes);
  Check(Reservation > 0, Format('reserved %d MiB (more than the RAM)', [Bytes div Mebibyte]));
  if Reservation <= 0 then
    Exit;
  Check(KernelCommitMemory(Pointer(PtrUInt(Reservation)), Bytes, MemoryReadWrite) = -ErrorOutOfMemory,
    'committing all of it is refused');
  Check((GetMemoryPressure(After) = ErrorNone) and (After.CommitFailures > Pressure.CommitFailures),
    'and the refusal is counted');
  KernelFreeMemory(Pointer(PtrUInt(Reservation)));
end;

procedure CheckMemoryHog(const Baseline: TLateness; Busy: Int64);
var
  Hog: Int64;
  Before: TMemoryPressure;
  After: TMemoryPressure;
  During: TLateness;
  Status: LongInt;
begin
  Check(GetMemoryPressure(Before) = ErrorNone, 'the kernel reports memory');
  CheckCommitLimits(Before);
  CheckOversizedCommitment(Before);
  GetMemoryPressure(Before);
  Hog := Start('/bin/memorytest', ['hog', '--step', '8', '--hold', '2']);
  Check(Hog >= 0, 'started a program taking memory without end');
  if Hog < 0 then
    Exit;
  { Measured while the hog grows (and the busy program spins). }
  During := MeasureLateness;
  Check((During.Percentile95 <= Baseline.Percentile95 + InteractivePercentileAllowance * 2) and
    (During.Worst <= Baseline.Worst + InteractiveWorstAllowance * 2),
    'Interactive beside both: ' + Describe(During));
  Status := WaitForStatus(Hog, 120);
  Check((Status = 0) or (Status = ExitStatusHeapRefused) or (Status = ExitStatusEndedForMemory),
    Format('the hog was refused (0, or 203 from its heap) or ended for memory (137): status %d', [Status]));
  CloseFile(Hog);
  Check(GetMemoryPressure(After) = ErrorNone, 'the kernel reports memory again');
  Check((After.CommitFailures > Before.CommitFailures) or (After.ProcessesEnded > Before.ProcessesEnded),
    Format('the kernel refused commitments (%d) or ended a process (%d)',
    [After.CommitFailures - Before.CommitFailures, After.ProcessesEnded - Before.ProcessesEnded]));
  Check(Busy >= 0, 'the busy program was still there');
end;

procedure CheckStillUsable;
var
  Handle: Int64;
  Block: PByte;
  Offset: QWord;
  Pressure: TMemoryPressure;
  Waited: Integer;
begin
  Handle := Start('/bin/true', []);
  Check((Handle >= 0) and (WaitForStatus(Handle, 20) = 0), 'a program still starts and ends');
  if Handle >= 0 then
    CloseFile(Handle);
  Block := PByte(AllocateMemory(32 * Mebibyte));
  Check(Block <> nil, '32 MiB can still be taken');
  if Block <> nil then
  begin
    Offset := 0;
    while Offset < 32 * Mebibyte do
    begin
      Block[Offset] := 1;
      Offset := Offset + PageBytes;
    end;
    FreeMemory(Block);
  end;
  Waited := 0;
  repeat
    GetMemoryPressure(Pressure);
    if Pressure.FreePages > Pressure.LowWatermarkPages then
      Break;
    SleepMilliseconds(250);
    Inc(Waited);
  until Waited >= 40;
  Check(Pressure.FreePages > Pressure.LowWatermarkPages,
    Format('free memory came back (%d MiB)', [Pressure.FreePages * PageBytes div Mebibyte]));
end;

procedure CheckJob;
var
  Job: Int64;
  Resources: TAbiProcessResources;
  Hog: Int64;
  Information: TJobInformation;
  LimitBytes: QWord;
  Status: LongInt;
begin
  Job := CreateJob;
  Check(Job >= 0, 'made a job');
  if Job < 0 then
    Exit;
  KernelGetProcessResources(0, Resources);
  LimitBytes := Resources.CommitChargePages * PageBytes + 48 * Mebibyte;
  Check(SetJobCommitLimit(Job, LimitBytes) = ErrorNone, 'limited it to 48 MiB beyond this program''s charge');
  Check(AssignProcessToJob(Job, CurrentProcessHandle) = ErrorNone, 'this program joined it');
  Check(AssignProcessToJob(Job, CurrentProcessHandle) = ErrorExists, 'a process joins a job only once');
  Hog := Start('/bin/memorytest', ['hog', '--step', '4', '--limit', '128', '--hold', '1']);
  Check(Hog >= 0, 'started a hog in the job');
  if Hog >= 0 then
  begin
    Status := WaitForStatus(Hog, 60);
    Check((Status = 0) or (Status = ExitStatusHeapRefused),
      Format('it was refused, not ended (status %d)', [Status]));
    CloseFile(Hog);
  end;
  Check(GetJobInformation(Job, Information) = ErrorNone, 'the job reports itself');
  Check(Information.CommitFailures > 0, Format('the job refused commitments (%d)', [Information.CommitFailures]));
  Check(Information.PeakCommitChargePages * PageBytes <= LimitBytes, 'it never went over its limit');
  Check(Information.TotalProcesses >= 2, Format('the hog was in it too (%d processes)',
    [Information.TotalProcesses]));
  CloseFile(Job);
end;

var
  Baseline: TLateness;
begin
  CheckClasses;
  CheckLatency(Baseline);
  SetPriorityClass(0, PriorityClassNormal);
  CheckStillUsable;
  CheckJob;
  PrintStringLine(Format('responsivetest: %d of %d checks passed', [Checks - Failures, Checks]));
  if Failures > 0 then
    Halt(1);
  Halt(0);
end.
