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
  burn - keep processors busy, for trying out the task manager and top

  burn [-t THREADS] [-s SECONDS] [-m MEBIBYTES] [-i]

  Spins THREADS threads (one by default) for SECONDS (for ever without
  -s), after taking MEBIBYTES of memory and touching every page of it.
  With -i it takes requests to end and ignores them, so asking it to
  end does nothing and only ending it outright stops it (a program that
  does not respond). Prints "burn: ready PID" once it runs.
}
program burn;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Memory,
  Sys.Notifications,
  Sys.Processes,
  Sys.Streams,
  Sys.Threads,
  Sys.Time,
  Util.CommandLine,
  Util.Messages,
  Util.Numbers;

const
  Usage = 'Usage: burn [-t THREADS] [-s SECONDS] [-m MEBIBYTES] [-i]'#10 +
    'Keep THREADS threads busy for SECONDS (for ever), after taking and touching'#10 +
    'MEBIBYTES of memory. -i: ignore requests to end.'#10;

  OptionThreads = 1;
  OptionSeconds = 2;
  OptionMemory = 3;
  OptionIgnore = 4;

  MaximumThreads = 64;
  PageBytes = 4096;

var
  { Milliseconds since the system started at which the threads stop;
    zero for never. }
  StopAt: QWord;

{ Spins until StopAt; the sum keeps the loop from being optimized away. }
function Spin(Argument: Pointer): LongInt;
var
  Sum: QWord;
  Round: LongInt;
begin
  Sum := 0;
  repeat
    for Round := 1 to 100000 do
      Sum := Sum * 31 + QWord(Round);
  until (StopAt <> 0) and (UptimeMilliseconds >= StopAt);
  Result := LongInt(Sum and 1);
end;

{ Takes Mebibytes of memory and writes to every page, so it is all
  resident. The memory is kept until the program ends. }
procedure TakeMemory(Mebibytes: QWord);
var
  Block: PByte;
  Offset: QWord;
  Length: QWord;
begin
  if Mebibytes = 0 then
    Exit;
  Length := Mebibytes * 1024 * 1024;
  Block := PByte(AllocateMemory(Length));
  if Block = nil then
    Fail(1, Format('cannot take %u MiB', [Mebibytes]));
  Offset := 0;
  while Offset < Length do
  begin
    Block[Offset] := 1;
    Offset := Offset + PageBytes;
  end;
end;

function ParseCount(const Value, What: string): QWord;
begin
  if not ParseUnsignedDecimal(Value, Result) then
    FailWithUsageHint(Format('invalid %s ''%s''', [What, Value]));
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  ThreadCount: QWord;
  Seconds: QWord;
  Mebibytes: QWord;
  IgnoreEndRequests: Boolean;
  Handles: array of Int64;
  Index: Integer;
  ExitCode: LongInt;
begin
  ThreadCount := 1;
  Seconds := 0;
  Mebibytes := 0;
  IgnoreEndRequests := False;
  CommandLine := TCommandLine.Create([
    CommandOption('t', 'threads', True, OptionThreads),
    CommandOption('s', 'seconds', True, OptionSeconds),
    CommandOption('m', 'memory', True, OptionMemory),
    CommandOption('i', 'ignore-end', False, OptionIgnore)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionThreads: ThreadCount := ParseCount(Value, 'number of threads');
      OptionSeconds: Seconds := ParseCount(Value, 'number of seconds');
      OptionMemory: Mebibytes := ParseCount(Value, 'size');
      OptionIgnore: IgnoreEndRequests := True;
    end;
  if (ThreadCount = 0) or (ThreadCount > MaximumThreads) then
    FailWithUsageHint(Format('the number of threads must be 1 to %d', [MaximumThreads]));
  { Taken but never read: the system leaves such a request to the
    program, which does nothing about it. }
  if IgnoreEndRequests then
    TakeNotifications(NotifyEndRequests);
  TakeMemory(Mebibytes);
  StopAt := 0;
  if Seconds > 0 then
    StopAt := UptimeMilliseconds + Seconds * 1000;
  PrintString(Format('burn: ready %d'#10, [CurrentProcessId]));
  FlushStream(StandardOutput);
  Handles := nil;
  SetLength(Handles, ThreadCount);
  for Index := 1 to High(Handles) do
    Handles[Index] := CreateThread(@Spin, nil);
  Spin(nil);
  for Index := 1 to High(Handles) do
    if Handles[Index] >= 0 then
    begin
      WaitForThread(Handles[Index], InfiniteWait, ExitCode);
      CloseThreadHandle(Handles[Index]);
    end;
end.
