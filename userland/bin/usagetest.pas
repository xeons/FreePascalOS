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
  usagetest - tests of the kernel's processor time and memory accounting

  Run by coretest. Checks, on itself and on programs it starts, that:

    * a busy loop is charged processor time close to the time it ran
      (most of it in user mode), and the processors' busy time grows
      with it; a sleeping program is charged next to nothing,
    * threads that ended leave their time in the process's total, and
      the thread count follows them,
    * memory taken from the kernel and touched shows in the resident and
      private figures, and goes again when freed, the peak staying,
    * each processor's busy and idle time add up to the time it ran,
      and the memory figures to no more than the RAM there is,
    * a list given too little room says how many processes there are
      and fills only what fits.

  The bounds are generous, as an emulated machine (TCG) on a busy host
  may give a thread far less than the wall time; they compare the times
  with each other rather than with fixed values. Prints a line per
  check and "usagetest: N of M checks passed".
}
program usagetest;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Sys.Format,
  Sys.Environment,
  Sys.Processes,
  Sys.ProcessList,
  Sys.Streams,
  Sys.SystemUsage,
  Sys.Kernel,
  Sys.Threads,
  Sys.Time;

const
  NanosecondsPerMillisecond = 1000000;
  Mebibyte = 1024 * 1024;
  { How long the busy loops run. }
  SpinMilliseconds = 1000;
  ThreadSpinMilliseconds = 500;
  { The memory taken and touched. }
  TakenMebibytes = 16;

var
  Checks: LongInt;
  Failures: LongInt;

procedure Check(Name: PChar; Passed: Boolean);
begin
  Inc(Checks);
  if Passed then
    WriteFormatted(StandardOutput, 'usagetest: pass: %s'#10, [ArgumentText(Name)])
  else
  begin
    WriteFormatted(StandardOutput, 'usagetest: FAIL: %s'#10, [ArgumentText(Name)]);
    Inc(Failures);
  end;
end;

{ What was measured, for a check that failed. }
procedure Report(Name: PChar; Value: QWord);
begin
  WriteFormatted(StandardOutput, 'usagetest:   %s = %u'#10, [ArgumentText(Name), ArgumentUnsigned(Value)]);
end;

function OwnDetails(out Details: TProcessDetails): Boolean;
begin
  Result := GetProcessDetails(QWord(CurrentProcessId), Details);
end;

{ Spins until Milliseconds have passed by the clock. }
procedure SpinFor(Milliseconds: QWord);
var
  Deadline: QWord;
  Sum: QWord;
  Round: LongInt;
begin
  Deadline := UptimeMilliseconds + Milliseconds;
  Sum := 0;
  repeat
    for Round := 1 to 10000 do
      Sum := Sum * 31 + QWord(Round);
  until UptimeMilliseconds >= Deadline;
  { Keeps the loop from being optimized away. }
  if Sum = 1 then
    WriteStringLine(StandardOutput, '');
end;

function SpinningThread(Argument: Pointer): LongInt;
begin
  SpinFor(ThreadSpinMilliseconds);
  Result := 0;
end;

function TotalBusy(const Usage: TSystemUsage): QWord;
var
  Index: LongInt;
begin
  Result := 0;
  for Index := 0 to AbiMaximumProcessors - 1 do
    Result := Result + Usage.Processors[Index].BusyNanoseconds;
end;

procedure TestSystemUsage;
var
  Usage: TSystemUsage;
  Index: LongWord;
  Online: Boolean;
  Covered: Boolean;
  Accounted: QWord;
  Ran: QWord;
begin
  Check('the system usage is given', GetSystemUsage(Usage) = ErrorNone);
  Check('processors, processes and threads are counted',
    (OnlineProcessors(Usage) >= 1) and (Usage.ProcessCount >= 2) and (Usage.ThreadCount > Usage.ProcessCount));
  { A processor started a little after the system did; each runs its
    threads or its idle thread all the time it runs. }
  Online := True;
  Covered := True;
  for Index := 0 to Usage.ProcessorCount - 1 do
  begin
    if Usage.Processors[Index].Online = 0 then
      Online := False;
    Ran := Usage.Processors[Index].BusyNanoseconds + Usage.Processors[Index].IdleNanoseconds;
    if (Ran > Usage.UptimeNanoseconds) or (Ran < Usage.UptimeNanoseconds div 2) then
    begin
      Covered := False;
      Report('processor', Index);
      Report('busy and idle', Ran);
      Report('uptime', Usage.UptimeNanoseconds);
    end;
  end;
  Check('every processor started runs', Online);
  Check('each processor''s busy and idle time add up to the time it ran', Covered);
  Accounted := Usage.FreeMemory + Usage.UserMemory + Usage.ProgramImageMemory + Usage.SectionMemory +
    Usage.BlockCacheMemory + Usage.KernelHeapMemory + Usage.KernelStackMemory + Usage.PageTableMemory +
    Usage.KernelImageMemory + Usage.DriverMemory;
  Check('the memory figures add up to the RAM there is',
    (Accounted <= Usage.TotalMemory) and (Accounted >= Usage.TotalMemory div 10 * 9) and
    (Usage.UserMemory > 0) and (Usage.ProgramImageMemory > 0) and (Usage.KernelHeapMemory > 0) and
    (Usage.PageTableMemory > 0));
  if Accounted > Usage.TotalMemory then
    Report('accounted', Accounted);
end;

procedure TestOwnDetails;
var
  Details: TProcessDetails;
begin
  Check('its own details are found', OwnDetails(Details));
  Check('its name, command line and state',
    TextIsEqual(@Details.Name[0], 'usagetest') and TextIsEqual(@Details.CommandLine[0], 'usagetest --own-details') and
    (Details.State = ProcessStateRunning) and (Details.ThreadCount = 1));
  Check('its handles and priority', (Details.HandleCount >= 3) and (Details.Priority = 8) and (Details.Nice = 0));
  Check('its memory: resident, shared and private',
    (Details.ResidentBytes > 0) and (Details.SharedBytes > 0) and (Details.PrivateBytes > 0) and
    (Details.SharedBytes + Details.PrivateBytes = Details.ResidentBytes) and
    (Details.VirtualBytes >= Details.ResidentBytes) and (Details.PeakResidentBytes >= Details.ResidentBytes));
end;

procedure TestBusyLoop;
var
  Before: TProcessDetails;
  After: TProcessDetails;
  UsageBefore: TSystemUsage;
  UsageAfter: TSystemUsage;
  WallBefore: QWord;
  Wall: QWord;
  Charged: QWord;
  UserCharged: QWord;
  BusyAdded: QWord;
begin
  OwnDetails(Before);
  GetSystemUsage(UsageBefore);
  WallBefore := UptimeMilliseconds;
  SpinFor(SpinMilliseconds);
  Wall := (UptimeMilliseconds - WallBefore) * NanosecondsPerMillisecond;
  OwnDetails(After);
  GetSystemUsage(UsageAfter);
  Charged := After.ProcessorNanoseconds - Before.ProcessorNanoseconds;
  UserCharged := After.UserNanoseconds - Before.UserNanoseconds;
  BusyAdded := TotalBusy(UsageAfter) - TotalBusy(UsageBefore);
  { At most the wall time (plus the clock's last millisecond), and on a
    machine giving it its processor most of it. }
  Check('a busy loop is charged about the time it ran', (Charged <= Wall + 2 * NanosecondsPerMillisecond) and
    (Charged >= Wall div 5 * 2));
  Check('most of a busy loop''s time is in user mode', UserCharged >= Charged div 2);
  Check('the processors'' busy time grows with a busy loop', BusyAdded >= Charged div 10 * 9);
  if (Charged > Wall + 2 * NanosecondsPerMillisecond) or (Charged < Wall div 5 * 2) or (UserCharged < Charged div 2) then
  begin
    Report('wall', Wall);
    Report('charged', Charged);
    Report('user', UserCharged);
  end;
end;

procedure TestSleepingProgram;
var
  Arguments: array[0..2] of PChar;
  Options: TProcessOptions;
  Process: Int64;
  Details: TProcessDetails;
  Later: TProcessDetails;
  Found: Boolean;
  Added: QWord;
begin
  Arguments[0] := 'sleep';
  Arguments[1] := '5';
  Arguments[2] := nil;
  DefaultProcessOptions(Options);
  Process := StartProgram('/bin/sleep', @Arguments[0], Options);
  Check('a sleeping program starts', Process >= 0);
  if Process < 0 then
    Exit;
  { Its start (loading, the runtime) costs something, more on an
    emulated machine; what it is charged while it sleeps must be next
    to nothing. }
  SleepMilliseconds(1500);
  Found := GetProcessDetails(QWord(ProcessIdOf(Process)), Details);
  SleepMilliseconds(1000);
  Found := Found and GetProcessDetails(QWord(ProcessIdOf(Process)), Later);
  Added := 0;
  if Found then
    Added := Later.ProcessorNanoseconds - Details.ProcessorNanoseconds;
  Check('a sleeping program is charged next to nothing', Found and (Added < 20 * QWord(NanosecondsPerMillisecond)));
  Check('a sleeping program waits, its command line is known', Found and (Later.State = ProcessStateSleeping) and
    TextIsEqual(@Later.CommandLine[0], 'sleep 5') and (Later.ParentProcessId = QWord(CurrentProcessId)));
  if Found and (Added >= 20 * QWord(NanosecondsPerMillisecond)) then
    Report('charged while asleep', Added);
  TerminateProgram(QWord(ProcessIdOf(Process)), 143);
  WaitForProgram(Process);
end;

procedure TestEndedThreads;
var
  Handles: array[0..1] of Int64;
  Index: LongInt;
  ExitCode: LongInt;
  Before: TProcessDetails;
  During: TProcessDetails;
  After: TProcessDetails;
  Added: QWord;
begin
  OwnDetails(Before);
  for Index := 0 to 1 do
    Handles[Index] := CreateThread(@SpinningThread, nil);
  SleepMilliseconds(100);
  OwnDetails(During);
  for Index := 0 to 1 do
  begin
    WaitForThread(Handles[Index], InfiniteWait, ExitCode);
    CloseThreadHandle(Handles[Index]);
  end;
  { The threads' objects go once they are reaped; their time must stay
    either way. }
  SleepMilliseconds(200);
  OwnDetails(After);
  Added := After.ProcessorNanoseconds - Before.ProcessorNanoseconds;
  Check('the thread count follows the threads', (During.ThreadCount = 3) and (After.ThreadCount = 1));
  Check('ended threads leave their time in the process''s total',
    Added >= 2 * ThreadSpinMilliseconds * QWord(NanosecondsPerMillisecond) div 5);
  if Added < 2 * ThreadSpinMilliseconds * QWord(NanosecondsPerMillisecond) div 5 then
    Report('added', Added);
end;

procedure TestMemory;
var
  Before: TProcessDetails;
  Taken: TProcessDetails;
  Freed: TProcessDetails;
  Address: Int64;
  Block: PByte;
  Offset: QWord;
  Length: QWord;
  Grown: QWord;
begin
  OwnDetails(Before);
  Length := TakenMebibytes * Mebibyte;
  { Straight from the kernel: the heap might keep a freed block (in its
    quarantine, with heap checks on), and it is the kernel's figures
    that are tested. }
  Address := KernelAllocateMemory(Length);
  Check('memory is taken', Address > 0);
  if Address <= 0 then
    Exit;
  Block := PByte(Address);
  Offset := 0;
  while Offset < Length do
  begin
    Block[Offset] := 1;
    Offset := Offset + 4096;
  end;
  OwnDetails(Taken);
  KernelFreeMemory(Block);
  OwnDetails(Freed);
  Grown := Taken.ResidentBytes - Before.ResidentBytes;
  Check('memory taken and touched is resident and private',
    (Grown >= Length) and (Grown <= Length + 2 * Mebibyte) and
    (Taken.PrivateBytes - Before.PrivateBytes >= Length) and (Taken.VirtualBytes >= Before.VirtualBytes + Length));
  { (Looking takes a little heap memory of its own.) }
  Check('memory freed goes, the peak stays', (Freed.ResidentBytes + Length <= Taken.ResidentBytes + Mebibyte) and
    (Freed.PeakResidentBytes >= Taken.ResidentBytes));
  if (Grown < Length) or (Grown > Length + 2 * Mebibyte) then
    Report('grown', Grown);
end;

procedure TestShortList;
var
  Entries: array[0..1] of TProcessDetails;
  Total: Int64;
begin
  FillMemory(@Entries, SizeOf(Entries), $5A);
  Total := KernelListProcessDetails(@Entries[0], 1);
  Check('a list given room for one says how many there are and fills one',
    (Total >= 2) and (Entries[0].ProcessId <> $5A5A5A5A5A5A5A5A) and (Entries[1].ProcessId = $5A5A5A5A5A5A5A5A));
end;

begin
  Checks := 0;
  Failures := 0;
  if TextIsEqual(Argument(1), '--own-details') then
  begin
    TestOwnDetails;
    TestSystemUsage;
    TestBusyLoop;
    TestSleepingProgram;
    TestEndedThreads;
    TestMemory;
    TestShortList;
  end
  else
    WriteStringLine(StandardOutput, 'usagetest: run as "usagetest --own-details" (its command line is checked)');
  WriteFormatted(StandardOutput, 'usagetest: %d of %d checks passed'#10, [ArgumentNumber(Checks - Failures),
    ArgumentNumber(Checks)]);
  if (Failures > 0) or (Checks = 0) then
    Halt(1);
end.
